// swift-tools-version:6.0
import PackageDescription

let package = Package(
	name: "SamplePackage",
	products: [
		.library(name: "SampleKit", targets: ["SampleKit"]),
		.executable(name: "SampleApp", targets: ["SampleApp"]),
	],
	targets: [
		.target(name: "SampleKit"),
		.executableTarget(name: "SampleApp", dependencies: ["SampleKit"]),
		.testTarget(name: "SampleKitTests", dependencies: ["SampleKit"]),
	]
)
