import Foundation

/// One limit window as its vendor reports it: how much of it is spent and
/// when it starts over.
struct UsageLimit: Equatable, Sendable {
    /// Length of the window in minutes when it is known — 300 for the five
    /// hours both vendors use, 10080 for a week.
    var minutes: Int?
    /// What the window is narrowed to: Claude keeps a weekly cap per model on
    /// top of the one for everything.
    var scope: String?
    /// 0…100.
    var percent: Double
    var resetsAt: Date?

    /// A window whose reset has already passed has started over, whatever the
    /// last report said. Codex reports only while it runs, so a figure read
    /// from a session a week old is usually of this kind.
    func percent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return percent
    }
}

/// Tokens spent, split the two ways the tab shows them.
struct TokenTally: Equatable, Sendable {
    var today = 0
    var week = 0
}

/// The limits Codex last wrote into a session log, and when.
struct CodexLimits: Equatable, Sendable {
    var plan: String?
    var limits: [UsageLimit]
    var observedAt: Date
}

/// What one pass over the logs found. A tool that is not installed is nil
/// rather than zero: "nothing spent" and "nothing to spend with" read
/// differently in the tab.
struct UsageScan: Equatable, Sendable {
    var claude: TokenTally?
    var codex: TokenTally?
    var codexLimits: CodexLimits?
}

/// The formats, apart from the files: everything here takes bytes or a decoded
/// object and hands back a value, so the tests can feed it lines directly.
enum AIUsageParsing {
    // MARK: Claude

    /// The answer of `api.anthropic.com/api/oauth/usage` — the same numbers
    /// `/usage` shows inside Claude Code.
    ///
    /// Read from `limits` when it is there: it names each window by kind and
    /// carries the per-model cap with the model's name. The older
    /// `five_hour` / `seven_day` keys are the fallback — the endpoint is not
    /// documented, and either half may be the one that goes away.
    static func claudeLimits(from data: Data) -> [UsageLimit]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let rows = object["limits"] as? [[String: Any]], !rows.isEmpty {
            let parsed = rows.compactMap { row -> UsageLimit? in
                guard let percent = number(row["percent"]) else { return nil }
                let kind = row["kind"] as? String ?? ""
                let group = row["group"] as? String ?? ""
                let minutes: Int? = switch (kind, group) {
                case ("session", _), (_, "session"): 300
                case (_, "weekly"): 10080
                default: nil
                }
                let scope = ((row["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                return UsageLimit(minutes: minutes, scope: scope, percent: percent, resetsAt: date(row["resets_at"]))
            }
            if !parsed.isEmpty { return parsed }
        }

        let legacy: [(key: String, minutes: Int, scope: String?)] = [
            ("five_hour", 300, nil),
            ("seven_day", 10080, nil),
            ("seven_day_opus", 10080, "Opus"),
            ("seven_day_sonnet", 10080, "Sonnet"),
        ]
        let parsed = legacy.compactMap { entry -> UsageLimit? in
            guard let window = object[entry.key] as? [String: Any],
                  let percent = number(window["utilization"]) else { return nil }
            return UsageLimit(minutes: entry.minutes, scope: entry.scope, percent: percent, resetsAt: date(window["resets_at"]))
        }
        return parsed.isEmpty ? nil : parsed
    }

    /// A line of a Claude Code transcript that billed tokens: the key it is
    /// deduplicated by, when, and how many.
    ///
    /// The key is needed because one reply is written as several lines — one
    /// per content block, each carrying the same `usage` — and a resumed
    /// session copies earlier replies into its new file. Counted per line,
    /// the same answer would be paid for three times.
    static func claudeTokens(from object: [String: Any]) -> (key: String, date: Date, tokens: Int)? {
        guard let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let date = date(object["timestamp"]) else { return nil }
        // What Claude Code writes itself — an interrupted turn, an error — and
        // never sent anywhere.
        if message["model"] as? String == "<synthetic>" { return nil }
        let tokens = [
            "input_tokens", "output_tokens",
            "cache_creation_input_tokens", "cache_read_input_tokens",
        ].reduce(0) { $0 + Int(number(usage[$1]) ?? 0) }
        let id = message["id"] as? String ?? UUID().uuidString
        let request = object["requestId"] as? String ?? ""
        return ("\(id):\(request)", date, tokens)
    }

    /// "Max 5x" from `subscriptionType: max` and `rateLimitTier:
    /// default_claude_max_5x`; the bare plan name when the tier says nothing
    /// more.
    static func claudePlan(subscription: String?, tier: String?) -> String? {
        guard let subscription, !subscription.isEmpty else { return nil }
        let name = subscription.prefix(1).uppercased() + subscription.dropFirst()
        if let tier, let multiplier = tier.split(separator: "_").last, multiplier.hasSuffix("x"),
           Int(multiplier.dropLast()) != nil {
            return "\(name) \(multiplier)"
        }
        return name
    }

    /// Claude Code's own sign-in, as it keeps it in the Keychain.
    static func claudeCredentials(from data: Data) -> ClaudeCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let plan = claudePlan(subscription: oauth["subscriptionType"] as? String, tier: oauth["rateLimitTier"] as? String)
        return ClaudeCredentials(accessToken: token, expiresAt: expires, plan: plan)
    }

    // MARK: Codex

    /// A `token_count` event from a Codex session log. `total` is the
    /// session's running sum, `last` is the turn that just ended — see
    /// `UsageScanner` for why both are needed.
    static func codexEvent(from object: [String: Any]) -> (date: Date, total: Int?, last: Int?, limits: CodexLimits?)? {
        guard let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let date = date(object["timestamp"]) else { return nil }
        let info = payload["info"] as? [String: Any]
        let total = ((info?["total_token_usage"] as? [String: Any])?["total_tokens"]).flatMap(number).map { Int($0) }
        let last = ((info?["last_token_usage"] as? [String: Any])?["total_tokens"]).flatMap(number).map { Int($0) }
        let limits = (payload["rate_limits"] as? [String: Any]).flatMap { codexLimits(from: $0, observedAt: date) }
        return (date, total, last, limits)
    }

    /// `primary` and `secondary` are whatever windows the plan has — five
    /// hours and a week on a paid one, a single thirty days on the free one.
    /// Older builds wrote `resets_in_seconds`, counted from the event.
    static func codexLimits(from object: [String: Any], observedAt: Date) -> CodexLimits? {
        let limits = ["primary", "secondary"].compactMap { key -> UsageLimit? in
            guard let window = object[key] as? [String: Any],
                  let percent = number(window["used_percent"]) else { return nil }
            var resets: Date?
            if let at = number(window["resets_at"]) {
                resets = Date(timeIntervalSince1970: at)
            } else if let seconds = number(window["resets_in_seconds"]) {
                resets = observedAt.addingTimeInterval(seconds)
            }
            let minutes = number(window["window_minutes"]).map { Int($0) }
            return UsageLimit(minutes: minutes, scope: nil, percent: percent, resetsAt: resets)
        }
        guard !limits.isEmpty else { return nil }
        let plan = (object["plan_type"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return CodexLimits(plan: plan, limits: limits, observedAt: observedAt)
    }

    // MARK: Values

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }

    /// ISO 8601 with or without fractional seconds, `Z` or `+00:00` — the two
    /// vendors write all four between them. Epoch seconds are taken as well.
    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
        return nil
    }
}

/// The part of Claude Code's sign-in the tab needs. The refresh token is
/// never read out: renewing the sign-in is Claude Code's business, and doing
/// it from here would rotate the token from under it and sign it out.
struct ClaudeCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let plan: String?

    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(60)
    }
}

/// Reads the session logs Claude Code and Codex leave on disk and adds up what
/// they spent over the last seven days.
///
/// Incremental, because the logs are large — hundreds of megabytes of Claude
/// Code transcripts are nothing unusual — and the tab rescans every minute it
/// is on screen. Each file is remembered by how far it has been read, and only
/// what was appended since is parsed. The logs are append-only; a file that
/// shrinks was rewritten and is read again from the top.
actor UsageScanner {
    private struct Event {
        let date: Date
        let tokens: Int
    }

    private struct FileState {
        var offset: UInt64 = 0
        /// Codex: the session's running total as of the last event, so a
        /// repeated event adds nothing.
        var lastTotal: Int?
        /// Codex: this file's turns. Kept per file, so a file read again from
        /// the top replaces its own events instead of adding to them.
        var events: [Event] = []
    }

    private let claudeRoots: [URL]
    private let codexRoot: URL
    private var files: [URL: FileState] = [:]
    /// Claude: every billed reply by its key, across all files — see
    /// `AIUsageParsing.claudeTokens` for why across.
    private var claudeEvents: [String: Event] = [:]
    private var codexLimits: CodexLimits?

    init(claudeRoots: [URL]? = nil, codexRoot: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.claudeRoots = claudeRoots ?? [
            home.appendingPathComponent(".claude"),
            home.appendingPathComponent(".config/claude"),
        ]
        self.codexRoot = codexRoot ?? home.appendingPathComponent(".codex")
    }

    func scan(now: Date = Date(), calendar: Calendar = .current) -> UsageScan {
        let today = calendar.startOfDay(for: now)
        // Seven days counting today, so "7 days" means this day and the six
        // before it rather than a window that starts mid-afternoon.
        let cutoff = calendar.date(byAdding: .day, value: -6, to: today) ?? today

        var result = UsageScan()

        let claudeRoots = claudeRoots.filter { Self.exists($0) }
        if !claudeRoots.isEmpty {
            for root in claudeRoots {
                for url in Self.logs(in: root.appendingPathComponent("projects"), since: cutoff) {
                    read(url) { line in self.takeClaude(line) }
                }
            }
            claudeEvents = claudeEvents.filter { $0.value.date >= cutoff }
            result.claude = Self.tally(claudeEvents.values, today: today, cutoff: cutoff)
        }

        if Self.exists(codexRoot) {
            // The newest session is read whatever its age: its limits may still
            // be current even if its tokens no longer count — on a thirty-day
            // window, very likely.
            let sessions = codexRoot.appendingPathComponent("sessions")
            var urls = Self.logs(in: sessions, since: cutoff)
            if let newest = Self.logs(in: sessions, since: .distantPast).max(by: { Self.modified($0) < Self.modified($1) }),
               !urls.contains(newest) {
                urls.append(newest)
            }
            for url in urls {
                read(url) { line in self.takeCodex(line, file: url) }
            }
            // Only Codex files keep events of their own; Claude's are shared
            // in `claudeEvents`.
            var events: [Event] = []
            for key in files.keys {
                files[key]?.events.removeAll { $0.date < cutoff }
                events += files[key]?.events ?? []
            }
            result.codex = Self.tally(events, today: today, cutoff: cutoff)
            result.codexLimits = codexLimits
        }

        return result
    }

    // MARK: - Lines

    private static let claudeNeedle = Data("\"output_tokens\"".utf8)
    private static let codexNeedle = Data("\"token_count\"".utf8)

    private func takeClaude(_ line: Data) {
        // Most lines are tool output and prompts, some of them megabytes long.
        // Looking for the key in the bytes is far cheaper than decoding each
        // one to find out it has no usage in it.
        guard line.range(of: Self.claudeNeedle) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let entry = AIUsageParsing.claudeTokens(from: object) else { return }
        claudeEvents[entry.key] = Event(date: entry.date, tokens: entry.tokens)
    }

    /// A turn counts once, when the running total moves. Codex repeats the
    /// event without new usage — a rate-limit update alone is written as one —
    /// and a resumed session starts its total from what it carried over, so
    /// neither the total alone nor every `last` alone gives the right sum.
    private func takeCodex(_ line: Data, file: URL) {
        guard line.range(of: Self.codexNeedle) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = AIUsageParsing.codexEvent(from: object) else { return }
        if let limits = event.limits, limits.observedAt >= (codexLimits?.observedAt ?? .distantPast) {
            codexLimits = limits
        }
        guard let total = event.total, total != files[file]?.lastTotal else { return }
        files[file]?.lastTotal = total
        if let last = event.last, last > 0 {
            files[file]?.events.append(Event(date: event.date, tokens: last))
        }
    }

    // MARK: - Files

    /// Feeds `take` every complete line appended since the last read. A line
    /// still being written — no newline yet — is left for the next pass.
    private func read(_ url: URL, take: (Data) -> Void) {
        let size = Self.size(url)
        var state = files[url] ?? FileState()
        if size < state.offset { state = FileState() }
        guard size > state.offset else {
            files[url] = state
            return
        }
        files[url] = state

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil,
              let data = try? handle.readToEnd(),
              let end = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...end]
        for line in complete.split(separator: 0x0A) where !line.isEmpty {
            take(Data(line))
        }
        files[url]?.offset = state.offset + UInt64(complete.count)
    }

    private static func logs(in folder: URL, since cutoff: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
            found.append(url)
        }
        return found
    }

    private static func tally(_ events: some Sequence<Event>, today: Date, cutoff: Date) -> TokenTally {
        var tally = TokenTally()
        for event in events where event.date >= cutoff {
            tally.week += event.tokens
            if event.date >= today { tally.today += event.tokens }
        }
        return tally
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}
