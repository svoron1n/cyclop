import SwiftUI

struct CalendarPane: View {
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var privacy: PrivacyMode

    /// One cover for the whole tab rather than one per meeting: the agenda is a
    /// dense list of short rows, and a column of eyes in it would be louder
    /// than the meetings. Times stay legible either way — a time says nothing
    /// on its own, and the countdown in the panel's header shows one anyway.
    private var hidden: Bool { privacy.hides(.calendar, "calendar") }

    /// Which calendars feed the panel, apart from which ones Calendar.app
    /// shows (#36). A button rather than a menu: toggling several calendars
    /// in a row through a menu means reopening it after every click, since a
    /// menu closes on the click that answers it — a view in the tab itself
    /// does not have that problem.
    @State private var showingCalendars = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch calendar.access {
                case .notRequested:
                    permissionPrompt
                case .denied:
                    deniedState
                case .granted:
                    if showingCalendars {
                        calendarsList
                    } else if let next = calendar.next {
                        agenda(next: next)
                    } else {
                        emptyState
                    }
                }
            }
            if calendar.access == .granted {
                calendarsToggle
            }
        }
    }

    /// A gear while browsing the agenda; a filled "Done" pill while the list
    /// is open, so leaving it reads as finishing a choice rather than as
    /// dismissing a popup — even though every tap already applied on its own.
    private var calendarsToggle: some View {
        Button {
            showingCalendars.toggle()
        } label: {
            if showingCalendars {
                Text(localized("Done"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.surfaceHover))
            } else {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 22, height: 22)
            }
        }
        .buttonStyle(.plain)
        .help(localized(showingCalendars ? "Done" : "Calendars"))
    }

    /// A checkbox per calendar EventKit knows about, defaulting to whatever
    /// Calendar.app currently shows — a pick made here overrides that
    /// permanently, in either direction, and holds regardless of what the
    /// checkbox in Calendar.app does afterwards. Each tap reloads the agenda
    /// at once, there is nothing here to save.
    private var calendarsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("Calendars"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.trailing, 60)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(calendar.calendarOptions) { option in
                        Button {
                            calendar.setCalendarShown(!option.isShown, identifier: option.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: option.isShown ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(option.isShown ? Theme.text : Theme.tertiary)
                                Text(option.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 60)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 4)
    }

    // MARK: - Agenda

    private func agenda(next: CalendarStore.Meeting) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color(next.calendarColor))
                        .frame(width: 7, height: 7)
                    SpoilerText(
                        text: next.title,
                        hidden: hidden,
                        font: .system(size: 16, weight: .semibold),
                        height: 18,
                        seed: UInt64(bitPattern: Int64(next.id.hashValue))
                    )
                    if privacy.covers(.calendar) {
                        RevealEye(hidden: hidden) { privacy.toggle("calendar") }
                    }
                }
                Text(subtitle(for: next))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .padding(.top, 4)
                    .padding(.leading, 14)

                Spacer(minLength: 10)

                if next.link != nil {
                    Button {
                        calendar.join(next)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "video.fill").font(.system(size: 10))
                            Text(next.provider.map { localized("Join · %@", $0) } ?? localized("Join"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(next.isRunning ? Theme.text.opacity(0.92) : Theme.surfaceHover)
                        )
                        .foregroundStyle(next.isRunning ? Theme.background : Theme.text)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rest
        }
        .padding(.top, 4)
    }

    /// A run of meetings that share a day, under one heading.
    private struct Day: Identifiable {
        let start: Date
        var meetings: [CalendarStore.Meeting]
        var id: Date { start }
    }

    /// Lines the right column has room for, headings included — a heading
    /// takes a line like a meeting does, so a week of one daily stand-up
    /// fits fewer meetings than a single busy afternoon, and that is right:
    /// the column is a glance, not the week.
    private static let restLines = 7

    /// `upcoming`, cut into days and trimmed to `restLines`. A day never
    /// ends up as a heading with nothing under it.
    private var days: [Day] {
        let calendar = Foundation.Calendar.current
        var days: [Day] = []
        var lines = 0
        for meeting in self.calendar.upcoming {
            let start = calendar.startOfDay(for: meeting.start)
            let isNewDay = days.last?.start != start
            let cost = isNewDay ? 2 : 1
            guard lines + cost <= Self.restLines else { break }
            lines += cost
            if isNewDay {
                days.append(Day(start: start, meetings: [meeting]))
            } else {
                days[days.count - 1].meetings.append(meeting)
            }
        }
        return days
    }

    /// Everything after the next meeting, as a column on the right, under a
    /// heading per day. Times alone were ambiguous the moment the list ran
    /// past today: a week of the same stand-up read as one "10:00" repeated,
    /// with nothing to say which morning each one was.
    ///
    /// Every meeting with a call gets its own Join button, not only `next`:
    /// a link that only the first meeting shows reads as a link the others
    /// do not have, and the one that matters might be an overlap, or the
    /// one after a meeting that is about to be skipped.
    private var rest: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                Text(Self.heading(for: day.start))
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .padding(.top, index == 0 ? 0 : 3)
                ForEach(day.meetings) { meeting in
                    row(for: meeting)
                }
            }
            if calendar.upcoming.isEmpty {
                Text("No other meetings this week")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 230, alignment: .leading)
        // Clears the gear button sitting at the pane's own top-trailing
        // corner (#36) — without this, its first row ran straight under it.
        .padding(.trailing, 26)
    }

    private func row(for meeting: CalendarStore.Meeting) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(meeting.calendarColor))
                .frame(width: 5, height: 5)
            Text(Self.clock.string(from: meeting.start))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: 34, alignment: .leading)
            SpoilerText(
                text: meeting.title,
                hidden: hidden,
                font: .system(size: 10.5),
                color: Theme.tertiary,
                height: 11,
                seed: UInt64(bitPattern: Int64(meeting.id.hashValue))
            )
            if meeting.link != nil {
                Spacer(minLength: 4)
                joinButton(for: meeting)
            }
        }
    }

    /// An icon rather than the label the main button spells out: the row has
    /// room for a timestamp and a once-truncated title already, and "Подключиться"
    /// wrapped onto two lines the one time it was tried at this width.
    private func joinButton(for meeting: CalendarStore.Meeting) -> some View {
        Button {
            calendar.join(meeting)
        } label: {
            Image(systemName: "video.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.text)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.surfaceHover))
        }
        .buttonStyle(.plain)
        .help(meeting.provider.map { localized("Join · %@", $0) } ?? localized("Join"))
    }

    private func subtitle(for meeting: CalendarStore.Meeting) -> String {
        var parts = [Self.day(for: meeting.start)]
        parts.append("\(Self.clock.string(from: meeting.start))–\(Self.clock.string(from: meeting.end))")
        if let provider = meeting.provider { parts.append(provider) }
        return parts.joined(separator: " · ").sentenceCased
    }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter
    }()

    /// A word for today and tomorrow, a full date for anything further out.
    /// Today is named too, not left to the time: the agenda spans a week, and
    /// a bare "10:00" next to one that says "tomorrow" reads as a guess.
    static func day(for date: Date) -> String {
        let calendar = Foundation.Calendar.current
        if calendar.isDateInToday(date) { return localized("today") }
        if calendar.isDateInTomorrow(date) { return localized("tomorrow") }
        return weekday.string(from: date)
    }

    /// The day heading in the right column: the same words as `day(for:)`,
    /// upper-cased like the panel's own section title so it reads as a
    /// heading and not as one more meeting.
    static func heading(for date: Date) -> String {
        day(for: date).uppercased(with: Locale(identifier: appLanguage))
    }

    /// "Через 12 мин" / "Идёт сейчас" — shown in the panel header, on its own,
    /// so it is a label and starts with a capital in either language.
    static func countdown(to meeting: CalendarStore.Meeting, from now: Date) -> String {
        phrase(to: meeting, from: now).sentenceCased
    }

    /// The wording alone, lower-case as the languages have it. Kept apart from
    /// the capital so the same phrases could stand mid-sentence one day.
    private static func phrase(to meeting: CalendarStore.Meeting, from now: Date) -> String {
        if meeting.isRunning { return localized("now") }
        let minutes = Int((meeting.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return localized("any moment") }
        if minutes < 60 { return localized("in %d min", minutes) }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? localized("in %d h", hours) : localized("in %d h %d min", hours, rest)
        }
        let days = hours / 24
        return days == 1 ? localized("tomorrow") : localized("in %d d", days)
    }

    // MARK: - States

    private var permissionPrompt: some View {
        VStack(spacing: 9) {
            Image(systemName: "calendar")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("See your next meetings")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text("Cyclop needs access to Calendar. It is the only permission\nthe app asks for, and only for this tab.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
            // Padding and background belong inside the label: with .plain the
            // hit area is the label itself, so decorating the Button from the
            // outside leaves a capsule that only responds on its lettering.
            // "Continue", not "Allow": the granting happens in the system
            // dialog that follows, and App Review reads our own button saying
            // "Allow" as the app pressing for a yes before macOS has asked.
            Button {
                calendar.requestAccess()
            } label: {
                Text("Continue")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.surfaceHover))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("Calendar access is off")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text("Settings → Privacy → Calendars")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("No more meetings")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text("Nothing on the calendar this week")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
