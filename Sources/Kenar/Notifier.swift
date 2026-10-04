import Foundation
import UserNotifications

/// Persistent, independently testable notification rules. Reset identities allow
/// a small tolerance for relative reset timestamps and survive app restarts.
struct NotificationLedger: Codable {
    struct State: Codable { var reset: Date?; var used: Double; var period: String; var fired: Set<Int>; var observedAt: Date }
    var states: [String: State] = [:]
    mutating func observe(key: String, used: Double, reset: Date?, thresholds: [Int], now: Date = Date()) -> (crossed: [Int], period: String, renewed: Bool) {
        let old = states[key]
        let changedReset = old?.reset.flatMap { previous in reset.map { abs($0.timeIntervalSince(previous)) > 120 } } ?? false
        let unknownResetDrop = old != nil && reset == nil && old?.reset == nil && used < (old?.used ?? 0) - 1
        let renewed = changedReset || unknownResetDrop
        var state = renewed || old == nil ? State(reset: reset, used: used, period: UUID().uuidString, fired: [], observedAt: now) : old!
        let crossed = thresholds.filter { used >= Double($0) && !state.fired.contains($0) }
        state.fired.formUnion(crossed)
        state.used = used; state.observedAt = now
        if let reset, state.reset == nil { state.reset = reset }
        states[key] = state
        return (crossed, state.period, renewed)
    }
}

@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private var ledger: NotificationLedger
    private var scheduled: [String: Date] = [:]
    private var connectionRevisions: [String: Int] = [:]
    private let defaults = UserDefaults.standard
    private override init() {
        ledger = UserDefaults.standard.data(forKey: "notification.ledger.v1").flatMap { try? JSONDecoder().decode(NotificationLedger.self, from: $0) } ?? NotificationLedger()
        super.init(); center.delegate = self
    }
    func requestAuthorizationIfNeeded() {
        guard Settings.shared.values.notifications, !Preview.isEnabled else { return }
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        }
    }
    func preferencesChanged() {
        center.removeAllPendingNotificationRequests(); scheduled.removeAll()
        requestAuthorizationIfNeeded()
    }
    private func belongs(_ key: String, to providerID: String) -> Bool {
        if key.hasPrefix(providerID + "|") { return true }
        guard key.hasPrefix("account:"), let data = Data(base64Encoded: String(key.dropFirst(8))),
              let fields = try? JSONDecoder().decode([String].self, from: data) else { return false }
        return fields.first == providerID
    }
    func connectionChanged(providerID: String) {
        connectionRevisions[providerID, default: 0] += 1
        let keys = scheduled.keys.filter { belongs($0, to: providerID) }
        center.removePendingNotificationRequests(withIdentifiers: keys.map { "reset|\($0)" })
        keys.forEach { scheduled.removeValue(forKey: $0) }
        // Pending resets survive app restarts; the in-memory dictionary does not.
        Task {
            let requests = await center.pendingNotificationRequests()
            let ids = requests.map(\.identifier).filter { id in
                id.hasPrefix("reset|") && belongs(String(id.dropFirst(6)), to: providerID)
            }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
    func observe(_ snapshot: ProviderSnapshot) {
        let revision = connectionRevisions[snapshot.id, default: 0]
        Task {
            let permission = await center.notificationSettings()
            guard revision == connectionRevisions[snapshot.id, default: 0],
                  permission.authorizationStatus == .authorized || permission.authorizationStatus == .provisional else { return }
            observeAuthorized(snapshot)
        }
    }
    private func observeAuthorized(_ snapshot: ProviderSnapshot) {
        let settings = Settings.shared
        guard settings.values.notifications, !snapshot.isDemo, snapshot.error == nil, !settings.values.hiddenProviders.contains(snapshot.id) else { return }
        for window in snapshot.windows where !window.isUnlimited {
            guard let used = window.usedPercent else { continue }
            let key = window.identity(provider: snapshot.id)
            guard window.issue == nil else { continue }
            let result = ledger.observe(key: key, used: used, reset: window.resetsAt, thresholds: settings.thresholds(for: snapshot.id))
            // A poll jumping across several thresholds produces one banner.
            if let threshold = result.crossed.max() {
                post(id: "threshold|\(key)|\(result.period)|\(threshold)", title: "\(snapshot.name) · \(window.title)",
                     body: L("Kullanım %@ seviyesinde. Uyarı eşiği: %@. %@",DisplayFormat.percent(used),DisplayFormat.percent(threshold),window.resetText ?? ""))
            }
            let resetID = "reset|\(key)"
            if result.renewed { center.removePendingNotificationRequests(withIdentifiers: [resetID]); scheduled.removeValue(forKey: key) }
            if settings.values.resetNotifications, let reset = window.resetsAt, reset.timeIntervalSinceNow > 1,
               scheduled[key].map({ abs($0.timeIntervalSince(reset)) > 120 }) ?? true {
                let content = UNMutableNotificationContent()
                content.title = L("%@ · Yenilenme zamanı",snapshot.name)
                content.body = L("%@ için bildirilen yenilenme zamanı geldi. Güncel kotayı Kenar’dan kontrol edebilirsin.",window.title)
                content.sound = .default
                center.add(UNNotificationRequest(identifier: resetID, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: reset.timeIntervalSinceNow, repeats: false)))
                scheduled[key] = reset
            }
        }
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: "notification.ledger.v1") }
    }
    func test() { post(id: "test", title: "Kenar", body: L("Bildirimler çalışıyor. Kullanım eşiklerini sağlayıcı bazında ayarlayabilirsin.")) }
    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) { handler([.banner, .sound]) }
}
