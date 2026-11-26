import Cocoa
import ApplicationServices
import ServiceManagement

enum ModChoice: String, CaseIterable, Identifiable {
    case none = "Off"
    case control = "Control ⌃"
    case option = "Option ⌥"
    case command = "Command ⌘"
    case shift = "Shift ⇧"

    var id: String { rawValue }

    var flag: CGEventFlags? {
        switch self {
        case .none: return nil
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .shift: return .maskShift
        }
    }
}

struct HomeRowSlot: Identifiable {
    let keyCode: CGKeyCode
    let label: String
    let isLeft: Bool
    let isPinkyOrRing: Bool
    var id: CGKeyCode { keyCode }
}

final class HomeRowEngine: ObservableObject {
    static let slots: [HomeRowSlot] = [
        HomeRowSlot(keyCode: 0,  label: "Left Pinky (A)",  isLeft: true,  isPinkyOrRing: true),
        HomeRowSlot(keyCode: 1,  label: "Left Ring (S/R)", isLeft: true,  isPinkyOrRing: true),
        HomeRowSlot(keyCode: 2,  label: "Left Mid (D/S)",  isLeft: true,  isPinkyOrRing: false),
        HomeRowSlot(keyCode: 3,  label: "Left Index (F/T)",isLeft: true,  isPinkyOrRing: false),
        HomeRowSlot(keyCode: 38, label: "Right Index (J/N)",isLeft: false, isPinkyOrRing: false),
        HomeRowSlot(keyCode: 40, label: "Right Mid (K/E)", isLeft: false, isPinkyOrRing: false),
        HomeRowSlot(keyCode: 37, label: "Right Ring (L/I)",isLeft: false, isPinkyOrRing: true),
        HomeRowSlot(keyCode: 41, label: "Right Pinky (;/O)",isLeft: false, isPinkyOrRing: true),
    ]

    @Published var isEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            if !isEnabled { clearActiveState() }
            syncCapsLockMapping()
        }
    }
    @Published var homeRowModsEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(homeRowModsEnabled, forKey: "homeRowModsEnabled")
            if !homeRowModsEnabled { clearActiveState() }
        }
    }
    @Published var capsLockToBackspace: Bool = true {
        didSet {
            UserDefaults.standard.set(capsLockToBackspace, forKey: "capsLockToBackspace")
            syncCapsLockMapping()
        }
    }
    @Published var navLayerEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(navLayerEnabled, forKey: "navLayerEnabled")
            if !navLayerEnabled { clearActiveState() }
        }
    }
    @Published var swapCmdCtrlTab: Bool = true {
        didSet { UserDefaults.standard.set(swapCmdCtrlTab, forKey: "swapCmdCtrlTab") }
    }
    @Published var oppositeHandOnly: Bool = true {
        didSet { UserDefaults.standard.set(oppositeHandOnly, forKey: "oppositeHandOnly") }
    }
    @Published var pinkyRingGrace: Bool = true {
        didSet { UserDefaults.standard.set(pinkyRingGrace, forKey: "pinkyRingGrace") }
    }
    @Published var bothShiftsToggle: Bool = true {
        didSet { UserDefaults.standard.set(bothShiftsToggle, forKey: "bothShiftsToggle") }
    }

    @Published var tappingTermMs: Double = 200 {
        didSet { UserDefaults.standard.set(tappingTermMs, forKey: "tappingTermMs") }
    }
    @Published var priorIdleMs: Double = 250 {
        didSet { UserDefaults.standard.set(priorIdleMs, forKey: "priorIdleMs") }
    }
    @Published var quickTapMs: Double = 175 {
        didSet { UserDefaults.standard.set(quickTapMs, forKey: "quickTapMs") }
    }

    @Published var keyMods: [CGKeyCode: ModChoice] = [
        0: .control, 1: .option, 2: .command, 3: .shift,
        38: .shift, 40: .command, 37: .option, 41: .control
    ] {
        didSet {
            let encoded = Dictionary(uniqueKeysWithValues: keyMods.map { (String($0.key), $0.value.rawValue) })
            UserDefaults.standard.set(encoded, forKey: "keyMods")
        }
    }

    @Published var hasAccessibility: Bool = false
    @Published var launchAtLogin: Bool = false
    @Published var launchAtLoginError: String? = nil

    @Published var isCalibrating: Bool = false
    @Published var calibrationInput: String = ""
    @Published var sampleCount: Int = 0
    @Published var recommendedTapMs: Double?
    @Published var recommendedIdleMs: Double?

    @Published var pendingSlots: Set<CGKeyCode> = []
    @Published var promotedSlots: Set<CGKeyCode> = []
    @Published var lastTappedSlot: CGKeyCode? = nil
    @Published var lastNavKey: CGKeyCode? = nil
    @Published var isNavLayerActive: Bool = false

    private var calibKeyDownTimes: [CGKeyCode: CFAbsoluteTime] = [:]
    private var calibTapDurationsMs: [Double] = []
    private var calibLastKeyUpTime: CFAbsoluteTime = 0
    private var calibRollGapsMs: [Double] = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var willTerminateObserver: NSObjectProtocol?

    private let leftHandKeys: Set<CGKeyCode> = [
        10, 18, 19, 20, 21, 23,
        12, 13, 14, 15, 17,
        0, 1, 2, 3, 5,
        50, 6, 7, 8, 9, 11
    ]
    private let rightHandKeys: Set<CGKeyCode> = [
        22, 26, 28, 25, 29, 27, 24,
        16, 32, 34, 31, 35, 33, 30,
        4, 38, 40, 37, 41, 39, 42,
        45, 46, 43, 47, 44
    ]
    private let neutralKeys: Set<CGKeyCode> = [
        49, 36, 76, 48, 53, 51, 117,
        115, 119, 116, 121,
        123, 124, 125, 126
    ]

    private let navMap: [CGKeyCode: (key: CGKeyCode, mods: CGEventFlags)] = [
        0:  (0,   .maskCommand), // A -> Cmd+A
        32: (115, []),           // U -> Home
        31: (119, []),           // O -> End
        4:  (116, []),           // H -> Page Up
        38: (123, []),           // J -> Left
        40: (125, []),           // K -> Down
        37: (126, []),           // L -> Up
        41: (124, []),           // ; -> Right
        45: (121, []),           // N -> Page Down
        6:  (6,   .maskCommand), // Z -> Cmd+Z
        7:  (7,   .maskCommand), // X -> Cmd+X
        8:  (8,   .maskCommand), // C -> Cmd+C
        9:  (9,   .maskCommand), // V -> Cmd+V
        46: (33,  .maskCommand), // M -> Cmd+[
        43: (30,  .maskCommand), // , -> Cmd+]
    ]

    private struct PendingKey {
        let keyCode: CGKeyCode
        let downTime: CFAbsoluteTime
        let flag: CGEventFlags
        let isLeft: Bool
        var withinPriorIdle: Bool = false
        var promotedToMod: Bool = false
        var timer: DispatchWorkItem? = nil
    }

    private var pending: [CGKeyCode: PendingKey] = [:]
    private var activeMods: CGEventFlags = []
    private var bufferedKeys: [(keyCode: CGKeyCode, flags: CGEventFlags)] = []
    private var synthesizedDownKeys: Set<CGKeyCode> = []
    private var lastNonModKeyTime: CFAbsoluteTime = 0
    private var lastTapReleaseTime: [CGKeyCode: CFAbsoluteTime] = [:]
    private var leftCmdDown: Bool = false
    private var bothShiftsConsumed: Bool = false
    private var tapFlashToken: UInt64 = 0
    private let syntheticTag: Int64 = 0x48524D31

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "isEnabled") != nil { isEnabled = d.bool(forKey: "isEnabled") }
        if d.object(forKey: "homeRowModsEnabled") != nil { homeRowModsEnabled = d.bool(forKey: "homeRowModsEnabled") }
        if d.object(forKey: "capsLockToBackspace") != nil { capsLockToBackspace = d.bool(forKey: "capsLockToBackspace") }
        if d.object(forKey: "navLayerEnabled") != nil { navLayerEnabled = d.bool(forKey: "navLayerEnabled") }
        if d.object(forKey: "swapCmdCtrlTab") != nil { swapCmdCtrlTab = d.bool(forKey: "swapCmdCtrlTab") }
        if d.object(forKey: "oppositeHandOnly") != nil { oppositeHandOnly = d.bool(forKey: "oppositeHandOnly") }
        if d.object(forKey: "pinkyRingGrace") != nil { pinkyRingGrace = d.bool(forKey: "pinkyRingGrace") }
        if d.object(forKey: "bothShiftsToggle") != nil { bothShiftsToggle = d.bool(forKey: "bothShiftsToggle") }
        if d.object(forKey: "tappingTermMs") != nil { tappingTermMs = d.double(forKey: "tappingTermMs") }
        if d.object(forKey: "priorIdleMs") != nil { priorIdleMs = d.double(forKey: "priorIdleMs") }
        if d.object(forKey: "quickTapMs") != nil { quickTapMs = d.double(forKey: "quickTapMs") }
        if let saved = d.dictionary(forKey: "keyMods") as? [String: String] {
            var parsed: [CGKeyCode: ModChoice] = [:]
            for (k, v) in saved {
                if let code = CGKeyCode(k), let choice = ModChoice(rawValue: v) {
                    parsed[code] = choice
                }
            }
            if !parsed.isEmpty { keyMods = parsed }
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        syncCapsLockMapping()
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setHidutilCapsLock(enabled: false, synchronous: true)
        }
        checkAccessibility(prompt: false)
    }

    deinit {
        permissionTimer?.invalidate()
        if let obs = willTerminateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        for p in pending.values {
            p.timer?.cancel()
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
    }

    private func clearActiveState() {
        for p in pending.values {
            p.timer?.cancel()
        }
        pending.removeAll()
        activeMods = []
        bufferedKeys.removeAll()
        synthesizedDownKeys.removeAll()
        leftCmdDown = false
        lastNavKey = nil
        syncLiveUIState()
    }

    private func slotTappingSec(for keyCode: CGKeyCode) -> Double {
        let isOuter = Self.slots.first(where: { $0.keyCode == keyCode })?.isPinkyOrRing ?? false
        let extra = (pinkyRingGrace && isOuter) ? 30.0 : 0.0
        return (tappingTermMs + extra) / 1000.0
    }

    private func syncLiveUIState() {
        var newPending: Set<CGKeyCode> = []
        var newPromoted: Set<CGKeyCode> = []
        for (code, item) in pending {
            if item.promotedToMod {
                newPromoted.insert(code)
            } else {
                newPending.insert(code)
            }
        }
        if pendingSlots != newPending { pendingSlots = newPending }
        if promotedSlots != newPromoted { promotedSlots = newPromoted }
        let navActive = isEnabled && navLayerEnabled && leftCmdDown
        if isNavLayerActive != navActive { isNavLayerActive = navActive }
    }

    private func flashTappedSlot(_ keyCode: CGKeyCode) {
        tapFlashToken &+= 1
        let token = tapFlashToken
        lastTappedSlot = keyCode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self, self.tapFlashToken == token else { return }
            self.lastTappedSlot = nil
        }
    }

    private func canModify(_ targetKey: CGKeyCode, with modIsLeft: Bool) -> Bool {
        if !oppositeHandOnly { return true }
        if neutralKeys.contains(targetKey) { return true }
        return modIsLeft ? rightHandKeys.contains(targetKey) : leftHandKeys.contains(targetKey)
    }

    private func recomputeActiveMods() {
        var flags: CGEventFlags = []
        for p in pending.values where p.promotedToMod {
            flags.insert(p.flag)
        }
        activeMods = flags
    }

    private func applyTabSwapIfNeeded(keyCode: CGKeyCode, flags: CGEventFlags) -> CGEventFlags {
        guard swapCmdCtrlTab && keyCode == 48 else { return flags }
        let hasCmd = flags.contains(.maskCommand)
        let hasCtrl = flags.contains(.maskControl)
        guard hasCmd != hasCtrl else { return flags }
        var result = flags
        if hasCmd {
            result.remove(.maskCommand)
            result.insert(.maskControl)
        } else {
            result.remove(.maskControl)
            result.insert(.maskCommand)
        }
        return result
    }

    private func syncCapsLockMapping() {
        setHidutilCapsLock(enabled: isEnabled && capsLockToBackspace, synchronous: false)
    }

    private func setHidutilCapsLock(enabled: Bool, synchronous: Bool = false) {
        // 0x700000039 (caps) -> 0x70000002A (backspace)
        let json = enabled
            ? "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771114}]}"
            : "{\"UserKeyMapping\":[]}"
        let runTask = {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
            task.arguments = ["property", "--set", json]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                if synchronous {
                    task.waitUntilExit()
                }
            } catch {}
        }
        if synchronous {
            runTask()
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: runTask)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func resetDefaults() {
        tappingTermMs = 200
        priorIdleMs = 250
        quickTapMs = 175
        oppositeHandOnly = true
        pinkyRingGrace = true
        bothShiftsToggle = true
        homeRowModsEnabled = true
        capsLockToBackspace = true
        navLayerEnabled = false
        swapCmdCtrlTab = true
        keyMods = [
            0: .control, 1: .option, 2: .command, 3: .shift,
            38: .shift, 40: .command, 37: .option, 41: .control
        ]
    }

    func startCalibration() {
        clearActiveState()
        calibrationInput = ""
        calibKeyDownTimes.removeAll()
        calibTapDurationsMs.removeAll()
        calibRollGapsMs.removeAll()
        calibLastKeyUpTime = 0
        sampleCount = 0
        recommendedTapMs = nil
        recommendedIdleMs = nil
        isCalibrating = true
    }

    func finishCalibration(apply: Bool) {
        isCalibrating = false
        if apply, let tap = recommendedTapMs, let idle = recommendedIdleMs {
            tappingTermMs = tap
            priorIdleMs = idle
            quickTapMs = max(120, min(220, tap - 25))
        }
    }

    private func recordCalibration(type: CGEventType, keyCode: CGKeyCode, now: CFAbsoluteTime) {
        if type == .keyDown {
            calibKeyDownTimes[keyCode] = now
            if calibLastKeyUpTime > 0 {
                let gap = (now - calibLastKeyUpTime) * 1000.0
                if gap > 10 && gap < 500 {
                    calibRollGapsMs.append(gap)
                }
            }
        } else if type == .keyUp, let down = calibKeyDownTimes.removeValue(forKey: keyCode) {
            let dur = (now - down) * 1000.0
            if dur > 20 && dur < 400 {
                calibTapDurationsMs.append(dur)
                calibLastKeyUpTime = now
                updateRecommendations()
            }
        }
    }

    private func updateRecommendations() {
        let count = calibTapDurationsMs.count
        guard count >= 8 else {
            DispatchQueue.main.async { self.sampleCount = count }
            return
        }
        let sortedTaps = calibTapDurationsMs.sorted()
        let p95Index = min(sortedTaps.count - 1, Int(Double(sortedTaps.count) * 0.95))
        let p95Tap = sortedTaps[p95Index]
        let recTap = (min(300, max(150, p95Tap + 55)) / 5.0).rounded() * 5.0

        var recIdle = 240.0
        if !calibRollGapsMs.isEmpty {
            let sortedGaps = calibRollGapsMs.sorted()
            let p85Index = min(sortedGaps.count - 1, Int(Double(sortedGaps.count) * 0.85))
            let p85Gap = sortedGaps[p85Index]
            recIdle = (min(350, max(140, p85Gap + 60)) / 5.0).rounded() * 5.0
        }

        DispatchQueue.main.async {
            self.sampleCount = count
            self.recommendedTapMs = recTap
            self.recommendedIdleMs = recIdle
        }
    }

    @discardableResult
    func checkAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasAccessibility = trusted
            if trusted {
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                if self.eventTap == nil {
                    self.startTap()
                }
            } else if self.permissionTimer == nil {
                self.permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                    self?.checkAccessibility(prompt: false)
                }
            }
        }
        return trusted
    }

    func startTap() {
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<HomeRowEngine>.fromOpaque(refcon).takeUnretainedValue()
                return engine.handleEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func emitKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .privateState),
              let ev = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { return }
        ev.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        ev.flags = applyTabSwapIfNeeded(keyCode: keyCode, flags: flags)
        ev.post(tap: .cgSessionEventTap)
    }

    private func flushPendingKeysAsTaps(_ keys: [CGKeyCode], now: CFAbsoluteTime, alsoFlushBuffered: Bool) {
        let sortedKeys = keys
            .compactMap { pending[$0] }
            .sorted { $0.downTime < $1.downTime }
            .map(\.keyCode)
        for pKey in sortedKeys {
            guard let p = pending.removeValue(forKey: pKey) else { continue }
            p.timer?.cancel()
            lastTapReleaseTime[pKey] = now
            lastNonModKeyTime = now
            flashTappedSlot(pKey)
            emitKey(pKey, down: true, flags: activeMods)
            emitKey(pKey, down: false, flags: activeMods)
        }
        syncLiveUIState()
        if alsoFlushBuffered && !bufferedKeys.isEmpty {
            let bufs = bufferedKeys
            bufferedKeys.removeAll()
            for buf in bufs {
                lastNonModKeyTime = now
                synthesizedDownKeys.insert(buf.keyCode)
                emitKey(buf.keyCode, down: true, flags: buf.flags.union(activeMods))
            }
        }
    }

    private func promotePendingKeys(_ keys: [CGKeyCode], flushBuffered: Bool) {
        var changed = false
        for pKey in keys {
            guard var p = pending[pKey], !p.promotedToMod else { continue }
            p.timer?.cancel()
            p.timer = nil
            p.promotedToMod = true
            pending[pKey] = p
            changed = true
        }
        if changed {
            recomputeActiveMods()
        }
        syncLiveUIState()
        if flushBuffered && !bufferedKeys.isEmpty {
            let bufs = bufferedKeys
            bufferedKeys.removeAll()
            for buf in bufs {
                synthesizedDownKeys.insert(buf.keyCode)
                emitKey(buf.keyCode, down: true, flags: buf.flags.union(activeMods))
            }
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == syntheticTag {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let now = CFAbsoluteTimeGetCurrent()
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if isCalibrating {
            if (type == .keyDown || type == .keyUp) && !isRepeat {
                recordCalibration(type: type, keyCode: keyCode, now: now)
            }
            return Unmanaged.passUnretained(event)
        }

        if bothShiftsToggle && type == .flagsChanged && (keyCode == 56 || keyCode == 60) {
            let leftDown = (event.flags.rawValue & 0x2) != 0
            let rightDown = (event.flags.rawValue & 0x4) != 0
            if leftDown && rightDown && !bothShiftsConsumed {
                bothShiftsConsumed = true
                isEnabled.toggle()
            } else if !leftDown && !rightDown {
                bothShiftsConsumed = false
            }
        }

        guard isEnabled else { return Unmanaged.passUnretained(event) }

        if type == .flagsChanged && keyCode == 55 {
            leftCmdDown = event.flags.contains(.maskCommand)
            if !leftCmdDown { lastNavKey = nil }
            syncLiveUIState()
            if navLayerEnabled { return nil }
            return Unmanaged.passUnretained(event)
        }

        if navLayerEnabled && leftCmdDown && (type == .keyDown || type == .keyUp) {
            if let mapped = navMap[keyCode] {
                lastNavKey = (type == .keyDown) ? keyCode : nil
                var f = event.flags
                f.remove(.maskCommand)
                f.formUnion(mapped.mods)
                f.formUnion(activeMods)
                emitKey(mapped.key, down: type == .keyDown, flags: f)
                return nil
            } else {
                lastNavKey = nil
                var f = event.flags
                f.insert(.maskCommand)
                f.formUnion(activeMods)
                emitKey(keyCode, down: type == .keyDown, flags: f)
                return nil
            }
        }

        guard homeRowModsEnabled, (type == .keyDown || type == .keyUp) else {
            if type == .keyDown || type == .keyUp {
                event.flags = applyTabSwapIfNeeded(keyCode: keyCode, flags: event.flags.union(activeMods))
            }
            return Unmanaged.passUnretained(event)
        }

        let priorIdleSec = priorIdleMs / 1000.0
        let quickTapSec = quickTapMs / 1000.0

        if type == .keyUp && pending[keyCode] == nil {
            if bufferedKeys.contains(where: { $0.keyCode == keyCode }) {
                let eligible = pending.values.filter { !$0.promotedToMod && canModify(keyCode, with: $0.isLeft) }
                if !eligible.isEmpty && eligible.contains(where: { !$0.withinPriorIdle || (now - $0.downTime >= slotTappingSec(for: $0.keyCode)) }) {
                    promotePendingKeys(eligible.map(\.keyCode), flushBuffered: true)
                } else {
                    let allUnpromoted = pending.values.filter { !$0.promotedToMod }.map(\.keyCode)
                    flushPendingKeysAsTaps(allUnpromoted, now: now, alsoFlushBuffered: true)
                }
            }
            if synthesizedDownKeys.remove(keyCode) != nil {
                emitKey(keyCode, down: false, flags: event.flags.union(activeMods))
                return nil
            }
            event.flags = applyTabSwapIfNeeded(keyCode: keyCode, flags: event.flags.union(activeMods))
            return Unmanaged.passUnretained(event)
        }

        if let slot = Self.slots.first(where: { $0.keyCode == keyCode }),
           let modFlag = keyMods[keyCode]?.flag {
            if type == .keyDown {
                if isRepeat {
                    if pending[keyCode] != nil || synthesizedDownKeys.contains(keyCode) || bufferedKeys.contains(where: { $0.keyCode == keyCode }) {
                        return nil
                    }
                    event.flags = event.flags.union(activeMods)
                    return Unmanaged.passUnretained(event)
                }

                let promoted = pending.values.filter { $0.promotedToMod }
                if !promoted.isEmpty && promoted.allSatisfy({ $0.isLeft == slot.isLeft }) {
                    pending[keyCode] = PendingKey(
                        keyCode: keyCode,
                        downTime: now,
                        flag: modFlag,
                        isLeft: slot.isLeft,
                        withinPriorIdle: false,
                        promotedToMod: true,
                        timer: nil
                    )
                    recomputeActiveMods()
                    syncLiveUIState()
                    return nil
                }

                let oppositeUnpromoted = pending.values.filter { !$0.promotedToMod && $0.keyCode != keyCode && canModify(keyCode, with: $0.isLeft) }
                if !oppositeUnpromoted.isEmpty {
                    if oppositeUnpromoted.contains(where: { now - $0.downTime >= slotTappingSec(for: $0.keyCode) }) {
                        promotePendingKeys(oppositeUnpromoted.map(\.keyCode), flushBuffered: true)
                        synthesizedDownKeys.insert(keyCode)
                        emitKey(keyCode, down: true, flags: event.flags.union(activeMods))
                        return nil
                    } else {
                        bufferedKeys.append((keyCode: keyCode, flags: event.flags))
                        return nil
                    }
                }

                if !activeMods.isEmpty {
                    synthesizedDownKeys.insert(keyCode)
                    emitKey(keyCode, down: true, flags: event.flags.union(activeMods))
                    return nil
                }

                if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
                    flashTappedSlot(keyCode)
                    return Unmanaged.passUnretained(event)
                }

                let sameHandUnpromoted = pending.values.filter { !$0.promotedToMod && $0.isLeft == slot.isLeft }
                let sinceSame = now - (lastTapReleaseTime[keyCode] ?? 0)
                if sameHandUnpromoted.isEmpty && sinceSame < quickTapSec {
                    lastNonModKeyTime = now
                    flashTappedSlot(keyCode)
                    event.flags = event.flags.union(activeMods)
                    return Unmanaged.passUnretained(event)
                }

                let slotSec = slotTappingSec(for: keyCode)
                let withinIdle = (now - lastNonModKeyTime) < priorIdleSec
                var item = PendingKey(
                    keyCode: keyCode,
                    downTime: now,
                    flag: modFlag,
                    isLeft: slot.isLeft,
                    withinPriorIdle: withinIdle
                )
                let work = DispatchWorkItem { [weak self] in
                    guard let self, var cur = self.pending[keyCode], !cur.promotedToMod else { return }
                    if let firstBuf = self.bufferedKeys.first {
                        let toPromote = self.pending.values
                            .filter { !$0.promotedToMod && self.canModify(firstBuf.keyCode, with: $0.isLeft) }
                            .map(\.keyCode)
                        if !toPromote.isEmpty {
                            self.promotePendingKeys(toPromote, flushBuffered: true)
                            return
                        }
                    }
                    if !self.oppositeHandOnly {
                        self.promotePendingKeys([keyCode], flushBuffered: true)
                    } else {
                        cur.withinPriorIdle = false
                        self.pending[keyCode] = cur
                    }
                }
                item.timer = work
                pending[keyCode] = item
                syncLiveUIState()
                DispatchQueue.main.asyncAfter(deadline: .now() + slotSec, execute: work)
                return nil
            } else {
                if let p = pending[keyCode] {
                    let slotSec = slotTappingSec(for: keyCode)
                    p.timer?.cancel()
                    if p.promotedToMod {
                        pending.removeValue(forKey: keyCode)
                        recomputeActiveMods()
                        syncLiveUIState()
                    } else if let firstBuf = bufferedKeys.first,
                              (now - p.downTime >= slotSec),
                              canModify(firstBuf.keyCode, with: p.isLeft) {
                        let toPromote = pending.values
                            .filter { !$0.promotedToMod && canModify(firstBuf.keyCode, with: $0.isLeft) }
                            .map(\.keyCode)
                        promotePendingKeys(toPromote, flushBuffered: true)
                        pending.removeValue(forKey: keyCode)
                        recomputeActiveMods()
                        syncLiveUIState()
                    } else if (now - p.downTime >= slotSec) && bufferedKeys.isEmpty {
                        pending.removeValue(forKey: keyCode)
                        syncLiveUIState()
                    } else {
                        let toFlush = pending.values
                            .filter { !$0.promotedToMod && $0.isLeft == p.isLeft && $0.downTime <= p.downTime }
                            .map(\.keyCode)
                        let remainingUnpromoted = pending.values.filter { !$0.promotedToMod && !toFlush.contains($0.keyCode) }
                        flushPendingKeysAsTaps(toFlush, now: now, alsoFlushBuffered: remainingUnpromoted.isEmpty)
                    }
                    return nil
                }
                if synthesizedDownKeys.remove(keyCode) != nil {
                    emitKey(keyCode, down: false, flags: event.flags.union(activeMods))
                    return nil
                }
                event.flags = applyTabSwapIfNeeded(keyCode: keyCode, flags: event.flags.union(activeMods))
                return Unmanaged.passUnretained(event)
            }
        }

        if type == .keyDown && !isRepeat {
            lastNonModKeyTime = now
            var eligible: [CGKeyCode] = []
            var ineligible: [CGKeyCode] = []
            for pVal in pending.values where !pVal.promotedToMod {
                if keyCode == 51 {
                    if (now - pVal.downTime >= slotTappingSec(for: pVal.keyCode)) || !pVal.withinPriorIdle {
                        eligible.append(pVal.keyCode)
                    } else {
                        ineligible.append(pVal.keyCode)
                    }
                } else if canModify(keyCode, with: pVal.isLeft) {
                    eligible.append(pVal.keyCode)
                } else {
                    ineligible.append(pVal.keyCode)
                }
            }

            var flushedBeforeKey = false
            if !ineligible.isEmpty {
                flushPendingKeysAsTaps(ineligible, now: now, alsoFlushBuffered: false)
                flushedBeforeKey = true
            }

            if !eligible.isEmpty {
                if eligible.contains(where: {
                    guard let p = pending[$0] else { return false }
                    return now - p.downTime >= slotTappingSec(for: $0)
                }) {
                    promotePendingKeys(eligible, flushBuffered: true)
                } else {
                    bufferedKeys.append((keyCode: keyCode, flags: event.flags))
                    return nil
                }
            }

            if flushedBeforeKey || !activeMods.isEmpty {
                synthesizedDownKeys.insert(keyCode)
                emitKey(keyCode, down: true, flags: event.flags.union(activeMods))
                return nil
            }
        }

        event.flags = applyTabSwapIfNeeded(keyCode: keyCode, flags: event.flags.union(activeMods))
        return Unmanaged.passUnretained(event)
    }
}
