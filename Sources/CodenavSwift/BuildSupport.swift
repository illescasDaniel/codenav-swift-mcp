import Foundation
import NavShared

// Tier 2 of the compile check: the real compiler. sourcekit-lsp can't see an in-memory change across
// module boundaries, so files that depend on a changed module are checked by building the package.

// MARK: - Package graph

/// The targets of a SwiftPM package and what depends on what, from `swift package describe`.
struct PackageGraph: Sendable {
	struct Target: Sendable, Equatable {
		var name: String
		/// Absolute directory of the target's sources.
		var directory: String
		var dependencies: [String]
		/// Absolute paths of the target's source files.
		var sources: [String] = []
	}

	var targets: [Target]

	/// The target whose directory contains `path`.
	func target(ofPath path: String) -> Target? {
		targets.filter { path == $0.directory || path.hasPrefix($0.directory + "/") }.max { $0.directory.count < $1.directory.count }
	}

	/// Every target `name` depends on, directly or not.
	func upstream(of name: String) -> Set<String> {
		var result: Set<String> = []
		var queue = [name]
		while let current = queue.popLast() {
			for dependency in targets.first(where: { $0.name == current })?.dependencies ?? [] where result.insert(dependency).inserted {
				queue.append(dependency)
			}
		}
		return result
	}

	static func parse(json: Data, root: URL) -> PackageGraph? {
		guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
			let rawTargets = object["targets"] as? [[String: Any]]
		else { return nil }
		let base = root.realPath.path
		let targets = rawTargets.compactMap { raw -> Target? in
			guard let name = raw["name"] as? String, let path = raw["path"] as? String else { return nil }
			let directory = (path.hasPrefix("/") ? path : base + "/" + path)
			let folder = URL(fileURLWithPath: directory).standardizedFileURL.path
			return Target(
				name: name, directory: folder, dependencies: (raw["target_dependencies"] as? [String]) ?? [],
				sources: ((raw["sources"] as? [String]) ?? []).map { folder + "/" + $0 })
		}
		return targets.isEmpty ? nil : PackageGraph(targets: targets)
	}
}

// MARK: - Running tools

struct ProcessOutput: Sendable {
	var status: Int32
	var stdout: String
	var stderr: String
	var timedOut: Bool
	var seconds: Double

	var combined: String { stdout + (stdout.isEmpty || stderr.isEmpty ? "" : "\n") + stderr }
}

enum ToolProcess {
	/// Runs a program and collects its output, killing it after `timeout`.
	static func run(
		_ executable: String, arguments: [String], directory: URL, environment: [String: String]? = nil, timeout: TimeInterval
	) async -> ProcessOutput {
		let started = Date()
		let process = Process()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments
		process.currentDirectoryURL = directory
		if let environment { process.environment = environment }
		let out = Pipe()
		let err = Pipe()
		process.standardOutput = out
		process.standardError = err
		process.standardInput = FileHandle.nullDevice
		final class Box: @unchecked Sendable {
			let lock = NSLock()
			var out = Data()
			var err = Data()
			var timedOut = false
			var closedPipes = 0
		}
		let box = Box()
		func stream(_ pipe: Pipe, into append: @escaping @Sendable (Box, Data) -> Void) {
			pipe.fileHandleForReading.readabilityHandler = { handle in
				let data = handle.availableData
				if data.isEmpty {
					handle.readabilityHandler = nil  // end of file
					box.lock.withLock { box.closedPipes += 1 }
				} else {
					box.lock.withLock { append(box, data) }
				}
			}
		}
		stream(out) { $0.out.append($1) }
		stream(err) { $0.err.append($1) }
		/// `Process` is thread-safe for what is done with it here (`isRunning`, `terminate`, the pid).
		final class SharedProcess: @unchecked Sendable {
			let process: Process
			init(_ process: Process) { self.process = process }
		}
		let shared = SharedProcess(process)
		let launchError: Error? = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
			process.terminationHandler = { _ in continuation.resume(returning: nil) }
			do {
				try process.run()
			} catch {
				continuation.resume(returning: error)  // never started: the termination handler won't fire
				return
			}
			Task.detached {
				try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
				guard !Task.isCancelled, shared.process.isRunning else { return }
				box.lock.withLock { box.timedOut = true }
				// A build is a tree of processes. Killing only the top one leaves the compilers running (and, on
				// Linux, Foundation doesn't report the exit until they let go of the pipes).
				for child in Self.descendants(of: shared.process.processIdentifier).reversed() { kill(child, SIGKILL) }
				shared.process.terminate()
				try? await Task.sleep(nanoseconds: 1_000_000_000)
				if shared.process.isRunning { kill(shared.process.processIdentifier, SIGKILL) }
			}
		}
		if let launchError {
			return ProcessOutput(status: -1, stdout: "", stderr: "could not run \(executable): \(launchError.localizedDescription)", timedOut: false, seconds: 0)
		}
		// The output is complete once both pipes reach end of file. A killed tool's children can keep a pipe
		// open for a long time, so don't wait for them: take what has arrived.
		let deadline = Date().addingTimeInterval(1.5)
		while Date() < deadline, box.lock.withLock({ box.closedPipes }) < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
		out.fileHandleForReading.readabilityHandler = nil
		err.fileHandleForReading.readabilityHandler = nil
		let collected = box.lock.withLock { (out: box.out, err: box.err, timedOut: box.timedOut) }
		return ProcessOutput(
			status: process.terminationStatus, stdout: String(decoding: collected.out, as: UTF8.self),
			stderr: String(decoding: collected.err, as: UTF8.self), timedOut: collected.timedOut, seconds: Date().timeIntervalSince(started))
	}

	/// `swiftc` of the same toolchain as `swift`.
	static func swiftcExecutable(swift: String) -> String? {
		let sibling = URL(fileURLWithPath: swift).deletingLastPathComponent().appendingPathComponent("swiftc").path
		return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
	}

	/// Every process below `pid`, parents before children.
	static func descendants(of pid: Int32) -> [Int32] {
		let ps = Process()
		ps.executableURL = URL(fileURLWithPath: "/bin/ps")
		ps.arguments = ["-A", "-o", "pid=,ppid="]
		let pipe = Pipe()
		ps.standardOutput = pipe
		ps.standardError = FileHandle.nullDevice
		guard (try? ps.run()) != nil else { return [] }
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		ps.waitUntilExit()
		var children: [Int32: [Int32]] = [:]
		for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
			let parts = line.split(separator: " ").compactMap { Int32($0) }
			if parts.count == 2 { children[parts[1], default: []].append(parts[0]) }
		}
		var result: [Int32] = []
		var queue = [pid]
		while !queue.isEmpty {
			let next = queue.removeFirst()
			for child in children[next] ?? [] where !result.contains(child) {
				result.append(child)
				queue.append(child)
			}
		}
		return result
	}

	/// The `swift` driver of the toolchain in use: next to the language server, else via xcrun, else on PATH.
	static func swiftExecutable(environment: [String: String], languageServer: [String]?) -> String? {
		let fileManager = FileManager.default
		if let first = languageServer?.first {
			let sibling = URL(fileURLWithPath: first).deletingLastPathComponent().appendingPathComponent("swift").path
			if fileManager.isExecutableFile(atPath: sibling) { return sibling }
		}
		for directory in (environment["PATH"] ?? "").split(separator: ":") {
			let candidate = "\(directory)/swift"
			if fileManager.isExecutableFile(atPath: candidate) { return candidate }
		}
		for candidate in ["/usr/bin/swift", "/usr/local/bin/swift", "/opt/homebrew/bin/swift"] where fileManager.isExecutableFile(atPath: candidate) {
			return candidate
		}
		return nil
	}
}

// MARK: - Building

struct BuildDiagnostic: Hashable, Sendable {
	var path: String
	var line: Int
	var column: Int
	var severity: String
	var message: String

	/// Same problem in the same file regardless of where in it: used to compare before and after.
	var identity: String { "\(URL(fileURLWithPath: path).lastPathComponent)|\(severity)|\(message)" }
}

struct BuildResult: Sendable {
	var command: String
	var status: Int32
	var timedOut: Bool
	var seconds: Double
	var errors: [BuildDiagnostic]
	var warnings: Int
	var tail: String

	var succeeded: Bool { status == 0 && !timedOut }
}

enum BuildRunner {
	static func parse(_ output: String) -> [BuildDiagnostic] {
		guard let regex = try? NSRegularExpression(pattern: #"^(/[^\n:]+?\.swift):(\d+):(\d+): (error|warning): (.+)$"#, options: [.anchorsMatchLines])
		else { return [] }
		var seen: Set<BuildDiagnostic> = []
		var result: [BuildDiagnostic] = []
		let text = output as NSString
		for match in regex.matches(in: output, range: NSRange(location: 0, length: text.length)) {
			let diagnostic = BuildDiagnostic(
				path: text.substring(with: match.range(at: 1)), line: Int(text.substring(with: match.range(at: 2))) ?? 0,
				column: Int(text.substring(with: match.range(at: 3))) ?? 0, severity: text.substring(with: match.range(at: 4)),
				message: text.substring(with: match.range(at: 5)))
			if seen.insert(diagnostic).inserted { result.append(diagnostic) }  // SwiftPM prints each one twice
		}
		return result
	}

	static func run(swift: String, root: URL, buildTests: Bool, environment: [String: String], timeout: TimeInterval) async -> BuildResult {
		var arguments = ["build"]
		if buildTests { arguments.append("--build-tests") }
		let output = await ToolProcess.run(swift, arguments: arguments, directory: root, environment: environment, timeout: timeout)
		let diagnostics = parse(output.combined)
		let tail = output.combined.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(6)
			.joined(separator: "\n")
		return BuildResult(
			command: "swift " + arguments.joined(separator: " "), status: output.status, timedOut: output.timedOut,
			seconds: output.seconds, errors: diagnostics.filter { $0.severity == "error" },
			warnings: diagnostics.filter { $0.severity == "warning" }.count, tail: tail)
	}
}
