// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Annotator",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/krzysztofzablocki/Inject.git", exact: "1.6.0"),
    ],
    targets: [
        .target(name: "AnnotatorCore"),
        .executableTarget(
            name: "Annotator",
            dependencies: ["AnnotatorCore", .product(name: "Inject", package: "Inject")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-interposable"], .when(configuration: .debug))]
        ),
        .testTarget(name: "AnnotatorCoreTests", dependencies: ["AnnotatorCore"]),
        .testTarget(name: "AnnotatorTests", dependencies: ["Annotator", "AnnotatorCore"]),
    ]
)
