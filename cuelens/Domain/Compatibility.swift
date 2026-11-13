import Foundation

struct OverlayPreferences: Codable, Equatable {
    static let opacityRange = 0.55...1.0

    static func clampedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }

    var fontSize = 16.0
    var opacity = 1.0
    var compact = true
    var shortcut = "h"
    var emergencyShortcut: String? = "x"
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
