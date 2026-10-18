import Foundation

// ── 跨会议检索 + 列表过滤(移植自直发版 server.py,v2.1)──────────
// 数据小到不需要索引:全库现读现扫。匹配一律 NFKC + 大小写折叠的子串(不分词,
// 中文原样可用)。拼音模糊直发版靠 pypinyin;这里用系统自带的汉字转拼音
// (ICU Han-Latin,经 Foundation 的 applyingTransform),零依赖、不加常驻内存。
// 多音字一律取默认读音——查询和原文按同一规则转,读音一致比读得对更重要;
// 单字读音不同(行 xing / 银行 hang)靠「原文命中照算」兜住。
enum Search {
    static let snippetMax = 200     // 命中段超过这么长就截取命中点附近
    static let contextMax = 80      // 上下文段每段最多字符

    struct BadArgument: Error { let message: String }

    // ── 归一化 ────────────────────────────────────────────

    // 工具调用可能并发进来,两个缓存都上锁
    private static let lock = NSLock()
    nonisolated(unsafe) private static var normCache: [String: String] = [:]

    /// 全角→半角(NFKC)+ 大小写折叠。按原文缓存
    static func norm(_ any: Any?) -> String {
        let s = (any as? String) ?? ""
        lock.lock(); defer { lock.unlock() }
        if let r = normCache[s] { return r }
        if normCache.count > 200_000 { normCache.removeAll() }
        let r = s.precomposedStringWithCompatibilityMapping.lowercased()
        normCache[s] = r
        return r
    }

    /// 'a|b, c' → 归一化后的候选列表(| 或逗号分隔,任一命中)
    static func alts(_ value: String) -> [String] {
        norm(value).split(whereSeparator: { $0 == "|" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // ── 时间参数 ──────────────────────────────────────────

    /// since/until → Apple 参考秒。支持 YYYY-MM-DD[ HH:MM[:SS]]、today / yesterday、
    /// 相对的 7d / 12h / 2w。纯日期作 until 时取次日零点(含当天)。
    /// 钟点与「今天」都按显示时区解释——和 AI 拿到的时间串同一个区
    static func parseWhen(_ value: String, end: Bool = false) throws -> Double? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.isEmpty { return nil }
        let cal = DisplayTime.calendar
        let now = Date()
        let midnight = cal.startOfDay(for: now)
        var date: Date?
        if let m = v.wholeMatch(of: /(\d+)\s*([hdw])/) {
            let n = Double(m.1) ?? 0
            let unit: Double = m.2 == "h" ? 3600 : m.2 == "d" ? 86_400 : 604_800
            date = now.addingTimeInterval(-n * unit)
        } else if ["today", "今天", "yesterday", "昨天"].contains(v) {
            var d = (v == "today" || v == "今天") ? midnight
                : cal.date(byAdding: .day, value: -1, to: midnight)!
            if end { d = cal.date(byAdding: .day, value: 1, to: d)! }
            date = d
        } else {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.calendar = cal
            fmt.timeZone = cal.timeZone
            for f in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss",
                      "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
                fmt.dateFormat = f
                if let d = fmt.date(from: v) { date = d; break }
            }
            guard var d = date else {
                throw BadArgument(message: "unrecognized date \"\(value)\" — use YYYY-MM-DD, "
                    + "'YYYY-MM-DD HH:MM', today/yesterday, or 7d / 12h / 2w")
            }
            if end && v.count == 10 { d = cal.date(byAdding: .day, value: 1, to: d)! }
            date = d
        }
        return date.map { $0.timeIntervalSince1970 - appleEpochOffset }
    }

    // ── 会议级过滤(list_meetings / search_meetings 共用,保持 meetings.json 新→旧顺序)──

    static func hasSummary(_ m: [String: Any]) -> Bool {
        let overview = (m["summary"] as? [String: Any])?["overview"] as? String ?? ""
        return !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func filter(_ meetings: [[String: Any]], since: String, until: String,
                       titleContains: String, scenario: String,
                       hasSummary wantSummary: Bool?) throws -> [[String: Any]] {
        let lo = try parseWhen(since), hi = try parseWhen(until, end: true)
        let titles = alts(titleContains), scenarios = alts(scenario)
        return meetings.filter { m in
            let st = m["startTime"] as? Double
            if let lo, !(st.map { $0 >= lo } ?? false) { return false }
            if let hi, !(st.map { $0 < hi } ?? false) { return false }
            if !titles.isEmpty, !titles.contains(where: { norm(m["title"]).contains($0) }) { return false }
            if !scenarios.isEmpty, !scenarios.contains(Meetings.scenario(m)) { return false }
            if let wantSummary, hasSummary(m) != wantSummary { return false }
            return true
        }
    }

    // ── 拼音 ──────────────────────────────────────────────

    nonisolated(unsafe) private static var pinyinCache: [Character: String] = [:]

    /// 单个汉字 → 无声调拼音(按字缓存,常用字几千个,首查之后就是查表)
    private static func pinyin(_ c: Character) -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached = pinyinCache[c] { return cached }
        #if canImport(Darwin)
        let latin = String(c).applyingTransform(.mandarinToLatin, reverse: false) ?? String(c)
        let py = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin)
            .lowercased().trimmingCharacters(in: .whitespaces)
        #else
        let py = String(c)   // Linux 没有 ICU 转写接口:退化为精确匹配
        #endif
        pinyinCache[c] = py
        return py
    }

    private static func isHan(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3400...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    /// 近音归一:zh/ch/sh → z/c/s,n → l,后鼻音 ang/eng/ing → 前鼻音(ong 不动)
    static func nearSyllable(_ syl: String) -> String {
        var s = syl
        if s.count >= 2, ["zh", "ch", "sh"].contains(String(s.prefix(2))) {
            s.remove(at: s.index(after: s.startIndex))
        }
        if s.hasPrefix("n") { s = "l" + s.dropFirst() }
        if s.hasSuffix("ng") && !s.hasSuffix("ong") { s.removeLast() }
        return s
    }

    /// 归一化文本 → 逐字一个 token:汉字转无声调拼音,其余字符原样。
    /// token 与字一一对应,所以命中的 token 下标就是字的下标
    static func pinyinTokens(_ text: String, near: Bool) -> [String] {
        text.map { c -> String in
            guard isHan(c) else { return String(c) }
            let py = pinyin(c)
            return near ? nearSyllable(py) : py
        }
    }

    private static func find(_ needle: [String], in hay: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        outer: for i in 0...(hay.count - needle.count) {
            for j in 0..<needle.count where hay[i + j] != needle[j] { continue outer }
            return i
        }
        return nil
    }

    /// 字符下标(Character 计)。找不到 -1
    private static func charIndex(of needle: String, in hay: String) -> Int {
        guard let r = hay.range(of: needle) else { return -1 }
        return hay.distance(from: hay.startIndex, to: r.lowerBound)
    }

    // ── 片段 ──────────────────────────────────────────────

    /// 长文本截取命中点附近;pos 是归一化文本里的字下标,-1 = 取开头
    static func snippet(_ any: Any?, pos: Int = -1, width: Int = snippetMax) -> String {
        let text = Array((any as? String) ?? "")
        if text.count <= width { return String(text) }
        var p = pos
        if p > 0 {
            // NFKC 改了长度(如 … → ...):逐字回推到原文下标
            let normed = text.map { String($0).precomposedStringWithCompatibilityMapping.lowercased().count }
            if normed.contains(where: { $0 != 1 }) {
                var acc = 0
                for (i, n) in normed.enumerated() {
                    if acc >= p { p = i; break }
                    acc += n
                }
            }
        }
        let start = p >= 0 ? max(0, min(p - width / 3, text.count - width)) : 0
        let end = min(text.count, start + width)
        return (start > 0 ? "…" : "") + String(text[start..<end]) + (end < text.count ? "…" : "")
    }

    // ── 提要拆成可搜单元:(字段路径, 原文, bySpeaker 的说话人或空)──

    static func summaryUnits(_ any: Any?) -> [(String, String, String)] {
        guard let sm = any as? [String: Any],
              let overview = sm["overview"] as? String,
              !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var units: [(String, String, String)] = [("overview", overview, "")]
        for key in ["actionItems", "keyFacts", "openQuestions"] {
            for (i, t) in (sm[key] as? [String] ?? []).enumerated() {
                units.append(("\(key)[\(i)]", t, ""))
            }
        }
        for (who, items) in (sm["bySpeaker"] as? [String: [String]] ?? [:]).sorted(by: { $0.key < $1.key }) {
            for (i, t) in items.enumerated() {
                units.append(("bySpeaker.\(who)[\(i)]", t, who))
            }
        }
        return units
    }

    // ── search_meetings ───────────────────────────────────

    static func searchMeetings(query: String, since: String, until: String,
                               titleContains: String, scenario: String,
                               speaker: String, scope rawScope: String, fuzzy rawFuzzy: String,
                               limit rawLimit: Int, hitsPerMeeting rawHits: Int,
                               context rawContext: Int) -> [String: Any] {
        let groups = norm(query).split(whereSeparator: \.isWhitespace)
            .map { alts(String($0)) }.filter { !$0.isEmpty }
        guard !groups.isEmpty else { return ["error": "empty query"] }
        let scope = rawScope.trimmingCharacters(in: .whitespaces).isEmpty ? "both" : rawScope
        guard ["both", "summary", "transcript"].contains(scope) else {
            return ["error": "scope must be 'both', 'summary' or 'transcript'"]
        }
        let meetings: [[String: Any]]
        do {
            meetings = try filter(Meetings.load(), since: since, until: until,
                                  titleContains: titleContains, scenario: scenario, hasSummary: nil)
        } catch let e as BadArgument {
            return ["error": e.message]
        } catch {
            return ["error": "\(error)"]
        }
        let fuzzy = rawFuzzy.trimmingCharacters(in: .whitespaces).lowercased()
        guard ["", "pinyin", "near"].contains(fuzzy) else {
            return ["error": "fuzzy must be '', 'pinyin' or 'near'"]
        }
        let near = fuzzy == "near"
        let qKeys: [[[String]]] = fuzzy.isEmpty ? [] :
            groups.map { g in g.map { pinyinTokens($0, near: near) } }
        let speakers = Set(alts(speaker).map { $0 == "我" ? "me" : $0 })
        let hitsPerMeeting = max(1, rawHits)
        let context = max(0, min(rawContext, 3))

        /// 命中的组序号、第一处命中的字下标(截取片段用)、靠读音命中的原文字(精确命中为空)。
        /// 模糊模式下原文命中照算(单字多音字可能和查询读音不同)
        func matched(_ textN: String) -> (hit: [Int], pos: Int, heard: String) {
            var hit: [Int] = [], pos = -1, heard = ""
            var keyTokens: [String]? = nil
            for (gi, g) in groups.enumerated() {
                var p = -1
                for a in g {
                    let q = charIndex(of: a, in: textN)
                    if q >= 0 { p = q; break }
                }
                if p < 0, !fuzzy.isEmpty {
                    if keyTokens == nil { keyTokens = pinyinTokens(textN, near: near) }
                    for k in qKeys[gi] {
                        if let i = find(k, in: keyTokens!) {
                            p = i
                            if heard.isEmpty {
                                let chars = Array(textN)
                                heard = String(chars[i..<min(chars.count, i + k.count)])
                            }
                            break
                        }
                    }
                }
                if p >= 0 {
                    hit.append(gi)
                    if pos < 0 { pos = p }
                }
            }
            return (hit, pos, heard)
        }

        struct THit { let n: Int; let heard: String; let i: Int; let pos: Int }
        struct SHit { let n: Int; let heard: String; let field: String; let text: String; let pos: Int }

        /// 多组命中的优先,其次原文命中优先于读音命中,同分按原顺序;输出时恢复原顺序
        func top<T>(_ hits: [T], n: (T) -> Int, heard: (T) -> String) -> [T] {
            let picked = hits.indices.sorted { a, b in
                if n(hits[a]) != n(hits[b]) { return n(hits[a]) > n(hits[b]) }
                let ha = !heard(hits[a]).isEmpty, hb = !heard(hits[b]).isEmpty
                if ha != hb { return !ha }
                return a < b
            }.prefix(hitsPerMeeting)
            return picked.sorted().map { hits[$0] }
        }

        var found: [[String: Any]] = []
        for m in meetings {
            let mid = m["id"] as? String ?? ""
            var covered = Set<Int>()

            let titleHit = matched(norm(m["title"])).hit
            let titleMatch = !titleHit.isEmpty
            covered.formUnion(titleHit)

            var sHits: [SHit] = []
            if scope != "transcript" {
                for (field, text, who) in summaryUnits(m["summary"]) {
                    if !speakers.isEmpty, !speakers.contains(norm(who)) { continue }
                    let r = matched(norm(text))
                    if !r.hit.isEmpty {
                        covered.formUnion(r.hit)
                        sHits.append(SHit(n: r.hit.count, heard: r.heard, field: field, text: text, pos: r.pos))
                    }
                }
            }

            let segs = m["segments"] as? [[String: Any]] ?? []
            // 进行中的会,说话人标签可能还在 sidecar 里没合并
            let liveMap = (m["endTime"] == nil || m["endTime"] is NSNull)
                ? Meetings.liveSpeakerMap(meetingID: mid) : [:]
            func speakerOf(_ s: [String: Any]) -> String {
                (s["speaker"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? liveMap[s["id"] as? String ?? ""] ?? ""
            }
            var tHits: [THit] = []
            if scope != "summary" {
                for (i, s) in segs.enumerated() {
                    if !speakers.isEmpty, !speakers.contains(norm(speakerOf(s))) { continue }
                    let r = matched(norm(s["text"]))
                    if !r.hit.isEmpty {
                        covered.formUnion(r.hit)
                        tHits.append(THit(n: r.hit.count, heard: r.heard, i: i, pos: r.pos))
                    }
                }
            }

            guard covered.count >= groups.count,
                  !sHits.isEmpty || !tHits.isEmpty || (titleMatch && speakers.isEmpty) else { continue }

            func brief(_ j: Int) -> [String: Any] {
                ["speaker": speakerOf(segs[j]), "text": snippet(segs[j]["text"], width: contextMax)]
            }
            let tOut: [[String: Any]] = top(tHits, n: \.n, heard: \.heard).map { h in
                let s = segs[h.i]
                var out: [String: Any] = [
                    "index": h.i,
                    "timestamp": fmtTime(s["timestamp"]),
                    "speaker": speakerOf(s),
                    "text": snippet(s["text"], pos: h.pos),
                ]
                if !h.heard.isEmpty { out["heardAs"] = h.heard }
                if context > 0 {
                    out["before"] = (max(0, h.i - context)..<h.i).map(brief)
                    out["after"] = ((h.i + 1)..<min(segs.count, h.i + 1 + context)).map(brief)
                }
                return out
            }
            let sOut: [[String: Any]] = top(sHits, n: \.n, heard: \.heard).map { h in
                var out: [String: Any] = ["field": h.field, "text": snippet(h.text, pos: h.pos)]
                if !h.heard.isEmpty { out["heardAs"] = h.heard }
                return out
            }
            let total = sHits.count + tHits.count
            found.append([
                "id": mid,
                "title": m["title"] as? String ?? "Untitled",
                "scenario": Meetings.scenario(m),
                "startTime": fmtTime(m["startTime"], withDate: true),
                "isLive": Meetings.isLive(m),
                "hasSummary": hasSummary(m),
                "titleMatch": titleMatch,
                "summaryHits": sOut,
                "transcriptHits": tOut,
                "totalHits": total,
                "moreHits": total - sOut.count - tOut.count,
            ])
        }

        let limit = max(1, rawLimit)
        var out: [String: Any] = ["query": query, "matchedMeetings": found.count,
                                  "meetings": Array(found.prefix(limit))]
        if found.count > limit {
            out["note"] = "\(found.count - limit) more matching meetings — narrow with "
                + "since/until/title_contains, or raise limit"
        } else if found.isEmpty {
            out["note"] = "no match — try fewer terms, variant spellings joined with |, "
                + (fuzzy == "pinyin" ? "fuzzy=\"near\", " : fuzzy.isEmpty ? "fuzzy=\"pinyin\", " : "")
                + "or a wider time range"
        }
        return out
    }
}
