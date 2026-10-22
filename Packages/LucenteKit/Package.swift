// swift-tools-version: 6.2
import PackageDescription

// Everything that isn't SwiftUI lives here: the vendor-neutral model, the per-vendor protocol
// drivers, the CoreBluetooth transport and the observable store the app binds to. Kept as a
// package so `swift test` runs the protocol tests in seconds without building the app.
let package = Package(
    name: "LucenteKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LucenteKit", targets: ["LucenteKit"]),
        .executable(name: "lucente-probe", targets: ["LucenteProbe"]),
    ],
    targets: [
        .target(name: "LucenteKit"),
        .executableTarget(name: "LucenteProbe", dependencies: ["LucenteKit"]),
        .testTarget(name: "LucenteKitTests", dependencies: ["LucenteKit"]),
    ]
)
