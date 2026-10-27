// swift-tools-version: 6.0
import PackageDescription

// Shared building blocks for the portfolio's internal macOS admin apps
// (Stokked Wholesale, Nassau, Jeroboam, Carpe Vitem cd_internal, ThenCam,
// Contrarian, Otta). Backend-agnostic: no Supabase dependency — data comes in
// through closures and the `AdminGate` protocol, so each app keeps its own
// client and role model.
let package = Package(
    name: "PortfolioAdminKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PortfolioAdminKit", targets: ["PortfolioAdminKit"]),
    ],
    targets: [
        .target(name: "PortfolioAdminKit"),
        .testTarget(name: "PortfolioAdminKitTests", dependencies: ["PortfolioAdminKit"]),
    ]
)
