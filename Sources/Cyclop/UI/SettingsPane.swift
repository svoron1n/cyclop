import SwiftUI
import ServiceManagement

/// What used to live in the status bar menu, minus the two items that belong
/// there: opening the panel and hiding its contents are both things people
/// reach for in a hurry, often without wanting to open the panel at all — the
/// rest is configuration, read rarely, and reads better as a tab like any
/// other than as a menu that grows a new row per feature.
struct SettingsPane: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var shelf: ShelfStore
    let screenshots: ScreenshotFolderWatcher
    @ObservedObject private var config = ConfigStore.shared

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var menuBarIconVisible = AppDelegate.isMenuBarIconVisible
    @State private var saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
    @State private var allDisplays = NotchGeometry.showsOnAllDisplays
    @State private var fullSizeNotch = NotchGeometry.drawsFullSizeNotch
    @State private var watchScreenshotFolder = false
    @State private var claudeLimits = false
    @State private var screenshotUsage: (files: Int, bytes: Int64) = (0, 0)
    /// The colour row whose swatches are open — one at a time.
    @State private var editingColor: ColorSlot?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                section(localized("General")) {
                    toggleRow(
                        symbol: "arrow.forward.to.line",
                        title: localized("Launch at Login"),
                        isOn: launchAtLoginBinding
                    )
                    // Off means the same thing a ⌘-drag off the bar does —
                    // both go through `AppDelegate.isMenuBarIconVisible`, so
                    // whichever one somebody used, this switch shows it (#5).
                    toggleRow(
                        symbol: "eye.fill",
                        title: localized("Show Menu Bar Icon"),
                        isOn: menuBarIconVisibleBinding
                    )
                }

                appearanceSection

                // The rail is for what gets a glance between other things.
                // A tab used once a month is not banned from it, but it lives
                // there only as long as whoever never uses it can take it off —
                // and off means quiet too: its background stops with the icon.
                section(localized("Show in Panel")) {
                    ForEach(NotchViewModel.Tab.leftRail + NotchViewModel.Tab.rightRail) { tab in
                        if tab.canHide {
                            toggleRow(symbol: tab.symbol, title: tab.title, isOn: visibilityBinding(tab))
                        }
                    }
                }

                section(localized("Displays")) {
                    toggleRow(
                        symbol: "display.2",
                        title: localized("Show on All Displays"),
                        isOn: allDisplaysBinding
                    )
                    toggleRow(
                        symbol: "rectangle.topthird.inset.filled",
                        title: localized("Full-Height Notch Without a Cutout"),
                        isOn: fullSizeNotchBinding
                    )
                }

                section(localized("Screenshots")) {
                    toggleRow(
                        symbol: "photo.on.rectangle",
                        title: localized("Save Clipboard Screenshots"),
                        isOn: saveClipboardImagesBinding
                    )
                    toggleRow(
                        symbol: "eye",
                        title: localized("Watch Screenshots Folder"),
                        isOn: watchScreenshotFolderBinding
                    )
                    actionRow(symbol: "folder", title: localized("Show Screenshots Folder")) {
                        ScreenshotVault.reveal()
                    }
                    actionRow(
                        symbol: "trash",
                        title: clearTitle,
                        disabled: screenshotUsage.files == 0
                    ) {
                        ScreenshotVault.clear()
                        shelf.load()
                        // The files were just deleted, so the cards have to go
                        // with them. Safe to look here: the vault lives in the
                        // app's own folder, which macOS does not guard.
                        shelf.refreshFromDisk()
                        refreshUsage()
                    }
                }

                section(localized("Snippets")) {
                    actionRow(symbol: "doc.text", title: localized("Show Snippets File")) {
                        vm.snippets.reveal()
                    }
                }

                // The way back out of the button on the AI tab: turning the
                // limits on is done there, where it is explained; here it
                // can only be seen and undone.
                section(localized("AI Usage")) {
                    toggleRow(
                        symbol: "key",
                        title: localized("Claude Limits from Keychain"),
                        isOn: claudeLimitsBinding
                    )
                }

                // What lives in this file is documented in #67: everything
                // above that makes sense on another Mac, in one place instead
                // of five.
                section(localized("Configuration")) {
                    if config.fileBroken { configBrokenNotice }
                    actionRow(symbol: "gearshape", title: localized("Show Config File")) {
                        ConfigStore.reveal()
                    }
                }

                // The one door left once the menu bar icon is gone (#5): a
                // status item is not required to hide it any more, so quitting
                // must not require one either. Last on purpose — leaving is
                // not something to meet on the way to a switch.
                section(localized("Cyclop")) {
                    actionRow(symbol: "power", title: localized("Quit Cyclop")) {
                        NSApp.terminate(nil)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Live state, not a snapshot taken once at launch: System Settings can
        // flip Launch at Login from outside, and the folder can empty or fill
        // between visits to this tab (#11 taught the same lesson for the menu
        // this replaces).
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            // Also flipped by a ⌘-drag off the bar, not only by the switch
            // below it — re-read for the same reason as the rest of this block.
            menuBarIconVisible = AppDelegate.isMenuBarIconVisible
            saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
            allDisplays = NotchGeometry.showsOnAllDisplays
            fullSizeNotch = NotchGeometry.drawsFullSizeNotch
            watchScreenshotFolder = screenshots.isEnabled
            claudeLimits = vm.usage.claudeLimitsEnabled
            refreshUsage()
        }
    }

    private var clearTitle: String {
        guard screenshotUsage.files > 0 else { return localized("Clear Screenshots Folder") }
        let size = ByteCountFormatter.string(fromByteCount: screenshotUsage.bytes, countStyle: .file)
        return localized("Clear Screenshots Folder (%@)", size)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wants in
                do {
                    if wants {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("Cyclop: launch-at-login failed: \(error.localizedDescription)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }

    private var menuBarIconVisibleBinding: Binding<Bool> {
        Binding(
            get: { menuBarIconVisible },
            set: { wants in
                menuBarIconVisible = wants
                AppDelegate.isMenuBarIconVisible = wants
            }
        )
    }

    private func visibilityBinding(_ tab: NotchViewModel.Tab) -> Binding<Bool> {
        Binding(
            get: { vm.isVisible(tab) },
            set: { wants in vm.setVisible(tab, wants) }
        )
    }

    private var saveClipboardImagesBinding: Binding<Bool> {
        Binding(
            get: { saveClipboardImages },
            set: { wants in
                saveClipboardImages = wants
                NotchViewModel.saveClipboardImagesEnabled = wants
            }
        )
    }

    /// Turning this off folds the panel back to one screen — the notched one
    /// if this Mac has a notch, the main display otherwise. The panels are
    /// rebuilt on the spot, so the switch is its own confirmation.
    private var allDisplaysBinding: Binding<Bool> {
        Binding(
            get: { allDisplays },
            set: { wants in
                allDisplays = wants
                NotchGeometry.showsOnAllDisplays = wants
            }
        )
    }

    /// Where a display has no cutout, the notch is drawn as a thin strip along
    /// the top edge; this brings back the old one, the height of the menu bar.
    /// Panels rebuild on the spot, so the switch is its own confirmation.
    private var fullSizeNotchBinding: Binding<Bool> {
        Binding(
            get: { fullSizeNotch },
            set: { wants in
                fullSizeNotch = wants
                NotchGeometry.drawsFullSizeNotch = wants
            }
        )
    }

    /// Turning off is instant. Turning on goes through the Open panel first —
    /// `requestAccess` is itself the consent, so the switch only follows what
    /// actually happened once the panel closes, not the click that opened it.
    private var watchScreenshotFolderBinding: Binding<Bool> {
        Binding(
            get: { watchScreenshotFolder },
            set: { wants in
                if wants {
                    screenshots.requestAccess { granted in watchScreenshotFolder = granted }
                } else {
                    screenshots.disable()
                    watchScreenshotFolder = false
                }
            }
        )
    }

    private var claudeLimitsBinding: Binding<Bool> {
        Binding(
            get: { claudeLimits },
            set: { wants in
                claudeLimits = wants
                vm.usage.claudeLimitsEnabled = wants
            }
        )
    }

    /// Off the main thread: walking the folder takes as long as the folder is
    /// big, and this is the thread the whole panel lives on (#11).
    private func refreshUsage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let usage = ScreenshotVault.usage()
            DispatchQueue.main.async { screenshotUsage = usage }
        }
    }

    // MARK: - Appearance

    /// The colours one can set over a theme, and where each one lives in
    /// `ThemeChoice`.
    private enum ColorSlot: CaseIterable, Identifiable {
        case background, header, icons, accent

        var id: Self { self }

        var title: String {
            switch self {
            case .background: localized("Background")
            case .header: localized("Header")
            case .icons: localized("Tab Icons")
            case .accent: localized("Accent")
            }
        }

        var symbol: String {
            switch self {
            case .background: "rectangle.inset.filled"
            case .header: "menubar.rectangle"
            case .icons: "square.grid.2x2"
            case .accent: "circle.lefthalf.filled"
            }
        }

        var role: ThemeColor.Role {
            switch self {
            case .background: .background
            case .header: .header
            case .icons: .icon
            case .accent: .accent
            }
        }

        var keyPath: WritableKeyPath<ThemeChoice, String?> {
            switch self {
            case .background: \.background
            case .header: \.header
            case .icons: \.icons
            case .accent: \.accent
            }
        }
    }

    /// Drawn in the panel rather than handed to `ColorPicker`: the system
    /// colour panel is a window of its own, and the moment the pointer goes
    /// over to it this panel folds and takes the picker with it. Any other
    /// colour can still be written into `config.json` by hand as `#RRGGBB`.
    private static let swatches = [
        "#000000", "#1C1C1E", "#2A1A41", "#241934", "#823066", "#DF6B6A",
        "#F5C286", "#ABD1E8", "#0A84FF", "#30D158", "#FBF4F2", "#FFFFFF",
    ]

    private var appearanceSection: some View {
        section(localized("Appearance")) {
            presetPicker
            ForEach(ColorSlot.allCases) { slot in
                colorRow(slot)
                if editingColor == slot {
                    swatchRow(slot)
                }
            }
        }
    }

    private var presetPicker: some View {
        HStack(spacing: 4) {
            ForEach(ThemePreset.allCases) { preset in
                let isSelected = (ThemePreset(rawValue: config.theme.preset) ?? .standard) == preset
                Button {
                    // A preset is a whole look: colours picked over the
                    // previous one would only fight it.
                    var choice = ThemeChoice()
                    choice.preset = preset.rawValue
                    config.theme = choice
                } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(preset.palette.background)
                            Circle().fill(preset.palette.icon).frame(width: 5, height: 5)
                        }
                        .frame(width: 13, height: 13)
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                        Text(preset.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isSelected ? Theme.text : Theme.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Theme.surfaceHover : Theme.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private func colorRow(_ slot: ColorSlot) -> some View {
        Button {
            withAnimation(Theme.contentAnimation) {
                editingColor = editingColor == slot ? nil : slot
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: slot.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
                Text(slot.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Circle()
                    .fill(ThemeColor(slot.role))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(editingColor == slot ? 0 : -90))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func swatchRow(_ slot: ColorSlot) -> some View {
        let current = config.theme[keyPath: slot.keyPath]?.uppercased()
        return HStack(spacing: 6) {
            ForEach(Self.swatches, id: \.self) { hex in
                Button {
                    config.theme[keyPath: slot.keyPath] = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex) ?? .clear)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                        .padding(2.5)
                        .overlay(
                            Circle()
                                .strokeBorder(Theme.accent, lineWidth: 1.5)
                                .opacity(current == hex ? 1 : 0)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            Button {
                config.theme[keyPath: slot.keyPath] = nil
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(current == nil)
            .opacity(current == nil ? 0.4 : 1)
            .help(localized("As in the Theme"))
        }
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .frame(height: 28)
        .transition(.opacity)
    }

    // MARK: - Rows

    @ViewBuilder
    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 8)
            VStack(spacing: 1) {
                rows()
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
            )
        }
    }

    private func toggleRow(symbol: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(NotchToggleStyle())
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    /// The refusal to write over a broken file (#7) is only honest if it is
    /// said out loud — same reasoning as `SnippetsPane.brokenNotice`.
    private var configBrokenNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.warning)
            Text(localized("config.json is broken — click to open; nothing is overwritten"))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { ConfigStore.reveal() }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private func actionRow(
        symbol: String,
        title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}
