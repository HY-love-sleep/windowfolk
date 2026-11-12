// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Windowfolk",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/x-sheep/swift-property-based.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "WindowfolkCore"),
        .executableTarget(name: "Windowfolk", dependencies: ["WindowfolkCore"]),
        .testTarget(
            name: "WindowfolkCoreTests",
            dependencies: [
                "WindowfolkCore",
                .product(name: "PropertyBased", package: "swift-property-based"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
