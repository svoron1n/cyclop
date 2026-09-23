import Foundation

/// What the AI tab shows: tokens Claude Code and Codex spent, read from their
/// logs, and how much of each plan's limits is left.
///
/// Nothing runs in the background. The tab's pane drives `watch()` while it is
/// on screen and cancels it on the way out — a tally nobody is looking at is
/// not worth a pass over hundreds of megabytes of transcripts.
///
/// Codex's limits come from its own logs, like the tokens. Claude Code keeps
/// none there: the only source is the endpoint behind its `/usage` command,
/// which answers to Claude Code's own sign-in. That makes it the one part of
/// the tab that reaches the network and the Keychain, so it is off until the
/// user turns it on with the button in the pane.
@MainActor
final class AIUsageStore: ObservableObject {
    enum ClaudeState: Equatable {
        /// Not turned on. The pane offers the button.
        case off
        case loading
        case ready
        /// No sign-in to use, or one that has run out. Claude Code renews it
        /// the next time it runs; the tab never does.
        case signedOut
        case failed(String)
    }

    @Published private(set) var scan = UsageScan()
    @Published private(set) var hasScanned = false
    @Published private(set) var claudeLimits: [UsageLimit] = []
    @Published private(set) var claudeFetchedAt: Date?
    @Published private(set) var claudePlan: String?
    @Published private(set) var claudeState: ClaudeState = .off

    /// Per Mac, not in `config.json`: it is consent to read this Mac's
    /// Keychain, and a copied config must not carry that to another one.
    var claudeLimitsEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if newValue {
                claudeState = .loading
                Task { await fetchClaudeLimits(force: true) }
            } else {
                credentials = nil
                claudeLimits = []
                claudeFetchedAt = nil
                claudeState = .off
            }
        }
    }

    private let scanner = UsageScanner()
    private let defaults = UserDefaults.standard
    private static let enabledKey = "usage.claudeLimits"
    /// Held in memory only, and read again only once it has run out.
    private var credentials: ClaudeCredentials?
    private var lastFetch: Date?
    private var isFetching = false
    /// The endpoint answers too-frequent callers with 429, and the numbers
    /// behind it do not move faster than this anyway.
    private let fetchInterval: TimeInterval = 120
    private let rescanInterval = Duration.seconds(60)

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    init() {
        if claudeLimitsEnabled { claudeState = .loading }
    }

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
        if claudeLimitsEnabled { await fetchClaudeLimits(force: false) }
    }

    // MARK: - Claude limits

    private func fetchClaudeLimits(force: Bool) async {
        guard !isFetching else { return }
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < fetchInterval { return }
        isFetching = true
        defer { isFetching = false }
        lastFetch = Date()

        if credentials?.isExpired(at: Date()) ?? true {
            credentials = await Self.readCredentials()
        }
        guard let credentials, !credentials.isExpired(at: Date()) else {
            claudeState = .signedOut
            return
        }
        claudePlan = credentials.plan

        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard claudeLimitsEnabled else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                guard let limits = AIUsageParsing.claudeLimits(from: data) else {
                    claudeState = .failed(localized("Unexpected answer"))
                    return
                }
                claudeLimits = limits
                claudeFetchedAt = Date()
                claudeState = .ready
            case 401, 403:
                // Revoked or replaced by a newer sign-in: read the Keychain
                // again next time instead of retrying a token that is dead.
                self.credentials = nil
                claudeState = .signedOut
            case 429:
                // Too soon. What is on screen is at most a couple of minutes
                // old, which is better than an error in its place.
                if claudeLimits.isEmpty { claudeState = .failed(localized("Too many requests")) }
            default:
                claudeState = .failed("HTTP \(status)")
            }
        } catch {
            if claudeLimits.isEmpty { claudeState = .failed(error.localizedDescription) }
        }
    }

    /// Claude Code's sign-in, read the way Claude Code itself reads it back:
    /// with `/usr/bin/security`. The Keychain item is Claude Code's, and its
    /// access list names that tool; the same read through the Security
    /// framework is another app asking, and raises a system prompt that has
    /// nowhere sensible to appear above a panel that is never active. The
    /// consent is the button in the pane, which says what it reads. On
    /// Linux-style setups the same JSON lives in a file instead.
    private nonisolated static func readCredentials() async -> ClaudeCredentials? {
        await Task.detached(priority: .utility) {
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: file),
               let credentials = AIUsageParsing.claudeCredentials(from: data) {
                return credentials
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
        }.value
    }
}
