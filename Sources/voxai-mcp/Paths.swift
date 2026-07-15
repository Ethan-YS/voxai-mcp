import Foundation

// ── App 容器内的 IPC 文件路径 ─────────────────────────────
// 本进程不在沙盒内，看到的是真实家目录；App 在沙盒内，它的
// Application Support 解析进容器。两侧约定同一物理目录：
//   ~/Library/Containers/com.ethanys.voxai/Data/Library/Application Support/VoxAI/
// 契约与直发版 server.py 一致，只是根从 ~/Library/Application Support/VoxSage
// 换成容器路径。macOS 14+ 外部进程首次访问他人容器会弹一次性 TCC 授权。
enum Paths {
    static let dataDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Containers/com.ethanys.voxai/Data")
            .appendingPathComponent("Library/Application Support/VoxAI", isDirectory: true)
    }()

    // App 是唯一写入方（server 只读）
    static let meetings     = dataDir.appendingPathComponent("meetings.json")
    static let sidecar      = dataDir.appendingPathComponent("live_speakers.json")
    static let dialogInput  = dataDir.appendingPathComponent("dialog_input.json")
    // server 是写入方（App 读取）
    static let advice         = dataDir.appendingPathComponent("live_advice.json")
    static let listener       = dataDir.appendingPathComponent("listener.json")
    static let bootStamp      = dataDir.appendingPathComponent("server_boot.json")
    static let dialogOutput   = dataDir.appendingPathComponent("dialog_output.json")
    static let dialogListener = dataDir.appendingPathComponent("dialog_listener.json")
    static let renameRequests = dataDir.appendingPathComponent("rename_requests.json")
    static let recentTTS      = dataDir.appendingPathComponent("recent_tts.json")
    // 双方读写（App 设置页 P4 起写，server 的 update_voice_config 也写）
    static let config       = dataDir.appendingPathComponent("config.json")
}

// ── JSON 便捷读写（对齐 server.py：读失败给默认值，写走原子替换）──
enum JSONFile {
    static func readDict(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    static func readArray(_ url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return obj
    }

    @discardableResult
    static func write(_ obj: Any, to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

// Swift Date 编码为 timeIntervalSinceReferenceDate（2001-01-01 起算）。
// meetings.json 里的时间戳是 Apple 历法；dialog/listener/boot 系列是 Unix 历法。
let appleEpochOffset = 978_307_200.0

// Apple reference 时间戳 → 本地可读时间，非法值原样返回字符串
func fmtTime(_ appleTS: Any?, withDate: Bool = false) -> String {
    guard let ts = appleTS as? Double else {
        if let n = appleTS as? Int { return fmtTime(Double(n), withDate: withDate) }
        return appleTS.map { "\($0)" } ?? ""
    }
    let date = Date(timeIntervalSince1970: ts + appleEpochOffset)
    let fmt = DateFormatter()
    fmt.dateFormat = withDate ? "yyyy-MM-dd HH:mm:ss" : "HH:mm:ss"
    return fmt.string(from: date)
}

// 本地当前时刻 "HH:mm:ss"（push_advice 的 time 字段用）
func nowHMS(withDate: Bool = false) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = withDate ? "yyyy-MM-dd HH:mm:ss" : "HH:mm:ss"
    return fmt.string(from: Date())
}
