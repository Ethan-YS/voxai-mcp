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

    static func listMeetings() -> [[String: Any]] {
        load().map { m in
            let segments = m["segments"] as? [[String: Any]] ?? []
            let firstText = segments.first?["text"] as? String
            return [
                "id": m["id"] as? String ?? "",
                "title": m["title"] as? String ?? "Untitled",
                "scenario": scenario(m),
                "startTime": fmtTime(m["startTime"], withDate: true),
                "endTime": fmtTime(m["endTime"], withDate: true),
                "isLive": isLive(m),
                "segmentCount": segments.count,
                "preview": firstText.map { String($0.prefix(50)) } ?? "(empty)",
            ]
        }
    }

    static func getMeeting(id meetingID: String) -> [String: Any] {
        for m in load() where m["id"] as? String == meetingID {
            let liveMap = liveSpeakerMap(meetingID: meetingID)
            let segments = m["segments"] as? [[String: Any]] ?? []
            return [
                "id": m["id"] as? String ?? "",
                "title": m["title"] as? String ?? "Untitled",
                "scenario": scenario(m),
                "startTime": fmtTime(m["startTime"], withDate: true),
                "endTime": fmtTime(m["endTime"], withDate: true),
                "isLive": isLive(m),
                "segments": segments.map { segmentOut($0, liveMap: liveMap) },
            ]
        }
        return ["error": "No meeting found with ID '\(meetingID)'"]
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
                    "message": "No meeting in progress; poll get_live_transcript() to wait for one"]
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
        // 标签由 worker 滞后 30~60s 补写，而增量游标不重发旧段——
        // 始终附带全部段的最新标签映射（很轻），agent 据此刷新已拉取段的标签
        var speakers: [String: String] = [:]
        for (i, s) in segments.enumerated() {
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

    // ── 旁听建议 ──────────────────────────────────────────

    static let adviceKinds: Set<String> =
        ["check", "ask", "risk", "strategy", "emotion", "action", "note"]

    static func pushAdvice(text: String, kind: String, ref: String, label: String) -> String {
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
