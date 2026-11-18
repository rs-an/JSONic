// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "JSONic", platforms: [.macOS(.v13)],
    products: [.executable(name: "JSONic", targets: ["JSONic"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CLibXLS", path: "Vendor/libxls", sources: ["src"], publicHeadersPath: "include", linkerSettings: [.linkedLibrary("iconv")]),
        .target(name: "ZIPFoundation", path: "Vendor/ZIPFoundation", exclude: ["Resources"]),
        .target(name: "JSONicCore", dependencies: ["CSQLite", "CLibXLS", "ZIPFoundation"]),
        .executableTarget(name: "JSONic", dependencies: ["JSONicCore"]),
        .executableTarget(name: "JSONicChecks", dependencies: ["JSONicCore", "ZIPFoundation"], path: "Checks", exclude: ["Fixtures"])
    ])
