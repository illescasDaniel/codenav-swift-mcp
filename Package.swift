// swift-tools-version:6.1
import PackageDescription

let package = Package(
	name: "codenav-swift-mcp",
	platforms: [.macOS(.v13)],
	products: [
		.executable(name: "codenav-swift-mcp", targets: ["codenav-swift-mcp"]),
		.library(name: "NavShared", targets: ["NavShared"]),
	],
	dependencies: [
		.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
	],
	targets: [
		.target(name: "NavShared"),
		.target(name: "CodenavSwift", dependencies: ["NavShared"]),
		.executableTarget(
			name: "codenav-swift-mcp",
			dependencies: [
				"CodenavSwift",
				.product(name: "MCP", package: "swift-sdk"),
			]
		),
		.testTarget(name: "NavSharedTests", dependencies: ["NavShared"]),
		.testTarget(name: "CodenavSwiftTests", dependencies: ["CodenavSwift", "NavShared"]),
	]
)
