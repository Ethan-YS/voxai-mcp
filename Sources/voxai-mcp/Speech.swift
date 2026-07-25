import Foundation

// Linux 把 URLSession/HTTPURLResponse 拆在 FoundationNetworking 里
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// ── TTS 层 ───────────────────────────────────────────────
// 三条路：
//   system —— /usr/bin/say（= AVSpeechSynthesizer 的命令行形态，离线零
//             依赖，terminate 即打断）。默认档。
//   azure  —— BYOK：SSML + 官方端点 + afplay，用户自己的 key 与额度。
//   local  —— **Qwen 六声线**（P4-3 补回；组件由本 server 管，App 不碰
//             ——见 VoiceComponent 顶部对 MAS 2.5.2 边界的说明）。
// 任一路失败一律降级 say：有声可出优先（直发版同款哲学）。
actor SpeechEngine {
    static let shared = SpeechEngine()

    private var playProc: Process? = nil
    private var generation = 0          // speak 换代号：旧任务的降级兜底不再出声

    // ── 配置 ──────────────────────────────────────────────
    // 计算属性：[String: Any] 非 Sendable，Swift 6 不允许做静态存储
    static var defaultConfig: [String: Any] { [
        "cn_engine": "system",          // "system" | "azure"(BYOK) | "local"(Qwen 六声线)
        "cn_voice": "xiaoxiao",         // azure: xiaoxiao/yunxi/xiaoyi；local: Vivian/Aiden/…
        "en_voice": "default",          // system 声音名（say -v 的名字）
        "speed": 1.0,                   // 0.5 ~ 2.0
        "language": "auto",             // "auto" | "zh" | "en"
    ] }

    static let azureVoices: [String: String] = [
        "xiaoxiao": "zh-CN-XiaoxiaoNeural",
        "yunxi": "zh-CN-YunxiNeural",
        "xiaoyi": "zh-CN-XiaoyiNeural",
    ]

    static func loadConfig() -> [String: Any] {
        defaultConfig.merging(JSONFile.readDict(Paths.config)) { _, new in new }
    }

    // ⚠️ azure_tts_key/region 是凭据，绝不进 defaultConfig
    //（list_voices/update_voice_config 只回显 defaultConfig 键——安全线）
    static func azureCfg() -> (key: String, region: String) {
        let cfg = loadConfig()
        let key = (cfg["azure_tts_key"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let region = (cfg["azure_tts_region"] as? String ?? "eastasia")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key, region.isEmpty ? "eastasia" : region)
    }

    static func isChinese(_ text: String) -> Bool {
        let total = max(text.count, 1)
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return Double(cjk) / Double(total) > 0.2
    }

    // macOS say 是否装了中文声 Tingting（选声用；结果进程内缓存）
    private static let hasTingting: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "?"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.contains("Tingting") ?? false
    }()

    // ── speak 的文本落盘（最近 10 条）——App 据此过滤麦克风录回的 TTS 回声 ──
    static func recordRecentTTS(_ text: String) {
        var items = JSONFile.readDict(Paths.recentTTS)["items"] as? [[String: Any]] ?? []
        items.append(["timestamp": Date().timeIntervalSince1970, "text": text])
        if items.count > 10 { items.removeFirst(items.count - 10) }
        JSONFile.write(["items": items], to: Paths.recentTTS)
    }

    // ── 播放控制 ──────────────────────────────────────────

    func stop() {
        generation += 1
        if let p = playProc, p.isRunning { p.terminate() }
        playProc = nil
    }

    // 启动外部播放命令（say / afplay），不等待结束；换代打断由 stop() 负责
    private func launch(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if (try? p.run()) != nil { playProc = p }
    }

    // macOS 内建 say——离线、零依赖。系统引擎主路径 + Azure 失败兜底
    private func speakSay(_ text: String, speed: Double, chinese: Bool, voice: String? = nil) {
        let rate = String(Int(175 * min(2.0, max(0.5, speed))))
        var args = ["-r", rate]
        if let voice, voice != "default" {
            args += ["-v", voice]
        } else if chinese, Self.hasTingting {
            args += ["-v", "Tingting"]
        }
        args.append(text)
        launch("/usr/bin/say", args)
    }

    // ── 中文 TTS · Azure 官方（用户自带 Key，BYOK）────────
    // 用量记在用户自己的 Azure 账户上；key 无效/断网降级 say，有声可出优先
    private func speakAzure(_ text: String, voiceName: String, speed: Double) async {
        let (key, region) = Self.azureCfg()
        guard !key.isEmpty else {
            speakSay(text, speed: speed, chinese: true)
            return
        }
        let myGen = generation
        let ratePct = Int((speed - 1.0) * 100)
        let rateStr = ratePct >= 0 ? "+\(ratePct)%" : "\(ratePct)%"
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let ssml = "<speak version='1.0' xml:lang='zh-CN'>"
            + "<voice name='\(voiceName)'><prosody rate='\(rateStr)'>"
            + "\(escaped)</prosody></voice></speak>"
        var req = URLRequest(
            url: URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1")!,
            timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = Data(ssml.utf8)
        req.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        req.setValue("audio-24khz-96kbitrate-mono-mp3",
                     forHTTPHeaderField: "X-Microsoft-OutputFormat")
        req.setValue("VoxAI", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                throw URLError(.badServerResponse)
            }
            guard myGen == generation else { return }   // 下载期间被 stop/新 speak 打断
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("voxai-tts-\(UUID().uuidString).mp3")
            try data.write(to: tmp)
            launch("/usr/bin/afplay", [tmp.path])
            // afplay 结束后清理临时文件（不阻塞当前调用）
            let proc = playProc
            Task.detached {
                proc?.waitUntilExit()
                try? FileManager.default.removeItem(at: tmp)
            }
        } catch {
            guard myGen == generation else { return }
            speakSay(text, speed: speed, chinese: true)
        }
    }

    // ── 中文本地 TTS · Qwen 六声线（组件由 server 管，App 不碰）────
    // 组件的 CLI 契约与直发版一致：--text/--voice/--speed/--out。
    // 模型走 HF_HOME 缓存（首次约 2GB）；国内 HF 直连不稳，config 的
    // hf_endpoint 可覆盖成镜像（直发版下载器同款兜底）。
    private func speakLocalQwen(_ text: String, speed: Double, voice: String) async {
        guard let bin = VoiceComponent.resolvedBinary() else {
            speakSay(text, speed: speed, chinese: true)   // 组件没装 → 有声可出优先
            return
        }
        let myGen = generation
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxai-qwen-\(UUID().uuidString).wav")
        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = VoiceComponent.hfCacheDir.path
        if let ep = Self.loadConfig()["hf_endpoint"] as? String, !ep.isEmpty {
            env["HF_ENDPOINT"] = ep
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--text", text, "--voice", voice,
                       "--speed", String(speed), "--out", tmp.path]
        p.environment = env
        p.standardOutput = Pipe()   // 合成日志不许污染 stdio 的 JSON-RPC 信道
        p.standardError = Pipe()
        do {
            try p.run()
            // 合成期间不占用 playProc：此刻还没出声，stop() 该打断的是播放。
            // **必须有超时**（直发版同款 120s）：模型没下好时组件会一直等
            // HuggingFace——而 HF 对未认证请求限速，实测 2GB 能拖 40 分钟。
            // 没有这道闸，用户让 AI 朗读一句会换来几十分钟的静默死等。
            let finished = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async {
                    let deadline = Date().addingTimeInterval(120)
                    while p.isRunning, Date() < deadline { usleep(100_000) }
                    if p.isRunning { p.terminate(); c.resume(returning: false) }
                    else { c.resume(returning: true) }
                }
            }
            guard myGen == generation else {          // 合成期间被打断
                try? FileManager.default.removeItem(at: tmp); return
            }
            guard finished, p.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: tmp.path) else {
                // 超时/失败 → 有声可出优先（模型多半还在后台下）
                try? FileManager.default.removeItem(at: tmp)
                speakSay(text, speed: speed, chinese: true); return
            }
            launch("/usr/bin/afplay", [tmp.path])
            let proc = playProc
            Task.detached {
                proc?.waitUntilExit()
                try? FileManager.default.removeItem(at: tmp)
            }
        } catch {
            guard myGen == generation else { return }
            speakSay(text, speed: speed, chinese: true)
        }
    }

    // ── speak 主路由 ──────────────────────────────────────
    func speak(text: String, voiceID: String) async -> String {
        let cfg = Self.loadConfig()
        stop()

        let lang = cfg["language"] as? String ?? "auto"
        let useChinese = lang == "auto" ? Self.isChinese(text) : lang == "zh"
        let speed = (cfg["speed"] as? Double) ?? (cfg["speed"] as? Int).map(Double.init) ?? 1.0
        let vid = voiceID != "default" ? voiceID
            : (useChinese ? cfg["cn_voice"] as? String ?? "xiaoxiao"
                          : cfg["en_voice"] as? String ?? "default")

        if useChinese {
            let engine = cfg["cn_engine"] as? String ?? "system"
            if engine == "local" {
                // cn_voice 传到底：直发版曾把这里写死成常量 Vivian，六声线
                // 在 speak 路径上白白失效过——那个 bug 不要再犯一次
                let speaker = VoiceComponent.speakers.contains(vid)
                    ? vid : VoiceComponent.defaultSpeaker
                let installed = VoiceComponent.isInstalled
                await speakLocalQwen(text, speed: speed, voice: speaker)
                let label = installed ? "local Qwen3-TTS \(speaker)"
                    : "macOS say — voice component not installed "
                      + "(ask me to run install_voice_component)"
                return "Playing (Chinese, \(text.count) chars, \(label))"
            }
            if engine == "azure" {
                let voiceName = Self.azureVoices[vid] ?? Self.azureVoices["xiaoxiao"]!
                let hasKey = !Self.azureCfg().key.isEmpty
                await speakAzure(text, voiceName: voiceName, speed: speed)
                let label = hasKey ? "Azure \(vid) (your key)"
                                   : "macOS say — Azure key not configured"
                return "Playing (Chinese, \(text.count) chars, \(label))"
            }
            // system（及未知引擎值）→ 系统声
            speakSay(text, speed: speed, chinese: true)
            let label = Self.hasTingting ? "system say Tingting" : "system say"
            return "Playing (Chinese, \(text.count) chars, \(label))"
        }
        speakSay(text, speed: speed, chinese: false, voice: vid)
        return "Playing (English, \(text.count) chars, system say)"
    }

    // ── list_voices / update_voice_config ────────────────

    static func listVoices() -> [String: Any] {
        let cfg = loadConfig()
        // 只回显语音相关键——config.json 里还有 azure_tts_key 等凭据，
        // 不能泄给接入的 AI 客户端（会进对方聊天日志）
        let visible = defaultConfig.keys.reduce(into: [String: Any]()) {
            if let v = cfg[$1] { $0[$1] = v }
        }
        return [
            "config": visible,
            "engines": [
                "system_say": "available (built-in, offline)",
                "chinese_azure_tts": azureCfg().key.isEmpty
                    ? "no key configured (set in app Settings; falls back to macOS say)"
                    : "available (user's own key)",
                // 如实分三态：装了但模型还在下 ≠ 能用。含糊报「available」
                // 会让 AI 以为切过去就能听到 Qwen，用户却只听到系统声
                "chinese_local_qwen3_tts": !VoiceComponent.isInstalled
                    ? "not installed — call install_voice_component to add it "
                      + "(falls back to macOS say meanwhile)"
                    : (VoiceComponent.modelReady
                        ? "available (offline, on-device)"
                        : "installed, but the voice model is still downloading "
                          + "in the background — speak() uses the system voice "
                          + "until it finishes"),
            ],
            "chinese_azure_tts": Array(azureVoices.keys).sorted(),
            "chinese_local_qwen3_tts": VoiceComponent.speakers,
            "system_say": "auto-selects a system voice (Tingting for Chinese); "
                + "en_voice accepts any name from `say -v '?'`",
        ]
    }

    static func updateConfig(cnEngine: String?, cnVoice: String?, enVoice: String?,
                             speed: Double?, language: String?) -> String {
        var cfg = JSONFile.readDict(Paths.config)   // 保留凭据等未知键
        if let cnEngine { cfg["cn_engine"] = cnEngine }
        if let cnVoice { cfg["cn_voice"] = cnVoice }
        if let enVoice { cfg["en_voice"] = enVoice }
        if let speed { cfg["speed"] = min(2.0, max(0.5, speed)) }
        if let language { cfg["language"] = language }
        JSONFile.write(cfg, to: Paths.config)

        // 同 list_voices：凭据键不回显
        let merged = defaultConfig.merging(cfg) { _, new in new }
        let visible = defaultConfig.keys.sorted().reduce(into: [String: Any]()) {
            if let v = merged[$1] { $0[$1] = v }
        }
        let json = (try? JSONSerialization.data(withJSONObject: visible, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "Config updated: \(json)"
    }
}
