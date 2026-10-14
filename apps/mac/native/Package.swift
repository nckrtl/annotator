// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnnotatorNative",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "AnnotatorNativeCore"),
        .executableTarget(name: "AnnotatorNative", dependencies: ["AnnotatorNativeCore"]),
        .testTarget(name: "AnnotatorNativeCoreTests", dependencies: ["AnnotatorNativeCore"]),
        .testTarget(name: "AnnotatorNativeTests", dependencies: ["AnnotatorNative"]),
    ]
)
