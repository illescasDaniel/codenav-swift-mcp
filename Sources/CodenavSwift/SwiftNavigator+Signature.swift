import Foundation
import NavShared

extension SwiftNavigator {
	/// Reads the `operations` of change_signature: `{op: add|remove|reorder|retype|default, ...}`.
	static func signatureOperations(_ arguments: ToolArguments) throws -> [(operation: [String: JSONValue], parsed: SignatureOperation)] {
		var objects = try arguments.objects("operations") ?? []
		let listed = !objects.isEmpty
		if objects.isEmpty, arguments.string("op") != nil { objects = [arguments.values] }
		guard !objects.isEmpty else {
			throw ToolInputError(
				"Pass `operations`, e.g. [{\"op\":\"add\",\"param\":\"overwrite: Bool = false\"}], [{\"op\":\"remove\",\"param\":\"flag\"}], [{\"op\":\"reorder\",\"order\":[\"b\",\"a\"]}], [{\"op\":\"retype\",\"param\":\"x\",\"type\":\"Int\"}] or [{\"op\":\"default\",\"param\":\"x\",\"value\":\"3\"}].")
		}
		return try objects.map { object in
			let args = ToolArguments(object)
			if listed { try rejectUnknownKeys(of: object) }
			func position() throws -> SignatureOperation.Position {
				let raw = (args.string("position") ?? "last").trimmingCharacters(in: .whitespaces)
				if raw == "last" { return .last }
				if raw == "first" { return .first }
				if raw.hasPrefix("before:") { return .before(String(raw.dropFirst(7)).trimmingCharacters(in: .whitespaces)) }
				if raw.hasPrefix("after:") { return .after(String(raw.dropFirst(6)).trimmingCharacters(in: .whitespaces)) }
				throw ToolInputError("`position` must be `first`, `last`, `before:<param>` or `after:<param>`, got '\(raw)'.")
			}
			switch args.string("op")?.lowercased() {
			case "add":
				let text = try args.requiredString("param")
				guard let parameter = SignatureParameter.parse(text) else {
					throw ToolInputError("Can't read the parameter '\(text)': write it as in a declaration, e.g. `overwrite: Bool = false` or `_ user: User`.")
				}
				return (object, .add(parameter, position: try position(), callValue: object["call_value"]?.stringValue))
			case "remove":
				return (object, .remove(key: try args.requiredString("param")))
			case "reorder":
				guard let order = object["order"]?.arrayValue?.compactMap(\.stringValue), !order.isEmpty else {
					throw ToolInputError("`reorder` needs `order`: the parameter names in their new order.")
				}
				return (object, .reorder(keys: order))
			case "retype":
				return (object, .retype(key: try args.requiredString("param"), type: try args.requiredString("type")))
			case "default":
				return (object, .setDefault(key: try args.requiredString("param"), value: object["value"]?.stringValue))
			default:
				throw ToolInputError("Unknown op '\(args.string("op") ?? "")': use add, remove, reorder, retype or default.")
			}
		}
	}

	/// A key an operation doesn't read would otherwise be ignored without a word (`default` on an `add`
	/// silently dropping the default), so name it and say where it belongs.
	private static func rejectUnknownKeys(of object: [String: JSONValue]) throws {
		let allowed: [String: Set<String>] = [
			"add": ["op", "param", "position", "call_value"], "remove": ["op", "param"], "reorder": ["op", "order"],
			"retype": ["op", "param", "type"], "default": ["op", "param", "value"],
		]
		guard let op = object["op"]?.stringValue?.lowercased(), let keys = allowed[op] else { return }
		let unknown = object.keys.filter { !keys.contains($0) }.sorted()
		guard !unknown.isEmpty else { return }
		var hint = ""
		if op == "add", unknown.contains(where: { $0 == "default" || $0 == "value" || $0 == "default_value" }) {
			hint = " To give an added parameter a default, write it in `param` (e.g. \"force: Bool = false\"), or follow with a `default` operation."
		}
		throw ToolInputError(
			"The '\(op)' operation doesn't take \(unknown.map { "`\($0)`" }.joined(separator: ", ")); it reads \(keys.sorted().map { "`\($0)`" }.joined(separator: ", ")).\(hint)")
	}

	static func isIdentifierUnit(_ unit: UInt16) -> Bool {
		(48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit > 127
	}

	private struct SignatureSite {
		var declaration: Declaration
		var open: Int
		var close: Int
		var parameters: [SignatureParameter]
		var change: SignatureChange?
	}

	private enum RewriteTask {
		case declaration(open: Int, change: SignatureChange)
		case call(identifierEnd: Int, change: SignatureChange, line: Int)
	}

	/// Whether `{` after a call's `)` starts a trailing closure rather than the body of `if`/`while`/...
	private static func hasTrailingClosure(scan: SwiftScan, index: TextIndex, close: Int) -> Bool {
		guard let next = scan.nextSignificant(from: close + 1), scan.units[next] == scan.unit("{"),
			!scan.text(close + 1, next).contains("\n")
		else { return false }
		let line = index.lineText(index.position(at: close).line).trimmingCharacters(in: .whitespaces)
		return line.range(of: #"^(\}\s*)?(else\s+)?(if|guard|while|for|switch|repeat|catch)\b"#, options: .regularExpression) == nil
	}

	public func changeSignature(arguments: ToolArguments) async -> ToolResult {
		await runWrite { client in
			let options = try EditOptions(arguments)
			var staging = self.stagingForWorkspace()
			let operations = try Self.signatureOperations(arguments)
			let target = try await self.locateDeclaration(client, staging: &staging, arguments: arguments, example: "UserService.create(name:)")
			guard DeclarationLookup.callableKinds.contains(target.symbol.kind) else {
				throw ToolInputError("\(target.qualifiedName) is a \(SymbolKind.label(target.symbol.kind)), not a function, method or initializer.")
			}

			// The declaration, plus the ones that must change with it: overrides and witnesses.
			func site(for declaration: Declaration) -> SignatureSite? {
				let nameStart = (try? declaration.index.offset(declaration.symbol.selectionRange.start)) ?? 0
				let base = NavShared.baseName(declaration.symbol.name)
				guard let list = declaration.scan.parenthesized(after: nameStart + base.utf16.count),
					let parameters = SignatureEditor.parameters(in: declaration.scan, open: list.open, close: list.close)
				else { return nil }
				return SignatureSite(declaration: declaration, open: list.open, close: list.close, parameters: parameters, change: nil)
			}
			guard let primary = site(for: target) else {
				throw ToolInputError("Couldn't read the parameter list of \(target.qualifiedName).")
			}
			await self.awaitIndex(client)
			// A witness or override has to change together with the requirement or base declaration it
			// implements: find that one first (a same-named member elsewhere whose implementations include this).
			var root = target
			let same = try await client.workspaceSymbol(NavShared.baseName(target.symbol.name))
				.filter { $0.name == target.symbol.name && DeclarationLookup.callableKinds.contains($0.kind) }
			for candidate in same {
				guard let candidatePath = uriToPath(candidate.location.uri), !self.isOutsideWorkspace(candidate.location.uri) else { continue }
				let position = candidate.position
				if candidatePath == target.path, position.line == target.resolved.line { continue }
				let below = (try? await client.implementation(candidatePath, line: position.line + 1, column: position.character + 1)) ?? []
				guard below.contains(where: { location in
					uriToPath(location.uri).map { staging.canonical($0) } == target.path && location.range.start.line == target.symbol.selectionRange.start.line
				}) else { continue }
				let resolved = ResolvedSymbol(
					name: candidate.name, containerName: candidate.containerName, kind: candidate.kind, uri: candidate.location.uri,
					line: position.line, column: position.character)
				if let declaration = try? await self.declaration(for: resolved, client: client, staging: &staging) {
					root = declaration
					staging.note("\(target.qualifiedName) implements \(declaration.qualifiedName), so that declaration is changed too")
					break
				}
			}
			var sites: [SignatureSite] = []
			var seenDeclarations: Set<String> = []
			if root.path != target.path || root.symbol.selectionRange.start.line != target.symbol.selectionRange.start.line, let rootSite = site(for: root) {
				seenDeclarations.insert("\(root.path)#\(root.symbol.selectionRange.start.line)")
				sites.append(rootSite)
			}
			seenDeclarations.insert("\(target.path)#\(target.symbol.selectionRange.start.line)")
			sites.append(primary)
			let related = (try? await client.implementation(root.path, line: root.resolved.line + 1, column: root.resolved.column + 1)) ?? []
			for location in related {
				guard let path = uriToPath(location.uri), !self.isOutsideWorkspace(location.uri) else { continue }
				let resolved = ResolvedSymbol(
					name: target.symbol.name, containerName: nil, kind: target.symbol.kind, uri: location.uri,
					line: location.range.start.line, column: location.range.start.character)
				guard let declaration = try? await self.declaration(for: resolved, client: client, staging: &staging),
					seenDeclarations.insert("\(declaration.path)#\(declaration.symbol.selectionRange.start.line)").inserted,
					let found = site(for: declaration)
				else {
					_ = path
					continue
				}
				sites.append(found)
			}

			// Plan the same change for each, matching parameters by position (internal names may differ).
			let primaryPlan = try Self.plan(primary.parameters, operations, translateFrom: nil, target: primary.parameters)
			var planned: [SignatureSite] = []
			for var candidate in sites {
				if candidate.declaration.path == primary.declaration.path, candidate.open == primary.open {
					candidate.change = primaryPlan
				} else if candidate.parameters.count == primary.parameters.count {
					candidate.change = try Self.plan(candidate.parameters, operations, translateFrom: primary.parameters, target: candidate.parameters)
				} else {
					staging.needsAttention("\(candidate.declaration.qualifiedName) in \(self.relative(candidate.declaration.resolved.uri)) has a different parameter list from \(target.qualifiedName); it was not changed")
					continue
				}
				planned.append(candidate)
			}

			// Collect tasks per file.
			var tasks: [String: [RewriteTask]] = [:]
			var declarationNames: Set<String> = []
			var coveredLocations: Set<String> = []
			for site in planned {
				guard let change = site.change else { continue }
				declarationNames.insert(NavShared.baseName(site.declaration.symbol.name))
				tasks[site.declaration.path, default: []].append(.declaration(open: site.open, change: change))
				let selection = site.declaration.symbol.selectionRange.start
				coveredLocations.insert("\(site.declaration.path)#\(selection.line)#\(selection.character)")
			}
			var rewrittenCalls = 0
			var untouchedCalls = 0
			for site in planned {
				guard let change = site.change, change.needsCallRewrite else { continue }
				let found = try await self.referencesWithUsageFallback(
					client, file: site.declaration.path, line: site.declaration.resolved.line + 1,
					column: site.declaration.resolved.column + 1, includeDeclaration: false)
				for location in found.locations {
					guard let path = uriToPath(location.uri) else { continue }
					let canonical = staging.canonical(path)
					let key = "\(canonical)#\(location.range.start.line)#\(location.range.start.character)"
					guard coveredLocations.insert(key).inserted else { continue }
					guard let text = try staging.read(canonical) else { continue }
					let index = TextIndex(text)
					// A reference's range can be a point: find the end of the name from its start.
					guard let start = try? index.offset(location.range.start) else { continue }
					var end = start
					while end < index.units.count, Self.isIdentifierUnit(index.units[end]) { end += 1 }
					tasks[canonical, default: []].append(.call(identifierEnd: end, change: change, line: location.range.start.line + 1))
				}
				for location in found.unverified {
					staging.needsAttention("\(EditFormat.relativeName(uriToPath(location.uri) ?? location.uri, root: self.workspaceRoot)):\(location.range.start.line + 1) mentions `\(NavShared.baseName(site.declaration.symbol.name))` but the compiler couldn't resolve it; check it by hand")
				}
			}

			// Apply from the end of each file backwards: an edit never moves the offsets of those still to come,
			// and a call nested in another call is rewritten before the outer one is read.
			for (path, fileTasks) in tasks.sorted(by: { $0.key < $1.key }) {
				guard var text = try staging.read(path) else { continue }
				func offset(_ task: RewriteTask) -> Int {
					switch task {
					case .declaration(let open, _): return open
					case .call(let end, _, _): return end
					}
				}
				for task in fileTasks.sorted(by: { offset($0) > offset($1) }) {
					let scan = SwiftScan(text)
					let index = TextIndex(text)
					switch task {
					case .declaration(let open, let change):
						guard scan.units.indices.contains(open), scan.units[open] == scan.unit("("), let close = scan.matching(openAt: open) else { continue }
						let original = scan.text(open + 1, close)
						let edit = Self.edit(index, from: open + 1, to: close, change.renderedList(like: original))
						text = try TextEditing.apply([edit], to: text)
					case .call(let end, let change, let line):
						let spot = EditFormat.relativeName(path, root: self.workspaceRoot) + ":\(line)"
						guard let list = scan.parenthesized(after: end), !scan.text(end, list.open).contains("\n") else {
							staging.needsAttention("\(spot): `\(NavShared.baseName(target.symbol.name))` is used as a value here, not called; update it by hand")
							continue
						}
						let arguments = SignatureEditor.arguments(in: scan, open: list.open, close: list.close)
						let original = scan.text(list.open + 1, list.close)
						let trailing = Self.hasTrailingClosure(scan: scan, index: index, close: list.close)
						switch SignatureEditor.rewrite(arguments: arguments, original: original, hasTrailingClosure: trailing, change: change) {
						case .rewritten(let replacement):
							// A removed parameter's argument disappears with its evaluation: flag calls that may have had effects.
							let kept = Set(change.entries.compactMap(\.origin))
							for (position, parameter) in change.old.enumerated() where !kept.contains(position) {
								let dropped = parameter.label == "_" || parameter.label.isEmpty
									? (arguments.indices.contains(position) && arguments[position].label == nil ? arguments[position] : nil)
									: arguments.first { $0.label == parameter.label }
								if let dropped, dropped.expression.contains("("), !dropped.expression.hasPrefix("\"") {
									staging.needsAttention("\(spot): the dropped argument `\(dropped.expression)` looks like a call; its side effects no longer happen")
								}
							}
							text = try TextEditing.apply([Self.edit(index, from: list.open + 1, to: list.close, replacement)], to: text)
							rewrittenCalls += 1
						case .unchanged:
							untouchedCalls += 1
						case .manual(let reason):
							staging.needsAttention("\(spot): \(reason); update this call by hand")
						}
					}
				}
				try staging.write(text, to: path)
			}
			staging.note(
				"changed \(planned.count) declaration(s) (the function" + (planned.count > 1 ? " and \(planned.count - 1) override/witness(es)" : "")
					+ "), rewrote \(rewrittenCalls) call site(s)" + (untouchedCalls > 0 ? ", \(untouchedCalls) needed no change" : ""))
			staging.note("uses of a removed parameter inside the body, or of a changed type, are left for the compile check below to point at")
			return try await self.finishEdit(
				staging, client: client, title: "change_signature \(target.qualifiedName)", options: options, extraNames: declarationNames)
		}
	}

	/// Applies the operations to `parameters`. For an override/witness (`translateFrom` set) the keys the
	/// caller wrote refer to the primary declaration's parameters: they are mapped by position.
	private static func plan(
		_ parameters: [SignatureParameter], _ operations: [(operation: [String: JSONValue], parsed: SignatureOperation)],
		translateFrom primary: [SignatureParameter]?, target: [SignatureParameter]
	) throws -> SignatureChange {
		func translate(_ key: String) -> String {
			guard let primary,
				let index = primary.firstIndex(where: { $0.key == key || $0.name == key || $0.label == key }),
				target.indices.contains(index)
			else { return key }
			return target[index].key
		}
		let mapped: [SignatureOperation] = operations.map { operation in
			switch operation.parsed {
			case .add(let parameter, let position, let value):
				let translated: SignatureOperation.Position
				switch position {
				case .before(let key): translated = .before(translate(key))
				case .after(let key): translated = .after(translate(key))
				default: translated = position
				}
				return .add(parameter, position: translated, callValue: value)
			case .remove(let key): return .remove(key: translate(key))
			case .reorder(let keys): return .reorder(keys: keys.map(translate))
			case .retype(let key, let type): return .retype(key: translate(key), type: type)
			case .setDefault(let key, let value): return .setDefault(key: translate(key), value: value)
			}
		}
		do {
			return try SignatureChange.plan(old: parameters, operations: mapped)
		} catch let error as SignatureError {
			throw ToolInputError("Can't change the signature: \(error.message).")
		}
	}
}
