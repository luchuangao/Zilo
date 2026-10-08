// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "OwnList", platforms: [.macOS(.v14)], products: [.executable(name: "OwnList", targets: ["OwnList"])], targets: [.executableTarget(name: "OwnList", resources: [.copy("PreviewResources")]), .testTarget(name: "OwnListTests", dependencies: ["OwnList"])])
