// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProjectMCP",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ProjectMCPCore", targets: ["ProjectMCPCore"]),
        .executable(name: "ProjectMCPApp", targets: ["ProjectMCPApp"]),
        .executable(name: "ProjectMCPSupervisor", targets: ["ProjectMCPSupervisor"])
    ],
    targets: [
        .target(name: "ProjectMCPCore"),
        .executableTarget(name: "ProjectMCPApp", dependencies: ["ProjectMCPCore"]),
        .executableTarget(name: "ProjectMCPSupervisor", dependencies: ["ProjectMCPCore"]),
        .testTarget(name: "ProjectMCPCoreTests", dependencies: ["ProjectMCPCore", "ProjectMCPSupervisor"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ProjectMCPAppTests", dependencies: ["ProjectMCPApp", "ProjectMCPCore"])
    ]
)
