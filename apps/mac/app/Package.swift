// swift-tools-version: 6.2
import PackageDescription
import Foundation
let package = Package(name: "AnnotatorApp", platforms: [.macOS(.v26)], products: [.executable(name: "Annotator", targets: ["AnnotatorApp"])], dependencies: [
    .package(path: ProcessInfo.processInfo.environment["DESIGN_KIT_PATH"] ?? "../../../../design-kit/DesignKit")
], targets: [
    .target(name: "AnnotatorCore"),
    .executableTarget(name: "AnnotatorApp", dependencies: ["AnnotatorCore", "DesignKit"]),
    .testTarget(name: "AnnotatorCoreTests", dependencies: ["AnnotatorCore"])
])
