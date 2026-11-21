import AppKit
import ApplicationServices
import CoreGraphics

/// Synthesised keyboard, media-key, mouse and scroll events. Posting requires the Accessibility permission.
enum KeySender {
    /// When non-zero, stamped into every synthesised event instead of `ownMarker` (tests use it to recognise and
    /// swallow them).
    nonisolated(unsafe) static var eventMarker: Int64 = 0
    /// Stamped into LidTap's own events so tap filtering doesn't take them for the user typing, clicking or
    /// scrolling: two quick Desktop taps would otherwise look like a typing burst and block the next tap.
    static let ownMarker: Int64 = 0x4C69_6454_6170  // "LidTap"
    static var stamp: Int64 { eventMarker != 0 ? eventMarker : ownMarker }
    /// Mach-clock time LidTap last posted an event. Without Input Monitoring the system's last-event times can't be
    /// told apart by stamp, so InputMonitor skips the ones that are this close to LidTap's own.
    nonisolated(unsafe) static var lastPosted = -Double.infinity

    static func post(_ ev: CGEvent) {
        ev.setIntegerValueField(.eventSourceUserData, value: stamp)
        lastPosted = MachClock.now()
        ev.post(tap: .cghidEventTap)
    }

    enum Key: CGKeyCode {
        case leftArrow = 123, rightArrow = 124, downArrow = 125, upArrow = 126, n = 45, v = 9, o = 31, e = 14
        case leftBracket = 33, rightBracket = 30, space = 49, f11 = 103
    }

    static func press(_ key: Key, flags: CGEventFlags) {
        var flags = flags
        switch key {
        case .leftArrow, .rightArrow, .upArrow, .downArrow: flags.formUnion([.maskSecondaryFn, .maskNumericPad])
        case .f11: flags.formUnion(.maskSecondaryFn)
        default: break
        }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: key.rawValue, keyDown: down) else { continue }
            ev.flags = flags
            post(ev)
        }
    }

    /// A single click where the pointer is.
    static func click(right: Bool = false) {
        let src = CGEventSource(stateID: .hidSystemState)
        let at = CGEvent(source: nil)?.location ?? .zero
        let types: [CGEventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            guard let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: at, mouseButton: right ? .right : .left)
            else { continue }
            ev.setIntegerValueField(.mouseEventClickState, value: 1)
            post(ev)
        }
    }

    /// Scrolls whatever is under the pointer by `points` (positive: towards the top of the content, like turning a
    /// wheel up), as one trackpad flick: a short gesture, then momentum, 15 ms apart (see `scrollPlan`).
    static func scroll(points: Double) {
        let marker = stamp
        for (i, step) in scrollPlan(points: points).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015 * Double(i)) {
                guard let ev = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
                                       wheelCount: 1, wheel1: step.delta, wheel2: 0, wheel3: 0) else { return }
                ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: step.phase)
                ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: step.momentum)
                ev.setIntegerValueField(.eventSourceUserData, value: marker)
                lastPosted = MachClock.now()
                ev.post(tap: .cghidEventTap)
            }
        }
    }

    /// CGScrollPhase and CGMomentumScrollPhase values.
    enum ScrollPhase { static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4 }
    enum MomentumPhase { static let begin: Int64 = 1, `continue`: Int64 = 2, end: Int64 = 3 }

    /// The events of one flick: half the distance as a finger gesture (began, changed…, ended), the rest as momentum
    /// (begin, continue…, end). Pages that snap to items (Instagram Reels, Shorts, TikTok, carousels) read the
    /// momentum as a flick and carry on to the next item; without it Chrome snaps a short scroll back to where it
    /// started, so the video seems stuck. Ordinary pages just move by the deltas, which add up to exactly `points`.
    static func scrollPlan(points: Double) -> [(delta: Int32, phase: Int64, momentum: Int64)] {
        let gesture = scrollSteps(points: points / 2, steps: 5)
        let moved = Double(gesture.reduce(0) { $0 + Int($1) })
        let momentum = scrollSteps(points: points.rounded() - moved, steps: 8)
        return gesture.enumerated().map { ($1, $0 == 0 ? ScrollPhase.began : ScrollPhase.changed, 0) }
            + [(0, ScrollPhase.ended, 0)]
            + momentum.enumerated().map { ($1, 0, $0 == 0 ? MomentumPhase.begin : MomentumPhase.continue) }
            + [(0, 0, MomentumPhase.end)]
    }

    /// One mouse-wheel notch under the pointer. Swipe feeds (Instagram Reels, YouTube Shorts, TikTok) move exactly one
    /// video per notch, and pages that snap to items go to the next one; a smooth pixel glide can instead stop short
    /// and snap back to the same video. Three lines clears the "was that a real scroll?" threshold feeds use.
    static func wheelNotch(up: Bool) {
        guard let ev = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line,
                               wheelCount: 1, wheel1: up ? 3 : -3, wheel2: 0, wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        post(ev)
    }

    /// Whole-pixel steps that add up to exactly `points`, front-loaded so the scroll eases out like a trackpad flick.
    static func scrollSteps(points: Double, steps: Int = 8) -> [Int32] {
        let weights = (0..<steps).map { Double(steps - $0) }
        let total = weights.reduce(0, +)
        var out: [Int32] = [], done = 0.0, sent = 0
        for w in weights {
            done += points * w / total
            let target = Int(done.rounded())
            out.append(Int32(target - sent))
            sent = target
        }
        return out
    }

    /// NX_KEYTYPE_* codes from IOKit's ev_keymap.h.
    enum MediaKey: Int { case volumeUp = 0, volumeDown = 1, mute = 7, play = 16, next = 17, previous = 18 }

    /// Media keys are NSSystemDefined events (subtype 8) carrying NX_KEYTYPE_* in data1.
    static func media(_ key: MediaKey) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                        data1: (key.rawValue << 16) | (state << 8), data2: -1)
            guard let cg = ev?.cgEvent else { continue }
            post(cg)
        }
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    @MainActor private static var prompted = false

    /// Shows the system Accessibility prompt at most once per launch (later failures just report).
    @MainActor static func requestAccessibilityOnce() {
        guard !prompted else { return }
        prompted = true
        requestAccessibility()
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
enum ActionRunner {
    /// Default distance of one Scroll Up / Down tap, in points.
    nonisolated static let defaultScrollDistance = 300.0
    /// Repeated scroll taps the same way go further each time (up to 2.5x), like flicking a trackpad again.
    private static var scrollRun: (time: Double, up: Bool, count: Int) = (-.infinity, true, 0)

    static func scrollDistance(up: Bool, base: Double, now: Double = MachClock.now()) -> Double {
        let count = (now - scrollRun.time < 1.2 && scrollRun.up == up) ? scrollRun.count + 1 : 0
        scrollRun = (now, up, count)
        return base * min(1 + 0.5 * Double(count), 2.5)
    }

    /// Runs a zone's action. Returns an error message for the UI if it could not run.
    @discardableResult
    static func perform(_ action: ZoneAction, guardController: PrivacyGuard, scrollDistance: Double = defaultScrollDistance) -> String? {
        if action.kind.needsAccessibility && !Permissions.accessibility {
            Permissions.requestAccessibilityOnce()
            return "LidTap needs Accessibility permission to do this."
        }
        switch action.kind {
        case .none:
            return nil
        case .desktopLeft:
            KeySender.press(.leftArrow, flags: .maskControl)
        case .desktopRight:
            KeySender.press(.rightArrow, flags: .maskControl)
        case .playPause:
            KeySender.media(.play)
        case .nextTrack:
            KeySender.media(.next)
        case .previousTrack:
            KeySender.media(.previous)
        case .volumeUp:
            KeySender.media(.volumeUp)
        case .volumeDown:
            KeySender.media(.volumeDown)
        case .mute:
            KeySender.media(.mute)
        case .newNote:
            openApp(bundleID: "com.apple.Notes") { app in
                waitUntilFrontmost(app.bundleIdentifier) { KeySender.press(.n, flags: .maskCommand) }
            }
        case .openApp:
            guard let id = action.appBundleID else { return "Choose an app for this zone in Settings." }
            openApp(bundleID: id, then: nil)
        case .runShortcut:
            guard let name = action.shortcutName else { return "Choose a shortcut for this zone in Settings." }
            Shortcuts.run(name)
        case .privacyGuard:
            guardController.toggle()
        case .scrollUp:
            KeySender.scroll(points: Self.scrollDistance(up: true, base: scrollDistance))
        case .scrollDown:
            KeySender.scroll(points: -Self.scrollDistance(up: false, base: scrollDistance))
        case .nextReel:
            KeySender.wheelNotch(up: false)
        case .previousReel:
            KeySender.wheelNotch(up: true)
        case .click:
            KeySender.click()
        case .rightClick:
            KeySender.click(right: true)
        case .back:
            KeySender.press(.leftBracket, flags: .maskCommand)
        case .forward:
            KeySender.press(.rightBracket, flags: .maskCommand)
        case .missionControl:
            KeySender.press(.upArrow, flags: .maskControl)
        case .appWindows:
            KeySender.press(.downArrow, flags: .maskControl)
        case .showDesktop:
            KeySender.press(.f11, flags: [])
        case .spotlight:
            KeySender.press(.space, flags: .maskCommand)
        case .previousApp:
            guard let app = AppHistory.shared.previous else { return "No other app to switch to yet." }
            app.unhide()
            app.activate()
        }
        return nil
    }

    /// Launches the app, or brings it forward (and reopens a window) if it is already running.
    static func openApp(bundleID: String, then: ((NSRunningApplication) -> Void)?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.unhide()
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            guard let app, let then else { return }
            DispatchQueue.main.async { then(app) }
        }
    }

    /// Polls until the app is frontmost (up to ~3 s), then runs `body`.
    static func waitUntilFrontmost(_ bundleID: String?, attempts: Int = 30, _ body: @escaping @Sendable () -> Void) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: body)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitUntilFrontmost(bundleID, attempts: attempts - 1, body) }
        }
    }
}

/// Which app was frontmost before the current one, for Previous App. (A synthesised ⌘Tab can leave the app
/// switcher stuck on screen, since no real ⌘ release follows, so LidTap switches apps itself.)
@MainActor
final class AppHistory {
    static let shared = AppHistory()
    private var recent: [NSRunningApplication] = []
    private var observer: NSObjectProtocol?

    private init() {
        if let front = NSWorkspace.shared.frontmostApplication { note(front) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { AppHistory.shared.note(app) }
        }
    }

    func note(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        recent.removeAll { $0.processIdentifier == app.processIdentifier }
        recent.insert(app, at: 0)
        if recent.count > 8 { recent.removeLast() }
    }

    /// The most recent app other than the frontmost one that is still running.
    var previous: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return recent.first { $0.processIdentifier != front && !$0.isTerminated }
    }
}

struct AppInfo: Identifiable, Hashable {
    let name: String
    let bundleID: String
    let url: URL
    var isRunning: Bool
    var id: String { bundleID }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

enum AppCatalog {
    /// Running regular apps first, then everything installed in the usual Applications folders.
    static func load() -> [AppInfo] {
        var seen = Set<String>()
        var out: [AppInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, let url = app.bundleURL, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            out.append(AppInfo(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, bundleID: id, url: url, isRunning: true))
        }
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var installed: [AppInfo] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
                installed.append(AppInfo(name: fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                                         bundleID: id, url: url, isRunning: false))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            + installed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// The user's Shortcuts, through the `shortcuts` command-line tool that ships with macOS.
enum Shortcuts {
    static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Starts the shortcut and returns at once; failures are logged (a shortcut can run for a long time).
    static func run(_ name: String) {
        let p = Process()
        p.executableURL = tool
        p.arguments = ["run", name]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        p.terminationHandler = { proc in
            guard proc.terminationStatus != 0 else { return }
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Log.action.error("Shortcut \(name, privacy: .public) failed (\(proc.terminationStatus)): \(msg, privacy: .public)")
        }
        do { try p.run() } catch {
            Log.action.error("Could not run shortcut \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Names of every shortcut, in the order the Shortcuts app shows them. Blocks briefly: call off the main thread.
    static func list() -> [String] {
        let p = Process()
        p.executableURL = tool
        p.arguments = ["list"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }
}
