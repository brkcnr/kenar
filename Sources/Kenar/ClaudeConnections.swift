import Foundation
import AppKit
import WebKit

/// Public Claude Code rate_limits payload, received without reading credentials.
enum ClaudeQuotaBridge {
    static var sourceURL: URL { AppPaths.support.appendingPathComponent("claude-usage.json") }
    static func capture(_ data: Data, at now: Date = Date()) -> AntigravitySample? {
        guard data.count <= 2 * 1024 * 1024, let root = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let limits = root["rate_limits"] as? [String:Any] else { return nil }
        var quota: [String:Any] = [:]
        for (key,label) in [("five_hour","Current session"),("seven_day","All models")] {
            guard let window = limits[key] as? [String:Any], let percent = ClaudeProvider.number(window["used_percentage"]),
                  percent.isFinite, (0...100).contains(percent) else { continue }
            var bucket: [String:Any] = ["remaining_fraction": 1-percent/100]
            if let seconds = ClaudeProvider.number(window["resets_at"]), seconds.isFinite, (1...253_402_300_799).contains(seconds) {
                bucket["reset_time"] = ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:seconds))
            }
            quota[label] = bucket
        }
        guard !quota.isEmpty, let filtered = try? JSONSerialization.data(withJSONObject:["quota":quota]) else { return nil }
        return AntigravitySample.capture(filtered,at:now)
    }
    static func receive(_ data: Data, directory: URL = AppPaths.support, at now: Date = Date()) throws {
        guard let sample = capture(data,at:now) else { return }
        try AntigravitySample.store(sample,directory:directory,filename:"claude-usage.json",at:now)
    }
    static func snapshot(at now: Date = Date(), sourceURL: URL = sourceURL) -> ProviderSnapshot? {
        guard let sample = AntigravitySample.read(sourceURL), !sample.buckets.isEmpty,
              now.timeIntervalSince(sample.receivedAt) <= 300, sample.receivedAt.timeIntervalSince(now) <= 30 else { return nil }
        var windows = sample.windows.filter { $0.resetsAt.map { $0 > now } ?? true }
        guard !windows.isEmpty else { return nil }
        windows.sort { $0.id == "Current session" && $1.id != "Current session" }
        // Stable IDs match the existing Claude OAuth history.
        for i in windows.indices { windows[i].modelID = nil }
        return ProviderSnapshot(id:"claude",name:"Claude",systemImage:"asterisk",windows:windows,error:nil,updatedAt:sample.receivedAt)
    }
    static func install(directory: URL = AppPaths.config("CLAUDE_CONFIG_DIR",fallback:".claude"), executable: URL) throws -> URL {
        try StatusLineInstaller.install(directory:directory,executable:executable,argument:"--claude-statusline",options:["refreshInterval":60])
    }
}

struct ClaudeWorkspace: Identifiable { var id: String; var name: String }

/// User-owned web session in Kenar's WebKit store. No external browser or
/// Desktop cookies are imported. Account usage is shared across Claude surfaces.
@MainActor final class ClaudeWebConnection: NSObject, ObservableObject, WKUIDelegate, WKHTTPCookieStoreObserver {
    static let shared = ClaudeWebConnection()
    @Published var workspaces: [ClaudeWorkspace] = []
    @Published var connectionMessage: String?
    private var loginWindow: NSWindow?
    private var loginView: WKWebView?
    private var popupWindows: [NSWindow] = []
    private var cookieFingerprint: String?
    private override init() {
        super.init(); WKWebsiteDataStore.default().httpCookieStore.add(self)
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard Settings.shared.values.claudeSource == "web" else { return }
        cookieStore.getAllCookies { [weak self] cookies in
            let relevant = cookies.filter { ["claude.ai", ".claude.ai"].contains($0.domain) && ["sessionKey", "lastActiveOrg"].contains($0.name) }.sorted { $0.name < $1.name }
            let fingerprint = QuotaScope.accountID(relevant.map { $0.name + "=" + $0.value }.joined(separator: ";"))
            Task { @MainActor in
                guard let self, fingerprint != self.cookieFingerprint else { return }
                self.cookieFingerprint = fingerprint
                NotificationCenter.default.post(name: .kenarAccountReady, object: "claude")
            }
        }
    }
    func connect() {
        Settings.shared.values.claudeSource = "web"
        if let loginWindow { present(loginWindow,view:loginView); return }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .default()
        let view = ClaudeLoginWebView(frame:.zero,configuration:configuration); view.uiDelegate = self; loginView = view
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:720),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = L("Claude hesabını bağla · Kenar"); window.isReleasedWhenClosed = false; window.contentView = view
        window.center(); loginWindow = window; present(window,view:view)
        view.load(URLRequest(url:URL(string:"https://claude.ai/settings/usage")!))
        NotificationCenter.default.post(name:.kenarConnectionsChanged,object:nil)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let view = ClaudeLoginWebView(frame:.zero,configuration:configuration); view.uiDelegate = self
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = L("Claude girişi"); window.contentView = view; window.isReleasedWhenClosed = false
        popupWindows.append(window); window.center(); present(window,view:view); return view
    }
    private func present(_ window: NSWindow, view: WKWebView?) {
        NSApp.activate(ignoringOtherApps:true)
        window.makeKeyAndOrderFront(nil)
        if let view { window.makeFirstResponder(view) }
    }
    func disconnect() async {
        Settings.shared.values.claudeSource = "disconnected"
        loginView?.stopLoading(); loginWindow?.close(); popupWindows.forEach { $0.close() }; popupWindows.removeAll()
        loginView = nil; loginWindow = nil; workspaces = []; connectionMessage = L("Hesap bağlantısı kapalı.")
        let store = WKWebsiteDataStore.default()
        let cookies: [HTTPCookie] = await withCheckedContinuation { c in store.httpCookieStore.getAllCookies { c.resume(returning: $0) } }
        for cookie in cookies where ["claude.ai", ".claude.ai"].contains(cookie.domain) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in store.httpCookieStore.delete(cookie) { c.resume() } }
        }
        Settings.shared.values.claudeWorkspace = nil
        NotificationCenter.default.post(name: .kenarConnectionsChanged, object: "claude")
    }
    func fetch() async -> ProviderSnapshot {
        var snapshot = await fetchSnapshot()
        let workspace = Settings.shared.values.claudeWorkspace ?? ""
        let account = workspace.isEmpty ? nil : QuotaScope.accountID(workspace)
        if let account { snapshot.scopeWindows(account: account, product: "claude", source: "web-account", workspace: workspace) }
        snapshot.products = [ProductConnection(id: "claude", title: "Claude", state: snapshot.error == nil ? .connected : .failed, message: snapshot.error, source: "web-account", account: account, updatedAt: snapshot.updatedAt)]
        return snapshot
    }
    private func fetchSnapshot() async -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(id:"claude",name:"Claude",systemImage:"asterisk",windows:[],error:nil)
        defer { connectionMessage = snapshot.error ?? L("Claude bağlantısı açık · %d kota penceresi",snapshot.windows.count) }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning:$0) }
        }
        guard let session = cookies.first(where: { $0.name == "sessionKey" && ["claude.ai",".claude.ai"].contains($0.domain) && ($0.expiresDate.map { $0 > Date() } ?? true) }) else {
            snapshot.error = L("Kenar ayarlarından Claude hesabını bağla; web girişini tamamla."); return snapshot
        }
        do {
            let organizations = try await request(path:"/api/organizations",cookie:session)
            guard organizations.status == 200 else { snapshot.error = failure(organizations.status); return snapshot }
            let choices = Self.parseWorkspaces(organizations.data); workspaces = choices
            let selected = Settings.shared.values.claudeWorkspace
            let active = cookies.first { $0.name == "lastActiveOrg" && ["claude.ai",".claude.ai"].contains($0.domain) }?.value
            let id = choices.first { $0.id == selected }?.id ?? choices.first { $0.id == active }?.id ?? (choices.count == 1 ? choices.first?.id : nil)
            guard let id else { snapshot.error = L("Claude hesabında çalışma alanını Kenar ayarlarından seç."); return snapshot }
            Settings.shared.values.claudeWorkspace = id
            let usage = try await request(path:"/api/organizations/\(id)/usage",cookie:session)
            guard usage.status == 200 else { snapshot.error = failure(usage.status); return snapshot }
            snapshot.windows = ClaudeProvider.parseUsage(usage.data)
            guard !snapshot.windows.isEmpty else { snapshot.error = L("Claude hesabı okunabilir kota verisi döndürmedi."); return snapshot }
            snapshot.updatedAt = Date()
        } catch { snapshot.error = L("Claude hesabına bağlanılamadı. Ağ bağlantısını kontrol et.") }
        return snapshot
    }
    nonisolated static func parseWorkspaces(_ data: Data) -> [ClaudeWorkspace] {
        guard data.count <= 2 * 1024 * 1024, let rows = (try? JSONSerialization.jsonObject(with:data)) as? [[String:Any]] else { return [] }
        return rows.prefix(256).compactMap { row in
            guard let id = row["uuid"] as? String, UUID(uuidString:id) != nil else { return nil }
            return ClaudeWorkspace(id:id,name:String((row["name"] as? String ?? id).prefix(256)))
        }
    }
    private func request(path: String, cookie: HTTPCookie) async throws -> (data:Data,status:Int) {
        // Use the user's Kenar-owned browser context when it is on Claude.
        // This keeps normal website verification and its cookies in WebKit.
        // Only fixed account metadata GETs are issued; no cookies leave JS.
        if let view = loginView, view.url?.scheme == "https", view.url?.host == "claude.ai" {
            let result = try await view.quotaJavaScript(
                "const c = new AbortController(); const t = setTimeout(() => c.abort(),15000); try { const r = await fetch(path, {credentials:'same-origin',redirect:'error',cache:'no-store',signal:c.signal}); const body = await r.text(); if (body.length > 2097152) throw new Error('Response too large'); return {status:r.status,body}; } finally { clearTimeout(t); }",
                arguments:["path":path])
            if let value = result as? [String:Any], let status = value["status"] as? Int,
               let body = value["body"] as? String, let data = body.data(using:.utf8), data.count <= 2097152 { return (data,status) }
        }
        var request = URLRequest(url:URL(string:"https://claude.ai"+path)!); request.timeoutInterval = 15
        request.setValue(HTTPCookie.requestHeaderFields(with:[cookie])["Cookie"],forHTTPHeaderField:"Cookie")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        let (data,response) = try await ProviderHTTP.session.data(for:request)
        return (data,(response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    private func failure(_ status: Int) -> String {
        switch status {
        case 401: return L("Claude web oturumu sona erdi. Ayarlardan Claude hesabını yeniden bağla.")
        case 403: return L("Claude web erişimi doğrulama istiyor. Giriş penceresini açıp işlemi tamamla.")
        case 429: return L("Claude sorgu sınırına ulaşıldı; sonraki yenilemede tekrar denenecek.")
        default: return L("HTTP %d",status)
        }
    }
}

extension Notification.Name { static let kenarConnectionsChanged = Notification.Name("Kenar.connectionsChanged") }

/// Login fields accept the first click even when the edge utility is inactive.
private final class ClaudeLoginWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
