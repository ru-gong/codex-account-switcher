// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CodexAccountSwitcher", platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexAccountSwitcher", targets: ["SwitcherApp"]), .executable(name: "switcherctl", targets: ["SwitcherCLI"])],
    targets: [.target(name: "SwitcherCore"), .executableTarget(name: "SwitcherApp", dependencies: ["SwitcherCore"]), .executableTarget(name: "SwitcherCLI", dependencies: ["SwitcherCore"]), .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"])],
    swiftLanguageModes: [.v5]
)
