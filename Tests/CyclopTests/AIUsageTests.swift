import Foundation
import Testing
@testable import Cyclop

/// Тесты на вкладку «Лимиты ИИ» — разбор ответов и журналов, а не экран.
///
/// Оба формата чужие и нигде не описаны: ответ `/api/oauth/usage` и журналы
/// сессий Claude Code и Codex. Меняются они без предупреждения, так что тесты
/// держат в руках то, что видели вживую, — с живыми же кусками JSON.
///
/// Сканер гоняется по временным папкам. Настоящие `~/.claude` и `~/.codex`
/// не читаются: цифры в них у каждого свои.
struct AIUsageParsingTests {

    // MARK: - Ответ Anthropic

    /// Так эндпоинт отвечал в сентябре 2026: окна перечислены в `limits`,
    /// недельный лимит на модель несёт её имя.
    @Test func claudeLimitsFromLimitsArray() throws {
        let json = """
        {"five_hour":{"utilization":5.0,"resets_at":"2026-09-24T00:20:00.068446+00:00"},
         "limits":[
          {"kind":"session","group":"session","percent":5,"resets_at":"2026-09-24T00:20:00.068446+00:00","scope":null},
          {"kind":"weekly_all","group":"weekly","percent":10,"resets_at":"2026-09-28T11:00:00.068468+00:00","scope":null},
          {"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":"2026-09-28T11:00:00+00:00",
           "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
        """
        let limits = try #require(AIUsageParsing.claudeLimits(from: Data(json.utf8)))
        #expect(limits.count == 3)
        #expect(limits[0].minutes == 300)
        #expect(limits[0].percent == 5)
        #expect(limits[1].minutes == 10080)
        #expect(limits[1].scope == nil)
        #expect(limits[2].scope == "Fable")
        let reset = try #require(limits[0].resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_790_209_200.068) < 0.01)
    }

    /// Без `limits` — старые ключи. Отсутствующее окно (`null`) пропускается,
    /// а не превращается в ноль процентов.
    @Test func claudeLimitsFallBackToNamedWindows() throws {
        let json = """
        {"five_hour":{"utilization":42.5,"resets_at":"2026-09-24T00:20:00Z"},
         "seven_day":{"utilization":10,"resets_at":null},
         "seven_day_opus":null}
        """
        let limits = try #require(AIUsageParsing.claudeLimits(from: Data(json.utf8)))
        #expect(limits.map(\.minutes) == [300, 10080])
        #expect(limits[0].percent == 42.5)
        #expect(limits[1].resetsAt == nil)
    }

    @Test func claudeLimitsRejectGarbage() {
        #expect(AIUsageParsing.claudeLimits(from: Data("{}".utf8)) == nil)
        #expect(AIUsageParsing.claudeLimits(from: Data("<html>".utf8)) == nil)
    }

    @Test func claudePlanName() {
        #expect(AIUsageParsing.claudePlan(subscription: "max", tier: "default_claude_max_5x") == "Max 5x")
        #expect(AIUsageParsing.claudePlan(subscription: "max", tier: "default_claude_max_20x") == "Max 20x")
        #expect(AIUsageParsing.claudePlan(subscription: "pro", tier: "default_claude_ai") == "Pro")
        #expect(AIUsageParsing.claudePlan(subscription: nil, tier: "default_claude_max_5x") == nil)
    }

    /// Из записи в связке ключей берётся токен доступа, срок и тариф — и
    /// больше ничего.
    @Test func claudeCredentials() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"tok","refreshToken":"ref","expiresAt":1790220121659,
         "subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}
        """
        let credentials = try #require(AIUsageParsing.claudeCredentials(from: Data(json.utf8)))
        #expect(credentials.accessToken == "tok")
        #expect(credentials.plan == "Max 5x")
        #expect(credentials.isExpired(at: Date(timeIntervalSince1970: 1_790_220_100)) == true)
        #expect(credentials.isExpired(at: Date(timeIntervalSince1970: 1_790_200_000)) == false)
    }

    // MARK: - Журналы

    /// Служебные ответы самого Claude Code (`<synthetic>`) никуда не
    /// отправлялись и токенов не стоили.
    @Test func claudeSyntheticRepliesAreFree() throws {
        let line = #"{"timestamp":"2026-09-23T10:00:00.000Z","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(AIUsageParsing.claudeTokens(from: object) == nil)
    }

    /// Бесплатный тариф Codex — одно окно в тридцать дней. Старые сборки писали
    /// `resets_in_seconds` вместо `resets_at`.
    @Test func codexLimitsBothResetSpellings() throws {
        let observed = Date(timeIntervalSince1970: 1_790_000_000)
        let current = try #require(AIUsageParsing.codexLimits(from: [
            "primary": ["used_percent": 11.0, "window_minutes": 43200, "resets_at": 1_790_501_346],
            "secondary": NSNull(),
            "plan_type": "free",
        ], observedAt: observed))
        #expect(current.plan == "Free")
        #expect(current.limits.count == 1)
        #expect(current.limits[0].minutes == 43200)
        #expect(current.limits[0].resetsAt == Date(timeIntervalSince1970: 1_790_501_346))

        let legacy = try #require(AIUsageParsing.codexLimits(from: [
            "primary": ["used_percent": 50, "window_minutes": 300, "resets_in_seconds": 600],
        ], observedAt: observed))
        #expect(legacy.limits[0].resetsAt == observed.addingTimeInterval(600))
    }

    /// Окно, чей сброс уже прошёл, начато заново — что бы ни говорил последний
    /// отчёт.
    @Test func limitPastItsResetIsEmpty() {
        let reset = Date(timeIntervalSince1970: 1000)
        let limit = UsageLimit(minutes: 300, scope: nil, percent: 80, resetsAt: reset)
        #expect(limit.percent(at: reset.addingTimeInterval(-1)) == 80)
        #expect(limit.percent(at: reset) == 0)
    }
}

struct UsageScannerTests {
    private let now = Date()
    private let calendar = Calendar.current

    private static func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cyclop-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ lines: [String], to url: URL, append: Bool = false, newline: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (newline ? "\n" : "")
        if append, let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    private func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func claudeLine(id: String, request: String = "r", at date: Date, output: Int = 10) -> String {
        #"{"type":"assistant","requestId":"\#(request)","timestamp":"\#(stamp(date))","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":\#(output),"cache_creation_input_tokens":100,"cache_read_input_tokens":1000}}}"#
    }

    private func codexLine(at date: Date, total: Int, last: Int, percent: Double = 20) -> String {
        #"{"timestamp":"\#(stamp(date))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"total_tokens":\#(last)}},"rate_limits":{"primary":{"used_percent":\#(percent),"window_minutes":300,"resets_at":\#(Int(date.timeIntervalSince1970) + 3600)},"secondary":null,"plan_type":"plus"}}}"#
    }

    /// Нет папки — нет инструмента. Ноль токенов значит другое: инструмент
    /// есть, но сегодня им не пользовались.
    @Test func missingToolsAreNil() async throws {
        let root = try Self.folder()
        let scanner = UsageScanner(claudeRoots: [root.appendingPathComponent("claude")], codexRoot: root.appendingPathComponent("codex"))
        let scan = await scanner.scan(now: now, calendar: calendar)
        #expect(scan.claude == nil)
        #expect(scan.codex == nil)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude"), withIntermediateDirectories: true)
        let again = await scanner.scan(now: now, calendar: calendar)
        #expect(again.claude == TokenTally())
    }

    /// Один ответ Claude Code пишется несколькими строками с одинаковым
    /// `usage`, а продолженная сессия копирует прошлые ответы в новый файл.
    /// Считать по строкам — заплатить за ответ трижды.
    @Test func claudeRepliesCountOnce() async throws {
        let root = try Self.folder()
        let claude = root.appendingPathComponent("claude")
        let line = claudeLine(id: "a", at: now)
        try Self.write([line, line, #"{"type":"user","message":{"content":"hi"}}"#], to: claude.appendingPathComponent("projects/p/one.jsonl"))
        try Self.write([line, claudeLine(id: "b", at: now)], to: claude.appendingPathComponent("projects/p/two/subagents/agent.jsonl"))

        let scanner = UsageScanner(claudeRoots: [claude], codexRoot: root.appendingPathComponent("none"))
        let scan = await scanner.scan(now: now, calendar: calendar)
        // 1 + 10 + 100 + 1000 за каждый из двух разных ответов.
        #expect(scan.claude?.today == 2 * 1111)
        #expect(scan.claude?.week == 2 * 1111)
    }

    /// Вчерашнее идёт в неделю, но не в сегодня; восьмидневное — никуда.
    @Test func claudeDaysSplit() async throws {
        let root = try Self.folder()
        let claude = root.appendingPathComponent("claude")
        let today = calendar.startOfDay(for: now)
        let yesterday = today.addingTimeInterval(-3600)
        let old = calendar.date(byAdding: .day, value: -8, to: today)!
        try Self.write([
            claudeLine(id: "t", at: now),
            claudeLine(id: "y", at: yesterday),
            claudeLine(id: "o", at: old),
        ], to: claude.appendingPathComponent("projects/p/s.jsonl"))

        let scan = await UsageScanner(claudeRoots: [claude], codexRoot: root).scan(now: now, calendar: calendar)
        #expect(scan.claude?.today == 1111)
        #expect(scan.claude?.week == 2222)
    }

    /// Второй проход дочитывает только дописанное. Строка без перевода строки
    /// ещё пишется — её место в следующем проходе, а не половина сейчас.
    @Test func appendedLinesAreReadOnce() async throws {
        let root = try Self.folder()
        let claude = root.appendingPathComponent("claude")
        let file = claude.appendingPathComponent("projects/p/s.jsonl")
        try Self.write([claudeLine(id: "a", at: now)], to: file)

        let scanner = UsageScanner(claudeRoots: [claude], codexRoot: root.appendingPathComponent("none"))
        #expect(await scanner.scan(now: now, calendar: calendar).claude?.today == 1111)

        let partial = claudeLine(id: "b", at: now)
        try Self.write([String(partial.prefix(40))], to: file, append: true, newline: false)
        #expect(await scanner.scan(now: now, calendar: calendar).claude?.today == 1111)

        try Self.write([String(partial.dropFirst(40))], to: file, append: true)
        #expect(await scanner.scan(now: now, calendar: calendar).claude?.today == 2222)
        #expect(await scanner.scan(now: now, calendar: calendar).claude?.today == 2222)
    }

    /// Codex повторяет событие без нового расхода — например, когда обновились
    /// только лимиты. Ход засчитывается, когда сдвинулась сумма сессии.
    @Test func codexRepeatedEventsCountOnce() async throws {
        let root = try Self.folder()
        let codex = root.appendingPathComponent("codex")
        let t = now.addingTimeInterval(-60)
        try Self.write([
            codexLine(at: t, total: 100, last: 100, percent: 10),
            codexLine(at: t.addingTimeInterval(1), total: 100, last: 100, percent: 11),
            codexLine(at: t.addingTimeInterval(2), total: 250, last: 150, percent: 12),
        ], to: codex.appendingPathComponent("sessions/2026/09/23/rollout-a.jsonl"))

        let scan = await UsageScanner(claudeRoots: [root.appendingPathComponent("none")], codexRoot: codex).scan(now: now, calendar: calendar)
        #expect(scan.codex?.today == 250)
        #expect(scan.codexLimits?.plan == "Plus")
        #expect(scan.codexLimits?.limits.first?.percent == 12)
    }

    /// Самая свежая сессия читается ради лимитов, даже если она старше недели:
    /// на тридцатидневном окне её цифра всё ещё в силе. Её токены при этом в
    /// неделю не идут.
    @Test func codexLimitsFromAnOldSession() async throws {
        let root = try Self.folder()
        let codex = root.appendingPathComponent("codex")
        let then = calendar.date(byAdding: .day, value: -20, to: now)!
        let file = codex.appendingPathComponent("sessions/2026/09/03/rollout-old.jsonl")
        try Self.write([codexLine(at: then, total: 500, last: 500, percent: 33)], to: file)
        try FileManager.default.setAttributes([.modificationDate: then], ofItemAtPath: file.path)

        let scan = await UsageScanner(claudeRoots: [root.appendingPathComponent("none")], codexRoot: codex).scan(now: now, calendar: calendar)
        #expect(scan.codex == TokenTally())
        #expect(scan.codexLimits?.limits.first?.percent == 33)
        #expect(scan.codexLimits?.observedAt.timeIntervalSince(then).magnitude ?? 1 < 0.01)
    }
}
