// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DynamicNotch",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NotchKit", targets: ["NotchKit"]),
        .executable(name: "DynamicNotch", targets: ["DynamicNotch"]),
    ],
    targets: [
        // 플랫폼 공용 UI/상태 (macOS + 나중에 iPhone 13 Pro Max)
        .target(name: "NotchKit"),
        // macOS 앱: 노치 위 패널 + 시스템 이벤트 수집
        .executableTarget(
            name: "DynamicNotch",
            dependencies: ["NotchKit"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
