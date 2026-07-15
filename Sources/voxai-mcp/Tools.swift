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
}

// ── 13 工具定义（描述逐条平移自直发版 server.py docstring）──

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
        List summary info for all recorded meetings.

        Returns one entry per meeting: id, title, scenario ("meeting" / \
        "call" / "in_person"), startTime, endTime, isLive, segmentCount, \
        preview (excerpt of the first segment).
        """,
        inputSchema: schema()
    ),
    Tool(
        name: "get_meeting",
        description: """
        Get the full content of a meeting, including all transcript segments \
        and speaker labels.

        Speaker values are canonical: "me" / "partner" (call mode), \
        "speaker_1", "speaker_2", ... (voice diarization), a custom name \
        assigned by the user, or "" when not yet labeled.
        """,
        inputSchema: schema([
            "meeting_id": str("Meeting ID (from list_meetings())"),
        ], required: ["meeting_id"])
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

        Speaker labels lag 30-60s behind the text (filled in by a background \
        worker), and the incremental cursor never re-sends old segments — so \
        every response also carries `speakers`: the CURRENT label map for ALL \
        segments ({"<index>": "<speaker>"}, 0-based global indices, unlabeled \
        segments omitted). On every poll, refresh the labels of segments you \
        already fetched from this map. Values are canonical: "me" / "partner" \
        / "speaker_N" / custom name.

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
        name: "start_listening",
        description: """
        Check in as the live-listening agent. The app's advice panel then \
        shows "<name> · Listening" so the user can see their AI is actually \
        connected. Call this once when entering listening mode; after that, \
        every get_live_transcript() poll refreshes the heartbeat \
        automatically (the app treats a heartbeat older than ~3 minutes as \
        disconnected, so keep polling every 30-60s).
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
        return toolJSON(Meetings.listMeetings())

    case "get_meeting":
        return toolJSON(Meetings.getMeeting(id: arguments.string("meeting_id")))

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
