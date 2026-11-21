import AppKit
import SwiftUI

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case none, desktopLeft, desktopRight, newNote, playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute, openApp, runShortcut, privacyGuard
    case scrollUp, scrollDown, nextReel, previousReel, click, rightClick, back, forward, previousApp, missionControl, appWindows, showDesktop, spotlight
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Nothing"
        case .desktopLeft: "Desktop Left"
        case .desktopRight: "Desktop Right"
        case .newNote: "New Note"
        case .playPause: "Play / Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .mute: "Mute Sound"
        case .openApp: "Open App"
        case .runShortcut: "Run Shortcut"
        case .privacyGuard: "Privacy Guard"
        case .scrollUp: "Scroll Up"
        case .scrollDown: "Scroll Down"
        case .nextReel: "Next Reel"
        case .previousReel: "Previous Reel"
        case .click: "Click"
        case .rightClick: "Right Click"
        case .back: "Back"
        case .forward: "Forward"
        case .previousApp: "Previous App"
        case .missionControl: "Mission Control"
        case .appWindows: "App Windows"
        case .showDesktop: "Show Desktop"
        case .spotlight: "Spotlight"
        }
    }

    var detail: String {
        switch self {
        case .none: "This zone does nothing"
        case .desktopLeft: "Switch to the Space on the left"
        case .desktopRight: "Switch to the Space on the right"
        case .newNote: "Open Notes with a fresh note"
        case .playPause: "Play or pause whatever is playing"
        case .nextTrack: "Skip to the next track"
        case .previousTrack: "Go back a track"
        case .volumeUp: "Turn the sound up one step"
        case .volumeDown: "Turn the sound down one step"
        case .mute: "Mute or unmute the sound"
        case .openApp: "Launch an app, or bring it to the front"
        case .runShortcut: "Run one of your Shortcuts"
        case .privacyGuard: "Mute, camera off and blur the screen"
        case .scrollUp: "Scroll what's under the pointer up. Tap again to scroll further"
        case .scrollDown: "Scroll what's under the pointer down. Tap again to scroll further"
        case .nextReel: "One video on in Reels, Shorts, TikTok and other swipe feeds (point at the video)"
        case .previousReel: "One video back in Reels, Shorts, TikTok and other swipe feeds (point at the video)"
        case .click: "Click where the pointer is"
        case .rightClick: "Right-click where the pointer is"
        case .back: "Go back (⌘[) in Safari, Chrome, Finder and more"
        case .forward: "Go forward (⌘])"
        case .previousApp: "Switch to the app you used before this one"
        case .missionControl: "Show every window and Space (⌃↑)"
        case .appWindows: "Show the front app's windows (⌃↓)"
        case .showDesktop: "Move windows aside to show the desktop (F11)"
        case .spotlight: "Open Spotlight search (⌘Space)"
        }
    }

    var symbol: String {
        switch self {
        case .none: "minus"
        case .desktopLeft: "rectangle.lefthalf.inset.filled.arrow.left"
        case .desktopRight: "rectangle.righthalf.inset.filled.arrow.right"
        case .newNote: "square.and.pencil"
        case .playPause: "playpause.fill"
        case .nextTrack: "forward.end.fill"
        case .previousTrack: "backward.end.fill"
        case .volumeUp: "speaker.wave.3.fill"
        case .volumeDown: "speaker.wave.1.fill"
        case .mute: "speaker.slash.fill"
        case .openApp: "arrow.up.forward.app"
        case .runShortcut: "square.2.layers.3d.fill"
        case .privacyGuard: "eye.slash"
        case .scrollUp: "arrow.up.circle"
        case .scrollDown: "arrow.down.circle"
        case .nextReel: "play.square.stack"
        case .previousReel: "arrow.up.square"
        case .click: "cursorarrow.click"
        case .rightClick: "cursorarrow.click.2"
        case .back: "chevron.backward.circle"
        case .forward: "chevron.forward.circle"
        case .previousApp: "arrow.uturn.backward.circle"
        case .missionControl: "rectangle.3.group"
        case .appWindows: "macwindow.on.rectangle"
        case .showDesktop: "menubar.dock.rectangle"
        case .spotlight: "magnifyingglass"
        }
    }

    /// Each action wears the hue of the Mac app or feature it belongs to (Spaces, Notes, Music, Privacy).
    var tint: Color {
        switch self {
        case .none: Color(nsColor: .tertiaryLabelColor)
        case .desktopLeft, .desktopRight, .missionControl, .appWindows, .showDesktop: .blue
        case .scrollUp, .scrollDown, .nextReel, .previousReel, .click, .rightClick: .green
        case .back, .forward, .previousApp, .spotlight: .cyan
        case .newNote: .yellow
        case .playPause, .nextTrack, .previousTrack: .pink
        case .volumeUp, .volumeDown, .mute: .orange
        case .openApp: .teal
        case .runShortcut: .purple
        case .privacyGuard: .indigo
        }
    }

    /// Picker sections, in the order they are shown.
    static let groups = ["None", "Pointer", "Navigate", "Desktop", "Music", "Sound", "Apps", "Privacy"]

    /// Short group used to organise the action picker.
    var group: String {
        switch self {
        case .none: "None"
        case .scrollUp, .scrollDown, .nextReel, .previousReel, .click, .rightClick: "Pointer"
        case .back, .forward, .previousApp, .spotlight: "Navigate"
        case .desktopLeft, .desktopRight, .missionControl, .appWindows, .showDesktop: "Desktop"
        case .playPause, .nextTrack, .previousTrack: "Music"
        case .volumeUp, .volumeDown, .mute: "Sound"
        case .newNote, .openApp, .runShortcut: "Apps"
        case .privacyGuard: "Privacy"
        }
    }

    /// Whether the action synthesises key events (needs Accessibility permission).
    var needsAccessibility: Bool {
        switch self {
        case .desktopLeft, .desktopRight, .newNote, .playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown, .mute,
             .scrollUp, .scrollDown, .nextReel, .previousReel, .click, .rightClick, .back, .forward, .missionControl, .appWindows, .showDesktop, .spotlight: true
        // Previous App only activates an app, which needs no permission.
        case .previousApp: false
        // Privacy Guard's blur and mic mute work without it; only the camera shortcut needs it (reported in the overlay).
        case .none, .openApp, .runShortcut, .privacyGuard: false
        }
    }

    /// Actions that need something chosen (an app, a shortcut) before they can run.
    var needsChoice: Bool { self == .openApp || self == .runShortcut }

    /// Actions that show their own result (the system volume indicator and its click, the page moving, a click
    /// landing) get no sound from LidTap: a tick on every scroll tap would only be noise.
    var hasSystemFeedback: Bool {
        switch self {
        case .volumeUp, .volumeDown, .mute, .scrollUp, .scrollDown, .nextReel, .previousReel, .click, .rightClick: true
        default: false
        }
    }
}

struct ZoneAction: Codable, Equatable, Hashable {
    var kind: ActionKind = .none
    var appBundleID: String?
    var appName: String?
    var shortcutName: String?

    var title: String {
        if kind == .openApp, let appName { return appName }
        if kind == .runShortcut, let shortcutName { return shortcutName }
        return kind.title
    }

    /// False while an app or shortcut still has to be chosen.
    /// What the action does, so zones that do the same thing can be recognised as one (see `ZoneModel.predict`).
    var effect: String { [kind.rawValue, appBundleID ?? "", shortcutName ?? ""].joined(separator: "|") }

    var isComplete: Bool {
        switch kind {
        case .openApp: appBundleID != nil
        case .runShortcut: shortcutName != nil
        default: true
        }
    }

    static func defaults(for grid: Grid) -> [String: ZoneAction] {
        let layout: [ActionKind]
        switch (grid.rows, grid.cols) {
        case (2, 2): layout = [.desktopLeft, .desktopRight, .playPause, .privacyGuard]
        case (2, 3): layout = [.desktopLeft, .newNote, .desktopRight, .previousTrack, .playPause, .privacyGuard]
        case (3, 3): layout = [.desktopLeft, .newNote, .desktopRight, .previousTrack, .playPause, .nextTrack, .openApp, .none, .privacyGuard]
        default: layout = []
        }
        var out: [String: ZoneAction] = [:]
        for i in 0..<grid.count { out[zoneLabel(i)] = ZoneAction(kind: i < layout.count ? layout[i] : .none) }
        return out
    }
}
