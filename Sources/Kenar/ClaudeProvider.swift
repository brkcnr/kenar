import Foundation
import Security

/// Reads Claude Code's OAuth access token (macOS Keychain or
/// ~/.claude/.credentials.json) and queries Anthropic's usage endpoint —
/// the same request Claude Code itself makes for `/usage`.
///
/// Design notes:
/// - Kenar never refreshes tokens itself. Doing so with Claude Code's
///   refresh token could rotate it and log the user out of Claude Code.
///   When the access token expires, we simply re-read Claude Code's store
///   (Claude Code keeps it fresh whenever it runs).
/// - Only the short-lived access token (+ expiry) is cached locally, so the
///   Keychain prompt appears once, not on every refresh cycle.
/// - The usage endpoint itself is shared with Claude Code's own `/usage`
///   command, so it rate-limits fairly easily. On a 429, `fetch()` backs off
///   for the `Retry-After` window and serves the last good snapshot instead
///   of hammering the endpoint and blanking the ring.
struct ClaudeProvider: UsageProvider {
    let id = "claude"

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    struct Credentials {
        var accessToken: String
        var expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 30
        }
    }

    // MARK: Response cache / 429 backoff
    //
    // The usage endpoint is shared with Claude Code's own `/usage` command and
    // any other client polling it, so it rate-limits fairly easily. On a 429
    // we stop hitting the network until Anthropic's own `Retry-After` window
    // has passed, and meanwhile keep showing the last good numbers instead of
    // blanking the ring out.
    private static var cache: ProviderSnapshot?
    private static var cooldownUntil: Date?

    func fetch() async -> ProviderSnapshot { await fetch(userInitiated: false) }

    func fetch(userInitiated: Bool) async -> ProviderSnapshot {
        if let until = Self.cooldownUntil, Date() < until {
            return Self.rateLimitedSnapshot(retryAt: until)
        }

        var snap = ProviderSnapshot(id: id, name: "Claude",
                                    systemImage: "asterisk",
                                    windows: [], error: nil,
                                    accent: UsageColor.claudeOrange)
        let creds: Credentials
        switch Self.credentials(forceSourceRead: userInitiated, allowInteraction: userInitiated) {
        case .success(let value): creds = value
        case .failure(let failure):
            snap.error = failure.message
            snap.needsCredentialRecovery = true
            return snap
        }

        do {
            var activeToken = creds.accessToken
            var (data, status, response) = try await Self.requestUsage(token: activeToken)
            if status == 401 {
                // Claude Code rotated its token: drop our cache, re-read its store
                // (Keychain / file) and retry once right away.
                Self.clearOwnCopy(rejectedAccessToken: activeToken)
                if case .success(let fresh) = Self.credentials(forceSourceRead: true, allowInteraction: userInitiated), fresh.accessToken != creds.accessToken {
                    activeToken = fresh.accessToken
                    (data, status, response) = try await Self.requestUsage(token: activeToken)
                }
            }
            if status == 401 {
                Self.clearOwnCopy(rejectedAccessToken: activeToken)
                snap.error = L("Unauthorized — open Claude Code once to refresh login")
                snap.needsCredentialRecovery = true
                return snap
            }
            if status == 429 {
                // The window is short (often "Retry-After: 0"): quietly try again
                // twice within ~5 s before showing anything. Only if that fails do
                // we back off for the Retry-After window (min 30 s) and say so.
                for delay: UInt64 in [2, 3] {
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    (data, status, response) = try await Self.requestUsage(token: activeToken)
                    if status != 429 { break }
                }
            }
            if status == 429 {
                let retrySeconds = max(30, Self.retryAfterSeconds(response) ?? 60)
                let until = Date().addingTimeInterval(retrySeconds)
                Self.cooldownUntil = until
                return Self.rateLimitedSnapshot(retryAt: until)
            }
            guard status == 200 else {
                snap.error = L("HTTP %d", status)
                return snap
            }
            snap.windows = Self.parseUsage(data)
            snap.updatedAt = Date()
            if snap.windows.isEmpty { snap.error = L("No usage data in response") }
            Self.cooldownUntil = nil
            Self.cache = snap
            return snap
        } catch {
            snap.error = error.localizedDescription
            return snap
        }
    }

    /// While rate-limited, prefer the last good snapshot (still shows real
    /// numbers) over a blank/error ring; falls back to an error if we never
    /// had one yet.
    private static func rateLimitedSnapshot(retryAt: Date) -> ProviderSnapshot {
        let waitMin = max(1, Int(retryAt.timeIntervalSinceNow / 60))
        if var snap = cache {
            snap.error = L("Rate limited — showing cached usage, retrying in ~%d min", waitMin)
            return snap
        }
        var snap = ProviderSnapshot(id: "claude", name: "Claude", systemImage: "asterisk",
                                    windows: [], error: nil, accent: UsageColor.claudeOrange)
        snap.error = L("Rate limited (429) — retrying in ~%d min", waitMin)
        return snap
    }

    /// `Retry-After` is valid as either delta-seconds ("120") or an HTTP-date
    /// ("Wed, 21 Oct 2026 07:28:00 GMT") per RFC 9110 §10.2.3 — servers do use
    /// both forms, so both need parsing rather than just falling back to a
    /// fixed default when the value isn't a plain number.
    private static func retryAfterSeconds(_ response: HTTPURLResponse?) -> TimeInterval? {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static func requestUsage(token: String) async throws -> (Data, Int, HTTPURLResponse?) {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Kenar/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await ProviderHTTP.session.data(for: request)
        let http = response as? HTTPURLResponse
        return (data, http?.statusCode ?? 0, http)
    }

    // MARK: Parsing

    /// Newer responses carry a structured `limits` array:
    /// `{kind: session|weekly_all|weekly_scoped, percent, resets_at, scope:{model:{display_name}}}`.
    /// Older responses only have `five_hour`, `seven_day`, `seven_day_sonnet`,
    /// `seven_day_opus` dicts with `utilization` (0-100) and `resets_at`.
    static func parseUsage(_ data: Data) -> [UsageWindow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        let fromLimits = parseLimitsArray(root["limits"])
        if !fromLimits.isEmpty { return fromLimits }
        return parseLegacyWindows(root)
    }

    static func parseLimitsArray(_ any: Any?) -> [UsageWindow] {
        guard let limits = any as? [[String: Any]] else { return [] }
        var windows: [UsageWindow] = []
        for item in limits {
            guard let kind = item["kind"] as? String,
                  let pct = Self.number(item["percent"]) else { continue }
            let resets = Self.isoDate(item["resets_at"])
            let label: String
            switch kind {
            case "session":
                label = "Current session"
            case "weekly_all":
                label = "All models"
            case "weekly_scoped":
                let scope = item["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let surface = scope?["surface"] as? [String: Any]
                let name = (model?["display_name"] as? String)
                    ?? (surface?["display_name"] as? String)
                    ?? "Scoped"
                label = name
            default:
                // Unknown kind — still surface it rather than silently drop.
                label = kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
            // Avoid duplicate ids (UsageWindow.id == label).
            if windows.contains(where: { $0.label == label }) { continue }
            windows.append(UsageWindow(label: label, usedPercent: pct, resetsAt: resets))
        }
        return windows
    }

    static func parseLegacyWindows(_ root: [String: Any]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        let ordered: [(String, String)] = [
            ("five_hour", "Current session"),
            ("seven_day", "All models"),
            ("seven_day_sonnet", "Sonnet"),
            ("seven_day_opus", "Opus"),
        ]
        for (key, label) in ordered {
            guard let dict = root[key] as? [String: Any] else { continue }
            guard let pct = Self.number(dict["utilization"]) else { continue }
            let resets = Self.isoDate(dict["resets_at"])
            windows.append(UsageWindow(label: label, usedPercent: pct, resetsAt: resets))
        }
        return windows
    }

    static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    static func isoDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        return f2.date(from: s)
    }

    // MARK: Credentials

    static func credentials(forceSourceRead: Bool = false, allowInteraction: Bool = false) -> Result<Credentials, ClaudeCredentialStore.Failure> {
        let result = ClaudeCredentialStore.shared.load(forceSourceRead: forceSourceRead, allowInteraction: allowInteraction)
        if case .success(let creds) = result { saveOwnCopy(creds) }
        return result
    }

    // Holds only the short-lived access token and expiry, never the refresh token.
    static var ownStoreURL: URL {
        AppPaths.support
            .appendingPathComponent("credentials.json")
    }

    static func saveOwnCopy(_ creds: Credentials) {
        var oauth: [String: Any] = ["accessToken": creds.accessToken]
        if let e = creds.expiresAt { oauth["expiresAt"] = Int(e.timeIntervalSince1970 * 1000) }
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]) else { return }
        let dir = ownStoreURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: ownStoreURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownStoreURL.path)
    }

    static func clearOwnCopy(rejectedAccessToken: String? = nil) {
        ClaudeCredentialStore.shared.invalidate(rejectedAccessToken: rejectedAccessToken)
        try? FileManager.default.removeItem(at: ownStoreURL)
    }

    /// Probe only the local credential source. No dialog or network request;
    /// quota fetching resumes once Claude Code provides a usable login.
    static func canRecoverConnection() -> Bool {
        if case .success = ClaudeCredentialStore.shared.load(forceSourceRead: true, allowInteraction: false) { return true }
        return false
    }

    static func parseCredentialsJSON(_ data: Data) -> Credentials? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var expires: Date?
        if let ms = number(oauth["expiresAt"]) {
            expires = Date(timeIntervalSince1970: ms / 1000.0)
        }
        return Credentials(accessToken: token, expiresAt: expires)
    }

    static func keychainData(service: String, account: String? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    // MARK: Demo fallback

    static func demoSnapshot(name: String, systemImage: String, note: String) -> ProviderSnapshot {
        ProviderSnapshot(id: name.lowercased(), name: name, systemImage: systemImage,
                         windows: [], error: note)
    }
}
