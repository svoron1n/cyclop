import SwiftUI

/// Claude Code and Codex side by side: how much of each plan's windows is
/// spent, when they start over, and how many tokens went through this Mac.
///
/// A column per tool that is installed and none for one that is not — an
/// empty "Codex" beside a busy "Claude" would only say that somebody does not
/// use Codex, which they know.
struct UsagePane: View {
    @ObservedObject var usage: AIUsageStore

    var body: some View {
        Group {
            if !usage.hasScanned {
                // The first pass reads a week of transcripts whole — a second
                // or two on a busy Mac. Every pass after reads only what was
                // appended, so this is seen once per launch.
                note(localized("Loading…"))
            } else if usage.scan.claude == nil, usage.scan.codex == nil {
                nothingInstalled
            } else {
                HStack(alignment: .top, spacing: 14) {
                    if let tokens = usage.scan.claude {
                        claudeColumn(tokens)
                    }
                    if usage.scan.claude != nil, usage.scan.codex != nil {
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(width: 1)
                            .padding(.vertical, 2)
                    }
                    if let tokens = usage.scan.codex {
                        codexColumn(tokens)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Lives exactly as long as the pane: leaving the tab or folding the
        // panel cancels the rescans with it.
        .task { await usage.watch() }
    }

    // MARK: - Claude

    private func claudeColumn(_ tokens: TokenTally) -> some View {
        column(name: "Claude Code", plan: usage.claude.plan, tokens: tokens) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if usage.claude.state == .off {
                    connectPrompt(.claude, localized("Limits are fetched from Anthropic with Claude Code's own sign-in, read from the Keychain."))
                } else {
                    live(usage.claude, signedOut: localized("Claude Code is signed out, or its sign-in has expired. Run “claude” in Terminal once and it renews. The Claude desktop app signs in on its own and won’t help."), now: context.date)
                }
            }
        }
    }

    // MARK: - Codex

    private func codexColumn(_ tokens: TokenTally) -> some View {
        column(name: "Codex", plan: usage.codex.plan ?? usage.scan.codexLimits?.plan, tokens: tokens) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if usage.codex.state == .off {
                    VStack(alignment: .leading, spacing: 8) {
                        logged(now: context.date)
                        connectPrompt(.codex, localized("Current limits come from OpenAI, with Codex's sign-in from ~/.codex."))
                    }
                } else {
                    live(usage.codex, signedOut: localized("Codex is signed out, or its sign-in has expired. Open it once and it renews."), now: context.date)
                }
            }
        }
    }

    /// What Codex last wrote into a session log. It reports its limits only
    /// while it runs, so the figure is as old as the last session — said when
    /// that is long enough to matter.
    @ViewBuilder
    private func logged(now: Date) -> some View {
        if let snapshot = usage.scan.codexLimits {
            VStack(alignment: .leading, spacing: 6) {
                limits(snapshot.limits, now: now)
                if now.timeIntervalSince(snapshot.observedAt) > 10 * 60 {
                    Text(localized("Updated %@", Self.ago(snapshot.observedAt, now: now)))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.tertiary)
                }
            }
        } else {
            note(localized("No limits yet: Codex writes them during a session."))
        }
    }

    // MARK: - Live limits

    @ViewBuilder
    private func live(_ live: AIUsageStore.Live, signedOut: String, now: Date) -> some View {
        switch live.state {
        case .loading where live.limits.isEmpty:
            note(localized("Loading…"))
        case .signedOut:
            note(signedOut)
        case .failed(let reason) where live.limits.isEmpty:
            note(localized("Could not load limits: %@", reason))
        default:
            limits(live.limits, now: now)
        }
    }

    /// Said before the button, not after: this is the part of the tab that
    /// goes to the network and reads a sign-in, and it asks nobody else —
    /// neither `/usr/bin/security` nor a file of one's own raises a prompt.
    private func connectPrompt(_ tool: AIUsageStore.Tool, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(explanation)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                usage.setLive(tool, true)
            } label: {
                Text("Show Limits")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.surfaceHover))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Pieces

    private func column<Body: View>(
        name: String,
        plan: String?,
        tokens: TokenTally,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let plan {
                    Text(plan)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.surface))
                }
            }
            body()
            Spacer(minLength: 0)
            Text(localized("Tokens: today %@ · 7 days %@", Self.compact(tokens.today), Self.compact(tokens.week)))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                // The Russian line fills a column with a few points to spare,
                // and a count in billions takes those.
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func limits(_ limits: [UsageLimit], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(limits.prefix(3).enumerated()), id: \.offset) { _, limit in
                row(limit, now: now)
            }
        }
    }

    private func row(_ limit: UsageLimit, now: Date) -> some View {
        let percent = limit.percent(at: now)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(Self.title(of: limit))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let resets = limit.resetsAt, resets > now {
                    Text(Self.reset(resets, now: now))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 30, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface)
                    Capsule()
                        .fill(Self.tint(percent))
                        .frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
                }
            }
            .frame(height: 4)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var nothingInstalled: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("No Claude Code or Codex on this Mac")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text("The tab reads their logs in ~/.claude and ~/.codex")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Wording

    /// Named by length rather than by vendor jargon: "5 h", "Week", "30 d".
    /// A per-model cap carries the model after a dot.
    static func title(of limit: UsageLimit) -> String {
        let span: String
        switch limit.minutes {
        case 10080?: span = localized("Week")
        case let minutes? where minutes % 1440 == 0: span = localized("%d d", minutes / 1440)
        case let minutes? where minutes % 60 == 0: span = localized("%d h", minutes / 60)
        case let minutes?: span = localized("%d min", minutes)
        case nil: span = localized("Limit")
        }
        guard let scope = limit.scope else { return span }
        return "\(span) · \(scope)"
    }

    /// Same wording as the meeting countdown for anything within a day; past
    /// that, the weekday and time it happens, which is what one plans by.
    ///
    /// Rounded to the minute first: Anthropic sends a reset on the hour as
    /// `10:59:59.068`, and cut down to minutes that reads as 10:59.
    static func reset(_ exact: Date, now: Date) -> String {
        let date = Date(timeIntervalSinceReferenceDate: (exact.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return localized("in %d min", max(minutes, 1)) }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? localized("in %d h", hours) : localized("in %d h %d min", hours, rest)
        }
        return weekday.string(from: date)
    }

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return formatter
    }()

    static func ago(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        // Not `.abbreviated`: in Russian that drops "назад" for a minus
        // sign, "-3 нед.".
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "840", "12.4K", "3.1M" — a token count only has to be read at a glance.
    static func compact(_ value: Int) -> String {
        let steps: [(Double, String)] = [(1e9, "%@B"), (1e6, "%@M"), (1e3, "%@K")]
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        for (size, key) in steps where Double(value) >= size {
            let scaled = Double(value) / size
            formatter.maximumFractionDigits = scaled < 100 ? 1 : 0
            return localized(key, formatter.string(from: NSNumber(value: scaled)) ?? "\(scaled)")
        }
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// The text colour while there is room, then the theme's warning. Past
    /// 90% it is red in every theme: no palette has a role for "about to
    /// stop", and a warning tone that only deepens reads as the same one.
    private static func tint(_ percent: Double) -> AnyShapeStyle {
        switch percent {
        case ..<75: AnyShapeStyle(Theme.text.opacity(0.85))
        case ..<90: AnyShapeStyle(Theme.warning)
        default: AnyShapeStyle(Color.red.opacity(0.85))
        }
    }
}
