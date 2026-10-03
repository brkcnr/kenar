import Foundation

/// Receives the documented agy statusLine payload. Only quota fields are
/// retained: no credentials, account email, prompts or context token counters.
struct AntigravitySample: Codable, Equatable {
    struct Bucket: Codable, Equatable {
        var id: String
        var remainingFraction: Double?
        var resetsAt: Date?
    }
    var version = 1
    var receivedAt: Date
    var buckets: [Bucket]

    static func capture(_ data: Data, at now: Date = Date()) -> AntigravitySample? {
        struct Payload: Decodable {
            struct Quota: Decodable {
                var remaining_fraction: Double?
                var reset_time: String?
                var reset_in_seconds: Double?
                enum CodingKeys: String, CodingKey { case remaining_fraction, reset_time, reset_in_seconds }
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    remaining_fraction = try? c.decode(Double.self, forKey: .remaining_fraction)
                    reset_time = try? c.decode(String.self, forKey: .reset_time)
                    reset_in_seconds = try? c.decode(Double.self, forKey: .reset_in_seconds)
                }
            }
            var product: String?
            var quota: [String: Quota]
        }
        guard data.count <= 2 * 1024 * 1024,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.product == nil || payload.product == "antigravity", payload.quota.count <= 256, validDate(now) else { return nil }
        let buckets = payload.quota.keys.sorted().compactMap { id -> Bucket? in
            guard !id.isEmpty, id.count <= 256, let quota = payload.quota[id] else { return nil }
            let fraction = quota.remaining_fraction.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            let relative = quota.reset_in_seconds.flatMap { $0.isFinite && $0 >= 0 && $0 <= 3_155_760_000 ? now.addingTimeInterval($0) : nil }
            return Bucket(id: id, remainingFraction: fraction,
                          resetsAt: ClaudeProvider.isoDate(quota.reset_time).flatMap { validDate($0) ? $0 : nil } ?? relative)
        }
        return AntigravitySample(receivedAt: now, buckets: buckets)
    }
    var windows: [UsageWindow] {
        buckets.map { bucket in
            UsageWindow(label: bucket.id, usedPercent: bucket.remainingFraction.map { (1 - $0) * 100 },
                        resetsAt: bucket.resetsAt, id: bucket.id, modelID: bucket.id)
        }.sorted {
            if ($0.usedPercent ?? -1) != ($1.usedPercent ?? -1) { return ($0.usedPercent ?? -1) > ($1.usedPercent ?? -1) }
            return $0.id < $1.id
        }
    }
    static func read(_ url: URL) -> AntigravitySample? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1024,
              let data = try? Data(contentsOf: url), let sample = try? JSONDecoder().decode(Self.self, from: data),
              sample.version == 1, validDate(sample.receivedAt), sample.buckets.count <= 256,
              Set(sample.buckets.map(\.id)).count == sample.buckets.count else { return nil }
        // Validate persisted values too; the bridge file is still external input.
        guard sample.buckets.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 256 &&
            ($0.remainingFraction.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
            ($0.resetsAt.map(validDate) ?? true) }) else { return nil }
        return sample
    }
    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (0...253_402_300_799).contains(date.timeIntervalSince1970)
    }
    @discardableResult static func receive(_ data: Data, directory: URL, at now: Date = Date()) throws -> Bool {
        guard var sample = capture(data, at: now) else { return false }
        let url = directory.appendingPathComponent("antigravity-usage.json")
        if let old = read(url) {
            // Normalize small rounding jitter in reset hints. Absolute reset
            // timestamps from agy are preferred when capturing the payload.
            for i in sample.buckets.indices {
                if let prior = old.buckets.first(where: { $0.id == sample.buckets[i].id }),
                   prior.remainingFraction == sample.buckets[i].remainingFraction,
                   let previous = prior.resetsAt, let next = sample.buckets[i].resetsAt,
                   abs(previous.timeIntervalSince(next)) <= 2 {
                    sample.buckets[i].resetsAt = previous
                }
            }
            // Avoid recording TUI repaints as new quota consumption. Keep a
            // two-minute heartbeat while an active CLI keeps publishing data.
            if old.buckets == sample.buckets && now.timeIntervalSince(old.receivedAt) >= 0 && now.timeIntervalSince(old.receivedAt) < 120 { return false }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(sample).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}

struct AntigravityProvider: UsageProvider {
    let id = "antigravity"
    var sourceURL = AppPaths.support.appendingPathComponent("antigravity-usage.json")
    func fetch() async -> ProviderSnapshot { Self.snapshot(at: Date(), sourceURL: sourceURL) }
    static func snapshot(at now: Date, sourceURL: URL) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(id: "antigravity", name: "Antigravity", systemImage: "sparkles", windows: [], error: nil)
        guard let sample = AntigravitySample.read(sourceURL) else {
            snapshot.error = L("Antigravity bağlantısını ayarlardan bağla; ardından agy içinde /usage aç."); return snapshot
        }
        snapshot.windows = sample.windows; snapshot.updatedAt = sample.receivedAt
        if sample.buckets.isEmpty { snapshot.error = L("agy henüz kota bilgisi göndermedi. /usage ile yenile.") }
        else if now.timeIntervalSince(sample.receivedAt) > 300 || sample.receivedAt.timeIntervalSince(now) > 30 {
            snapshot.error = L("Son agy ölçümü güncel değil. Açık agy oturumunda /usage ile yenile.")
        }
        return snapshot
    }
}

enum AntigravityIntegration {
    static var directory: URL { AppPaths.config("AGY_CONFIG_DIR", fallback: ".gemini/antigravity-cli") }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func install(directory: URL = directory, executable: URL) throws -> URL {
        let settingsURL = directory.appendingPathComponent("settings.json")
        let launcher = directory.appendingPathComponent("kenar-statusline.sh")
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            guard (try settingsURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] else { throw failure("Antigravity ayar dosyası okunamadı; değiştirilmedi.") }
            settings = value
        }
        var ownCommands = [quote(launcher.path), launcher.path]
        if launcher.path.hasPrefix(AppPaths.home.path + "/") {
            ownCommands.append("~/" + launcher.path.dropFirst(AppPaths.home.path.count + 1))
        }
        if let existing = settings["statusLine"], !(existing is NSNull) {
            guard let config = existing as? [String: Any], let command = config["command"] as? String,
                  ownCommands.contains(command) else { throw failure("Mevcut agy status line ayarın korunuyor. Kenar bağlantısını eklemek için önce bu ayarı düzenle.") }
        }
        let script = "#!/bin/sh\nexec \(quote(executable.path)) --antigravity-statusline\n"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(script.utf8).write(to: launcher, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        settings["statusLine"] = ["type": "command", "command": quote(launcher.path), "enabled": true, "stack_with_default": true]
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        return launcher
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Kenar", code: 1, userInfo: [NSLocalizedDescriptionKey: L(message)])
    }
}
