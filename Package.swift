// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlindWatermark",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        // iOS 接入用（含 UIKit 窗口层与自动加载）
        .library(name: "BlindWatermark", targets: ["BlindWatermark"]),
        // 仅编解码核心，跨平台（macOS 上可跑测试与解码 CLI）
        .library(name: "BlindWatermarkCore", targets: ["BlindWatermarkCore"]),
        // 截图解码工具：swift run bwdecode shot.png
        .executable(name: "bwdecode", targets: ["bwdecode"]),
    ],
    targets: [
        .target(name: "BlindWatermarkCore"),
        // ObjC +load，实现零接入自动挂载
        .target(name: "BlindWatermarkAutoLoad", publicHeadersPath: "include"),
        .target(
            name: "BlindWatermark",
            dependencies: ["BlindWatermarkCore", "BlindWatermarkAutoLoad"]
        ),
        .executableTarget(name: "bwdecode", dependencies: ["BlindWatermarkCore"]),
        .testTarget(name: "BlindWatermarkCoreTests", dependencies: ["BlindWatermarkCore"]),
    ]
)
