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
        store = UsageStore(providers: [CodexProvider(),ClaudeProvider(),CursorProvider(),AntigravityProvider()],analytics: analytics)
        controller = PanelController(store: store,settings: .shared)
        Notifier.shared.requestAuthorizationIfNeeded()
        store.startAutoRefresh()
        NotificationCenter.default.addObserver(forName:.kenarConnectionsChanged,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.store.connectionsChanged() } }
        if CommandLine.arguments.contains("--connect-claude-web") { ClaudeWebConnection.shared.connect() }
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
        if CommandLine.arguments.contains("--antigravity-statusline") || CommandLine.arguments.contains("--claude-statusline") {
            var data = Data()
            while let chunk = try? FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 2 * 1024 * 1024 { return }
            }
            if CommandLine.arguments.contains("--claude-statusline") { try? ClaudeQuotaBridge.receive(data) }
            else { _ = try? AntigravitySample.receive(data, directory: AppPaths.support) }
            return
        }
        if CommandLine.arguments.contains("--connect-claude") {
            do { print(try ClaudeQuotaBridge.install(executable:Bundle.main.executableURL!).path) }
            catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }; return
        }
        if CommandLine.arguments.contains("--connect-antigravity") {
            do {
                let launcher = try AntigravityIntegration.install(executable: Bundle.main.executableURL!)
                print("Connected. In an already-running agy session, run: /statusline \(launcher.path)")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
