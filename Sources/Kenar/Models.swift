import Foundation
import SwiftUI

struct UsageWindow: Identifiable, Codable {
    var id: String
    var label: String
    var usedPercent: Double?
    var resetsAt: Date?
    var modelID: String?
    var unit: String
    var isUnlimited: Bool
    var scope: QuotaScope? = nil
    var measuredAt: Date? = nil
    var issue: String? = nil
    init(label: String, usedPercent: Double?, resetsAt: Date?, id: String? = nil, modelID: String? = nil, unit: String = "quota", isUnlimited: Bool = false) {
        self.id = id ?? label; self.label = label
        self.usedPercent = usedPercent.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.resetsAt = resetsAt; self.modelID = modelID; self.unit = unit; self.isUnlimited = isUnlimited
        if isUnlimited { self.usedPercent = nil }
    }
    var fraction: Double { min(max((usedPercent ?? 0) / 100, 0), 1) }
    func countdown(at now: Date) -> String? {
        guard let date = resetsAt else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return L("Yenilenme kontrol ediliyor…") }
        if seconds < 60 { return L("Yenilenme: %d sn",seconds) }
        if seconds < 3600 { return L("Yenilenme: %d dk",seconds / 60) }
        if seconds < 86400 { return L("Yenilenme: %d sa %d dk",seconds / 3600,(seconds % 3600) / 60) }
        return L("Yenilenme: %d gün %d sa",seconds / 86400,(seconds % 86400) / 3600)
    }
    var resetText: String? { countdown(at: Date()) }
    var title: String {
        switch label {
        case "Current session": return L("Oturum")
        case "All models": return L("Tüm modeller · Haftalık")
        case "Weekly": return L("Haftalık")
        case "Included usage": return L("Dahil kullanım")
        case "On-demand": return L("Ek kullanım")
        default: return L(label)
        }
    }
}

struct ProviderSnapshot: Identifiable {
    let id: String
    var name: String
    var systemImage: String
    var windows: [UsageWindow]
    var error: String?
    var isDemo = false
    var accent: Color? = nil
    var updatedAt: Date? = nil
    var needsCredentialRecovery = false
    var products: [ProductConnection] = []
    var primary: UsageWindow? {
        let usable = windows.filter { $0.issue == nil && ($0.measuredAt.map { Date().timeIntervalSince($0) <= 300 } ?? true) }
        return usable.filter { $0.usedPercent != nil }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) } ?? usable.first ?? windows.first
    }
    var isStale: Bool { !isDemo && (error != nil || (updatedAt.map { Date().timeIntervalSince($0) > 300 } ?? false)) }
    func hasActiveConnection(at now: Date = Date()) -> Bool {
        guard error == nil, windows.contains(where: { window in
            window.issue == nil && (window.usedPercent != nil || window.isUnlimited || window.resetsAt != nil) &&
            (window.measuredAt.map { now.timeIntervalSince($0) <= 300 && $0.timeIntervalSince(now) <= 30 } ?? true)
        }) else { return false }
        if isDemo { return Preview.isEnabled }
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) <= 300 && updatedAt.timeIntervalSince(now) <= 30
    }
    var color: Color { switch id { case "claude": return UsageColor.claudeOrange; case "codex": return .teal; case "cursor": return .purple; default: return .blue } }
    var initial: String { switch id { case "claude": return "A"; case "cursor": return "U"; case "gemini", "antigravity": return "G"; default: return "C" } }
}
enum UsageColor { static let claudeOrange = Color(red: 0.94, green: 0.56, blue: 0.32) }
protocol UsageProvider {
    var id: String { get }
    func fetch() async -> ProviderSnapshot
    func fetch(userInitiated: Bool) async -> ProviderSnapshot
}
extension UsageProvider {
    func fetch(userInitiated: Bool) async -> ProviderSnapshot { await fetch() }
}

@MainActor final class UsageStore: ObservableObject {
    @Published var snapshots: [ProviderSnapshot] = []
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?
    @Published var storageError: String?
    @Published private(set) var connectionRevision = 0
    private var connectedIDs = Set<String>()
    let analytics: AnalyticsStore?
    private let providers: [UsageProvider]
    private var timer: Timer?
    private var deadlineTimer: Timer?
    private var resetAttempts: [String: Date] = [:]
    private let quotaObserver: @MainActor (ProviderSnapshot) -> Void
    private let credentialProbe: @Sendable () -> Bool
    private(set) var probingCredentials = false
    private var lastCredentialProbe: Date = .distantPast
    private var lastAntigravityFileStamp: Date?
    private var lastClaudeFileStamp: Date?
    private var sourceRevisions: [String: Int] = [:]
    private var pendingRefresh = Set<String>()
    init(providers: [UsageProvider], analytics: AnalyticsStore?,
         credentialProbe: @escaping @Sendable () -> Bool = { ClaudeProvider.canRecoverConnection() },
         quotaObserver: @escaping @MainActor (ProviderSnapshot) -> Void = { Notifier.shared.observe($0) }) {
        self.providers = providers; self.analytics = analytics
        self.credentialProbe = credentialProbe; self.quotaObserver = quotaObserver
        snapshots = providers.map { ProviderSnapshot(id: $0.id, name: AccountGroup.name($0.id), systemImage: "circle", windows: [], error: nil) }
        if analytics == nil && !Preview.isEnabled { storageError = L("Yerel veritabanı açılamadı; geçmiş kaydedilmiyor.") }
    }
    func startAutoRefresh() {
        if Preview.isEnabled { snapshots = Preview.snapshots; return }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshAll() } }
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkResets() }
        }
        refreshAll()
    }
    func compactProviders(hiddenProviders: [String], at now: Date = Date()) -> [ProviderSnapshot] {
        snapshots.filter { !hiddenProviders.contains($0.id) && $0.hasActiveConnection(at: now) }
    }
    func updateConnectionHealth(at now: Date = Date()) {
        let active = Set(snapshots.filter { $0.hasActiveConnection(at: now) }.map(\.id))
        if active != connectedIDs { connectedIDs = active; connectionRevision += 1 }
    }
    private func checkResets() {
        let now = Date()
        checkCredentialRecovery(at: now)
        if !isRefreshing, providers.contains(where: { $0.id == "antigravity" }),
           let stamp = try? AntigravityProvider().sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           stamp != lastAntigravityFileStamp {
            lastAntigravityFileStamp = stamp
            refresh(providerID: "antigravity", userInitiated: false)
        }
        if !isRefreshing, providers.contains(where: { $0.id == "claude" }),
           let stamp = try? ClaudeQuotaBridge.sourceURL.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate, stamp != lastClaudeFileStamp {
            lastClaudeFileStamp = stamp; refresh(providerID:"claude",userInitiated:false)
        }
        updateConnectionHealth(at: now)
        for snap in snapshots where !snap.isDemo {
            for window in snap.windows {
                let key = window.identity(provider: snap.id)
                if let reset = window.resetsAt, reset <= now, now.timeIntervalSince(resetAttempts[key] ?? .distantPast) >= 120 {
                    resetAttempts[key] = now; refreshAll(); return
                }
            }
        }
    }
    func checkCredentialRecovery(at now: Date = Date()) {
        guard !Preview.isEnabled, !isRefreshing, !probingCredentials,
              now.timeIntervalSince(lastCredentialProbe) >= 5,
              snapshots.contains(where: { $0.id == "claude" && $0.needsCredentialRecovery }) else { return }
        lastCredentialProbe = now; probingCredentials = true
        let probe = credentialProbe
        Task {
            let available = await Task.detached(priority: .utility) { probe() }.value
            probingCredentials = false
            guard available, !isRefreshing,
                  snapshots.contains(where: { $0.id == "claude" && $0.needsCredentialRecovery }) else { return }
            refresh(providerID: "claude", userInitiated: false)
        }
    }
    static func merging(_ fresh: ProviderSnapshot, with previous: ProviderSnapshot?) -> ProviderSnapshot {
        guard let previous, !previous.windows.isEmpty, !previous.isDemo else { return fresh }
        var merged = fresh
        if fresh.error != nil {
            // A different account/source cannot revive another account's quota.
            if !fresh.products.isEmpty {
                merged.windows = previous.windows.filter { window in
                    fresh.products.contains { product in
                        product.account != nil && window.scope?.account == product.account &&
                        window.scope?.product == product.id && window.scope?.source == product.source
                    }
                }
            } else { merged.windows = previous.windows }
            if !merged.windows.isEmpty { merged.updatedAt = previous.updatedAt }
        } else {
            for product in fresh.products where [.failed, .expired].contains(product.state) {
                for var old in previous.windows where old.scope?.product == product.id && old.scope?.account == product.account && product.account != nil && old.scope?.source == product.source {
                    old.issue = product.message ?? L("Bu ölçüm güncel değil.")
                    if !merged.windows.contains(where: { $0.identity(provider: fresh.id) == old.identity(provider: fresh.id) }) { merged.windows.append(old) }
                }
            }
        }
        return merged
    }
    func connectionsChanged(providerID: String = "claude") {
        sourceRevisions[providerID, default: 0] += 1
        if let index = snapshots.firstIndex(where:{ $0.id == providerID }) {
            snapshots[index] = ProviderSnapshot(id:providerID,name:AccountGroup.name(providerID),systemImage:"circle",windows:[],error:nil)
        }
        if isRefreshing { pendingRefresh.insert(providerID) } else { refresh(providerID:providerID,userInitiated:false) }
    }
    func refreshAll(userInitiated: Bool = false) { refresh(providerID: nil, userInitiated: userInitiated) }
    func retryConnection(providerID: String) { refresh(providerID: providerID, userInitiated: true) }
    func refresh(providerID: String?, userInitiated: Bool) {
        guard !Preview.isEnabled else { return }
        if isRefreshing { if let providerID { pendingRefresh.insert(providerID) }; return }
        isRefreshing = true
        let sourceRevisions = self.sourceRevisions
        let providers = self.providers.filter { providerID == nil || $0.id == providerID }
        Task {
            await withTaskGroup(of: ProviderSnapshot.self) { group in
                for provider in providers { group.addTask { await provider.fetch(userInitiated: userInitiated) } }
                for await fresh in group {
                    if sourceRevisions[fresh.id, default: 0] != self.sourceRevisions[fresh.id, default: 0] { continue }
                    let previous = snapshots.first { $0.id == fresh.id }
                    if let index = snapshots.firstIndex(where: { $0.id == fresh.id }) {
                        snapshots[index] = Self.merging(fresh, with: snapshots[index])
                    }
                    if fresh.error == nil && !fresh.isDemo && (fresh.updatedAt == nil || previous?.updatedAt != fresh.updatedAt) {
                        let history = analytics
                        await Task.detached(priority: .utility) { history?.record(fresh, now: fresh.updatedAt ?? Date()) }.value
                        quotaObserver(fresh)
                    }
                }
            }
            lastRefresh = Date(); isRefreshing = false
            if !pendingRefresh.isEmpty { pendingRefresh.removeAll(); refreshAll() }
            if let error = analytics?.lastError { storageError = L("Geçmiş kaydı: %@",error) }
            NotificationCenter.default.post(name: .kenarDataChanged, object: nil)
        }
    }
}
extension Notification.Name { static let kenarDataChanged = Notification.Name("kenar.data.changed") }
enum Preview {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["KENAR_PREVIEW"] == "1" || Bundle.main.bundleIdentifier == "local.kenar.preview" }
    static var snapshots: [ProviderSnapshot] {
        sampleSnapshots(at: Date())
    }
    /// Use each provider's response schema and parser, so preview details match
    /// the real panel rather than giving every account Codex's quota windows.
    static func sampleSnapshots(at now: Date) -> [ProviderSnapshot] {
        let iso = ISO8601DateFormatter()
        func reset(_ seconds: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(seconds)) }
        func sample(_ id: String, _ response: String, _ parse: (Data) -> [UsageWindow]) -> ProviderSnapshot {
            ProviderSnapshot(id: id, name: id == "claude" ? "Claude" : id.capitalized,
                systemImage: "circle", windows: parse(Data(response.utf8)), error: nil,
                isDemo: true, updatedAt: now)
        }
        var snapshots = [
            sample("codex", """
                {"rate_limit":{"primary_window":{"used_percent":42,"reset_at":"\(reset(8280))"},
                "secondary_window":{"used_percent":31,"reset_at":"\(reset(345600))"}}}
                """, CodexProvider.parseUsage),
            sample("claude", """
                {"limits":[{"kind":"session","percent":68,"resets_at":"\(reset(16140))"},
                {"kind":"weekly_all","percent":16,"resets_at":"\(reset(81540))"},
                {"kind":"weekly_scoped","percent":12,"resets_at":"\(reset(81540))",
                "scope":{"model":{"display_name":"Fable"}}}]}
                """, ClaudeProvider.parseUsage),
            sample("cursor", """
                {"billingCycleEnd":"\(reset(864000))","individualUsage":{"plan":{
                "totalPercentUsed":23,"autoPercentUsed":18,"apiPercentUsed":5}}}
                """, CursorProvider.parseUsage),
            sample("antigravity", """
                {"product":"antigravity","quota":{"gemini-weekly":{"remaining_fraction":0.64,"reset_time":"\(reset(32400))"},
                "claude-weekly":{"remaining_fraction":0.88,"reset_time":"\(reset(32400))"}}}
                """, { AntigravitySample.capture($0, at: now)?.windows ?? [] })
        ]
        for i in snapshots.indices {
            snapshots[i].name = AccountGroup.name(snapshots[i].id)
            let product = snapshots[i].id == "codex" ? "codex-work" : snapshots[i].id == "antigravity" ? "antigravity" : snapshots[i].id
            snapshots[i].scopeWindows(account: "preview-account", product: product, source: "preview")
            snapshots[i].products = [ProductConnection(id: product, title: product == "codex-work" ? "Codex / Work" : product == "antigravity" ? "Antigravity" : snapshots[i].name, state: .connected, source: "preview", account: "preview-account", updatedAt: now)]
            if snapshots[i].id == "codex" { snapshots[i].products.append(ProductConnection(id: "chatgpt-chat", title: "ChatGPT Chat", state: .limited, message: L("Kullanım yüzdesi paylaşılmıyor. Codex / Work kotasından ayrıdır."), source: "preview")) }
            if snapshots[i].id == "antigravity" { snapshots[i].products.insert(ProductConnection(id: "gemini-web", title: "Gemini", state: .limited, message: L("Kullanım yüzdesi paylaşılmıyor."), source: "preview"), at: 0) }
        }
        return snapshots

    }
    static func history(provider: String) -> [QuotaPoint] {
        let now = Date()
        return (0..<168).map { (hour: Int) -> QuotaPoint in
            let offset: TimeInterval = Double(hour - 167) * 3600
            let percent: Double = Double((hour % 12) * 7 + 5)
            let period: String = "preview-\(hour / 12)"
            return QuotaPoint(id:Int64(hour),provider:provider,meter:"preview-session",title:L("Örnek oturum"),model:L("Örnek model"),unit:"quota",date:now.addingTimeInterval(offset),percent:percent,reset:nil,period:period)
        }
    }
}
