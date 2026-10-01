import Foundation

/// Read-only client of Gemini CLI's Code Assist quota RPC. No generation,
/// onboarding or refresh-token requests; CLI credentials are never modified.
struct GeminiProvider: UsageProvider {
    let id = "gemini"
    private static let endpoint = "https://cloudcode-pa.googleapis.com/v1internal:"
    struct Credentials: Decodable {
        var access_token: String?
        var expiry_date: Double?
        var token: Token?
        struct Token: Decodable { var accessToken: String?; var expiresAt: Double? }
        var accessToken: String? { token?.accessToken ?? access_token }
        var expiry: Date? { (token?.expiresAt ?? expiry_date).map { Date(timeIntervalSince1970: $0 / 1000) } }
    }
    static func loadCredentials() -> Credentials? {
        let file = AppPaths.config("GEMINI_CLI_HOME", fallback: ".gemini").appendingPathComponent("oauth_creds.json")
        if let data = try? Data(contentsOf: file), let creds = try? JSONDecoder().decode(Credentials.self, from: data), creds.accessToken != nil,
           creds.expiry.map({ $0 > Date().addingTimeInterval(15) }) ?? true { return creds }
        if let data = ClaudeProvider.keychainData(service: "gemini-cli-oauth", account: "main-account"),
           let creds = try? JSONDecoder().decode(Credentials.self, from: data), creds.accessToken != nil,
           creds.expiry.map({ $0 > Date().addingTimeInterval(15) }) ?? true { return creds }
        return nil
    }
    func fetch() async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: id, name: "Gemini", systemImage: "sparkles", windows: [], error: nil)
        guard let creds = Self.loadCredentials(), let token = creds.accessToken else {
            snap.error = L("Gemini CLI’de Google hesabıyla oturum aç veya oturumunu yenile: gemini"); return snap
        }
        let configured = await MainActor.run { Settings.shared.values.geminiProject }
        do {
            let result = try await Self.fetchQuota(token: token, configuredProject: configured)
            if result.status == 401 {
                if let fresh = Self.loadCredentials()?.accessToken, fresh != token {
                    let retry = try await Self.fetchQuota(token: fresh, configuredProject: configured)
                    guard retry.status == 200 else { snap.error = Self.message(retry.status); return snap }
                    snap.windows = Self.parseUsage(retry.data)
                } else { snap.error = Self.message(401); return snap }
            } else {
                guard result.status == 200 else { snap.error = Self.message(result.status); return snap }
                snap.windows = Self.parseUsage(result.data)
            }
            if snap.windows.isEmpty { snap.error = L("Gemini hesabından okunabilir kota verisi gelmedi.") }
            else { snap.updatedAt = Date() }
        } catch { snap.error = (error as NSError).domain == "Kenar" ? error.localizedDescription : L("Gemini’ye bağlanılamadı. Ağ bağlantısını ve CLI oturumunu kontrol et.") }
        return snap
    }
    private static func fetchQuota(token: String, configuredProject: String) async throws -> (data: Data, status: Int) {
        let projectEnv = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]
        var project = configuredProject.isEmpty ? projectEnv : configuredProject
        var load: [String: Any] = ["metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]
        if let project { load["cloudaicompanionProject"] = project }
        let info = try await post("loadCodeAssist", body: load, token: token)
        guard info.status == 200 else { return info }
        if let root = (try? JSONSerialization.jsonObject(with: info.data)) as? [String: Any] {
            project = root["cloudaicompanionProject"] as? String ?? project
        }
        guard let project, !project.isEmpty else {
            throw NSError(domain: "Kenar", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Gemini CLI Google Cloud proje kimliği bulunamadı. Kenar ayarlarından CLI’de kullandığın proje kimliğini gir.")])
        }
        return try await post("retrieveUserQuota", body: ["project": project], token: token)
    }
    private static func post(_ method: String, body: [String: Any], token: String) async throws -> (data: Data, status: Int) {
        var req = URLRequest(url: URL(string: endpoint + method)!)
        req.httpMethod = "POST"; req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Kenar/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await ProviderHTTP.session.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    private static func message(_ status: Int) -> String {
        switch status { case 401: return L("Gemini CLI oturumunu yenile: gemini")
        case 403: return L("Gemini kota erişimi yok. Google hesabını ve proje ayarını kontrol et.")
        case 429: return L("Gemini sorgu sınırına ulaşıldı; sonraki yenilemede tekrar denenecek.")
        default: return L("Gemini kota servisi yanıt vermedi (HTTP %d).",status) }
    }
    static func parseUsage(_ data: Data) -> [UsageWindow] {
        struct Response: Decodable { var buckets: [Bucket]? }
        struct Bucket: Decodable { var remainingFraction: Double?; var resetTime: String?; var modelId: String?; var tokenType: String? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        var windows: [String: UsageWindow] = [:]
        for bucket in response.buckets ?? [] {
            let unit = bucket.tokenType ?? "quota"
            let model = bucket.modelId ?? "Gemini"
            let reset = ClaudeProvider.isoDate(bucket.resetTime)
            let key = "\(model)|\(unit)"
            let fraction = bucket.remainingFraction.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            let window = UsageWindow(label: model, usedPercent: fraction.map { (1 - $0) * 100 }, resetsAt: reset,
                                     id: key, modelID: model, unit: unit)
            // Multiple buckets for a model/unit may arrive from Google. Surface
            // the most constrained bucket once, keeping its reset timestamp.
            if let previous = windows[key], (previous.usedPercent ?? -1) >= (window.usedPercent ?? -1) { continue }
            windows[key] = window
        }
        return windows.values.sorted {
            if ($0.usedPercent ?? -1) != ($1.usedPercent ?? -1) { return ($0.usedPercent ?? -1) > ($1.usedPercent ?? -1) }
            return $0.id < $1.id
        }
    }
}
