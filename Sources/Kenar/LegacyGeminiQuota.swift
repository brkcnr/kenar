import Foundation

/// Decoder retained for legacy quota fixtures and data compatibility.
/// Active Google integration uses AntigravityProvider; no legacy OAuth or RPC.
enum LegacyGeminiQuota {
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
