import AppKit
import WebKit
import AVFoundation
import CoreAudio
import CoreGraphics
import IOKit

// MARK: - Helpers

/// Runs AppleScript via osascript with a timeout. Returns nil on error (e.g. Automation permission denied).
@MainActor func osa(_ script: String, timeout: Double = 15) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    guard (try? p.run()) != nil else { return nil }
    let end = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    if p.isRunning { p.terminate(); return nil }
    guard p.terminationStatus == 0 else {
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("      · osascript error: \(e.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))")
        return nil
    }
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct WindowInfo { let id: Int; let layer: Int; let bounds: CGRect; let alpha: Double }

func windows(pid: pid_t) -> [WindowInfo] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { return nil }
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return WindowInfo(id: w[kCGWindowNumber as String] as? Int ?? 0, layer: w[kCGWindowLayer as String] as? Int ?? 0,
                          bounds: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0),
                          alpha: w[kCGWindowAlpha as String] as? Double ?? 1)
    }
}

@discardableResult
func capture(windowID: Int, name: String) -> URL {
    let url = T.artifacts.appendingPathComponent("\(name).png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(windowID)", url.path]
    try? p.run()
    p.waitUntilExit()
    return url
}

func click(at point: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(50_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(30_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

/// Reads mute and per-element input volume for every input device.
func micState() -> [AudioDeviceID: [Float]] {
    var out: [AudioDeviceID: [Float]] = [:]
    for id in MicMuter.inputDevices() {
        var vals: [Float] = []
        var m = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &m) {
            var v: UInt32 = 0, s = UInt32(4)
            AudioObjectGetPropertyData(id, &m, 0, nil, &s, &v)
            vals.append(Float(v) * 100)  // tagged so mute and volume can't be confused
        }
        for el in 0...8 {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput, mElement: AudioObjectPropertyElement(el))
            guard AudioObjectHasProperty(id, &a) else { continue }
            var v: Float32 = 0, s = UInt32(4)
            AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v)
            vals.append(v)
        }
        out[id] = vals
    }
    return out
}

/// Catches (and swallows) events carrying our marker, so synthesised keys can be checked without side effects.
final class EventCatcher {
    struct Caught {
        let type: UInt32; let key: Int64; let flags: CGEventFlags; let data1: Int
        var location = CGPoint.zero, pixels: Int64 = 0, lines: Int64 = 0, continuous: Int64 = 0
    }
    var caught: [Caught] = []
    let marker: Int64
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init?(marker: Int64) {
        self.marker = marker
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(1 << 14)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, user in
            let me = Unmanaged<EventCatcher>.fromOpaque(user!).takeUnretainedValue()
            guard event.getIntegerValueField(.eventSourceUserData) == me.marker else { return Unmanaged.passUnretained(event) }
            let data1 = type.rawValue == 14 ? (NSEvent(cgEvent: event)?.data1 ?? 0) : 0
            me.caught.append(Caught(type: type.rawValue, key: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags, data1: data1,
                                    location: event.location,
                                    pixels: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                                    lines: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                                    continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous)))
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}

// MARK: - Hardware

@MainActor
func hardwareTests() {
    T.suite = "Hardware"
    print("\n▶ Hardware (live sensors, microphones, camera)")

    let reader = IMUReader()
    var counts = ["accel": 0, "gyro": 0]
    var lastAccel = SIMD3<Double>.zero, maxGyro = 0.0
    let lock = NSLock()
    reader.onSample = { kind, _, v in
        lock.withLock {
            if kind == .accel { counts["accel", default: 0] += 1; lastAccel = v } else {
                counts["gyro", default: 0] += 1; maxGyro = max(maxGyro, (v * v).sum().squareRoot())
            }
        }
    }

    T.run("motion sensor streams accel + gyro at ~800 Hz with sane values") {
        reader.start()
        T.sleep(3)
        let c = lock.withLock { counts }
        let g = lock.withLock { (lastAccel * lastAccel).sum().squareRoot() }
        T.note("3 s: accel \(c["accel"]!), gyro \(c["gyro"]!) samples; |accel| \(String(format: "%.3f", g)) g; lid \(reader.lidAngle.map(String.init) ?? "-")°; found accel \(reader.foundAccel) gyro \(reader.foundGyro) lid \(reader.foundLid)")
        T.expect(reader.error == nil, "sensor error: \(reader.error ?? "")")
        T.expect(c["accel"]! > 2100 && c["gyro"]! > 2100, "rates too low: \(c)")
        T.expect(abs(g - 1) < 0.15, "accelerometer magnitude \(g) g, expected ~1 g (gravity)")
        T.expect(reader.lidAngle.map { $0 > 10 && $0 < 200 } ?? false, "lid angle \(String(describing: reader.lidAngle))")
    }

    T.run("sensor reopen keeps data flowing") {
        let before = lock.withLock { counts["gyro"]! }
        reader.requestReopen()
        T.expect(T.wait(2) { reader.reopenCount == 1 }, "reopen did not run")
        T.sleep(1.5)
        let after = lock.withLock { counts["gyro"]! }
        T.note("gyro samples in the 1.5 s after reopen: \(after - before)")
        T.expect(after - before > 900, "data did not resume after reopen")
        T.expect(reader.error == nil, "error after reopen: \(reader.error ?? "")")
    }

    T.run("watchdog reopens the sensor by itself after a data gap") {
        let before = reader.reopenCount
        reader.simulateStall()
        T.expect(T.wait(2) { reader.reopenCount == before + 1 }, "watchdog did not fire (reopens \(reader.reopenCount))")
        let start = lock.withLock { counts["gyro"]! }
        T.sleep(1)
        T.expect(lock.withLock { counts["gyro"]! } - start > 600, "no data after watchdog reopen")
    }

    T.run("watchdog revives the sensor after it is powered down") {
        // Power the sensor down the way sleep would, then expect the watchdog to bring it back.
        var it: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it)
        var drivers: [io_service_t] = []
        while case let s = IOIteratorNext(it), s != 0 { drivers.append(s) }
        IOObjectRelease(it)
        for d in drivers { IORegistryEntrySetCFProperty(d, "SensorPropertyReportingState" as CFString, NSNumber(value: 0)) }
        let start = lock.withLock { counts["gyro"]! }
        T.sleep(1.5)
        let stalled = lock.withLock { counts["gyro"]! } - start
        T.note("gyro samples in 1.5 s after power-down: \(stalled)")
        if stalled > 600 {
            for d in drivers { IOObjectRelease(d) }
            throw T.Skip(reason: "powering the sensor down from another process doesn't stop it (watchdog path not reachable this way)")
        }
        let revived = T.wait(10) { reader.reopenCount >= 2 }
        T.sleep(1.5)
        let mid = lock.withLock { counts["gyro"]! }
        T.sleep(1)
        let rate = lock.withLock { counts["gyro"]! } - mid
        T.note("watchdog reopened: \(revived); gyro rate after: \(rate) Hz")
        for d in drivers { IORegistryEntrySetCFProperty(d, "SensorPropertyReportingState" as CFString, NSNumber(value: 1)); IOObjectRelease(d) }
        T.expect(revived && rate > 600, "sensor not revived (reopened \(revived), rate \(rate))")
    }

    T.run("microphones: at least one input can be muted") {
        let ids = MicMuter.inputDevices()
        T.expect(!ids.isEmpty, "no input devices")
        let state = micState()
        T.note("input devices: \(ids.count), controllable values: \(state.values.map(\.count))")
        T.expect(state.values.contains { !$0.isEmpty }, "no mutable input")
    }

    T.run("camera-in-use check reads idle") {
        T.expect(!Cameras.anyRunning(), "a camera reports running while idle (another app may be using it)")
    }

    T.run("system input timing is readable") {
        let s = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        T.expect(s.isFinite && s >= 0, "secondsSinceLastEventType = \(s)")
    }
}

// MARK: - Actions

@MainActor
func actionTests() {
    T.suite = "Actions"
    print("\n▶ Actions (real system)")
    guard Permissions.accessibility else {
        T.run("accessibility") { throw T.Skip(reason: "this process has no Accessibility permission") }
        return
    }
    let guardStub = PrivacyGuard(presentsOverlay: false)

    T.run("every action posts the right key events (caught and swallowed)") {
        guard let catcher = EventCatcher(marker: 0x11DA7A9) else { throw T.Skip(reason: "could not create an event tap") }
        defer { catcher.stop(); KeySender.eventMarker = 0 }
        KeySender.eventMarker = catcher.marker
        let cases: [(String, () -> Void, (EventCatcher.Caught) -> Bool)] = [
            ("Desktop Left = ⌃←", { _ = ActionRunner.perform(ZoneAction(kind: .desktopLeft), guardController: guardStub) },
             { $0.type == 10 && $0.key == 123 && $0.flags.contains(.maskControl) && !$0.flags.contains(.maskCommand) }),
            ("Desktop Right = ⌃→", { _ = ActionRunner.perform(ZoneAction(kind: .desktopRight), guardController: guardStub) },
             { $0.type == 10 && $0.key == 124 && $0.flags.contains(.maskControl) }),
            ("Play/Pause media key", { _ = ActionRunner.perform(ZoneAction(kind: .playPause), guardController: guardStub) },
             { $0.type == 14 && ($0.data1 >> 16) == 16 && (($0.data1 >> 8) & 0xFF) == 0xA }),
            ("Next media key", { _ = ActionRunner.perform(ZoneAction(kind: .nextTrack), guardController: guardStub) },
             { $0.type == 14 && ($0.data1 >> 16) == 17 }),
            ("Previous media key", { _ = ActionRunner.perform(ZoneAction(kind: .previousTrack), guardController: guardStub) },
             { $0.type == 14 && ($0.data1 >> 16) == 18 }),
            ("Zoom camera = ⌘⇧V", { KeySender.press(.v, flags: [.maskCommand, .maskShift]) },
             { $0.type == 10 && $0.key == 9 && $0.flags.contains([.maskCommand, .maskShift]) }),
            ("Teams camera = ⌘⇧O", { KeySender.press(.o, flags: [.maskCommand, .maskShift]) },
             { $0.type == 10 && $0.key == 31 && $0.flags.contains([.maskCommand, .maskShift]) }),
            ("Meet camera = ⌘E", { KeySender.press(.e, flags: .maskCommand) },
             { $0.type == 10 && $0.key == 14 && $0.flags.contains(.maskCommand) && !$0.flags.contains(.maskShift) }),
        ]
        for (name, fire, check) in cases {
            catcher.caught.removeAll()
            fire()
            T.wait(1) { catcher.caught.count >= 2 }
            let downs = catcher.caught.filter { $0.type == 10 || ($0.type == 14 && (($0.data1 >> 8) & 0xFF) == 0xA) }
            T.expect(catcher.caught.count == 2, "\(name): caught \(catcher.caught.count) events (want down+up)")
            T.expect(downs.count == 1 && check(downs[0]), "\(name): wrong event \(catcher.caught.map { "type \($0.type) key \($0.key) flags \($0.flags.rawValue) data1 \(String($0.data1, radix: 16))" })")
            if !catcher.caught.isEmpty { T.note("\(name) ✓") }
        }
    }

    T.run("Desktop Left/Right really switch Spaces (and come back)") {
        // Read the active Space from the window server (Space-change notifications don't reach a CLI process).
        typealias GetConn = @convention(c) () -> Int32
        typealias GetSpace = @convention(c) (Int32) -> UInt64
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let c = dlsym(h, "SLSMainConnectionID"), let g = dlsym(h, "SLSGetActiveSpace") else {
            throw T.Skip(reason: "cannot read the active Space")
        }
        let conn = unsafeBitCast(c, to: GetConn.self)()
        let space = { unsafeBitCast(g, to: GetSpace.self)(conn) }
        let start = space()
        _ = ActionRunner.perform(ZoneAction(kind: .desktopRight), guardController: guardStub)
        let movedRight = T.wait(2.5) { space() != start }
        T.sleep(0.6)
        let afterRight = space()
        _ = ActionRunner.perform(ZoneAction(kind: .desktopLeft), guardController: guardStub)
        let movedLeft = T.wait(2.5) { space() != afterRight }
        T.sleep(0.6)
        if !movedRight && movedLeft {  // started on the right-most Space: return
            _ = ActionRunner.perform(ZoneAction(kind: .desktopRight), guardController: guardStub)
            T.wait(2.5) { space() == start }
        }
        T.note("Spaces: start \(start), after right \(afterRight), after left \(space())")
        T.expect(movedRight || movedLeft, "no Space change after ⌃→ and ⌃←")
        T.expect(space() == start, "did not return to the starting Space")
    }

    T.run("Play/Pause really toggles Spotify, then restores") {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first != nil else {
            throw T.Skip(reason: "Spotify not running")
        }
        guard let before = osa(#"tell application id "com.spotify.client" to player state as string"#) else {
            throw T.Skip(reason: "no Automation access to Spotify")
        }
        _ = ActionRunner.perform(ZoneAction(kind: .playPause), guardController: guardStub)
        let toggled = T.wait(3) { osa(#"tell application id "com.spotify.client" to player state as string"#) != before }
        let mid = osa(#"tell application id "com.spotify.client" to player state as string"#) ?? "?"
        _ = ActionRunner.perform(ZoneAction(kind: .playPause), guardController: guardStub)
        let restored = T.wait(3) { osa(#"tell application id "com.spotify.client" to player state as string"#) == before }
        T.note("Spotify: \(before) → \(mid) → restored \(restored)")
        T.expect(toggled, "media key did not change Spotify's state (\(before))")
        T.expect(restored, "Spotify not restored to \(before)")
    }

    T.run("Open App launches, then brings forward when running or hidden") {
        let id = "com.apple.calculator"
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        let front = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        _ = ActionRunner.perform(ZoneAction(kind: .openApp, appBundleID: id, appName: "Calculator"), guardController: guardStub)
        T.expect(T.wait(6) { front() == id }, "Calculator not frontmost after launch (front: \(front() ?? "-"))")
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        T.wait(2) { front() == "com.apple.finder" }
        _ = ActionRunner.perform(ZoneAction(kind: .openApp, appBundleID: id, appName: "Calculator"), guardController: guardStub)
        T.expect(T.wait(4) { front() == id }, "running Calculator not brought forward (front: \(front() ?? "-"))")
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.hide()
        T.wait(2) { front() != id }
        _ = ActionRunner.perform(ZoneAction(kind: .openApp, appBundleID: id, appName: "Calculator"), guardController: guardStub)
        T.expect(T.wait(4) { front() == id && NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.isHidden == false },
                 "hidden Calculator not unhidden and focused")
        _ = ActionRunner.perform(ZoneAction(kind: .openApp, appBundleID: "com.invalid.nothing"), guardController: guardStub)  // must not crash
        if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.terminate() }
    }

    T.run("New Note opens Notes with a fresh note (then removes it)") {
        let idsScript = #"tell application id "com.apple.Notes" to get id of every note"#
        let before = osa(idsScript, timeout: 30)
        if before == nil { T.note("no Automation access to Notes: checking focus only") }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty
        _ = ActionRunner.perform(ZoneAction(kind: .newNote), guardController: guardStub)
        T.expect(T.wait(8) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Notes" }, "Notes not frontmost")
        T.sleep(1.5)
        guard let before, let after = osa(idsScript, timeout: 30) else { return }
        let old = Set(before.components(separatedBy: ", ")), new = Set(after.components(separatedBy: ", ")).subtracting(old)
        T.note("new notes created: \(new.count)")
        T.expect(new.count == 1, "expected exactly one new note, got \(new.count)")
        for n in new { _ = osa("tell application id \"com.apple.Notes\" to delete note id \"\(n)\"") }
        if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first?.terminate() }
    }

    T.run("tap feedback lights the zone on the laptop screen") {
        let pid = ProcessInfo.processInfo.processIdentifier
        TapFeedback.shared.show(zone: 1, grid: Grid(rows: 2, cols: 2), action: ZoneAction(kind: .desktopRight))
        T.sleep(0.25)
        let w = windows(pid: pid).first { $0.layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
        T.expect(w != nil, "no feedback window on screen")
        if let w { capture(windowID: w.id, name: "live_tap_feedback"); T.note("feedback window \(Int(w.bounds.width))×\(Int(w.bounds.height))") }
        T.sleep(1.4)
        T.expect(windows(pid: pid).allSatisfy { $0.layer != Int(CGWindowLevelForKey(.popUpMenuWindow)) }, "feedback did not disappear")
    }
}

// MARK: - Privacy Guard

// MARK: - Pointer actions

/// Click, scroll, Reels and the navigation keys. Posts real events but catches and swallows them, except two
/// scroll checks aimed at windows this test opens itself (the pointer is moved over them, then put back).
@MainActor
func pointerTests() {
    T.suite = "Pointer"
    print("\n▶ Pointer actions (real system)")
    guard Permissions.accessibility else {
        T.run("accessibility") { throw T.Skip(reason: "this process has no Accessibility permission") }
        return
    }
    let guardStub = PrivacyGuard(presentsOverlay: false)
    func perform(_ kind: ActionKind, distance: Double = 300) {
        _ = ActionRunner.perform(ZoneAction(kind: kind), guardController: guardStub, scrollDistance: distance)
    }

    T.run("navigation actions post the right keys (caught and swallowed)") {
        guard let catcher = EventCatcher(marker: 0x7A9C11) else { throw T.Skip(reason: "could not create an event tap") }
        defer { catcher.stop(); KeySender.eventMarker = 0 }
        KeySender.eventMarker = catcher.marker
        let cases: [(ActionKind, Int64, CGEventFlags)] = [
            (.back, 33, .maskCommand), (.forward, 30, .maskCommand), (.missionControl, 126, .maskControl),
            (.appWindows, 125, .maskControl), (.showDesktop, 103, []), (.spotlight, 49, .maskCommand),
        ]
        for (kind, key, flags) in cases {
            catcher.caught.removeAll()
            perform(kind)
            T.wait(1) { catcher.caught.count >= 2 }
            let down = catcher.caught.filter { $0.type == CGEventType.keyDown.rawValue }
            T.expect(catcher.caught.count == 2 && down.count == 1 && down[0].key == key
                     && down[0].flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate]) == flags,
                     "\(kind.title): \(catcher.caught.map { "type \($0.type) key \($0.key) flags \($0.flags.rawValue)" })")
        }
    }

    T.run("Click and Right Click press and release where the pointer is (caught and swallowed)") {
        guard let catcher = EventCatcher(marker: 0x7A9C12) else { throw T.Skip(reason: "could not create an event tap") }
        defer { catcher.stop(); KeySender.eventMarker = 0 }
        KeySender.eventMarker = catcher.marker
        let pointer = CGEvent(source: nil)!.location
        for (kind, types) in [(ActionKind.click, [CGEventType.leftMouseDown, .leftMouseUp]), (.rightClick, [.rightMouseDown, .rightMouseUp])] {
            catcher.caught.removeAll()
            perform(kind)
            T.wait(1) { catcher.caught.count >= 2 }
            T.expect(catcher.caught.map(\.type) == types.map(\.rawValue), "\(kind.title): types \(catcher.caught.map(\.type))")
            T.expect(catcher.caught.allSatisfy { abs($0.location.x - pointer.x) < 1 && abs($0.location.y - pointer.y) < 1 },
                     "\(kind.title) landed away from the pointer")
        }
    }

    T.run("Scroll glides by the set distance; Next/Previous Reel post one wheel notch (caught and swallowed)") {
        guard let catcher = EventCatcher(marker: 0x7A9C13) else { throw T.Skip(reason: "could not create an event tap") }
        defer { catcher.stop(); KeySender.eventMarker = 0 }
        KeySender.eventMarker = catcher.marker
        for (kind, want) in [(ActionKind.scrollDown, -300), (.scrollUp, 300)] {
            catcher.caught.removeAll()
            perform(kind)
            T.sleep(0.4)
            let total = catcher.caught.reduce(0) { $0 + $1.pixels }
            T.expect(catcher.caught.count >= 4 && total == want && catcher.caught.allSatisfy { $0.continuous == 1 },
                     "\(kind.title): \(catcher.caught.count) events, \(total) px")
        }
        for (kind, want) in [(ActionKind.nextReel, -3), (.previousReel, 3)] {
            catcher.caught.removeAll()
            perform(kind)
            T.sleep(0.3)
            T.expect(catcher.caught.count == 1 && catcher.caught[0].lines == Int64(want) && catcher.caught[0].continuous == 0,
                     "\(kind.title): \(catcher.caught.map { "lines \($0.lines) continuous \($0.continuous)" })")
        }
    }

    /// A window of this test's own with the pointer over its middle; the pointer goes back afterwards.
    func withPointer(over view: NSView, _ body: () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = view
        window.orderFrontRegardless()
        let saved = CGEvent(source: nil)!.location
        let mainHeight = NSScreen.screens[0].frame.height
        let f = window.frame
        CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: mainHeight - f.midY))
        T.sleep(0.3)
        body()
        CGWarpMouseCursorPosition(saved)
        window.orderOut(nil)
    }

    T.run("Scroll Down moves real content down, Scroll Up brings it back") {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        scroll.documentView = Flipped(frame: NSRect(x: 0, y: 0, width: 300, height: 6000))
        scroll.hasVerticalScroller = true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 2000))
        withPointer(over: scroll) {
            let start = scroll.contentView.bounds.origin.y
            perform(.scrollDown)
            T.sleep(0.6)
            let down = scroll.contentView.bounds.origin.y
            T.sleep(1.3)  // let the repeat-tap boost lapse
            perform(.scrollUp)
            T.sleep(0.6)
            let up = scroll.contentView.bounds.origin.y
            T.note("content offset \(Int(start)) → \(Int(down)) → \(Int(up))")
            T.expect(down > start + 100, "Scroll Down didn't move the content down (\(start) → \(down))")
            T.expect(up < down - 100, "Scroll Up didn't move it back (\(down) → \(up))")
        }
    }

    T.run("Next/Previous Reel move exactly one video in a Reels-style page (WebKit, CSS scroll snap)") {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let reels = (0..<10).map { "<div class=r style='background:hsl(\($0 * 36),60%,50%)'>\($0)</div>" }.joined()
        web.loadHTMLString("""
            <style>html,body{margin:0;height:100%;overflow:hidden}#f{height:100%;overflow-y:scroll;scroll-snap-type:y mandatory}
            .r{height:100%;scroll-snap-align:start;font:80px sans-serif;color:#fff}</style><div id=f>\(reels)</div>
            """, baseURL: nil)
        T.wait(5) { !web.isLoading }
        @MainActor func current() -> Int? {
            var out: Int?, done = false
            web.evaluateJavaScript("var f=document.getElementById('f');Math.round(f.scrollTop/f.clientHeight)") { v, _ in
                out = (v as? NSNumber)?.intValue
                done = true
            }
            T.wait(2) { done }
            return out
        }
        withPointer(over: web) {
            var seen: [Int?] = [current()]
            for kind in [ActionKind.nextReel, .nextReel, .previousReel] {
                perform(kind)
                T.sleep(1.2)  // the snap animation
                seen.append(current())
            }
            T.note("reel index: \(seen.map { $0.map(String.init) ?? "?" }.joined(separator: " → "))")
            T.expect(seen == [0, 1, 2, 1], "reels went \(seen)")
        }
    }

    T.run("Scroll Down on a page that snaps to items settles on an item, never halfway") {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let items = (0..<10).map { "<div class=r style='background:hsl(\($0 * 36),60%,50%)'>\($0)</div>" }.joined()
        web.loadHTMLString("""
            <style>html,body{margin:0;height:100%;overflow:hidden}#f{height:100%;overflow-y:scroll;scroll-snap-type:y mandatory}
            .r{height:100%;scroll-snap-align:start;font:80px sans-serif;color:#fff}</style><div id=f>\(items)</div>
            """, baseURL: nil)
        T.wait(5) { !web.isLoading }
        @MainActor func offset() -> Double? {
            var out: Double?, done = false
            web.evaluateJavaScript("var f=document.getElementById('f');f.scrollTop/f.clientHeight") { v, _ in
                out = (v as? NSNumber)?.doubleValue
                done = true
            }
            T.wait(2) { done }
            return out
        }
        withPointer(over: web) {
            var seen: [Double] = []
            for _ in 0..<3 {
                // A third of an item, like one 300 pt tap on a full-height video on a 13" screen.
                perform(.scrollDown, distance: 160)
                T.sleep(1.5)  // a snap, if any, has finished
                seen.append(offset() ?? -1)
            }
            T.note("offset in items after each tap: \(seen.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
            T.expect(seen.allSatisfy { abs($0 - $0.rounded()) < 0.02 }, "stopped between items: \(seen)")
        }
    }
}

@MainActor
func guardTests() {
    T.suite = "Privacy Guard"
    print("\n▶ Privacy Guard (real microphone, screen and camera)")
    let pid = ProcessInfo.processInfo.processIdentifier
    let overlayLevel = Int(CGWindowLevelForKey(.screenSaverWindow))

    T.run("microphone mute is exact and fully restored") {
        let before = micState()
        let m = MicMuter()
        let n = m.mute()
        let muted = micState()
        T.note("muted \(n) device(s); before \(before.values.map { $0.map { String(format: "%.2f", $0) } }) muted \(muted.values.map { $0.map { String(format: "%.2f", $0) } })")
        T.expect(n >= 1, "nothing muted")
        for (id, vals) in muted where !(before[id] ?? []).isEmpty {
            T.expect(vals.allSatisfy { $0 == 0 || $0 == 100 }, "device \(id) not silent: \(vals)")
        }
        m.reassert()
        m.restore()
        T.expect(micState() == before, "not restored: \(micState()) vs \(before)")
    }

    T.run("engage: blur on every screen, mic muted, camera idle; click dismisses; mic restored") {
        let before = micState()
        let g = PrivacyGuard(presentsOverlay: true)
        g.engage()
        T.sleep(0.6)
        let overlays = windows(pid: pid).filter { $0.layer == overlayLevel }
        T.note("overlay windows: \(overlays.count) for \(NSScreen.screens.count) screen(s); mic \(g.mic); camera \(g.camera)")
        T.expect(overlays.count == NSScreen.screens.count, "overlay count \(overlays.count) vs screens \(NSScreen.screens.count)")
        if let main = overlays.first { capture(windowID: main.id, name: "live_privacy_guard") }
        if case .muted = g.mic {} else { T.fail("mic state \(g.mic)") }
        T.expect(T.wait(3) { g.camera == .notInUse }, "camera state \(g.camera)")
        let center = CGPoint(x: NSScreen.screens[0].frame.midX, y: NSScreen.screens[0].frame.midY)
        var seen: [String] = []
        let mon = NSEvent.addLocalMonitorForEvents(matching: .any) { e in seen.append("\(e.type.rawValue)@\(e.window?.className ?? "nil")"); return e }
        click(at: center)
        T.expect(T.wait(2) { !g.isActive }, "click did not release Privacy Guard")
        if let mon { NSEvent.removeMonitor(mon) }
        let onTop = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).prefix(4)
            .map { "\($0[kCGWindowOwnerName as String] ?? "?") L\($0[kCGWindowLayer as String] ?? "?")" }
        T.note("events seen: \(seen.prefix(12)); topmost windows: \(onTop)")
        T.sleep(0.6)
        T.expect(windows(pid: pid).allSatisfy { $0.layer != overlayLevel }, "overlay still on screen")
        T.expect(micState() == before, "mic not restored after click")
        if g.isActive { g.release() }
    }

    T.run("toggle twice quickly leaves everything restored") {
        let before = micState()
        let g = PrivacyGuard(presentsOverlay: true)
        for _ in 0..<5 { g.toggle(); T.sleep(0.05); g.toggle(); T.sleep(0.05) }
        T.sleep(0.8)
        T.expect(!g.isActive && micState() == before, "state after rapid toggles: active \(g.isActive)")
        T.expect(windows(pid: pid).allSatisfy { $0.layer != overlayLevel }, "overlay left behind after rapid toggles")
    }

    T.run("camera in use with no meeting app: reports it honestly") {
        guard let device = AVCaptureDevice.default(for: .video) else { throw T.Skip(reason: "no camera") }
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            var answered = false
            AVCaptureDevice.requestAccess(for: .video) { _ in answered = true }
            T.wait(30) { answered }
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard status == .authorized, let input = try? AVCaptureDeviceInput(device: device) else {
            throw T.Skip(reason: "camera permission not granted to the test process")
        }
        let session = AVCaptureSession()
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        session.addOutput(output)
        session.startRunning()
        defer { session.stopRunning() }
        T.expect(T.wait(4) { Cameras.anyRunning() }, "Cameras.anyRunning() did not see our capture session")
        let g = PrivacyGuard(presentsOverlay: false)
        g.muteMic = false
        g.engage()
        T.expect(T.wait(6) { g.camera != .checking }, "camera check hung")
        T.note("camera state with no meeting app: \(g.camera)")
        T.expect(g.camera == .stillOn(nil) || g.camera == .needsAccessibility || { if case .stillOn = g.camera { return true }; return false }(),
                 "unexpected camera state \(g.camera)")
        g.release()
        session.stopRunning()
        T.expect(T.wait(4) { !Cameras.anyRunning() }, "camera still running after stopping the session")
    }

    T.run("meeting app selection logic") {
        let zoom = "us.zoom.xos", teams = "com.microsoft.teams2"
        T.expect(Meetings.nativeTarget(front: nil, running: []) == nil, "none running")
        T.expect(Meetings.nativeTarget(front: nil, running: [zoom])?.name == "Zoom", "zoom only")
        T.expect(Meetings.nativeTarget(front: teams, running: [zoom, teams])?.name == "Microsoft Teams", "frontmost wins")
        T.expect(Meetings.nativeTarget(front: "com.apple.finder", running: [teams, zoom])?.name == "Zoom", "first in priority when none frontmost")
        let t = Meetings.nativeTarget(front: nil, running: ["com.microsoft.teams"])!
        T.expect(t.key == .o && t.flags.contains([.maskCommand, .maskShift]), "classic Teams shortcut")
        let order = Meetings.browserOrder(front: "com.apple.Safari", running: ["com.google.Chrome", "com.apple.Safari"])
        T.expect(order.map(\.1) == ["com.apple.Safari", "com.google.Chrome"], "browser order \(order.map(\.1))")
    }

    T.run("finds and focuses a Google Meet tab in Chrome") {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first != nil else {
            throw T.Skip(reason: "Chrome not running")
        }
        let make = """
        tell application id "com.google.Chrome"
          set w to make new window
          set URL of active tab of w to "https://meet.google.com/"
          make new tab at end of tabs of w with properties {URL:"about:blank"}
          set active tab index of w to 2
          return id of w
        end tell
        """
        guard let winID = osa(make, timeout: 30) else { throw T.Skip(reason: "no Automation access to Chrome") }
        defer { _ = osa("tell application id \"com.google.Chrome\" to close (every window whose id is \(winID))") }
        T.sleep(1)
        var found = false
        Task { found = await Meetings.focusMeetTab(browserID: "com.google.Chrome") }
        T.wait(20) { found }
        let idx = osa("tell application id \"com.google.Chrome\" to get active tab index of (first window whose id is \(winID))") ?? "?"
        T.note("Meet tab found: \(found), active tab index now \(idx)")
        T.expect(found && idx == "1", "Meet tab not found/focused (found \(found), active index \(idx))")
    }
}
