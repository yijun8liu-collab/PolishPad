// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PolishPad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PolishPad",
            dependencies: ["whisper"],
            path: "Sources/PolishPad",
            linkerSettings: [
                // whisper.framework 打包在 App 的 Frameworks 目录（build.sh 负责拷贝）
                .unsafeFlags(["-Xlinker", "-rpath",
                              "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        // whisper.cpp 官方预编译 xcframework（Metal 加速，arm64+x86_64）。
        // 文件较大不入库：build.sh 缺失时自动下载到 Vendor/
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
    ]
)
