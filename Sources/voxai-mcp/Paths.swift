import Foundation

// ── App 容器内的 IPC 文件路径 ─────────────────────────────
// 本进程不在沙盒内，看到的是真实家目录；App 在沙盒内，它的
// Application Support 解析进容器。两侧约定同一物理目录：
//   ~/Library/Containers/com.ethanys.voxai/Data/Library/Application Support/VoxAI/
// 契约与直发版 server.py 一致，只是根从 ~/Library/Application Support/VoxSage
// 换成容器路径。macOS 14+ 外部进程首次访问他人容器会弹一次性 TCC 授权。
enum Paths {
    static let dataDir: URL = {
        // 测试用:VOXAI_MCP_DATA_DIR 指向一个临时目录,回归脚本造假会议不碰真容器
        if let override = ProcessInfo.processInfo.environment["VOXAI_MCP_DATA_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Containers/com.ethanys.voxai/Data")
            .appendingPathComponent("Library/Application Support/VoxAI", isDirectory: true)
    }()

    // App 是唯一写入方（server 只读）
    static let meetings     = dataDir.appendingPathComponent("meetings.json")
    static let sidecar      = dataDir.appendingPathComponent("live_speakers.json")
    static let dialogInput  = dataDir.appendingPathComponent("dialog_input.json")
    // 实时半句预览(2.2 App 起写:volatile 文本,0.8s 节流;旧版 App 没有这个文件)
    static let livePartial  = dataDir.appendingPathComponent("live_partial.json")
    // server 是写入方（App 读取）
    static let advice         = dataDir.appendingPathComponent("live_advice.json")
    static let listener       = dataDir.appendingPathComponent("listener.json")
    static let bootStamp      = dataDir.appendingPathComponent("server_boot.json")
    static let dialogOutput   = dataDir.appendingPathComponent("dialog_output.json")
    static let dialogListener = dataDir.appendingPathComponent("dialog_listener.json")
    static let renameRequests = dataDir.appendingPathComponent("rename_requests.json")
    static let summaryRequests = dataDir.appendingPathComponent("summary_requests.json")
    static let recentTTS      = dataDir.appendingPathComponent("recent_tts.json")
    // 双方读写（App 设置页 P4 起写，server 的 update_voice_config 也写）
    static let config       = dataDir.appendingPathComponent("config.json")
    // App 启动时写(2.1 起):版本与它认得的通道。server 据此判断写回类工具
    // (提要)对面有没有人接——旧版 App 不读 summary_requests.json,排了队也白排
    static let appInfo      = dataDir.appendingPathComponent("app_info.json")
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

// ── 显示时区(2.2;App 设置 → 显示 → 时区,经 config.json 的 display_timezone 共享)──
// 给 AI 看的时间与 App 界面同一个时区:出差时 Mac 时区在变,用户可以钉住一个。
// 没设 = 本机时区(与旧版行为一致)。fmtTime 逐段调用,配置读取缓存 2 秒、格式器按
// (时区, 格式)缓存。返回体只给换算好的时间,不带时区名 / 偏移,说明里也不提
// (AI 只读时间不读时区——直发版 10-17 Rebecca 拍板)。
// 落盘给 App 读的时间串(live_advice.json 的 updatedAt 等)不走这里,保持本机时区。
enum DisplayTime {
    static let ttl: TimeInterval = 2
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedAt = Date.distantPast
    nonisolated(unsafe) private static var cachedZone: TimeZone = .autoupdatingCurrent
    nonisolated(unsafe) private static var badID = ""
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    /// 当前显示时区;名字非法 → 回退本机时区并在 stderr 记一次(别静默)
    static var zone: TimeZone {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(cachedAt) < ttl { return cachedZone }
        let id = (JSONFile.readDict(Paths.config)["display_timezone"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var tz = TimeZone.autoupdatingCurrent
        if !id.isEmpty {
            if let z = TimeZone(identifier: id) {
                tz = z
            } else if badID != id {
                FileHandle.standardError.write(Data(
                    "[voxai-mcp] display_timezone \"\(id)\" unusable; using the system time zone\n".utf8))
                badID = id
            }
        }
        cachedZone = tz
        cachedAt = now
        return tz
    }

    /// 固定格式的格式器;en_US_POSIX + 公历,机读串不随用户地区 / 历法变形
    static func formatter(_ format: String, zone tz: TimeZone? = nil) -> DateFormatter {
        let tz = tz ?? zone
        lock.lock(); defer { lock.unlock() }
        let key = tz.identifier + "|" + format
        if let f = formatters[key] { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = format
        formatters[key] = f
        return f
    }

    /// 显示时区下的公历日历(since/until 的「今天」「零点」用它算)
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }
}

// Apple reference 时间戳 → 显示时区下的可读时间，非法值原样返回字符串
func fmtTime(_ appleTS: Any?, withDate: Bool = false) -> String {
    guard let ts = appleTS as? Double else {
        if let n = appleTS as? Int { return fmtTime(Double(n), withDate: withDate) }
        return appleTS.map { "\($0)" } ?? ""
    }
    let date = Date(timeIntervalSince1970: ts + appleEpochOffset)
    return DisplayTime.formatter(withDate ? "yyyy-MM-dd HH:mm:ss" : "HH:mm:ss").string(from: date)
}

// 当前时刻 "HH:mm:ss"。默认按显示时区(push_advice 的 time 字段:App 建议栏与导出照原样显示);
// systemZone = true 给落盘的机读串用(保持本机时区)
func nowHMS(withDate: Bool = false, systemZone: Bool = false) -> String {
    DisplayTime.formatter(withDate ? "yyyy-MM-dd HH:mm:ss" : "HH:mm:ss",
                          zone: systemZone ? .autoupdatingCurrent : nil)
        .string(from: Date())
}
