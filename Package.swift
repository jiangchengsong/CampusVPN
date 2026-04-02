// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CampusVPN",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CampusVPN",
            path: "CampusVPN",
            exclude: [
                "Info.plist",
                "CampusVPN.entitlements"
            ],
            resources: [
                .process("Assets.xcassets")
            ],
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security")
            ]
        )
    ]
)
