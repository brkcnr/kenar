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
    func observe(_ snapshot: ProviderSnapshot) {
        Task {
            let permission = await center.notificationSettings()
            guard permission.authorizationStatus == .authorized || permission.authorizationStatus == .provisional else { return }
            observeAuthorized(snapshot)
        }
    }
    private func observeAuthorized(_ snapshot: ProviderSnapshot) {
        let settings = Settings.shared
        guard settings.values.notifications, !snapshot.isDemo, snapshot.error == nil, !settings.values.hiddenProviders.contains(snapshot.id) else { return }
        for window in snapshot.windows where !window.isUnlimited {
            guard let used = window.usedPercent else { continue }
            let key = "\(snapshot.id)|\(window.id)"
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
