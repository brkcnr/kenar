import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore!
    private var controller: PanelController!
    private var indexer: TranscriptIndexer?
    private var indexing = false
    private var indexTimer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        L10n.override = Settings.shared.language.rawValue
        let analytics = Preview.isEnabled ? nil : AnalyticsStore(url: AppPaths.support.appendingPathComponent("analytics.sqlite"))
        if let analytics { indexer = TranscriptIndexer(store: analytics) }
        store = UsageStore(providers: [CodexProvider(),ClaudeProvider(),CursorProvider(),GeminiProvider()],analytics: analytics)
        controller = PanelController(store: store,settings: .shared)
        Notifier.shared.requestAuthorizationIfNeeded()
        store.startAutoRefresh()
        index()
        indexTimer = Timer.scheduledTimer(withTimeInterval: 30,repeats: true) { [weak self] _ in Task { @MainActor in self?.index() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,object: nil,queue: .main) { [weak self] _ in Task { @MainActor in self?.store.refreshAll(); self?.index() } }
    }
    private func index() {
        guard !indexing, let indexer else { return }; indexing = true
        Task {
            _ = await Task.detached(priority: .utility) { indexer.scan() }.value
            indexing = false; NotificationCenter.default.post(name: .kenarDataChanged,object: nil)
        }
    }
}

@main enum KenarApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
