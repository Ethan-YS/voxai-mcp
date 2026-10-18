import Foundation

// ── 会议数据读取与语义（逐函数对齐 server.py）────────────────
// meetings.json 写权归 App；这里只读。改名走 rename_requests.json 队列。
enum Meetings {

    // 读取 meetings.json，失败时返回空列表
    static func load() -> [[String: Any]] {
        JSONFile.readArray(Paths.meetings)
    }

    // 读取实时说话人标注 sidecar；不属于该会议或读取失败返回空
    static func liveSpeakerMap(meetingID: String) -> [String: String] {
        let sc = JSONFile.readDict(Paths.sidecar)
        guard sc["meetingId"] as? String == meetingID,
              let speakers = sc["speakers"] as? [String: String] else { return [:] }
        return speakers
    }

    // 场景标识（v0.10.0 起 App 写入；老记录由 isCall 推断）
    // 取值: meeting / call / in_person
    static func scenario(_ meeting: [String: Any]) -> String {
        if let s = meeting["scenario"] as? String, !s.isEmpty { return s }
        return (meeting["isCall"] as? Bool == true) ? "call" : "meeting"
    }

    // endTime 为空且 30 分钟内有活动才算进行中（App 崩溃会留下无 endTime 的残留）
    static func isLive(_ meeting: [String: Any]) -> Bool {
        if meeting["endTime"] != nil, !(meeting["endTime"] is NSNull) { return false }
        let segments = meeting["segments"] as? [[String: Any]] ?? []
        var lastActivity = meeting["startTime"] as? Double ?? 0
        if let ts = segments.last?["timestamp"] as? Double {
            lastActivity = max(lastActivity, ts)
        }
        let nowApple = Date().timeIntervalSince1970 - appleEpochOffset
        return nowApple - lastActivity <= 1800
    }

    // 最新一场会议（按 startTime）；更早的无 endTime 记录视为异常残留
    static func latest(_ meetings: [[String: Any]]) -> [String: Any]? {
        meetings.max { ($0["startTime"] as? Double ?? 0) < ($1["startTime"] as? Double ?? 0) }
    }

    // 转录段输出格式；已有说话人优先，空标签用实时标注补齐
    static func segmentOut(_ s: [String: Any], liveMap: [String: String]) -> [String: Any] {
        let speaker = (s["speaker"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? liveMap[s["id"] as? String ?? ""] ?? ""
        return [
            "timestamp": fmtTime(s["timestamp"]),
            "speaker": speaker,
            "text": s["text"] as? String ?? "",
        ]
    }

    // ── 工具实现 ──────────────────────────────────────────

    static func listMeetings(since: String = "", until: String = "", titleContains: String = "",
                             scenario: String = "", hasSummary: Bool? = nil,
                             limit: Int = 0, includePreview: Bool = true) throws -> [[String: Any]] {
        var meetings = try Search.filter(load(), since: since, until: until,
                                         titleContains: titleContains, scenario: scenario,
                                         hasSummary: hasSummary)
        if limit > 0 { meetings = Array(meetings.prefix(limit)) }
        return meetings.map { m in
            let segments = m["segments"] as? [[String: Any]] ?? []
            var item: [String: Any] = [
                "id": m["id"] as? String ?? "",
                "title": m["title"] as? String ?? "Untitled",
                "scenario": Meetings.scenario(m),
                "startTime": fmtTime(m["startTime"], withDate: true),
                "endTime": fmtTime(m["endTime"], withDate: true),
                "isLive": isLive(m),
                "segmentCount": segments.count,
                "hasSummary": Search.hasSummary(m),
            ]
            if includePreview {
                let firstText = segments.first?["text"] as? String
                item["preview"] = firstText.map { String($0.prefix(50)) } ?? "(empty)"
            }
            return item
        }
    }

    // meetings.json 里的 summary → 工具返回体(时间格式化;缺字段补空)
    static func summaryOut(_ m: [String: Any]) -> Any {
        guard Search.hasSummary(m), let sm = m["summary"] as? [String: Any] else { return NSNull() }
        return [
            "overview": sm["overview"] as? String ?? "",
            "actionItems": sm["actionItems"] as? [String] ?? [],
            "keyFacts": sm["keyFacts"] as? [String] ?? [],
            "openQuestions": sm["openQuestions"] as? [String] ?? [],
            "bySpeaker": sm["bySpeaker"] as? [String: [String]] ?? [:],
            "by": sm["by"] as? String ?? "",
            "generatedAt": fmtTime(sm["generatedAt"], withDate: true),
        ] as [String: Any]
    }

    static func getMeeting(id meetingID: String, includeTranscript: Bool = true) -> [String: Any] {
        for m in load() where m["id"] as? String == meetingID {
            let segments = m["segments"] as? [[String: Any]] ?? []
            var out: [String: Any] = [
                "id": m["id"] as? String ?? "",
                "title": m["title"] as? String ?? "Untitled",
                "scenario": scenario(m),
                "startTime": fmtTime(m["startTime"], withDate: true),
                "endTime": fmtTime(m["endTime"], withDate: true),
                "isLive": isLive(m),
                "summary": summaryOut(m),
                "segmentCount": segments.count,
            ]
            if includeTranscript {
                let liveMap = liveSpeakerMap(meetingID: meetingID)
                out["segments"] = segments.map { segmentOut($0, liveMap: liveMap) }
            }
            return out
        }
        return ["error": "No meeting found with ID '\(meetingID)'"]
    }

    // ── AI 会后提要(set_meeting_summary → summary_requests.json 队列,与改名同款通道)──
    static let summaryListMax = 30        // 每个列表最多条数
    static let summaryItemMax = 300       // 每条最长字符
    static let summaryOverviewMax = 3000

    private static func cleanList(_ items: [String]) -> [String] {
        var out: [String] = []
        for it in items {
            let t = it.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(String(t.prefix(summaryItemMax))) }
            if out.count >= summaryListMax { break }
        }
        return out
    }

    /// App 2.1 起启动时写 app_info.json,声明认得 summary 通道;没有就是旧版
    static func appAcceptsSummaries() -> Bool {
        (JSONFile.readDict(Paths.appInfo)["channels"] as? [String] ?? []).contains("summary")
    }

    static func setMeetingSummary(id meetingID: String, overview raw: String,
                                  actionItems: [String], keyFacts: [String],
                                  openQuestions: [String], bySpeaker: [String: [String]],
                                  by: String) -> String {
        let overview = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if overview.isEmpty { return "Error: empty overview — a summary needs at least the conclusions" }
        guard load().contains(where: { $0["id"] as? String == meetingID }) else {
            return "Error: no meeting found with ID '\(meetingID)'"
        }
        // 旧版 App 不读这个队列:如实说,别让 AI 以为写进去了
        guard appAcceptsSummaries() else {
            return "Error: this VoxAI app version can't store summaries — ask the user to update "
                + "VoxAI from the Mac App Store (2.1 or later), then call this again. "
                + "Meanwhile, give the summary in chat."
        }
        var spk: [String: [String]] = [:]
        for (k, v) in bySpeaker {
            let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
            let items = cleanList(v)
            if !key.isEmpty, !items.isEmpty { spk[key] = items }
        }
        let name = String(by.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let summary: [String: Any] = [
            "overview": String(overview.prefix(summaryOverviewMax)),
            "actionItems": cleanList(actionItems),
            "keyFacts": cleanList(keyFacts),
            "openQuestions": cleanList(openQuestions),
            "bySpeaker": spk,
            "by": name.isEmpty ? "AI" : name,
        ]
        // 同一场只保留最后一份
        var queue = JSONFile.readArray(Paths.summaryRequests)
            .filter { $0["meetingId"] as? String != meetingID }
        queue.append(["meetingId": meetingID, "summary": summary])
        JSONFile.write(queue, to: Paths.summaryRequests)
        let n = (summary["actionItems"] as! [String]).count + (summary["keyFacts"] as! [String]).count
            + (summary["openQuestions"] as! [String]).count
        return "Summary queued for \(meetingID.prefix(8))… (\(overview.count) chars overview, "
            + "\(n) items; applied by the app within seconds)"
    }

    // AI 改名队列：server 只排队，App 定时器落地（meetings.json 写权归 App）
    static func renameMeeting(id meetingID: String, newTitle: String) -> String {
        var title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "Error: empty title" }
        title = String(title.prefix(60))
        guard load().contains(where: { $0["id"] as? String == meetingID }) else {
            return "Error: no meeting found with ID '\(meetingID)'"
        }
        var queue = JSONFile.readArray(Paths.renameRequests)
        queue.append(["meetingId": meetingID, "title": title])
        JSONFile.write(queue, to: Paths.renameRequests)
        return "Rename queued: “\(title)” (applied by the app within seconds)"
    }

    // ── 旁听心跳 ──────────────────────────────────────────

    // 刷新心跳；name 仅显式报到时传入，纯轮询心跳保留已报到的名字
    static func touchListener(name: String? = nil) {
        var data = JSONFile.readDict(Paths.listener)
        if let name { data["name"] = name }
        data["lastPollAt"] = Date().timeIntervalSince1970
        JSONFile.write(data, to: Paths.listener)
    }

    static func startListening(name: String) -> [String: Any] {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        touchListener(name: cleaned.isEmpty ? "AI" : cleaned)
        let meetings = load()
        guard let latest = latest(meetings), isLive(latest) else {
            return ["checkedIn": true, "live": false,
                    "message": "No meeting in progress; call wait_live_transcript() to wait for one"]
        }
        return ["checkedIn": true, "live": true,
                "meetingId": latest["id"] as? String ?? "",
                "title": latest["title"] as? String ?? "Untitled"]
    }

    static func stopListening() -> String {
        try? FileManager.default.removeItem(at: Paths.listener)
        return "Checked out; the app now shows AI as not connected"
    }

    // ── 实时转录 ──────────────────────────────────────────

    static func getLiveTranscript(afterIndex: Int) -> [String: Any] {
        // 轮询即心跳：这一步让 App 建议栏显示「AI 旁听中」
        touchListener()
        let meetings = load()
        guard !meetings.isEmpty else {
            return ["live": false, "message": "No meetings recorded yet"]
        }
        guard let latest = latest(meetings), isLive(latest) else {
            let last = latest(meetings)
            return ["live": false,
                    "message": "No meeting in progress",
                    "lastMeetingId": last?["id"] as? String ?? "",
                    "lastMeetingTitle": last?["title"] as? String ?? "Untitled"]
        }
        let meetingID = latest["id"] as? String ?? ""
        let segments = latest["segments"] as? [[String: Any]] ?? []
        let after = max(0, afterIndex)
        let liveMap = liveSpeakerMap(meetingID: meetingID)
        let newSegs = segments.dropFirst(after).map { segmentOut($0, liveMap: liveMap) }
        // 标签滞后 30~60s 补写，而增量游标不重发旧段——附带标签映射让 agent 刷新
        // 已拉取段。全量表是返回体里唯一随会议变长的部分(直发版实测一小时会议
        // 占 95%),而只有最近一两分钟的段标签还会变:只回「游标往前 labelWindow 段」
        // 之后的标签;首拉(after_index=0)仍给全量
        var speakers: [String: String] = [:]
        let labelFrom = max(0, min(after, segments.count - labelWindow))
        for i in labelFrom..<segments.count {
            let s = segments[i]
            let sp = (s["speaker"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? liveMap[s["id"] as? String ?? ""] ?? ""
            if !sp.isEmpty { speakers[String(i)] = sp }
        }
        return [
            "live": true,
            "meetingId": meetingID,
            "title": latest["title"] as? String ?? "Untitled",
            "scenario": scenario(latest),
            "startTime": fmtTime(latest["startTime"], withDate: true),
            "segments": Array(newSegs),
            "speakers": speakers,
            "nextIndex": segments.count,
            "totalSegments": segments.count,
        ]
    }

    // ── 阻塞等待(旁听主循环)────────────────────────────────
    // 「等」放在 server 里阻塞,不让 agent 开后台 shell 盯文件:直发版 10-08 实录,
    // 后台监视命令 160 次里被 Claude Code 自动模式的分类器拦了 5 次,每拦一次副驾
    // 就掉线;同场 MCP 工具调用近 200 次零拦截。等待期间心跳照刷。
    static let waitPollInterval: UInt64 = 500_000_000   // 0.5s
    static let waitHeartbeatInterval = 10.0
    static let waitDefaultTimeout = 300.0
    static let labelWindow = 40     // 游标往前 40 段之外的标签已定型

    /// (最新会议 id, 是否进行中, 段数)——判「有没有新东西」用
    static func liveState() -> (id: String, live: Bool, count: Int) {
        guard let latest = latest(load()) else { return ("", false, 0) }
        return (latest["id"] as? String ?? "", isLive(latest),
                (latest["segments"] as? [[String: Any]] ?? []).count)
    }

    static func waitLiveTranscript(afterIndex: Int, timeout: Double) async -> [String: Any] {
        let deadline = Date().addingTimeInterval(max(1, min(timeout, 600)))
        let start = liveState()

        func result() -> [String: Any] {
            var r = getLiveTranscript(afterIndex: afterIndex)
            // 同一场会里的唤醒省掉会议头(标题/场景/开始时间),长会跟起来更省
            if start.live, r["live"] as? Bool == true, r["meetingId"] as? String == start.id {
                for k in ["title", "scenario", "startTime"] { r.removeValue(forKey: k) }
            }
            return r
        }

        var lastMtime: Date? = nil
        var lastBeat = Date.distantPast
        while true {
            let now = Date()
            if now.timeIntervalSince(lastBeat) >= waitHeartbeatInterval {
                touchListener()
                lastBeat = now
            }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: Paths.meetings.path))?[.modificationDate] as? Date
            if mtime != lastMtime {
                lastMtime = mtime
                let cur = liveState()
                if cur.id != start.id || cur.live != start.live || (cur.live && cur.count > afterIndex) {
                    return result()
                }
            }
            if now >= deadline { return result() }
            try? await Task.sleep(nanoseconds: waitPollInterval)
        }
    }

    // ── 旁听建议 ──────────────────────────────────────────

    static let adviceKinds: Set<String> =
        ["check", "ask", "risk", "strategy", "emotion", "action", "note"]

    static func pushAdvice(text: String, kind: String, ref: String, label: String) -> String {
        // 推卡也是在场证明——连发建议的间隙不该被面板判成离场
        // (直发版 07-30 实测:AI 持续推卡,面板却显示「还没进来旁听」)
        touchListener()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "Empty advice text, not pushed" }
        let kindOK = adviceKinds.contains(kind) ? kind : "note"

        let meetings = load()
        guard let latest = latest(meetings), isLive(latest) else {
            return "No meeting in progress, advice not pushed (give post-meeting notes directly in chat)"
        }
        let mid = latest["id"] as? String ?? ""

        var data = JSONFile.readDict(Paths.advice)
        var advice = data["advice"] as? [String: [[String: Any]]] ?? [:]
        var items = advice[mid] ?? []
        var item: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "time": nowHMS(),
            "kind": kindOK,
            "text": cleaned,
            "ref": ref.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        let labelClean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !labelClean.isEmpty { item["label"] = labelClean }
        items.append(item)
        advice[mid] = items
        // 只保留最近 20 场会议的建议，防止无限增长
        if advice.count > 20 {
            for old in advice.keys.sorted().prefix(advice.count - 20) where old != mid {
                advice.removeValue(forKey: old)
            }
        }
        data = ["updatedAt": nowHMS(withDate: true), "advice": advice]
        JSONFile.write(data, to: Paths.advice)
        return "Pushed (\(kindOK), #\(items.count))"
    }

    // ── 语音直达（对话浮窗）────────────────────────────────

    static func getDialogInput(afterIndex: Int) -> [String: Any] {
        // 拉取即心跳：对话浮窗据此显示「<name> · 已连接」
        var listener = JSONFile.readDict(Paths.dialogListener)
        let name = (listener["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "AI"
        listener = ["name": name, "lastPollAt": Date().timeIntervalSince1970]
        JSONFile.write(listener, to: Paths.dialogListener)

        let segs = JSONFile.readDict(Paths.dialogInput)["segments"] as? [[String: Any]] ?? []
        let after = max(0, afterIndex)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let out = segs.dropFirst(after).map { s -> [String: Any] in
            let ts = s["timestamp"] as? Double ?? 0    // 对话系文件是 Unix 历法
            return ["time": fmt.string(from: Date(timeIntervalSince1970: ts)),
                    "text": s["text"] as? String ?? ""]
        }
        return ["segments": Array(out), "nextIndex": segs.count, "total": segs.count]
    }

    static func postDialogReply(text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "Empty reply, not posted" }
        var segments = JSONFile.readDict(Paths.dialogOutput)["segments"] as? [[String: Any]] ?? []
        segments.append([
            "id": UUID().uuidString.lowercased(),
            "timestamp": Date().timeIntervalSince1970,
            "text": cleaned,
        ])
        if segments.count > 50 { segments.removeFirst(segments.count - 50) }
        JSONFile.write(["updatedAt": Date().timeIntervalSince1970,
                        "segments": segments] as [String: Any], to: Paths.dialogOutput)
        return "Posted (\(cleaned.count) chars)"
    }
}
