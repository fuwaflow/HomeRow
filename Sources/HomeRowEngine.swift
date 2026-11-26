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
    var id: CGKeyCode { keyCode }
}

final class HomeRowEngine: ObservableObject {
    static let slots: [HomeRowSlot] = [
        HomeRowSlot(keyCode: 0,  label: "Left Pinky (A)",  isLeft: true),
        HomeRowSlot(keyCode: 1,  label: "Left Ring (S/R)", isLeft: true),
        HomeRowSlot(keyCode: 2,  label: "Left Mid (D/S)",  isLeft: true),
        HomeRowSlot(keyCode: 3,  label: "Left Index (F/T)",isLeft: true),
        HomeRowSlot(keyCode: 38, label: "Right Index (J/N)",isLeft: false),
        HomeRowSlot(keyCode: 40, label: "Right Mid (K/E)", isLeft: false),
        HomeRowSlot(keyCode: 37, label: "Right Ring (L/I)",isLeft: false),
        HomeRowSlot(keyCode: 41, label: "Right Pinky (;/O)",isLeft: false),
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

    private var calibKeyDownTimes: [CGKeyCode: CFAbsoluteTime] = [:]
    private var calibTapDurationsMs: [Double] = []
    private var calibLastKeyUpTime: CFAbsoluteTime = 0
    private var calibRollGapsMs: [Double] = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var willTerminateObserver: NSObjectProtocol?

    private let leftHandKeys: Set<CGKeyCode> = [
        12, 13, 14, 15, 17,
        0, 1, 2, 3, 5,
        50, 6, 7, 8, 9, 11
    ]
    private let rightHandKeys: Set<CGKeyCode> = [
        16, 32, 34, 31, 35, 33, 30,
        4, 38, 40, 37, 41, 39, 42,
        45, 46, 43, 47, 44
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
        var bufferedDowns: [(keyCode: CGKeyCode, flags: CGEventFlags)] = []
        var timer: DispatchWorkItem? = nil
    }

    private var pending: [CGKeyCode: PendingKey] = [:]
    private var activeMods: CGEventFlags = []
    private var synthesizedDownKeys: Set<CGKeyCode> = []
    private var lastNonModKeyTime: CFAbsoluteTime = 0
    private var lastTapReleaseTime: [CGKeyCode: CFAbsoluteTime] = [:]
    private var leftCmdDown: Bool = false
    private let syntheticTag: Int64 = 0x48524D31

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "isEnabled") != nil { isEnabled = d.bool(forKey: "isEnabled") }
        if d.object(forKey: "homeRowModsEnabled") != nil { homeRowModsEnabled = d.bool(forKey: "homeRowModsEnabled") }
        if d.object(forKey: "capsLockToBackspace") != nil { capsLockToBackspace = d.bool(forKey: "capsLockToBackspace") }
        if d.object(forKey: "navLayerEnabled") != nil { navLayerEnabled = d.bool(forKey: "navLayerEnabled") }
        if d.object(forKey: "swapCmdCtrlTab") != nil { swapCmdCtrlTab = d.bool(forKey: "swapCmdCtrlTab") }
        if d.object(forKey: "oppositeHandOnly") != nil { oppositeHandOnly = d.bool(forKey: "oppositeHandOnly") }
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
        synthesizedDownKeys.removeAll()
        leftCmdDown = false
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
        ev.flags = flags
        ev.post(tap: .cgSessionEventTap)
    }

    private func flushPendingAsTap(_ pKey: CGKeyCode, now: CFAbsoluteTime) {
        guard let p = pending.removeValue(forKey: pKey) else { return }
        p.timer?.cancel()
        lastTapReleaseTime[pKey] = now
        lastNonModKeyTime = now
        emitKey(pKey, down: true, flags: activeMods)
        emitKey(pKey, down: false, flags: activeMods)
        for buf in p.bufferedDowns {
            lastNonModKeyTime = now
            synthesizedDownKeys.insert(buf.keyCode)
            emitKey(buf.keyCode, down: true, flags: buf.flags.union(activeMods))
        }
    }

    private func promotePendingToMod(_ pKey: CGKeyCode) {
        guard var p = pending[pKey], !p.promotedToMod else { return }
        p.timer?.cancel()
        p.promotedToMod = true
        let bufs = p.bufferedDowns
        p.bufferedDowns.removeAll()
        pending[pKey] = p
        activeMods.insert(p.flag)
        for buf in bufs {
            synthesizedDownKeys.insert(buf.keyCode)
            emitKey(buf.keyCode, down: true, flags: buf.flags.union(activeMods))
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

        guard isEnabled else { return Unmanaged.passUnretained(event) }

        if type == .flagsChanged && keyCode == 55 {
            leftCmdDown = event.flags.contains(.maskCommand)
            if navLayerEnabled { return nil }
            return Unmanaged.passUnretained(event)
        }

        if navLayerEnabled && leftCmdDown && (type == .keyDown || type == .keyUp) {
            if let mapped = navMap[keyCode] {
                var f = event.flags
                f.remove(.maskCommand)
                f.formUnion(mapped.mods)
                f.formUnion(activeMods)
                emitKey(mapped.key, down: type == .keyDown, flags: f)
                return nil
            }
        }

        if swapCmdCtrlTab && keyCode == 48 && (type == .keyDown || type == .keyUp) {
            var flags = event.flags.union(activeMods)
            let hasCmd = flags.contains(.maskCommand)
            let hasCtrl = flags.contains(.maskControl)
            if hasCmd != hasCtrl {
                if hasCmd {
                    flags.remove(.maskCommand)
                    flags.insert(.maskControl)
                } else {
                    flags.remove(.maskControl)
                    flags.insert(.maskCommand)
                }
                event.flags = flags
                return Unmanaged.passUnretained(event)
            }
        }

        guard homeRowModsEnabled, (type == .keyDown || type == .keyUp) else {
            return Unmanaged.passUnretained(event)
        }

        let tappingSec = tappingTermMs / 1000.0
        let priorIdleSec = priorIdleMs / 1000.0
        let quickTapSec = quickTapMs / 1000.0

        if type == .keyUp && pending[keyCode] == nil {
            for (pKey, pVal) in pending where !pVal.promotedToMod {
                if pVal.bufferedDowns.contains(where: { $0.keyCode == keyCode }) {
                    if !pVal.withinPriorIdle || (now - pVal.downTime >= tappingSec) {
                        promotePendingToMod(pKey)
                    } else {
                        flushPendingAsTap(pKey, now: now)
                    }
                }
            }
            if synthesizedDownKeys.remove(keyCode) != nil {
                emitKey(keyCode, down: false, flags: event.flags.union(activeMods))
                return nil
            }
            event.flags = event.flags.union(activeMods)
            return Unmanaged.passUnretained(event)
        }

        if let slot = Self.slots.first(where: { $0.keyCode == keyCode }),
           let modFlag = keyMods[keyCode]?.flag {
            if type == .keyDown {
                if isRepeat {
                    if pending[keyCode] != nil || synthesizedDownKeys.contains(keyCode) { return nil }
                    event.flags = event.flags.union(activeMods)
                    return Unmanaged.passUnretained(event)
                }

                var wasBuffered = false
                for (pKey, var pVal) in pending where pKey != keyCode && !pVal.promotedToMod {
                    let opposite = pVal.isLeft ? rightHandKeys.contains(keyCode) : leftHandKeys.contains(keyCode)
                    if opposite || !oppositeHandOnly {
                        if now - pVal.downTime >= tappingSec {
                            promotePendingToMod(pKey)
                        } else {
                            pVal.bufferedDowns.append((keyCode: keyCode, flags: event.flags))
                            pending[pKey] = pVal
                            wasBuffered = true
                        }
                    } else {
                        flushPendingAsTap(pKey, now: now)
                    }
                }
                if wasBuffered { return nil }

                if !activeMods.isEmpty {
                    synthesizedDownKeys.insert(keyCode)
                    emitKey(keyCode, down: true, flags: event.flags.union(activeMods))
                    return nil
                }

                if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
                    return Unmanaged.passUnretained(event)
                }

                let sinceSame = now - (lastTapReleaseTime[keyCode] ?? 0)
                if sinceSame < quickTapSec {
                    lastNonModKeyTime = now
                    event.flags = event.flags.union(activeMods)
                    return Unmanaged.passUnretained(event)
                }

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
                    if !self.oppositeHandOnly || !cur.bufferedDowns.isEmpty {
                        self.promotePendingToMod(keyCode)
                    } else {
                        cur.withinPriorIdle = false
                        self.pending[keyCode] = cur
                    }
                }
                item.timer = work
                pending[keyCode] = item
                DispatchQueue.main.asyncAfter(deadline: .now() + tappingSec, execute: work)
                return nil
            } else {
                if let p = pending[keyCode] {
                    p.timer?.cancel()
                    if p.promotedToMod {
                        pending.removeValue(forKey: keyCode)
                        activeMods.remove(p.flag)
                    } else if !p.bufferedDowns.isEmpty && (now - p.downTime >= tappingSec) {
                        promotePendingToMod(keyCode)
                        pending.removeValue(forKey: keyCode)
                        activeMods.remove(p.flag)
                    } else {
                        flushPendingAsTap(keyCode, now: now)
                    }
                    return nil
                }
                if synthesizedDownKeys.remove(keyCode) != nil {
                    emitKey(keyCode, down: false, flags: event.flags.union(activeMods))
                    return nil
                }
                event.flags = event.flags.union(activeMods)
                return Unmanaged.passUnretained(event)
            }
        }

        if type == .keyDown && !isRepeat {
            lastNonModKeyTime = now
            var wasBuffered = false
            var flushedBeforeKey = false
            for (pKey, var pVal) in pending where !pVal.promotedToMod {
                let opposite = pVal.isLeft ? rightHandKeys.contains(keyCode) : leftHandKeys.contains(keyCode)
                if (opposite || !oppositeHandOnly) && keyCode != 51 {
                    if now - pVal.downTime >= tappingSec {
                        promotePendingToMod(pKey)
                    } else {
                        pVal.bufferedDowns.append((keyCode: keyCode, flags: event.flags))
                        pending[pKey] = pVal
                        wasBuffered = true
                    }
                } else {
                    flushPendingAsTap(pKey, now: now)
                    flushedBeforeKey = true
                }
            }
            if wasBuffered { return nil }
            if flushedBeforeKey || !activeMods.isEmpty {
                synthesizedDownKeys.insert(keyCode)
                emitKey(keyCode, down: true, flags: event.flags.union(activeMods))
                return nil
            }
        }

        if !activeMods.isEmpty {
            event.flags = event.flags.union(activeMods)
        }
        return Unmanaged.passUnretained(event)
    }
}
