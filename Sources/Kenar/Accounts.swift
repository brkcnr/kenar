import Foundation
import CryptoKit

/// Public provider IDs remain stable so existing preferences and local token
/// events survive the move to account groups.
enum AccountGroup {
    static let ids = ["claude", "codex", "cursor", "antigravity"]
    static func name(_ id: String) -> String {
        switch id { case "codex": return "OpenAI"; case "antigravity": return "Google"; default: return id.capitalized }
    }
}

enum AccountProduct: String, CaseIterable, Codable, Identifiable {
    case cursor, openai, geminiWeb = "gemini-web", antigravityWeb = "antigravity-web"
    var id: String { rawValue }
    var title: String {
        switch self { case .cursor: return "Cursor"; case .openai: return "OpenAI"; case .geminiWeb: return "Gemini"; case .antigravityWeb: return "Antigravity" }
    }
    var group: String {
        switch self { case .cursor: return "cursor"; case .openai: return "codex"; default: return "antigravity" }
    }
    var usageURL: URL {
        switch self {
        case .cursor: return URL(string: "https://cursor.com/dashboard?tab=usage")!
        case .openai: return URL(string: "https://chatgpt.com/#settings/Usage")!
        case .geminiWeb: return URL(string: "https://gemini.google.com/app")!
        case .antigravityWeb: return URL(string: "https://antigravity.google.com/")!
        }
    }
    var host: String { usageURL.host! }
    func permits(_ url: URL?) -> Bool { url?.scheme == "https" && url?.host == host && (url?.port ?? 443) == 443 }
}

enum ConnectionState: String, Codable { case disconnected, connected, limited, expired, failed }
struct ProductConnection: Identifiable {
    var id: String
    var title: String
    var state: ConnectionState
    var message: String?
    var source: String
    var account: String?
    var updatedAt: Date?
}

struct QuotaScope: Codable, Equatable {
    var account: String
    var workspace: String = ""
    var product: String
    var pool: String
    var source: String
    /// Account IDs are opaque local hashes. Never use an access token or an
    /// email as an analytics/notification key.
    static func accountID(_ serverID: String) -> String {
        SHA256.hash(data: Data(serverID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func key(provider: String, window: String) -> String {
        let fields = [provider, account, workspace, product, pool, window]
        return "account:" + (try! JSONEncoder().encode(fields)).base64EncodedString()
    }
}

extension UsageWindow {
    func identity(provider: String) -> String { scope?.key(provider: provider, window: id) ?? "\(provider)|\(id)" }
    var historyMeter: String { scope?.key(provider: "", window: id) ?? id }
    var productTitle: String? {
        switch scope?.product {
        case "codex-work": return "Codex / Work"
        case "chatgpt-chat": return "ChatGPT Chat"
        case "gemini-web": return "Gemini"
        case "antigravity": return "Antigravity"
        default: return nil
        }
    }
}

extension ProviderSnapshot {
    mutating func scopeWindows(account: String, product: String, source: String, workspace: String = "") {
        for i in windows.indices {
            windows[i].scope = QuotaScope(account: account, workspace: workspace, product: product, pool: windows[i].id, source: source)
            windows[i].measuredAt = updatedAt
        }
    }
}

/// Browser-local frames are required by sign-in widgets such as Turnstile.
/// They cannot be top-level account pages or quota request destinations.
enum AccountNavigation {
    static func permitsLocalSubframe(_ url: URL, isMainFrame: Bool) -> Bool {
        !isMainFrame && ["about:blank", "about:srcdoc"].contains(url.absoluteString)
    }
}
