// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeDesktopSwap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cdswap", targets: ["cdswap"]),
        .executable(name: "ClaudeSwapApp", targets: ["ClaudeSwapApp"]),
    ],
    targets: [
        .target(name: "SwapCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "cdswap", dependencies: ["SwapCore"]),
        .executableTarget(name: "ClaudeSwapApp", dependencies: ["SwapCore"]),
    ]
)
