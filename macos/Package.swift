// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DecisionAdvisor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DecisionAdvisor", targets: ["DecisionAdvisor"])
    ],
    targets: [
        .executableTarget(
            name: "DecisionAdvisor",
            path: "Sources/DecisionAdvisor"
        )
    ]
)
