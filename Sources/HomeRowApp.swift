import SwiftUI

final class UIState: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
}

enum SetupPage: String, CaseIterable, Identifiable {
    case autoTune = "Quick Setup"
    case keys = "Home-Row Keys"
    case timing = "Timing & Feel"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .autoTune: return "wand.and.stars"
        case .keys: return "keyboard"
        case .timing: return "slider.horizontal.3"
        }
    }
}

@main
struct HomeRowApp: App {
    @StateObject private var engine = HomeRowEngine()
    @StateObject private var uiState = UIState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine)
        } label: {
            Image(systemName: engine.isEnabled && engine.hasAccessibility ? "keyboard.fill" : "keyboard")
                .accessibilityLabel("HomeRow - \(engine.isEnabled && engine.hasAccessibility ? "Active" : "Paused")")
        }
        .menuBarExtraStyle(.window)

        Window("HomeRow", id: "settings") {
            SetupView(engine: engine, uiState: uiState)
        }
        .defaultSize(width: 780, height: 540)
    }
}

struct MenuBarView: View {
    @ObservedObject var engine: HomeRowEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "keyboard.fill")
                    .font(.title2)
                    .foregroundStyle(engine.isEnabled ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HomeRow")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $engine.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if !engine.hasAccessibility {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("HomeRow needs Device Control permission (Accessibility). Your top-row buttons stay 100% normal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("Grant Permission") {
                                engine.checkAccessibility(prompt: true)
                            }
                            .buttonStyle(.borderedProminent)
                            Text("Checking automatically…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            Toggle("Home Row Shortcuts", isOn: $engine.homeRowModsEnabled)
            Toggle("Caps Lock → Backspace", isOn: $engine.capsLockToBackspace)
            Toggle("Left Cmd → Arrow Keys", isOn: $engine.navLayerEnabled)
            Toggle("Swap Cmd+Tab & Ctrl+Tab", isOn: $engine.swapCmdCtrlTab)
            Toggle("Both Shifts → Pause / Resume", isOn: $engine.bothShiftsToggle)

            Button {
                openWindow(id: "settings")
                NSApp.activate()
            } label: {
                Label("Open HomeRow Settings…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            HStack {
                Spacer()
                Button("Quit HomeRow") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 290)
        .onAppear {
            engine.checkAccessibility(prompt: false)
        }
    }

    private var statusText: String {
        if !engine.hasAccessibility { return "Needs Permission" }
        return engine.isEnabled ? "Active" : "Paused"
    }
}

struct SetupView: View {
    @ObservedObject var engine: HomeRowEngine
    @ObservedObject var uiState: UIState
    @AppStorage("selectedPage") private var selectedRaw: String = SetupPage.autoTune.rawValue

    private var selection: Binding<SetupPage?> {
        Binding(
            get: { SetupPage(rawValue: selectedRaw) ?? .autoTune },
            set: { selectedRaw = ($0 ?? .autoTune).rawValue }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $uiState.columnVisibility) {
            List(SetupPage.allCases, selection: selection) { page in
                Label(page.rawValue, systemImage: page.icon)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 190, max: 215)
        } detail: {
            switch SetupPage(rawValue: selectedRaw) ?? .autoTune {
            case .autoTune:
                AutoTuneTab(engine: engine)
            case .keys:
                KeysTab(engine: engine)
            case .timing:
                TimingTab(engine: engine)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 740, minHeight: 500)
    }
}

struct AutoTuneTab: View {
    @ObservedObject var engine: HomeRowEngine

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "hand.wave.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome to HomeRow")
                            .font(.headline)
                        Text("Type normally for a few seconds and HomeRow will find the most comfortable timing for your hands.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Quick Typing Test") {
                if !engine.isCalibrating {
                    LabeledContent {
                        Button("Start Test") {
                            engine.startCalibration()
                        }
                        .buttonStyle(.borderedProminent)
                    } label: {
                        Text("Automatic Setup")
                        Text("Current feel: \(feelSummary)")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Type this sentence at your normal speed:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("the quick brown fox jumps over the lazy dog")
                            .font(.body.monospaced())
                            .textSelection(.enabled)

                        TextField("Click here and type…", text: $engine.calibrationInput)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            if let recTap = engine.recommendedTapMs, let recIdle = engine.recommendedIdleMs {
                                Label("Ready! (\(Int(recTap))ms hold · \(Int(recIdle))ms protection)", systemImage: "checkmark.circle.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Text("Keep typing… (\(engine.sampleCount)/8 keys)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Cancel") {
                                engine.finishCalibration(apply: false)
                            }
                            .buttonStyle(.bordered)
                            Button("Save") {
                                engine.finishCalibration(apply: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(engine.recommendedTapMs == nil)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Features") {
                SettingToggleRow(
                    title: "Enable HomeRow",
                    whatItDoes: "Master switch that turns all HomeRow features on or off.",
                    howItWorks: "When off, your keyboard behaves 100% like a normal MacBook.",
                    isOn: $engine.isEnabled
                )
                SettingToggleRow(
                    title: "Home Row Shortcuts",
                    whatItDoes: "Lets your resting home-row keys act as Shift, Cmd, Opt, and Ctrl.",
                    howItWorks: "Tap normally to type a letter; hold a key and press another key to trigger a shortcut.",
                    isOn: $engine.homeRowModsEnabled
                )
                SettingToggleRow(
                    title: "Caps Lock → Backspace",
                    whatItDoes: "Turns your Caps Lock key into a fast, easy-to-reach Backspace (Delete) key.",
                    howItWorks: "Remaps Caps Lock at the macOS hardware level so holding it repeats Backspace smoothly without turning on the Caps Lock light.",
                    isOn: $engine.capsLockToBackspace
                )
                SettingToggleRow(
                    title: "Left Cmd → Arrow Keys",
                    whatItDoes: "Turns the Left Command key into an instant navigation layer.",
                    howItWorks: "Hold Left Cmd and press J/K/L/; for Left/Down/Up/Right, or U/O for Home/End.",
                    isOn: $engine.navLayerEnabled
                )
                SettingToggleRow(
                    title: "Swap Cmd+Tab & Ctrl+Tab",
                    whatItDoes: "Separates app switching from browser/editor tab switching.",
                    howItWorks: "Press Ctrl+Tab to switch apps on macOS, and Cmd+Tab to switch tabs inside an app.",
                    isOn: $engine.swapCmdCtrlTab
                )
                SettingToggleRow(
                    title: "Both Shifts → Pause / Resume",
                    whatItDoes: "Lets you quickly toggle HomeRow on or off for games or VMs.",
                    howItWorks: "Press Left Shift + Right Shift together anytime to pause or resume remapping.",
                    isOn: $engine.bothShiftsToggle
                )
                SettingToggleRow(
                    title: "Launch at Login",
                    whatItDoes: "Starts HomeRow automatically whenever you log in to your Mac.",
                    howItWorks: "Uses macOS Login Items so you don't have to reopen the app after a restart.",
                    isOn: Binding(
                        get: { engine.launchAtLogin },
                        set: { engine.setLaunchAtLogin($0) }
                    )
                )
                if let err = engine.launchAtLoginError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Quick Setup")
    }

    private var feelSummary: String {
        if engine.tappingTermMs <= 185 { return "Snappy (\(Int(engine.tappingTermMs))ms)" }
        if engine.tappingTermMs >= 235 { return "Relaxed (\(Int(engine.tappingTermMs))ms)" }
        return "Balanced (\(Int(engine.tappingTermMs))ms)"
    }
}

struct KeysTab: View {
    @ObservedObject var engine: HomeRowEngine
    @AppStorage("displayColemak") private var displayColemak: Bool = true

    private let leftSlots: [(code: CGKeyCode, qwerty: String, colemak: String)] = [
        (0, "A", "A"), (1, "S", "R"), (2, "D", "S"), (3, "F", "T")
    ]
    private let rightSlots: [(code: CGKeyCode, qwerty: String, colemak: String)] = [
        (38, "J", "N"), (40, "K", "E"), (37, "L", "I"), (41, ";", "O")
    ]

    private let navRows: [[(code: CGKeyCode, qwerty: String, colemak: String, action: String)]] = [
        [(32, "U", "L", "Home"), (31, "O", "Y", "End")],
        [(4, "H", "M", "PgUp"), (38, "J", "N", "←"), (40, "K", "E", "↓"), (37, "L", "I", "↑"), (41, ";", "O", "→")],
        [(45, "N", "K", "PgDn"), (46, "M", "H", "Back"), (43, ",", ",", "Fwd")],
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("Keyboard Labels") {
                    Picker("", selection: $displayColemak) {
                        Text("QWERTY").tag(false)
                        Text("Colemak-DH").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }

                VStack(spacing: 10) {
                    HStack {
                        Spacer(minLength: 0)
                        HStack(alignment: .top, spacing: 8) {
                            VStack(spacing: 6) {
                                HStack(spacing: 4) {
                                    ForEach(leftSlots, id: \.code) { item in
                                        NativeKeycapMenu(
                                            letter: displayColemak ? item.colemak : item.qwerty,
                                            mod: engine.keyMods[item.code] ?? .none,
                                            hasBump: item.code == 3,
                                            isPending: engine.pendingSlots.contains(item.code),
                                            isPromoted: engine.promotedSlots.contains(item.code),
                                            isTapped: engine.lastTappedSlot == item.code,
                                            onSelect: { engine.keyMods[item.code] = $0 }
                                        )
                                    }
                                }
                                Text("Left Hand")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 4) {
                                NativeStaticKeycap(letter: "G")
                                NativeStaticKeycap(letter: displayColemak ? "M" : "H")
                            }

                            VStack(spacing: 6) {
                                HStack(spacing: 4) {
                                    ForEach(rightSlots, id: \.code) { item in
                                        NativeKeycapMenu(
                                            letter: displayColemak ? item.colemak : item.qwerty,
                                            mod: engine.keyMods[item.code] ?? .none,
                                            hasBump: item.code == 38,
                                            isPending: engine.pendingSlots.contains(item.code),
                                            isPromoted: engine.promotedSlots.contains(item.code),
                                            isTapped: engine.lastTappedSlot == item.code,
                                            onSelect: { engine.keyMods[item.code] = $0 }
                                        )
                                    }
                                }
                                Text("Right Hand")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    Text(liveFeedbackText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } header: {
                Text("Your Home Row")
            } footer: {
                Text("Click any key above to choose what happens when you hold it. Type to see live tap vs. modifier feedback.")
            }

            Section {
                VStack(spacing: 6) {
                    ForEach(Array(navRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.code) { item in
                                NativeNavKeycap(
                                    letter: displayColemak ? item.colemak : item.qwerty,
                                    action: item.action,
                                    isLayerActive: engine.isNavLayerActive,
                                    isPressed: engine.isNavLayerActive && engine.lastNavKey == item.code
                                )
                            }
                        }
                    }
                    Text("A / Z / X / C / V → Cmd+A / Z / X / C / V · Any other key → Cmd+<key>")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } header: {
                Text("Left Cmd Navigation Layer")
            } footer: {
                Text("Hold Left Command to navigate with your right hand. Other shortcuts pass through normally.")
            }

            Section("About Home-Row Keys") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tap vs. Hold")
                        .font(.subheadline.weight(.medium))
                    Text("Tapping any of these keys types the letter as usual. Holding one down turns it into a Mac shortcut key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("How it works: Left-hand keys modify right-hand keys, and right-hand keys modify left-hand keys (when Safer Two-Hand Shortcuts is on).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Home-Row Keys")
    }

    private var liveFeedbackText: String {
        if !engine.isEnabled { return "HomeRow is paused (press Both Shifts to resume)" }
        if engine.isNavLayerActive { return "Left Cmd Navigation Layer active" }
        if !engine.promotedSlots.isEmpty {
            let mods = engine.promotedSlots.compactMap { engine.keyMods[$0]?.rawValue }
            return "Holding modifier: " + mods.joined(separator: " + ")
        }
        if !engine.pendingSlots.isEmpty { return "Evaluating hold delay…" }
        if let tapped = engine.lastTappedSlot {
            let all = leftSlots + rightSlots
            if let item = all.first(where: { $0.code == tapped }) {
                return "Tapped letter: \(displayColemak ? item.colemak : item.qwerty)"
            }
        }
        return "Try tapping or holding a home-row key"
    }
}

struct NativeKeycapMenu: View {
    let letter: String
    let mod: ModChoice
    let hasBump: Bool
    let isPending: Bool
    let isPromoted: Bool
    let isTapped: Bool
    let onSelect: (ModChoice) -> Void

    var body: some View {
        Menu {
            ForEach(ModChoice.allCases) { choice in
                Button {
                    onSelect(choice)
                } label: {
                    if choice == mod {
                        Label(choice.rawValue, systemImage: "checkmark")
                    } else {
                        Text(choice.rawValue)
                    }
                }
            }
        } label: {
            keycapBody
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(letter) key, hold for \(mod.rawValue)")
        .accessibilityHint("Choose which modifier triggers when holding \(letter)")
    }

    private var keycapBody: some View {
        VStack(spacing: 3) {
            Text(letter)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(isPromoted ? Color.white : Color.primary)
            Text(shortSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isPromoted ? Color.white.opacity(0.9) : (mod == .none ? Color.secondary : Color.accentColor))
            if hasBump {
                Capsule()
                    .fill(isPromoted ? Color.white.opacity(0.7) : Color.secondary.opacity(0.45))
                    .frame(width: 10, height: 2)
            }
        }
        .frame(width: 42, height: 54)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(backgroundColor)
                .shadow(color: Color.black.opacity(0.06), radius: 1, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(borderColor, lineWidth: isPromoted || isPending ? 1.5 : 1)
        )
    }

    private var backgroundColor: Color {
        if isPromoted { return Color.accentColor }
        if isPending { return Color.accentColor.opacity(0.28) }
        if isTapped { return Color.primary.opacity(0.14) }
        return mod == .none ? Color(nsColor: .controlBackgroundColor) : Color.accentColor.opacity(0.14)
    }

    private var borderColor: Color {
        if isPromoted { return Color.accentColor }
        if isPending { return Color.accentColor.opacity(0.85) }
        if isTapped { return Color.primary.opacity(0.5) }
        return mod == .none ? Color(nsColor: .separatorColor) : Color.accentColor.opacity(0.5)
    }

    private var shortSymbol: String {
        switch mod {
        case .none: return "Off"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        case .shift: return "⇧"
        }
    }
}

struct NativeNavKeycap: View {
    let letter: String
    let action: String
    let isLayerActive: Bool
    let isPressed: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(letter)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(isPressed ? Color.white : Color.primary)
            Text(action)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isPressed ? Color.white.opacity(0.9) : Color.accentColor)
        }
        .frame(width: 48, height: 46)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isPressed ? Color.accentColor : (isLayerActive ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isPressed ? Color.accentColor : (isLayerActive ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor)), lineWidth: 1)
        )
    }
}

struct NativeStaticKeycap: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .frame(width: 32, height: 54)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            )
            .accessibilityLabel("\(letter) key, standard letter")
    }
}

struct TimingTab: View {
    @ObservedObject var engine: HomeRowEngine

    var body: some View {
        Form {
            Section("Protection") {
                SettingToggleRow(
                    title: "Safer Two-Hand Shortcuts",
                    whatItDoes: "Prevents same-hand typing rolls from triggering accidental shortcuts.",
                    howItWorks: "A left-hand home-row key only becomes a modifier when you press a right-hand key (and vice versa).",
                    isOn: $engine.oppositeHandOnly
                )
                SettingToggleRow(
                    title: "Pinky & Ring Forgiveness (+30 ms)",
                    whatItDoes: "Adds extra hold delay to pinky and ring fingers so outer-finger rolls don't misfire.",
                    howItWorks: "Gives A, S/R, L/I, and ;/O 30 ms of extra time before switching from a letter to a modifier.",
                    isOn: $engine.pinkyRingGrace
                )
            }

            Section("Delays") {
                SettingSliderRow(
                    title: "Hold Delay",
                    whatItDoes: "Sets how long you must hold a key before it switches from a letter to a modifier.",
                    howItWorks: "Release faster than \(Int(engine.tappingTermMs)) ms to type the letter; hold longer to activate Shift/Cmd/Opt/Ctrl.",
                    value: $engine.tappingTermMs,
                    range: 120...350
                )

                SettingSliderRow(
                    title: "Fast-Typing Protection",
                    whatItDoes: "Keeps your home-row keys as normal letters while you are actively typing.",
                    howItWorks: "If you pressed any other key within the last \(Int(engine.priorIdleMs)) ms, holding a home-row key won't trigger a modifier.",
                    value: $engine.priorIdleMs,
                    range: 0...400
                )

                SettingSliderRow(
                    title: "Double-Tap Repeat",
                    whatItDoes: "Lets you hold a home-row key to repeat its letter instead of triggering a modifier.",
                    howItWorks: "Tap a key and press it again within \(Int(engine.quickTapMs)) ms to hold and repeat the character (like 'aaaa').",
                    value: $engine.quickTapMs,
                    range: 80...300
                )
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    engine.resetDefaults()
                }
                .buttonStyle(.bordered)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Timing & Feel")
    }
}

struct SettingToggleRow: View {
    let title: String
    let whatItDoes: String
    let howItWorks: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            Text("\(whatItDoes) How it works: \(howItWorks)")
        }
    }
}

struct SettingSliderRow: View {
    let title: String
    let whatItDoes: String
    let howItWorks: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                Text("\(Int(value)) ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: 5)
            Text("\(whatItDoes)\nHow it works: \(howItWorks)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
