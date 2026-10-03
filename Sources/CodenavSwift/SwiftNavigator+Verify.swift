import Foundation
import NavShared

struct BuildOutcome {
	var text: String
	var hasNewErrors: Bool
	/// Files somebody else changed while the build ran: they were left as they are, not put back or rewritten.
	var diverged: [String] = []
}

extension SwiftNavigator {
	static let buildTimeoutEnvironmentKey = "CODENAV_SWIFT_BUILD_TIMEOUT"

	var buildTimeout: TimeInterval {
		environment[Self.buildTimeoutEnvironmentKey].flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil } ?? 600
	}

	func swiftExecutable() -> String? {
		ToolProcess.swiftExecutable(
			environment: environment, languageServer: try? (commandOverride ?? SourceKitLSPLocator.command(environment: environment)))
	}

	/// The package's targets and dependencies (SwiftPM only), cached until the manifest changes.
	func packageGraph() async -> PackageGraph? {
		guard projectKind == .swiftPackage, let swift = swiftExecutable() else { return nil }
		let manifest = workspaceRoot.appendingPathComponent("Package.swift")
		let stamp = (try? manifest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
		if let cache = packageGraphCache, cache.stamp == stamp { return cache.graph }
		let output = await ToolProcess.run(
			swift, arguments: ["package", "--disable-automatic-resolution", "describe", "--type", "json"], directory: workspaceRoot,
			environment: environment, timeout: 60)
		var graph: PackageGraph?
		if output.status == 0, let brace = output.stdout.firstIndex(of: "{") {
			graph = PackageGraph.parse(json: Data(output.stdout[brace...].utf8), root: workspaceRoot)
		}
		packageGraphCache = (stamp, graph)
		return graph
	}

	/// Whether to build after an edit, and what to say when it can't.
	func buildPlan(report: CheckReport, options: EditOptions) -> (run: Bool, hint: String?) {
		let available = canBuild
		switch options.verify {
		case .none:
			return (false, nil)
		case .build:
			return available ? (true, nil) : (false, "Build verification isn't available here (it needs a SwiftPM package, or an Xcode project with a buildServer.json and xcodebuild); build the project yourself to verify.")
		case .auto:
			guard !report.crossModule.isEmpty else { return (false, nil) }
			return available
				? (true, nil)
				: (false, "\(report.crossModule.count) file(s) in dependent modules weren't compiled and this project can't be built from here; build it yourself (for example in Xcode) to verify them.")
		}
	}

	/// Whether a whole-project build can run here: `swift build` for a package, `xcodebuild` for an Xcode project.
	var canBuild: Bool {
		if projectKind == .swiftPackage { return swiftExecutable() != nil }
		return xcodeBuild() != nil && xcodebuildExecutable() != nil
	}

	func runBuild() async -> BuildResult? {
		if projectKind != .swiftPackage {
			guard let build = xcodeBuild(), let xcodebuild = xcodebuildExecutable() else { return nil }
			return await BuildRunner.runXcode(build, xcodebuild: xcodebuild, root: workspaceRoot, environment: environment, timeout: buildTimeout)
		}
		guard let swift = swiftExecutable() else { return nil }
		return await BuildRunner.run(swift: swift, root: workspaceRoot, buildTests: true, environment: environment, timeout: buildTimeout)
	}

	static func newErrors(_ after: BuildResult, comparedTo baseline: BuildResult) -> [BuildDiagnostic] {
		var counts = Dictionary(grouping: baseline.errors, by: \.identity).mapValues(\.count)
		return after.errors.filter { error in
			if let count = counts[error.identity], count > 0 {
				counts[error.identity] = count - 1
				return false
			}
			return true
		}
	}

	private func describe(_ result: BuildResult, fresh: [BuildDiagnostic], baseline: BuildResult?, failed: Bool) -> String {
		let seconds = String(format: "%.1f", result.seconds)
		let head = "Build (\(result.command), \(seconds)s)"
		if result.timedOut { return "\(head): ✗ timed out after \(Int(buildTimeout))s, so the change is unverified (set \(Self.buildTimeoutEnvironmentKey) to allow longer)." }
		if !failed {
			if result.succeeded { return "\(head): ✓ succeeded" + (result.warnings > 0 ? " (\(result.warnings) warning(s))" : "") }
			let before = baseline?.errors.count ?? 0
			return "\(head): the project already failed to build before this change (\(max(before, result.errors.count)) error(s)); the change adds none."
		}
		var lines = ["\(head): ✗ \(max(fresh.count, 1)) new error(s)"]
		for error in fresh.prefix(EditFormat.maxDiagnosticsShown) {
			lines.append("  \(EditFormat.relativeName(error.path, root: workspaceRoot)):\(error.line):\(error.column) error: \(error.message)")
		}
		if fresh.count > EditFormat.maxDiagnosticsShown { lines.append("  … and \(fresh.count - EditFormat.maxDiagnosticsShown) more") }
		if fresh.isEmpty { lines.append(result.tail.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")) }
		if let baseline, !baseline.errors.isEmpty { lines.append("(\(baseline.errors.count) error(s) were already there before the change.)") }
		return lines.joined(separator: "\n")
	}

	/// Builds the project with the plan written to disk. The state afterwards: written when the change adds no
	/// errors, restored when it does (so the caller can refuse it).
	func buildAfterWrite(_ plan: EditPlan, engine: EditEngine) async throws -> BuildOutcome {
		guard let first = await runBuild() else { return BuildOutcome(text: "Build: no swift toolchain found.", hasNewErrors: false) }
		if first.succeeded { return BuildOutcome(text: describe(first, fresh: [], baseline: nil, failed: false), hasNewErrors: false) }
		// It failed. Did the project build before?
		let skipped = try engine.restore(plan, skipChanged: true)
		let baseline = await runBuild()
		let fresh = baseline.map { Self.newErrors(first, comparedTo: $0) } ?? first.errors
		let unattributed = first.errors.isEmpty && baseline?.succeeded != false
		let blamed = first.timedOut || !fresh.isEmpty || unattributed
		var diverged = skipped
		if !blamed { diverged = try engine.reapply(plan, skipping: Set(skipped)) }
		return BuildOutcome(
			text: describe(first, fresh: fresh, baseline: baseline, failed: blamed) + divergedNote(diverged), hasNewErrors: blamed, diverged: diverged)
	}

	/// Xcode's index store is written by builds: a build of a proposed change that is then put back leaves the
	/// store describing the proposal, and the next rename or reference lookup would trust it. Building the
	/// restored files once refreshes the store (an incremental build, a few seconds).
	func resyncXcodeIndex() async {
		guard projectKind != .swiftPackage, xcodeBuild() != nil else { return }
		_ = await runBuild()
	}

	/// For a dry run that asked for a build: writes the plan, builds, and puts every file back.
	func buildOnTemporaryWrite(_ plan: EditPlan, engine: EditEngine) async throws -> BuildOutcome {
		try engine.commit(plan)
		// The files are changed on disk with nothing in the journal: if this process dies during the build,
		// the next one finds this record and puts them back.
		let pendingToken = beginPending(plan, title: "check_edit verify=build")
		let first: BuildResult?
		var diverged: [String] = []
		do {
			first = await runBuild()
			diverged = try engine.restore(plan, skipChanged: true)
		} catch {
			_ = try? engine.restore(plan, skipChanged: true)
			endPending(pendingToken)
			throw error
		}
		endPending(pendingToken)
		guard let first else { return BuildOutcome(text: "Build: no swift toolchain found.", hasNewErrors: false) }
		if first.succeeded {
			await resyncXcodeIndex()
			return BuildOutcome(text: describe(first, fresh: [], baseline: nil, failed: false) + divergedNote(diverged), hasNewErrors: false, diverged: diverged)
		}
		let baseline = await runBuild()
		let fresh = baseline.map { Self.newErrors(first, comparedTo: $0) } ?? first.errors
		let blamed = first.timedOut || !fresh.isEmpty || (first.errors.isEmpty && baseline?.succeeded != false)
		return BuildOutcome(
			text: describe(first, fresh: fresh, baseline: baseline, failed: blamed) + divergedNote(diverged), hasNewErrors: blamed, diverged: diverged)
	}

	func divergedNote(_ paths: [String]) -> String {
		guard !paths.isEmpty else { return "" }
		return "\n⚠ " + paths.map { EditFormat.relativeName($0, root: workspaceRoot) }.joined(separator: ", ")
			+ " changed while the build ran (an editor, another tool?), so codenav left "
			+ (paths.count == 1 ? "it" : "them") + " as " + (paths.count == 1 ? "it is" : "they are") + " instead of overwriting the newer text."
	}

	// MARK: verify

	public func verify(tests: Bool, filter: String?) async -> ToolResult {
		await run {
			await useWorkspace()
			_ = try await liveClient()  // also makes sure the language server has seen the latest files
			guard canBuild else {
				throw ToolInputError("verify builds with `swift build` (a SwiftPM package) or `xcodebuild` (an Xcode project with a buildServer.json from xcode-build-server). Neither is available here; build it in Xcode.")
			}
			return await withWriteLock {
				guard let build = await runBuild() else { return "Build: no build tool found." }
				var lines = [describeFull(build)]
				if tests, build.succeeded, projectKind != .swiftPackage {
					lines.append(await runXcodeTests(filter: filter))
				} else if tests, build.succeeded, let swift = swiftExecutable() {
					lines.append(await runTests(swift: swift, filter: filter))
				} else if tests {
					lines.append("Tests not run: the build failed.")
				}
				return lines.joined(separator: "\n")
			}
		}
	}

	private func describeFull(_ result: BuildResult) -> String {
		let seconds = String(format: "%.1f", result.seconds)
		let head = "Build (\(result.command), \(seconds)s)"
		if result.timedOut { return "\(head): timed out after \(Int(buildTimeout))s (set \(Self.buildTimeoutEnvironmentKey) to allow longer)." }
		if result.succeeded { return "\(head): ✓ succeeded" + (result.warnings > 0 ? " (\(result.warnings) warning(s))" : "") }
		var lines = ["\(head): ✗ failed, \(result.errors.count) error(s)"]
		for error in result.errors.prefix(20) {
			lines.append("  \(EditFormat.relativeName(error.path, root: workspaceRoot)):\(error.line):\(error.column) error: \(error.message)")
		}
		if result.errors.count > 20 { lines.append("  … and \(result.errors.count - 20) more") }
		if result.errors.isEmpty { lines.append(result.tail.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")) }
		return lines.joined(separator: "\n")
	}

	func runTests(swift: String, filter: String?) async -> String {
		var arguments = ["test"]
		if let filter { arguments += ["--filter", filter] }
		let output = await ToolProcess.run(swift, arguments: arguments, directory: workspaceRoot, environment: environment, timeout: buildTimeout)
		return Self.describeTests(output, command: "swift \(arguments.joined(separator: " "))")
	}

	/// Runs the scheme's tests with the products the verify build just made (`xcodebuild test-without-building`).
	func runXcodeTests(filter: String?) async -> String {
		guard let build = xcodeBuild(), let xcodebuild = xcodebuildExecutable() else { return "Tests not run: no xcodebuild." }
		var concrete: String?
		if build.testDestination.hasPrefix("platform="), !build.testDestination.contains("macOS") {
			let listing = await ToolProcess.run(
				xcodebuild, arguments: ["-showdestinations", build.containerFlag, build.container, "-scheme", build.scheme],
				directory: workspaceRoot, environment: environment, timeout: 120)
			concrete = XcodeBuild.pickDestination(fromListing: listing.combined, platform: String(build.testDestination.dropFirst("platform=".count)))
		}
		let arguments = build.testArguments(filter: filter, destination: concrete)
		let output = await ToolProcess.run(xcodebuild, arguments: arguments, directory: workspaceRoot, environment: environment, timeout: buildTimeout)
		if output.status != 0, output.combined.contains("not currently configured for the test action") {
			return "Tests not run: scheme \(build.scheme) has no test action (add a test target to it in Xcode)."
		}
		return Self.describeTests(output, command: "xcodebuild test -scheme \(build.scheme)" + (filter.map { " -only-testing:\($0)" } ?? ""))
	}

	static func describeTests(_ output: ProcessOutput, command: String) -> String {
		let seconds = String(format: "%.1f", output.seconds)
		let head = "Tests (\(command), \(seconds)s)"
		if output.timedOut { return "\(head): timed out." }
		let all = output.combined.components(separatedBy: "\n")
		let failures = all.filter { $0.contains("✘") || $0.contains(": error:") || $0.contains(" failed") && $0.contains("Test Case") }
		let summary = all.last(where: { $0.contains("Test run with") || $0.contains("Executed ") || $0.contains("** TEST ") }) ?? all.filter { !$0.isEmpty }.last ?? ""
		if output.status == 0 { return "\(head): ✓ \(summary.trimmingCharacters(in: .whitespaces))" }
		var lines = ["\(head): ✗ \(summary.trimmingCharacters(in: .whitespaces))"]
		for failure in failures.prefix(20) {
			let text = failure.trimmingCharacters(in: .whitespaces)
			lines.append("  " + (text.count > 240 ? text.prefix(240) + "…" : text))
		}
		if failures.isEmpty { lines.append(all.filter { !$0.isEmpty }.suffix(8).map { "  " + $0 }.joined(separator: "\n")) }
		return lines.joined(separator: "\n")
	}

	// MARK: affected_tests

	public func affectedTests(arguments: ToolArguments) async -> ToolResult {
		await run {
			await useWorkspace()
			let client = try await liveClient()
			let target = try await resolveTarget(
				client, name: arguments.string("name"), query: arguments.string("query"), example: "UserService.create(name:)",
				filePath: arguments.string("file_path"), line: try arguments.optionalInt("line"),
				column: try arguments.optionalInt("column"), symbol: arguments.string("symbol"))
			let resolved = target.symbol
			let file = try path(of: resolved.uri)
			await awaitIndex(client)
			let depth = max(1, min(try arguments.optionalInt("depth") ?? 3, 6))

			// Every place that uses it, and every function that (transitively) calls it.
			var sites: [(path: String, line: Int)] = []
			let found = try await referencesWithUsageFallback(client, file: file, line: resolved.line + 1, column: resolved.column + 1, includeDeclaration: false)
			for location in found.locations { if let path = uriToPath(location.uri) { sites.append((path, location.range.start.line)) } }
			var visited: Set<String> = []
			var frontier = (try? await client.prepareCallHierarchy(file, line: resolved.line + 1, column: resolved.column + 1)) ?? []
			for _ in 0..<depth where !frontier.isEmpty {
				var next: [HierarchyItem] = []
				for item in frontier {
					guard visited.insert("\(item.uri)#\(item.range.start.line)#\(item.name)").inserted else { continue }
					for call in (try? await client.incomingCalls(item)) ?? [] {
						if let path = uriToPath(call.from.uri) { sites.append((path, call.from.selectionRange.start.line)) }
						next.append(call.from)
					}
				}
				frontier = next
			}

			var tests: [String: (path: String, line: Int, container: String?)] = [:]
			for site in sites {
				let canonical = canonicalFileURL(site.path, relativeTo: workspaceRoot).path
				guard Self.isTestFile(canonical) else { continue }
				guard let symbols = try? await client.documentSymbol(canonical),
					let owner = Self.enclosingFunction(in: symbols, line: site.line)
				else { continue }
				let key = "\(canonical)#\(owner.symbol.name)"
				tests[key] = (canonical, owner.symbol.selectionRange.start.line + 1, owner.container?.name)
			}
			guard !tests.isEmpty else {
				var message = "No test found that uses or (within \(depth) call level(s)) reaches \(resolved.qualifiedName)."
				if let blind = testFilesWithoutBuildSettings() {
					message += " But the language server can't see into \(blind): they have no build settings yet (the last build didn't compile the test targets), so uses there are invisible. Run `verify` (it builds for testing, which fixes that) and ask again."
				} else {
					message += " Nothing in the tests exercises it: consider adding one."
				}
				return message
			}
			let ordered = tests.sorted { ($0.value.path, $0.value.line) < ($1.value.path, $1.value.line) }
			var lines = ["\(ordered.count) test(s) exercise \(resolved.qualifiedName):"]
			var names: [String] = []
			for (key, test) in ordered {
				let name = key.components(separatedBy: "#").last ?? key
				let base = NavShared.baseName(name)
				names.append(base)
				lines.append("  \(test.container.map { $0 + "." } ?? "")\(name)  (\(EditFormat.relativeName(test.path, root: workspaceRoot)):\(test.line))")
			}
			let regex = Array(Set(names)).sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
			if projectKind != .swiftPackage, xcodeBuild() != nil {
				// `-only-testing` identifiers (Target/Class), one per test class.
				let modules = xcodeModules()
				var identifiers: [String] = []
				for (_, test) in ordered {
					guard let container = test.container, let module = modules?.module(ofPath: test.path) else { continue }
					let identifier = "\(module)/\(container)"
					if !identifiers.contains(identifier) { identifiers.append(identifier) }
				}
				if identifiers.isEmpty {
					lines.append("Run them with `verify(tests=true, filter=\"<Target>/<Class>\")`.")
				} else {
					lines.append("Run them: verify(tests=true, filter=\"\(identifiers.joined(separator: ","))\")" + (identifiers.count > 1 ? " (one filter per class; run each)" : ""))
				}
				if arguments.bool("run", default: false) {
					guard xcodeBuild() != nil else { throw ToolInputError("No xcodebuild found to run the tests with.") }
					if identifiers.isEmpty {
						lines.append("Not run: couldn't tell which test target these belong to.")
					} else {
						lines.append(await withWriteLock {
							guard await runBuild()?.succeeded == true else { return "Tests not run: the build failed (use `verify`)." }
							var results: [String] = []
							for identifier in identifiers { results.append(await runXcodeTests(filter: identifier)) }
							return results.joined(separator: "\n")
						})
					}
				}
				return lines.joined(separator: "\n")
			}
			lines.append("Run them: swift test --filter '\(regex)'")
			if arguments.bool("run", default: false) {
				guard let swift = swiftExecutable() else { throw ToolInputError("No swift toolchain found to run the tests with.") }
				lines.append(await withWriteLock { await runTests(swift: swift, filter: regex) })
			}
			return lines.joined(separator: "\n")
		}
	}

	/// For an Xcode project: test files the last build never compiled (no build settings), as a short list; nil
	/// when there are none, or this isn't an Xcode project.
	func testFilesWithoutBuildSettings() -> String? {
		guard xcodeBuild() != nil else { return nil }
		let known = xcodeModules()
		var blind: [String] = []
		for root in [workspaceRoot] + ProjectKind.localPackageFolders(in: workspaceRoot) {
			guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
			for case let url as URL in enumerator {
				if Exclude.directoryNames.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
				guard url.pathExtension == "swift", Self.isTestFile(url.path) else { continue }
				if known?.module(ofPath: url.realPath.path) == nil { blind.append(EditFormat.relativeName(url.path, root: workspaceRoot)) }
				if blind.count >= 50 { break }
			}
		}
		guard !blind.isEmpty else { return nil }
		let folders = Set(blind.map { ($0 as NSString).deletingLastPathComponent }).sorted().prefix(3)
		return "\(blind.count) test file(s) (in \(folders.joined(separator: ", ")))"
	}

	static func isTestFile(_ path: String) -> Bool {
		if path.contains("/Tests/") || path.contains("Tests.swift") { return true }
		guard let text = try? readTextFile(URL(fileURLWithPath: path)) else { return false }
		return text.contains("import XCTest") || text.contains("import Testing")
	}

	/// The innermost function or method containing a 0-based line, with the type it is declared in.
	static func enclosingFunction(in symbols: [DocumentSymbol], line: Int, container: DocumentSymbol? = nil) -> (symbol: DocumentSymbol, container: DocumentSymbol?)? {
		for symbol in symbols where symbol.range.start.line <= line && line <= symbol.range.end.line {
			if let inner = enclosingFunction(in: symbol.children ?? [], line: line, container: symbol) { return inner }
			if DeclarationLookup.callableKinds.contains(symbol.kind) { return (symbol, container) }
		}
		return nil
	}
}
