import AppKit

enum SettingsKey {
    static let isAlwaysOnTop = "isAlwaysOnTop"
    static let hidesFromScreenCapture = "hidesFromScreenCapture"
    static let theme = "theme"
    static let isTranscriptCollapsed = "isTranscriptCollapsed"
    /// The main window's height while the transcript is expanded, restored when it expands again.
    static let expandedWindowHeight = "expandedWindowHeight"
}

/// The value of each setting until the user changes it. Every reader of a setting uses these.
enum SettingsDefault {
    static let isAlwaysOnTop = true
    static let hidesFromScreenCapture = true
    static let theme = AppTheme.system
    static let isTranscriptCollapsed = false
}

enum AppTheme: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: Self { self }

    var displayName: String {
        switch self {
        case .light: "ライト"
        case .dark: "ダーク"
        case .system: "システム"
        }
    }

    /// The appearance of every window in the app. `nil` follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}
