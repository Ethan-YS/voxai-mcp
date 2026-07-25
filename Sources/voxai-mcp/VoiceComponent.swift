#if canImport(CryptoKit)
    import CryptoKit  // Apple 平台
#else
    import Crypto  // swift-crypto：Linux 上的同名 API
#endif
import Foundation

// Linux 把 URLSession/HTTPURLResponse 拆在 FoundationNetworking 里
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// ── Qwen 语音组件（P4-3：补回 DR-030 砍错的一刀）──────────
//
// 为什么商店版能有 Qwen 六声线：
//   DR-030 砍它的理由是「组件是可执行程序，MAS 2.5.2 硬禁」——但那条规矩
//   只管**商店里的 App**。朗读（speak）是 MCP 工具，干活的是**本 server**，
//   而 server 商店外分发、不受 MAS 约束：它想下载什么、执行什么都行。
//   合规线因此清清楚楚：**App 全程不碰组件**（不下载、不执行、不感知），
//   下载与调用全在 server 这一侧。
//
// 组件本身是现成的：直发版打包好的 voxsage-tts.app（PyInstaller 打的
// Python + mlx-audio），已 Developer ID 签名 + 公证 + staple，官网
// manifest 托管。这里复用同一份产物与同一个 manifest。
//
// 装在哪：**App 容器内的 components/**。不是图省事——容器随 App 卸载一起
// 删，2.2GB 不会变成孤儿残留在用户盘上（装容器外就会）。server 是非沙盒
// 进程，写容器天经地义。
enum VoiceComponent {

    /// 组件清单（直发版与商店版共用同一份，官网托管）
    static let manifestURL = "https://voxai.ethanflow.com/tts-manifest.json"

    static var componentsDir: URL { Paths.dataDir.appendingPathComponent("components") }
    /// 复用直发版打包产物 → 目录名保持 voxsage-tts.app（改名要重打包+重公证，
    /// 徒增一条分叉；用户看不到这个路径）
    static var binaryURL: URL {
        componentsDir
            .appendingPathComponent("voxsage-tts.app/Contents/MacOS/voxsage-tts")
    }
    /// 模型缓存（组件首次朗读时按 HF_HOME 拉 ~2GB）
    static var hfCacheDir: URL { Paths.dataDir.appendingPathComponent("hf-cache") }

    /// 六声线（config.spk_id 实查；性别以基频实测为准——直发版原样继承）
    static let speakers = ["Vivian", "Aiden", "Dylan", "Serena", "Eric", "Ryan"]
    static let defaultSpeaker = "Vivian"

    /// env 覆盖优先（调试用），否则看容器内装没装
    static func resolvedBinary() -> String? {
        if let p = ProcessInfo.processInfo.environment["VOXAI_TTS"],
           FileManager.default.isExecutableFile(atPath: p) { return p }
        let p = binaryURL.path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    static var isInstalled: Bool { resolvedBinary() != nil }

    // ── 清单 ──────────────────────────────────────────────

    struct Manifest {
        let version: String
        let url: URL
        let sha256: String
        let size: Int64
        let modelBytes: Int64
    }

    static func fetchManifest() async throws -> Manifest {
        var req = URLRequest(url: URL(string: manifestURL)!, timeoutInterval: 20)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = o["version"] as? String,
              let u = (o["url"] as? String).flatMap(URL.init(string:)),
              let sha = o["sha256"] as? String
        else { throw Err.badManifest }
        return Manifest(version: v, url: u, sha256: sha.lowercased(),
                        size: (o["size"] as? NSNumber)?.int64Value ?? 0,
                        modelBytes: (o["modelBytes"] as? NSNumber)?.int64Value ?? 0)
    }

    enum Err: LocalizedError {
        case badManifest, download(String), checksum, unzip(String)
        var errorDescription: String? {
            switch self {
            case .badManifest: return "voice component manifest is unreadable"
            case .download(let s): return "download failed: \(s)"
            case .checksum: return "checksum mismatch — refusing to install"
            case .unzip(let s): return "unzip failed: \(s)"
            }
        }
    }

    // ── 安装 ──────────────────────────────────────────────

    /// 下载 → 校验 sha256 → 解压进容器。返回人话结果给 AI 复述给用户。
    static func install() async throws -> String {
        let m = try await fetchManifest()

        let (tmp, resp) = try await URLSession.shared.download(from: m.url)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Err.download("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        // 校验是硬门：装一个可执行程序，字节对不上就绝不落地
        let digest = try sha256(of: tmp)
        guard digest == m.sha256 else { throw Err.checksum }

        try? FileManager.default.createDirectory(at: componentsDir,
                                                 withIntermediateDirectories: true)
        // 旧版本先清掉，避免 ditto 把新旧文件混在一个 .app 里
        try? FileManager.default.removeItem(
            at: componentsDir.appendingPathComponent("voxsage-tts.app"))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", tmp.path, componentsDir.path]
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                           encoding: .utf8) ?? ""
            throw Err.unzip(e.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard isInstalled else { throw Err.unzip("binary missing after unzip") }

        // 模型预取：装完立刻在后台拉，别把它塞进用户的第一次朗读里。
        // HuggingFace 对未认证请求限速——实测 ~2GB 能拖 40 分钟，而 speak
        // 只等 120 秒就降级系统声。所以这里先起个后台进程暖着，用户在等的
        // 这段时间里朗读照常可用（只是暂时用系统声）。
        startModelPrefetch()

        let gb = Double(m.modelBytes) / 1_000_000_000
        return "Voice component v\(m.version) installed. "
            + "The ~\(String(format: "%.1f", gb))GB voice model is now downloading "
            + "in the background — it can take a while on a slow link. Until it "
            + "lands, speak() quietly falls back to the system voice; no need to "
            + "wait or retry. Call list_voices to see when it's ready."
    }

    /// 防重入：装两次别起两个下载进程互相抢 HF 的限速额度
    /// （Swift 6 不许裸的可变全局状态，圈进 actor）
    private actor PrefetchGate {
        static let shared = PrefetchGate()
        private var running = false
        /// 返回 true = 你拿到了这次机会
        func claim() -> Bool {
            if running { return false }
            running = true
            return true
        }
        func release() { running = false }
    }

    /// 后台跑一次极短的合成来把模型拉下来。不等它、不管它的输出——
    /// 进程活着就够，模型进了 HF_HOME 缓存后 speak 自然就快了。
    static func startModelPrefetch() {
        guard let bin = resolvedBinary() else { return }
        Task.detached {
            guard await PrefetchGate.shared.claim() else { return }
            await runPrefetch(bin: bin)
            await PrefetchGate.shared.release()
        }
    }

    private static func runPrefetch(bin: String) async {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxai-warmup-\(UUID().uuidString).wav")
        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = hfCacheDir.path
        if let ep = SpeechEngine.loadConfig()["hf_endpoint"] as? String, !ep.isEmpty {
            env["HF_ENDPOINT"] = ep       // 国内 HF 直连不稳时可指镜像
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--text", "预热", "--voice", defaultSpeaker,
                       "--speed", "1.0", "--out", out.path]
        p.environment = env
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }
        // 等它跑完（调用方已在 detached Task 里，不挡任何人），
        // 完事清掉暖机产物并交还闸口
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        try? FileManager.default.removeItem(at: out)
    }

    /// 模型是否已就位（缓存里有像样体积的权重）。list_voices 用它如实报告，
    /// 免得用户以为装完组件就能立刻听到 Qwen。
    static var modelReady: Bool {
        guard let e = FileManager.default.enumerator(
            at: hfCacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return false }
        var total: Int64 = 0
        for case let u as URL in e {
            // .incomplete 是 HF 的半成品分块，不算数
            if u.lastPathComponent.hasSuffix(".incomplete") { continue }
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if total > 1_500_000_000 { return true }
        }
        return false
    }

    static func sha256(of url: URL) throws -> String {
        // 分块读：组件近 200MB，整个读进内存没必要
        let h = FileHandle(forReadingAtPath: url.path)
        defer { try? h?.close() }
        guard let h else { throw Err.download("cannot open downloaded file") }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = h.readData(ofLength: 4 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
