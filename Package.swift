// swift-tools-version: 6.0
// VoxAI MCP server —— 商店外分发的独立伴生工具（DR-030）。
// 单二进制 stdio server；文件 IPC 指向 App 沙盒容器，App 本体不下载不执行它。
import PackageDescription

let package = Package(
    name: "voxai-mcp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // 仅 Linux 链接:CryptoKit 是 Apple 专有,swift-crypto 提供同名 API。
        // Apple 平台上它会被 resolve 但不参与链接(见下方 condition)。
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "voxai-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(
                    name: "Crypto", package: "swift-crypto",
                    condition: .when(platforms: [.linux])),
            ]
        )
    ]
)
