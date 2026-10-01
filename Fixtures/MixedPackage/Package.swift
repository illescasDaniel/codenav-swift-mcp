// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "MixedPackage",
	targets: [
		.target(name: "Bridge"),
		.executableTarget(name: "MixedApp", dependencies: ["Bridge"], path: "Sources/App"),
	]
)
