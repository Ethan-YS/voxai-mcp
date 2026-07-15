import Foundation
import Logging
import MCP

// ── 启动握手：写 boot stamp（App 设置页「AI 接入」据 pid 存活判「已连接」）──
// 握手失败不阻塞启动（磁盘只读等极端情况下 server 照常服务）
func writeBootStamp() {
    JSONFile.write([
        "pid": ProcessInfo.processInfo.processIdentifier,
        "startedAt": Date().timeIntervalSince1970,
        "server": "swift",
    ] as [String: Any], to: Paths.bootStamp)
}

// stdout 是 stdio JSON-RPC 信道，启动横幅必须走 stderr
FileHandle.standardError.write(Data("VoxAI MCP Server starting...\n".utf8))
writeBootStamp()

let server = Server(
    name: "VoxAI",
    version: "2.0.0",
    instructions: serverInstructions,
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: allTools)
}

await server.withMethodHandler(CallTool.self) { params in
    await dispatchTool(name: params.name, arguments: params.arguments ?? [:])
}

// 调试日志走 stderr（VOXAI_MCP_DEBUG=1 时打开；stdout 是 JSON-RPC 信道不能碰）
var debugLogger: Logger? = nil
if ProcessInfo.processInfo.environment["VOXAI_MCP_DEBUG"] == "1" {
    var logger = Logger(label: "voxai-mcp") { label in
        StreamLogHandler.standardError(label: label)
    }
    logger.logLevel = .trace
    debugLogger = logger
}

let transport = StdioTransport(logger: debugLogger)
try await server.start(transport: transport)
await server.waitUntilCompleted()
