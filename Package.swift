// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mactotalvolume",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VolumeMixer", targets: ["VolumeMixer"])
    ],
    targets: [
        .executableTarget(name: "VolumeMixer")
    ]
)
