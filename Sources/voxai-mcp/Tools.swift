import Foundation
import MCP

// ── 工具 schema 便捷构造 ─────────────────────────────────

private func schema(_ props: [String: Value] = [:], required: [String] = []) -> Value {
    var obj: [String: Value] = [
        "type": .string("object"),
        "properties": .object(props),
    ]
    if !required.isEmpty { obj["required"] = .array(required.map { .string($0) }) }
    return .object(obj)
}

private func str(_ desc: String) -> Value {
    .object(["type": .string("string"), "description": .string(desc)])
}

private func int(_ desc: String) -> Value {
    .object(["type": .string("integer"), "description": .string(desc)])
}

private func num(_ desc: String) -> Value {
    .object(["type": .string("number"), "description": .string(desc)])
}

private func bool(_ desc: String) -> Value {
    .object(["type": .string("boolean"), "description": .string(desc)])
}

private func strList(_ desc: String) -> Value {
    .object(["type": .string("array"), "items": .object(["type": .string("string")]),
             "description": .string(desc)])
}

private func strListMap(_ desc: String) -> Value {
    .object(["type": .string("object"),
             "additionalProperties": .object(["type": .string("array"),
                                              "items": .object(["type": .string("string")])]),
             "description": .string(desc)])
}

// ── 参数读取便捷层 ───────────────────────────────────────

private extension [String: Value] {
    func string(_ key: String, default def: String = "") -> String {
        self[key]?.stringValue ?? def
    }
    func integer(_ key: String, default def: Int = 0) -> Int {
        self[key]?.intValue ?? self[key]?.doubleValue.map(Int.init) ?? def
    }
    func number(_ key: String) -> Double? {
        self[key]?.doubleValue ?? self[key]?.intValue.map(Double.init)
    }
    func stringOrNil(_ key: String) -> String? { self[key]?.stringValue }
    func boolOrNil(_ key: String) -> Bool? {
        if let b = self[key]?.boolValue { return b }
        // 有的客户端把布尔传成字符串
        switch self[key]?.stringValue?.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
    /// 字符串数组;单个字符串也收(当一条)
    func strings(_ key: String) -> [String] {
        if let arr = self[key]?.arrayValue { return arr.compactMap(\.stringValue) }
        return self[key]?.stringValue.map { [$0] } ?? []
    }
    func stringLists(_ key: String) -> [String: [String]] {
        guard let obj = self[key]?.objectValue else { return [:] }
        var out: [String: [String]] = [:]
        for (k, v) in obj {
            if let arr = v.arrayValue { out[k] = arr.compactMap(\.stringValue) }
            else if let one = v.stringValue { out[k] = [one] }
        }
        return out
    }
}

// ── 17 工具定义（描述逐条平移自直发版 server.py docstring）──

let allTools: [Tool] = [
    // ── 语音输出 ──
    Tool(
        name: "speak",
        description: """
        Convert text to speech and play it aloud on the user's Mac. Language \
        is auto-detected and the engine is chosen from the current config \
        (system voice, or Azure with the user's own key).
        """,
        inputSchema: schema([
            "text": str("Text to speak"),
            "voice_id": str("Optional, overrides the voice set in config"),
        ], required: ["text"])
    ),
    Tool(
        name: "list_voices",
        description: "List all available voice IDs, grouped by engine.",
        inputSchema: schema()
    ),
    Tool(
        name: "stop_speaking",
        description: "Immediately stop any speech currently playing.",
        inputSchema: schema()
    ),
    Tool(
        name: "update_voice_config",
        description: """
        Update voice settings (persisted to config).

        cn_engine: Chinese engine — "system" (built-in macOS voice, offline), \
        "azure" (official API, requires the user's own key configured in the \
        app's Settings; do not set keys here), or "local" (Qwen3-TTS, six \
        on-device voices, needs install_voice_component first). \
        cn_voice: Chinese voice ID (azure: xiaoxiao/yunxi/xiaoyi; local: \
        Vivian/Aiden/Dylan/Serena/Eric/Ryan). \
        en_voice: English voice ID (any name from `say -v '?'`). \
        speed: Speech rate, 0.5-2.0, 1.0 = normal. \
        language: Language mode "auto"/"zh"/"en".
        """,
        inputSchema: schema([
            "cn_engine": str("Chinese engine: \"system\", \"azure\" or \"local\""),
            "cn_voice": str("Chinese voice ID (azure: xiaoxiao/yunxi/xiaoyi; "
                + "local: Vivian/Aiden/Dylan/Serena/Eric/Ryan)"),
            "en_voice": str("English voice ID (a `say -v '?'` name)"),
            "speed": num("Speech rate, 0.5-2.0, 1.0 = normal"),
            "language": str("Language mode \"auto\"/\"zh\"/\"en\""),
        ])
    ),
    Tool(
        name: "install_voice_component",
        description: """
        Install the optional Qwen3-TTS voice component — six natural Chinese \
        voices that run fully on-device, a big step up from the built-in \
        system voice.

        Tell the user the cost before you call this: a ~190MB download now, \
        plus a ~2GB model on the first local speak(). It is optional — the \
        system voice keeps working without it.

        After installing, switch to it with \
        update_voice_config(cn_engine: "local", cn_voice: "Vivian").

        Voices: Vivian, Aiden, Dylan (Beijing accent), Serena, Eric, Ryan. \
        Safe to call again to repair or update an existing install.
        """,
        inputSchema: schema()
    ),
    // ── 会议档案 ──
    Tool(
        name: "list_meetings",
        description: """
        List recorded meetings, newest first. With no arguments, returns all.

        Filters (all optional, combined with AND): since / until — start-time \
        bounds: "2026-10-01", "2026-10-01 14:00", "today", "yesterday", or \
        relative "7d" / "12h" / "2w" (a date-only `until` includes that whole \
        day); title_contains — substring of the title ("a|b" = either); \
        scenario — "meeting" / "call" / "in_person" ("call|in_person" = \
        either); has_summary — true = only meetings with an AI summary; \
        limit — at most this many (the newest), 0 = no limit; \
        include_preview — false drops the first-segment preview.

        To find meetings by what was said in them, use search_meetings.

        Returns one entry per meeting: id, title, scenario, startTime, \
        endTime, isLive, segmentCount, hasSummary, preview (excerpt of the \
        first segment).
        """,
        inputSchema: schema([
            "since": str("Start-time lower bound (\"2026-10-01\", \"today\", \"7d\", ...)"),
            "until": str("Start-time upper bound (a date-only value includes that day)"),
            "title_contains": str("Only titles containing this (\"a|b\" = either)"),
            "scenario": str("\"meeting\" / \"call\" / \"in_person\" (\"a|b\" = either)"),
            "has_summary": bool("true = only meetings that have an AI summary; false = only those without"),
            "limit": int("At most this many meetings (newest first); 0 = no limit"),
            "include_preview": bool("false drops the first-segment preview (default true)"),
        ])
    ),
    Tool(
        name: "get_meeting",
        description: """
        Get a meeting: its summary (if an AI wrote one, see \
        set_meeting_summary) and, by default, the full transcript with \
        speaker labels.

        To analyze a past meeting, call this first with \
        include_transcript=false: a long meeting's transcript is tens of \
        thousands of characters, while the summary is a screenful. Read the \
        transcript only when the summary does not answer the question.

        Speaker values are canonical: "me" / "partner" (call mode), \
        "speaker_1", "speaker_2", ... (voice diarization), a custom name \
        assigned by the user, or "" when not yet labeled.

        Returns id, title, scenario, startTime, endTime, isLive, summary \
        (null when none), segmentCount, and — unless include_transcript=false \
        — segments (each with timestamp, speaker, text).
        """,
        inputSchema: schema([
            "meeting_id": str("Meeting ID (from list_meetings())"),
            "include_transcript": bool("false = summary and metadata only (no segments). Default true"),
        ], required: ["meeting_id"])
    ),
    Tool(
        name: "set_meeting_summary",
        description: """
        Write the meeting's summary back into the app (shown on the \
        meeting's Summary tab, included in exports, returned first by \
        get_meeting). Do this right after a meeting you listened to ends — \
        or after reading a past meeting that has none — so the next \
        analysis starts from the summary instead of the full transcript.

        Write for someone who will NOT read the transcript. Four blocks, in \
        the user's language, each only if there is substance: overview — \
        conclusions and decisions, 3-8 sentences; action_items — "who · \
        what · by when", one per item; key_facts — numbers, names, quotes \
        worth keeping verbatim; open_questions — unresolved points, things \
        to follow up. by_speaker optionally maps a speaker label to their key \
        points. Replaces any previous summary for the meeting; the app \
        applies it within a few seconds.
        """,
        inputSchema: schema([
            "meeting_id": str("Meeting ID (from list_meetings() / get_live_transcript())"),
            "overview": str("Conclusions and decisions (required)"),
            "action_items": strList("Action items, one per entry"),
            "key_facts": strList("Key numbers / names / quotes"),
            "open_questions": strList("Open questions"),
            "by_speaker": strListMap("{speaker label: [their key points]}"),
            "by": str("Your display name (e.g. \"Claude\")"),
        ], required: ["meeting_id", "overview"])
    ),
    Tool(
        name: "search_meetings",
        description: """
        Search across all meetings — titles, AI summaries and transcripts — \
        for which meeting discussed X, who said X, or when X came up. Use \
        this instead of reading transcripts one by one.

        Query syntax: space-separated terms must ALL appear somewhere in the \
        same meeting (not necessarily the same sentence); "a|b" inside a \
        term = either. Matching is case- and width-insensitive substring (no \
        word segmentation, so Chinese works as-is). Transcripts are speech \
        recognition output with homophone errors — for names and jargon, \
        expand likely variants yourself, e.g. "婉婷|宛婷|万婷", or set \
        fuzzy="pinyin" to match any characters with the same pinyin.

        Returns matchedMeetings (total) and meetings: [{id, title, scenario, \
        startTime, isLive, hasSummary, titleMatch, summaryHits: [{field, \
        text}], transcriptHits: [{index, timestamp, speaker, text, before, \
        after}], totalHits, moreHits}]. `index` is the segment's position in \
        get_meeting(id)'s segments; `timestamp` is when that line ended. Long \
        lines are cut to the part around the match ("…"). With fuzzy, a hit \
        found only by sound carries `heardAs` — the characters that matched \
        (a real ASR error, or a coincidence): judge those before relying on \
        them. Exact hits rank first.
        """,
        inputSchema: schema([
            "query": str("e.g. \"预算|报价 蓝湖\" (= (预算 or 报价) and 蓝湖)"),
            "since": str("Start-time lower bound, same formats as list_meetings"),
            "until": str("Start-time upper bound (a date-only value includes that day)"),
            "title_contains": str("Only meetings whose title contains this (\"a|b\" = either)"),
            "scenario": str("\"meeting\" / \"call\" / \"in_person\" (\"a|b\" = either)"),
            "speaker": str("Only transcript lines by this speaker (\"me\", \"partner\", "
                + "\"speaker_2\", or a name; \"a|b\" = either)"),
            "scope": str("\"both\" (default) / \"summary\" / \"transcript\""),
            "fuzzy": str("\"\" exact (default) / \"pinyin\" = same pinyin ignoring tones "
                + "(婉婷 finds 宛婷) / \"near\" = also zh~z ch~c sh~s n~l and -ng~-n (accents). "
                + "Best for 2+ character names and terms; single characters over-match"),
            "limit": int("Max meetings returned, newest first (default 10)"),
            "hits_per_meeting": int("Max summary hits and transcript hits per meeting (default 3)"),
            "context": int("Transcript lines shown before/after each hit, 0-3 (default 1)"),
        ], required: ["query"])
    ),
    Tool(
        name: "rename_meeting",
        description: """
        Rename a recorded session. Use a short, descriptive title (≤60 chars) \
        in the user's language — e.g. "定价谈判 · 蓝湖科技" instead of a \
        timestamp.

        Good moments to rename: right after a session ends (users rarely \
        rename the default timestamp titles themselves), or when the user \
        asks. Don't rename a title the user clearly set by hand unless asked. \
        The app applies the change within a few seconds.
        """,
        inputSchema: schema([
            "meeting_id": str("Meeting ID (from list_meetings() / get_live_transcript())"),
            "new_title": str("The new title"),
        ], required: ["meeting_id", "new_title"])
    ),
    // ── 旁听 ──
    Tool(
        name: "push_advice",
        description: """
        Push a live-copilot advice item to the meeting in progress; it shows \
        up in real time in the app's advice panel and floating card.

        Use while listening in on a live meeting: fact-check results, \
        follow-up questions, risk alerts, negotiation strategy, emotion \
        observations, action items. Advice is archived with the meeting and \
        appended after the transcript on export.
        """,
        inputSchema: schema([
            "text": str("Advice content — one point per call, short and scannable "
                + "(ideally under 60 characters)"),
            "kind": str("One of: check (fact check) / ask (follow up) / risk / "
                + "strategy / emotion / action (action item) / note. "
                + "Sets the tag COLOR and category in the app UI."),
            "ref": str("Optional, which utterance this refers to "
                + "(e.g. \"10:29 partner's remark\")"),
            "label": str("Optional custom tag text shown INSTEAD of the kind's "
                + "default name — adapt it to the occasion and use the user's "
                + "language (e.g. sales: \"成交信号\"; interview: \"红旗\"; pick "
                + "the kind whose color fits). Keep it to a few characters. "
                + "Empty = show the kind's default name."),
        ], required: ["text"])
    ),
    Tool(
        name: "get_live_transcript",
        description: """
        Get the live transcript of the meeting currently in progress, with \
        incremental fetching.

        Listening-mode usage: call in a loop, passing the previous call's \
        nextIndex as after_index so only new segments are returned; empty \
        segments means nothing new yet.

        Speaker labels lag 30-60s behind the text, and the incremental cursor \
        never re-sends old segments — so every response also carries \
        `speakers`: the CURRENT label map ({"<index>": "<speaker>"}, 0-based \
        global indices, unlabeled segments omitted) from ~40 segments before \
        your cursor onward (older labels are final; after_index=0 covers \
        everything). On every poll, refresh the labels of segments you \
        already fetched from this map. Values are canonical: "me" / "partner" \
        / "speaker_N" / custom name.

        For the copilot's main loop prefer wait_live_transcript, which blocks \
        until there is something new.

        While someone is mid-sentence the response also carries `partial`: \
        the volatile text still being spoken (keys me / partner / \
        ageSeconds) — anticipate with it, quote only finalized segments.

        When live is False: no meeting is in progress; lastMeetingId / \
        lastMeetingTitle of the most recent finished meeting are included for \
        post-meeting retrieval via get_meeting(). The scenario field \
        ("meeting" / "call" / "in_person") should tune your advice style.
        """,
        inputSchema: schema([
            "after_index": int("Only return segments after this index (pass 0 on the first call)"),
        ])
    ),
    Tool(
        name: "wait_live_transcript",
        description: """
        Block until there is something new, then return what \
        get_live_transcript(after_index) returns — minus the meeting header \
        (title / scenario / startTime) when it is still the same meeting you \
        were in when you called, so a long meeting stays cheap to follow. \
        `meetingId` is always present: a changed id means a new meeting and \
        then the full header comes along. This is the copilot's main loop — \
        no background shell watcher needed:

            r = wait_live_transcript(cursor) → judge → push_advice() if \
            useful → cursor = r["nextIndex"] → wait_live_transcript again

        Returns as soon as one of these happens: new segments beyond \
        after_index (within ~1s of the app committing them); the meeting \
        starts, ends (live flips to false) or a new one begins (meetingId \
        changes — fetch it from after_index=0); timeout_s passes in silence \
        (segments empty: just call again). Your listening heartbeat is \
        refreshed throughout the wait, so the app keeps showing you as \
        present while you are blocked here.
        """,
        inputSchema: schema([
            "after_index": int("Your cursor — the previous response's nextIndex (0 on the first call)"),
            "timeout_s": num("Max seconds to wait (default 300, capped at 600)"),
        ])
    ),
    Tool(
        name: "start_listening",
        description: """
        Check in as the live-listening agent. The app's advice panel then \
        shows "<name> · Listening" so the user can see their AI is actually \
        connected. Call this once when entering listening mode; after that, \
        loop on wait_live_transcript(), which refreshes the heartbeat even \
        while it blocks (the app treats a heartbeat older than ~3 minutes as \
        disconnected).
        """,
        inputSchema: schema([
            "name": str("Display name shown in the app (e.g. \"Claude\", \"Codex\")"),
        ])
    ),
    Tool(
        name: "stop_listening",
        description: """
        Check out of listening mode. The app immediately shows "AI Not \
        Connected" instead of waiting for the heartbeat to expire.
        """,
        inputSchema: schema()
    ),
    // ── 语音直达（对话浮窗）──
    Tool(
        name: "get_dialog_input",
        description: """
        Fetch speech the user spoke into the dialog overlay (voice-direct \
        input), incrementally. This turns the user's voice into your input: \
        treat new segments as messages the user typed to you.

        Voice-dialog protocol: when the user asks to enter voice dialog, \
        first call once and use the returned nextIndex as your cursor (skip \
        history — only react to what is said from now on). Then poll every \
        few seconds. Merge segments that arrive close together — \
        silence-based splitting may cut one sentence into several. Ignore \
        segments that echo your own just-spoken TTS (the microphone hears \
        speak() output). Reply in chat AND speak() a short spoken summary. \
        Tell the user when you stop watching; stop after ~10 minutes of \
        silence.
        """,
        inputSchema: schema([
            "after_index": int("Only return segments after this index (pass 0 on the first call)"),
        ])
    ),
    Tool(
        name: "post_dialog_reply",
        description: """
        Post your reply into the dialog overlay's chat flow. When an agent is \
        connected, the overlay renders the user's speech as right-side \
        bubbles and these replies as left-side bubbles — a two-way voice \
        chat. Keep replies short and conversational; long code or detailed \
        results belong in the main chat, post a pointer here instead. \
        Optionally pair with speak() for audio (sparingly — the mic hears TTS \
        and echoes it back into the transcript).
        """,
        inputSchema: schema([
            "text": str("Reply text shown as a chat bubble in the overlay"),
        ], required: ["text"])
    ),
]

// ── 结果包装（与 FastMCP 序列化行为一致：结构化结果转 JSON 文本）──

func toolJSON(_ obj: Any) -> CallTool.Result {
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj,
                                                 options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return toolText("{}") }
    return toolText(text)
}

func toolText(_ text: String, isError: Bool = false) -> CallTool.Result {
    .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
}

// ── 分发 ─────────────────────────────────────────────────

func dispatchTool(name: String, arguments: [String: Value]) async -> CallTool.Result {
    // 非 macOS 平台：协议层照常服务，但工具没有宿主 App 可读写。
    // 明说缺什么,不静默返回空数据(见 Compat.swift)。
    guard Host.isSupported else {
        return toolText(Host.unsupportedMessage)
    }
    switch name {
    case "speak":
        let text = arguments.string("text")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return toolText("Empty text, skipped")
        }
        // TTS 文本落盘：对话浮窗开着麦克风时会把这段语音录回去，
        // App 据 recent_tts.json 识别并过滤这类回声
        SpeechEngine.recordRecentTTS(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let result = await SpeechEngine.shared.speak(
            text: text, voiceID: arguments.string("voice_id", default: "default"))
        return toolText(result)

    case "list_voices":
        return toolJSON(SpeechEngine.listVoices())

    case "install_voice_component":
        do {
            return toolText(try await VoiceComponent.install())
        } catch {
            // 装不上要说清是哪一步坏的——AI 才好如实转告用户而不是瞎猜
            return toolText("Install failed: \(error.localizedDescription)",
                            isError: true)
        }

    case "stop_speaking":
        await SpeechEngine.shared.stop()
        return toolText("Playback stopped")

    case "update_voice_config":
        return toolText(SpeechEngine.updateConfig(
            cnEngine: arguments.stringOrNil("cn_engine"),
            cnVoice: arguments.stringOrNil("cn_voice"),
            enVoice: arguments.stringOrNil("en_voice"),
            speed: arguments.number("speed"),
            language: arguments.stringOrNil("language")))

    case "list_meetings":
        do {
            return toolJSON(try Meetings.listMeetings(
                since: arguments.string("since"),
                until: arguments.string("until"),
                titleContains: arguments.string("title_contains"),
                scenario: arguments.string("scenario"),
                hasSummary: arguments.boolOrNil("has_summary"),
                limit: arguments.integer("limit"),
                includePreview: arguments.boolOrNil("include_preview") ?? true))
        } catch let e as Search.BadArgument {
            return toolText(e.message, isError: true)
        } catch {
            return toolText("\(error)", isError: true)
        }

    case "get_meeting":
        return toolJSON(Meetings.getMeeting(
            id: arguments.string("meeting_id"),
            includeTranscript: arguments.boolOrNil("include_transcript") ?? true))

    case "set_meeting_summary":
        return toolText(Meetings.setMeetingSummary(
            id: arguments.string("meeting_id"),
            overview: arguments.string("overview"),
            actionItems: arguments.strings("action_items"),
            keyFacts: arguments.strings("key_facts"),
            openQuestions: arguments.strings("open_questions"),
            bySpeaker: arguments.stringLists("by_speaker"),
            by: arguments.string("by", default: "AI")))

    case "search_meetings":
        return toolJSON(Search.searchMeetings(
            query: arguments.string("query"),
            since: arguments.string("since"),
            until: arguments.string("until"),
            titleContains: arguments.string("title_contains"),
            scenario: arguments.string("scenario"),
            speaker: arguments.string("speaker"),
            scope: arguments.string("scope", default: "both"),
            fuzzy: arguments.string("fuzzy"),
            limit: arguments.integer("limit", default: 10),
            hitsPerMeeting: arguments.integer("hits_per_meeting", default: 3),
            context: arguments.integer("context", default: 1)))

    case "rename_meeting":
        return toolText(Meetings.renameMeeting(
            id: arguments.string("meeting_id"),
            newTitle: arguments.string("new_title")))

    case "push_advice":
        return toolText(Meetings.pushAdvice(
            text: arguments.string("text"),
            kind: arguments.string("kind", default: "note"),
            ref: arguments.string("ref"),
            label: arguments.string("label")))

    case "get_live_transcript":
        return toolJSON(Meetings.getLiveTranscript(
            afterIndex: arguments.integer("after_index")))

    case "wait_live_transcript":
        return toolJSON(await Meetings.waitLiveTranscript(
            afterIndex: arguments.integer("after_index"),
            timeout: arguments.number("timeout_s") ?? Meetings.waitDefaultTimeout))

    case "start_listening":
        return toolJSON(Meetings.startListening(
            name: arguments.string("name", default: "AI")))

    case "stop_listening":
        return toolText(Meetings.stopListening())

    case "get_dialog_input":
        return toolJSON(Meetings.getDialogInput(
            afterIndex: arguments.integer("after_index")))

    case "post_dialog_reply":
        return toolText(Meetings.postDialogReply(text: arguments.string("text")))

    default:
        return toolText("Unknown tool: \(name)", isError: true)
    }
}
