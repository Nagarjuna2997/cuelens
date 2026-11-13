import Foundation

struct OverlayPreferences: Codable, Equatable {
    static let opacityRange = 0.55...1.0

    static func clampedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }

    var fontSize = 16.0
    var opacity = 0.85
    var compact = true
    var shortcut = "h"
    var emergencyShortcut: String? = "x"
    var theme: PanelTheme?
    var transcriptLayout: TranscriptLayout?
    var responsePlacement: ResponsePlacement?
}

enum PanelTheme: String, Codable, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: Self { self }
}

enum TranscriptLayout: String, Codable, CaseIterable, Identifiable {
    case docked = "Docked"
    case floating = "Floating"

    var id: Self { self }
}

enum ResponsePlacement: String, Codable, CaseIterable, Identifiable {
    case transcript = "With transcript"
    case answers = "With responses"

    var id: Self { self }
}

enum ShareMode: String, Codable, CaseIterable, Identifiable {
    case window = "Window or tab"
    case display = "Entire display"

    var id: Self { self }
}

enum ShareVisibility: String, Codable, CaseIterable, Identifiable {
    case unverified = "Unverified"
    case visible = "Visible in capture"
    case excluded = "Absent in observed capture"

    var id: Self { self }
}

struct ShareCheck: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var macOS = ProcessInfo.processInfo.operatingSystemVersionString
    var application = ""
    var mode = ShareMode.window
    var visibility = ShareVisibility.unverified
    var notes = ""
}
