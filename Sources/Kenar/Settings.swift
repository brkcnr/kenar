import AppKit
import SwiftUI

enum PanelEdge: String, Codable, CaseIterable { case right, left
    var title: String { self == .right ? L("Sağ") : L("Sol") }
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Legacy top/bottom placements migrate without resetting other preferences.
        self = PanelEdge(rawValue: raw) ?? .right
    }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}
enum PanelTheme: String, Codable, CaseIterable { case system, light, dark
    var title: String { switch self { case .system: return L("Sistem"); case .light: return L("Açık"); case .dark: return L("Koyu") } }
}
enum AppLanguage: String, Codable, CaseIterable { case turkish = "tr", english = "en"
    var title: String { self == .turkish ? "Türkçe" : "English" }
}

struct Preferences: Codable {
    var edge: PanelEdge = .right
    var displayID: UInt32? = nil
    var width: Double = 300
    var opacity: Double = 0.85
    var fontSize: Double = 13
    var theme: PanelTheme = .system
    var accent: String = "teal"
    var notifications: Bool = true
    var resetNotifications: Bool = true
    var thresholds: [String: [Int]] = ["claude": [75, 90, 100], "codex": [75, 90, 100], "cursor": [75, 90, 100], "antigravity": [75, 90, 100]]
    var hiddenProviders: [String] = []
    var geminiProject: String = ""
    var language: AppLanguage? = nil
}

@MainActor final class Settings: ObservableObject {
    static let shared = Settings()
    @Published var values: Preferences { didSet {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: "preferences.v1") }
    } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.data(forKey: "preferences.v1").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        if values.thresholds["antigravity"] == nil { values.thresholds["antigravity"] = values.thresholds["gemini"] ?? [75,90,100] }
        if !defaults.bool(forKey: "antigravity-provider.v1") {
            if values.hiddenProviders.contains("gemini"), !values.hiddenProviders.contains("antigravity") { values.hiddenProviders.append("antigravity") }
            defaults.set(true, forKey: "antigravity-provider.v1")
        }
        // Migrate the old default, while keeping a user's custom width.
        if !defaults.bool(forKey: "island-layout.v1") {
            if values.width == 340 { values.width = 300 }
            defaults.set(true, forKey: "island-layout.v1")
        }
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: "preferences.v1") }
    }
    var color: Color { switch values.accent { case "blue": return .blue; case "purple": return .purple; case "orange": return .orange; default: return .teal } }
    var scheme: ColorScheme? { values.theme == .system ? nil : values.theme == .dark ? .dark : .light }
    var language: AppLanguage { values.language ?? .turkish }
    func thresholds(for id: String) -> [Int] { (values.thresholds[id] ?? [75, 90, 100]).filter { (1...100).contains($0) }.sorted() }
}

enum AppPaths {
    static var support: URL {
        if let custom = ProcessInfo.processInfo.environment["KENAR_DATA_DIR"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kenar")
    }
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static func config(_ env: String, fallback: String) -> URL {
        ProcessInfo.processInfo.environment[env].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? home.appendingPathComponent(fallback)
    }
}
enum DisplayFormat {
    static var locale: Locale { Locale(identifier: L10n.override == "en" ? "en_US" : "tr_TR") }
    static func percent(_ value: Double) -> String { percent(Int(value.rounded())) }
    static func percent(_ value: Int) -> String { L10n.override == "en" ? "\(value)%" : "%\(value)" }
    static func number(_ value: Int64) -> String { value.formatted(.number.locale(locale)) }
    static func number(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
    static func date(_ date: Date, timeOnly: Bool = false) -> String {
        let formatter = DateFormatter(); formatter.locale = locale
        formatter.dateStyle = timeOnly ? .none : .medium; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

enum DisplayGeometry {
    static func frame(edge: PanelEdge, visible: NSRect, size: NSSize, expanded: Bool, compactSize: NSSize = NSSize(width: 66, height: 216)) -> NSRect {
        let width = min(size.width, max(120, visible.width - 24))
        let height = min(size.height, max(80, visible.height - 24))
        if !expanded {
            let compactWidth = min(compactSize.width, visible.width)
            let compactHeight = min(compactSize.height, visible.height)
            switch edge {
            case .right: return NSRect(x: visible.maxX - compactWidth, y: visible.midY - compactHeight/2, width: compactWidth, height: compactHeight)
            case .left: return NSRect(x: visible.minX, y: visible.midY - compactHeight/2, width: compactWidth, height: compactHeight)
            }
        }
        var origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2)
        switch edge { case .right: origin.x = visible.maxX - width; case .left: origin.x = visible.minX }
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }
    static func screenID(_ screen: NSScreen) -> UInt32? { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}
