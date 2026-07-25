import Foundation

// ── 跨平台垫片 ─────────────────────────────────────────────
// 这个 server 的**功能**需要 macOS 宿主 App：它靠读写 App 沙盒容器里的
// IPC 文件干活（见 Paths.swift）。但 MCP **协议层**（initialize / tools/list）
// 不碰宿主，所以 server 在 Linux 上也能编译、启动、如实握手并报出完整工具表。
//
// 为什么要能在 Linux 跑：MCP 目录站点（如 Glama）用容器化检查验证 server
// "能启动并响应 initialize"。与其为过检查造一个假 server，不如让真 server
// 在非 macOS 平台如实降级——协议层是真的，工具调用则明确说明缺什么，
// 不静默返回空数据骗人。

#if !canImport(ObjectiveC)
// Linux 的 Foundation 没有 autoreleasepool —— 那是 ObjC runtime 的设施。
// 语义上它只是个作用域，直接执行闭包即可。
@inline(__always)
func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T {
    try body()
}
#endif

enum Host {
    /// 宿主 App 只存在于 macOS；其他平台一律视为不可用。
    static var isSupported: Bool {
        #if os(macOS)
            return true
        #else
            return false
        #endif
    }

    /// 非 macOS 平台上工具调用的统一回复。说清三件事：server 是活的、
    /// 缺的是什么、去哪儿才能真正用起来。
    static let unsupportedMessage = """
        This tool needs the VoxAI macOS app, which isn't present on this platform.

        The server itself is running and will report its full tool list over MCP, \
        but every tool here reads or writes files inside the VoxAI app's container, \
        so none of them can return real data on a non-macOS host.

        To actually use it: install VoxAI on macOS 14+ (https://voxai.ethanflow.com) \
        and run this server on that machine.
        """
}
