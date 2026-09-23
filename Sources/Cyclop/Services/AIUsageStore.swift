import Foundation

/// What the AI tab shows: tokens Claude Code and Codex spent, read from their
/// logs, and how much of each plan's limits is left.
///
/// Nothing runs in the background. The tab's pane drives `watch()` while it is
/// on screen and cancels it on the way out — a tally nobody is looking at is
/// not worth a pass over hundreds of megabytes of transcripts.
///
/// Limits come two ways. Codex writes its own into the session log, but only
/// while it runs, so what the log says is as old as the last session. Claude
/// Code keeps none on disk at all. Both answer the question live from the
/// endpoint behind their own `/usage` and `/status`, with their own sign-in —
/// the one part of the tab that reaches the network and reads a credential,
/// so each is off until the user turns it on with the button in the pane.
@MainActor
final class AIUsageStore: ObservableObject {
    enum Tool: String, Sendable {
        case claude, codex
    }

    enum LiveState: Equatable {
        /// Not turned on. The pane offers the button.
        case off
        case loading
        case ready
        /// No sign-in to use, or one that has run out. The tool renews it the
        /// next time it runs; the tab never does.
        case signedOut
        case failed(String)
    }

    /// Limits as the vendor's endpoint gave them.
    struct Live: Equatable {
        var state: LiveState = .off
        var limits: [UsageLimit] = []
        var plan: String?
    }

    @Published private(set) var scan = UsageScan()
    @Published private(set) var hasScanned = false
    @Published private(set) var claude = Live()
    @Published private(set) var codex = Live()

    private let scanner = UsageScanner()
    private let defaults = UserDefaults.standard
    /// Held in memory only, and read again only once they have run out.
    private var signIns: [Tool: SignIn] = [:]
    private var lastFetch: [Tool: Date] = [:]
    private var fetching: Set<Tool> = []
    /// The endpoints answer too-frequent callers with 429, and the numbers
    /// behind them do not move faster than this anyway.
    private let fetchInterval: TimeInterval = 120
    private let rescanInterval = Duration.seconds(60)

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    init() {
        for tool in [Tool.claude, .codex] where isLive(tool) {
            self[tool].state = .loading
        }
    }

    // MARK: - Consent

    /// Per Mac, not in `config.json`: it is consent to read this Mac's
    /// credentials, and a copied config must not carry that to another one.
    func isLive(_ tool: Tool) -> Bool {
        defaults.bool(forKey: Self.enabledKey(tool))
    }

    func setLive(_ tool: Tool, _ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey(tool))
        if on {
            self[tool].state = .loading
            Task { await fetch(tool, force: true) }
        } else {
            signIns[tool] = nil
            self[tool] = Live()
        }
    }

    private static func enabledKey(_ tool: Tool) -> String {
        "usage.\(tool.rawValue)Limits"
    }

    private subscript(tool: Tool) -> Live {
        get { tool == .claude ? claude : codex }
        set {
            switch tool {
            case .claude: claude = newValue
            case .codex: codex = newValue
            }
        }
    }

    // MARK: - Refresh

    /// Rescans for as long as the calling task lives — the pane's `.task`.
    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: rescanInterval)
        }
    }

    func refresh() async {
        scan = await scanner.scan()
        hasScanned = true
        await withTaskGroup(of: Void.self) { group in
            for tool in [Tool.claude, .codex] where isLive(tool) {
                group.addTask { await self.fetch(tool, force: false) }
            }
        }
    }

    private func fetch(_ tool: Tool, force: Bool) async {
        guard !fetching.contains(tool) else { return }
        if !force, let last = lastFetch[tool], Date().timeIntervalSince(last) < fetchInterval { return }
        fetching.insert(tool)
        defer { fetching.remove(tool) }
        lastFetch[tool] = Date()

        if signIns[tool]?.isExpired(at: Date()) ?? true {
            signIns[tool] = await Self.readSignIn(tool)
        }
        guard let signIn = signIns[tool], !signIn.isExpired(at: Date()) else {
            self[tool].state = .signedOut
            return
        }
        self[tool].plan = signIn.plan

        do {
            let (data, response) = try await session.data(for: Self.request(tool, signIn: signIn))
            guard isLive(tool) else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                let parsed: (plan: String?, limits: [UsageLimit])? = switch tool {
                case .claude: AIUsageParsing.claudeLimits(from: data).map { (nil, $0) }
                case .codex: AIUsageParsing.codexUsage(from: data, now: Date()).map { ($0.plan, $0.limits) }
                }
                guard let parsed else {
                    self[tool].state = .failed(localized("Unexpected answer"))
                    return
                }
                self[tool].limits = parsed.limits
                if let plan = parsed.plan { self[tool].plan = plan }
                self[tool].state = .ready
            case 401, 403:
                // Revoked or replaced by a newer sign-in: read it again next
                // time instead of retrying a token that is dead.
                signIns[tool] = nil
                self[tool].state = .signedOut
            case 429:
                // Too soon. What is on screen is at most a couple of minutes
                // old, which is better than an error in its place.
                if self[tool].limits.isEmpty { self[tool].state = .failed(localized("Too many requests")) }
            default:
                self[tool].state = .failed("HTTP \(status)")
            }
        } catch {
            if self[tool].limits.isEmpty { self[tool].state = .failed(error.localizedDescription) }
        }
    }

    private static func request(_ tool: Tool, signIn: SignIn) -> URLRequest {
        var request: URLRequest
        switch tool {
        case .claude:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        case .codex:
            request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            if let account = signIn.accountID {
                request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        }
        request.setValue("Bearer \(signIn.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Sign-ins

    private nonisolated static func readSignIn(_ tool: Tool) async -> SignIn? {
        await Task.detached(priority: .utility) {
            switch tool {
            case .claude: readClaudeSignIn()
            case .codex: readCodexSignIn()
            }
        }.value
    }

    /// Claude Code's sign-in, read the way Claude Code itself reads it back:
    /// with `/usr/bin/security`. The Keychain item is Claude Code's, and its
    /// access list names that tool; the same read through the Security
    /// framework is another app asking, and raises a system prompt that has
    /// nowhere sensible to appear above a panel that is never active. The
    /// consent is the button in the pane, which says what it reads. On
    /// Linux-style setups the same JSON lives in a file instead.
    private nonisolated static func readClaudeSignIn() -> SignIn? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file),
           let signIn = AIUsageParsing.claudeCredentials(from: data) {
            return signIn
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drained before waiting: a pipe that fills up would block the
        // tool on its write and this on the wait, for ever.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return AIUsageParsing.claudeCredentials(from: data)
    }

    /// Codex keeps its sign-in in a file, readable by the user and nobody
    /// else — the same file the CLI and the ChatGPT app share.
    private nonisolated static func readCodexSignIn() -> SignIn? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return AIUsageParsing.codexCredentials(from: data)
    }
}
