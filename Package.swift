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
        .target(name: "WindowfolkArtKit", dependencies: ["WindowfolkCore"]),
        .target(name: "WindowfolkArtIO", dependencies: ["WindowfolkArtKit"]),
        .executableTarget(name: "windowfolk-art", dependencies: ["WindowfolkArtKit", "WindowfolkArtIO"]),
        .testTarget(
            name: "WindowfolkCoreTests",
            dependencies: [
                "WindowfolkCore",
                "WindowfolkArtKit",
                "WindowfolkArtIO",
                .product(name: "PropertyBased", package: "swift-property-based"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
