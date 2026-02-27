// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "S3Tools",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "S3Tools", targets: ["S3Tools"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/awslabs/aws-sdk-swift",
            from: "1.0.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "S3Tools",
            dependencies: [
                .product(name: "AWSS3", package: "aws-sdk-swift")
            ],
            path: "Sources/S3Tools"
        )
    ]
)
