import Foundation
import NavShared

struct SynthesisResult {
	var members: [SynthesizedMember]
	/// The members were worked out from the source because the compiler's own listing wasn't available.
	var inferred = false
	/// Why the compiler's listing wasn't available.
	var problem: String?
}

extension SwiftNavigator {
	static let astEnvironmentKey = "CODENAV_SWIFT_AST"
	static let astTimeoutEnvironmentKey = "CODENAV_SWIFT_AST_TIMEOUT"

	var astEnabled: Bool { environment[Self.astEnvironmentKey] != "0" }

	var astTimeout: TimeInterval {
		environment[Self.astTimeoutEnvironmentKey].flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil } ?? 30
	}

	// MARK: Asking the compiler

	/// `swiftc -print-ast` for the module a file belongs to (all its sources, so types and extensions in other
	/// files are seen), cached until one of those files changes.
	func astDump(forFile path: String) async -> (dump: String?, problem: String?) {
		guard astEnabled else { return (nil, "turned off with \(Self.astEnvironmentKey)=0") }
		guard let swift = swiftExecutable(), let swiftc = ToolProcess.swiftcExecutable(swift: swift) else {
			return (nil, "swiftc was not found next to the swift toolchain in use")
		}
		var files = [path]
		var module = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
		var key = "file:" + path
		if let target = await packageGraph()?.target(ofPath: path), !target.sources.isEmpty {
			files = target.sources.filter { FileManager.default.fileExists(atPath: $0) }
			module = target.name
			key = "target:" + target.name
		}
		module = module.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
		let stamp = files.map { file -> String in
			let values = try? URL(fileURLWithPath: file).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
			return "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values?.fileSize ?? 0)"
		}.joined(separator: ",")
		if let cached = astCache[key], cached.stamp == stamp, Date().timeIntervalSince(cached.when) < 3600 { return (cached.dump, cached.problem) }

		var arguments = ["-print-ast", "-module-name", module]
		if !files.contains(where: { ($0 as NSString).lastPathComponent == "main.swift" }) { arguments.append("-parse-as-library") }
		// Modules the target imports, as an earlier build left them.
		let build = workspaceRoot.appendingPathComponent(".build")
		var candidates = [build.appendingPathComponent("debug")]
		for child in (try? FileManager.default.contentsOfDirectory(at: build, includingPropertiesForKeys: nil)) ?? [] {
			candidates.append(child.appendingPathComponent("debug"))
		}
		for directory in candidates {
			for folder in [directory.appendingPathComponent("Modules"), directory] where FileManager.default.fileExists(atPath: folder.path) {
				arguments += ["-I", folder.path]
			}
		}
		arguments += files
		let output = await ToolProcess.run(swiftc, arguments: arguments, directory: workspaceRoot, environment: environment, timeout: astTimeout)
		var result: (dump: String?, problem: String?)
		// The AST is printed on stderr, mixed with any diagnostics: keep the declarations, drop the error excerpts.
		let diagnosticLine = try? NSRegularExpression(pattern: #"^(\s*\d+\s*\|.*|\s*\|.*|/.*: (error|warning|note): .*|\d+ errors? generated.*)$"#)
		let lines = output.stderr.components(separatedBy: "\n")
		let declarations = lines.filter { line in
			diagnosticLine?.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) == nil
		}
		if output.timedOut {
			result = (nil, "swiftc -print-ast took longer than \(Int(astTimeout))s (set \(Self.astTimeoutEnvironmentKey))")
		} else if !declarations.contains(where: { $0.range(of: #"^\S.*\b(struct|class|enum|actor)\b"#, options: .regularExpression) != nil }) {
			let error = lines.first { $0.contains("error:") }?.components(separatedBy: "error:").last?.trimmingCharacters(in: .whitespaces)
			result = (nil, error.map { "swiftc could not compile the module: \($0)" + ($0.contains("no such module") ? " (build the project once so its modules exist)" : "") } ?? "swiftc -print-ast printed no types")
		} else {
			result = (declarations.joined(separator: "\n"), nil)
		}
		if astCache.count >= 6 { astCache.removeValue(forKey: astCache.min { $0.value.when < $1.value.when }?.key ?? "") }
		astCache[key] = (stamp, Date(), result.dump, result.problem)
		return result
	}

	// MARK: Which members, and when it is worth asking

	/// Whether a type can have members it never declares: a memberwise or default initializer, or members of a
	/// synthesized conformance. Asking the compiler costs a second or more, so it is skipped for the rest.
	static func mayHaveSynthesizedMembers(_ symbol: DocumentSymbol, text: String, supertypes: String?) -> Bool {
		guard [SymbolKind.structure, SymbolKind.enumeration, SymbolKind.class].contains(symbol.kind) else { return false }
		let children = symbol.children ?? []
		let hasInit = children.contains { $0.kind == SymbolKind.initializer }
		if !hasInit, symbol.kind != SymbolKind.enumeration { return true }  // memberwise (struct) or default (class) initializer
		let index = TextIndex(text)
		guard let start = try? index.offset(symbol.range.start) else { return false }
		let header = index.text(from: start, to: min(start + 400, index.units.count)).components(separatedBy: "{")[0]
		let haystack = header + " " + (supertypes ?? "")
		for word in ["Codable", "Decodable", "Encodable", "Equatable", "Hashable", "Comparable", "RawRepresentable", "CaseIterable"]
		where haystack.range(of: "(?<![A-Za-z0-9_])\(word)(?![A-Za-z0-9_])", options: .regularExpression) != nil {
			return true
		}
		return header.range(of: #"\benum\s+[A-Za-z0-9_]+\s*:\s*(String|Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|Double|Float|Character)\b"#, options: .regularExpression) != nil
	}

	func synthesizedMembers(
		file path: String, symbol: DocumentSymbol, parents: [DocumentSymbol], text: String, supertypes: String?, force: Bool = false,
		client: LSPClient? = nil
	) async -> SynthesisResult? {
		guard force || Self.mayHaveSynthesizedMembers(symbol, text: text, supertypes: supertypes) else { return nil }
		let known = Set((symbol.children ?? []).flatMap { [$0.name, NavShared.baseName($0.name)] })
		let (dump, problem) = await astDump(forFile: path)
		var reason = problem
		if let dump {
			if let headers = ASTDump.members(of: parents.map(\.name) + [symbol.name], in: dump) {
				return SynthesisResult(members: ASTDump.synthesized(from: headers, known: known), inferred: false, problem: nil)
			}
			reason = "the compiler's listing doesn't contain \(symbol.name) (declared under #if, or in a file outside this module)"
		}
		// Without the compiler's listing, the commonest case can still be worked out.
		// A property whose type isn't written (`var count = 0`) is asked of the language server: hover knows it.
		var types: [String: String] = [:]
		if let client {
			for property in InferredMembers.untypedProperties(of: symbol, in: text) {
				let position = property.selectionRange.start
				guard let hover = try? await client.hover(path, line: position.line + 1, column: position.character + 1),
					let type = InferredMembers.type(fromHover: hover, property: property.name)
				else { break }
				types[property.name] = type
			}
		}
		if let inferred = InferredMembers.memberwiseInit(for: symbol, in: text, types: types) {
			return SynthesisResult(members: [inferred], inferred: true, problem: reason)
		}
		return SynthesisResult(members: [], inferred: false, problem: reason)
	}

	// MARK: Presenting them

	static func formatSynthesized(typeName: String, _ result: SynthesisResult) -> String? {
		if result.members.isEmpty {
			guard let problem = result.problem else { return nil }
			return "Auto-generated members of \(typeName): not listed (\(problem))."
		}
		var lines = [
			result.inferred
				? "Auto-generated by the compiler, worked out from the stored properties because the compiler's own listing wasn't available (\(result.problem ?? "unknown reason")); the source has no declaration for these:"
				: "Auto-generated by the compiler (the source has no declaration for these):"
		]
		for member in result.members.prefix(24) {
			lines.append("  \(member.declaration)  [Auto-Generated: \(member.reason)]")
		}
		if result.members.count > 24 { lines.append("  … and \(result.members.count - 24) more") }
		return lines.joined(separator: "\n")
	}

	/// The section `symbol_info` adds for a type.
	func synthesizedSection(for resolved: ResolvedSymbol, supertypes: String?, client: LSPClient) async -> String? {
		guard resolved.kind != SymbolKind.protocol, let path = uriToPath(resolved.uri), !isOutsideWorkspace(resolved.uri),
			let text = try? readTextFile(URL(fileURLWithPath: path)), let tree = try? await client.documentSymbol(path),
			let found = DeclarationLookup.find(in: tree, at: LSPPosition(line: resolved.line, character: resolved.column))
		else { return nil }
		guard let result = await synthesizedMembers(file: path, symbol: found.symbol, parents: found.parents, text: text, supertypes: supertypes, client: client)
		else { return nil }
		return Self.formatSynthesized(typeName: found.symbol.name, result)
	}

	/// The answer for one member the compiler writes, from its owning type's declaration.
	private func answer(
		member query: ParsedQuery, ownerSymbol: ResolvedSymbol, found: (symbol: DocumentSymbol, parents: [DocumentSymbol], siblings: [DocumentSymbol]),
		path: String, text: String, client: LSPClient
	) async -> String? {
		guard let result = await synthesizedMembers(file: path, symbol: found.symbol, parents: found.parents, text: text, supertypes: nil, force: true, client: client)
		else { return nil }
		let wanted = query.signature.map { query.base + $0 }
		let member = result.members.first { candidate in
			if let wanted { return candidate.key == wanted }
			return NavShared.baseName(candidate.key) == query.base
		}
		guard let member else { return nil }
		let place = "\(relative(ownerSymbol.uri)):\(ownerSymbol.line + 1)"
		return "\(ownerSymbol.qualifiedName).\(member.key)  [Auto-Generated: \(member.reason)]\n\n    \(member.declaration)\n\n"
			+ "The compiler writes this member, so no declaration of it exists in the source. It belongs to \(ownerSymbol.qualifiedName) (\(place))."
			+ (result.inferred ? "\n(Worked out from the stored properties; the compiler's own listing wasn't available: \(result.problem ?? "").)" : "")
	}

	/// `Type.member` asked for by name where the member is written by the compiler.
	func synthesizedMemberAnswer(client: LSPClient, query: String) async -> String? {
		let parsed = ParsedQuery(query)
		guard !parsed.container.isEmpty,
			let owner = try? await resolveTarget(
				client, name: parsed.container.joined(separator: "."), query: nil, example: "Person", filePath: nil, line: nil, column: nil, symbol: nil),
			SymbolKind.types.contains(owner.symbol.kind), let path = uriToPath(owner.symbol.uri),
			let text = try? readTextFile(URL(fileURLWithPath: path)), let tree = try? await client.documentSymbol(path),
			let found = DeclarationLookup.find(in: tree, at: LSPPosition(line: owner.symbol.line, character: owner.symbol.column))
		else { return nil }
		return await answer(member: parsed, ownerSymbol: owner.symbol, found: found, path: path, text: text, client: client)
	}

	/// sourcekit's index does list a memberwise initializer, but at the line of the type: hover and definition then
	/// describe the struct. When a resolved initializer sits on a type's declaration, say what it really is.
	func synthesizedInitializerAnswer(client: LSPClient, resolved: ResolvedSymbol) async -> String? {
		guard resolved.kind == SymbolKind.initializer, let path = uriToPath(resolved.uri), !isOutsideWorkspace(resolved.uri),
			let text = try? readTextFile(URL(fileURLWithPath: path)), let tree = try? await client.documentSymbol(path),
			let found = DeclarationLookup.find(in: tree, at: LSPPosition(line: resolved.line, character: resolved.column)),
			SymbolKind.types.contains(found.symbol.kind)
		else { return nil }
		let owner = ResolvedSymbol(
			name: found.symbol.name, containerName: found.parents.isEmpty ? nil : found.parents.map(\.name).joined(separator: "."),
			kind: found.symbol.kind, uri: resolved.uri, line: resolved.line, column: resolved.column)
		return await answer(member: ParsedQuery(resolved.name), ownerSymbol: owner, found: found, path: path, text: text, client: client)
	}
}
