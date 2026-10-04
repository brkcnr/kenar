import AppKit
import WebKit

struct AccountWorkspace: Identifiable { var id: String; var name: String }

/// A provider's own persistent WebKit session. Neither external browser cookies
/// nor conversation responses are imported. Requests are fixed metadata/usage
/// reads and are evaluated only on the expected HTTPS origin.
@MainActor final class AccountWebConnection: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    private static var instances: [AccountProduct: AccountWebConnection] = [:]
    static func connection(_ product: AccountProduct) -> AccountWebConnection {
        if let existing = instances[product] { return existing }
        let connection = AccountWebConnection(product: product); instances[product] = connection; return connection
    }
    let product: AccountProduct
    @Published var state: ConnectionState = .disconnected
    @Published var message: String?
    @Published var workspaces: [AccountWorkspace] = []
    private(set) var view: WKWebView?
    private var window: NSWindow?
    private var popups: [NSWindow] = []
    private var navigation: (UUID, CheckedContinuation<Bool, Never>)?
    private var retryAt: Date = .distantPast
    private var refreshPending = false
    private var lastNavigationAt: Date?
    private init(product: AccountProduct) {
        self.product = product; super.init()
        if isEnabled { state = .limited }
    }
    var isEnabled: Bool { Settings.shared.values.accountConnections?[product.rawValue] == "web" }
    var selectedWorkspace: String {
        get { Settings.shared.values.accountWorkspaces?[product.rawValue] ?? "" }
        set {
            var values = Settings.shared.values.accountWorkspaces ?? [:]; values[product.rawValue] = newValue
            Settings.shared.values.accountWorkspaces = values; changed()
        }
    }
    var sessionIdentity: String {
        let key = "account.session.v1.\(product.rawValue)"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString; UserDefaults.standard.set(id, forKey: key); return id
    }
    var knownAccount: String? { UserDefaults.standard.string(forKey: "account.identity.v1.\(product.rawValue)") }
    func rememberAccount(_ identity: String) {
        let previous = knownAccount
        UserDefaults.standard.set(identity, forKey: "account.identity.v1.\(product.rawValue)")
        if let previous, previous != identity { changed() }
    }
    func connect() {
        setSource("web"); state = .limited; message = L("Girişini tamamla, ardından resmi kullanım ekranını aç.")
        let view = makeView()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L("%@ hesabını bağla · Kenar", product.title); window.isReleasedWhenClosed = false; window.contentView = view
            let toolbar = NSToolbar(identifier: "Kenar.Account.\(product.rawValue)"); toolbar.delegate = self; window.toolbar = toolbar
            window.center(); self.window = window
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(view)
        if view.url == nil { view.load(URLRequest(url: product.usageURL)) }
        changed()
    }
    func disconnect() async {
        setSource("disconnected"); state = .disconnected; message = L("Hesap bağlantısı kapalı.")
        retryAt = .distantPast; window?.close(); popups.forEach { $0.close() }; popups.removeAll()
        view?.stopLoading(); view = nil; window = nil; finishNavigation(false)
        UserDefaults.standard.removeObject(forKey: "account.session.v1.\(product.rawValue)")
        UserDefaults.standard.removeObject(forKey: "account.identity.v1.\(product.rawValue)")
        UserDefaults.standard.removeObject(forKey: "account.page.v1.\(product.rawValue)")
        let store = WKWebsiteDataStore.default()
        let cookies: [HTTPCookie] = await withCheckedContinuation { c in store.httpCookieStore.getAllCookies { c.resume(returning: $0) } }
        // Google SSO belongs to both product sessions. Remove only this
        // product's host cookies; disconnect never logs out the other product.
        for cookie in cookies where cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == product.host {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in store.httpCookieStore.delete(cookie) { c.resume() } }
        }
        changed()
    }
    private func setSource(_ source: String) {
        var choices = Settings.shared.values.accountConnections ?? [:]; choices[product.rawValue] = source
        Settings.shared.values.accountConnections = choices
    }
    private func changed() { NotificationCenter.default.post(name: .kenarConnectionsChanged, object: product.group) }
    private func makeView() -> WKWebView {
        if let view { return view }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .default()
        let webView = AccountLoginView(frame: .zero, configuration: configuration)
        webView.uiDelegate = self; webView.navigationDelegate = self; view = webView; return webView
    }
    private func finishNavigation(_ success: Bool) {
        guard let (_, continuation) = navigation else { return }; navigation = nil; continuation.resume(returning: success)
    }
    private func navigate(_ url: URL, reload: Bool = false) async -> Bool {
        guard product.permits(url) else { return false }
        finishNavigation(false)
        let token = UUID()
        return await withCheckedContinuation { continuation in
            navigation = (token, continuation)
            let page = makeView()
            if reload, page.url == url { page.reload() } else { page.load(URLRequest(url: url)) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                if self?.navigation?.0 == token { self?.view?.stopLoading(); self?.finishNavigation(false) }
            }
        }
    }
    func prepare(refresh: Bool) async -> Bool {
        guard isEnabled else { state = .disconnected; message = L("Ayarlardan hesabını bağla."); return false }
        guard Date() >= retryAt else { return false }
        let page = makeView()
        if window?.isVisible == true {
            // Do not reload under the user's keyboard while they sign in.
            guard product.permits(page.url), !page.isLoading else { message = L("Girişini tamamla, ardından resmi kullanım ekranını aç."); return false }
            return true
        }
        let saved = UserDefaults.standard.string(forKey: "account.page.v1.\(product.rawValue)").flatMap(URL.init(string:))
        let url = saved.flatMap { product.permits($0) ? $0 : nil } ?? product.usageURL
        let success = await navigate(url, reload: refresh)
        if success { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        return success && product.permits(page.url)
    }
    func request(_ path: String, bearer: String? = nil, workspace: String? = nil) async throws -> (data: Data, status: Int) {
        guard product.permits(view?.url), let view else { throw AccountReadError.origin }
        let allowed: Set<String> = product == .cursor ? ["/api/usage-summary"] : product == .openai ? ["/api/auth/session", "/backend-api/wham/usage", "/backend-api/accounts/check/v4-2023-04-27"] : []
        guard allowed.contains(path) else { throw AccountReadError.origin }
        var headers = ["Accept": "application/json"]
        if let bearer { headers["Authorization"] = "Bearer \(bearer)" }
        if let workspace, !workspace.isEmpty { headers["ChatGPT-Account-Id"] = workspace }
        let value = try await view.quotaJavaScript("""
            const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 15000);
            try {
                const r = await fetch(path, {credentials:'same-origin', redirect:'error', cache:'no-store', headers, signal:controller.signal});
                const body = await r.text(); if (body.length > 2097152) throw new Error('Response too large');
                return {status:r.status, body};
            } finally { clearTimeout(timer); }
            """, arguments: ["path": path, "headers": headers])
        guard let result = value as? [String: Any], let status = result["status"] as? Int, let body = result["body"] as? String, let data = body.data(using: .utf8), data.count <= 2_097_152 else { throw AccountReadError.shape }
        if status == 429 { retryAt = Date().addingTimeInterval(120) }
        return (data, status)
    }
    func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { c in WKWebsiteDataStore.default().httpCookieStore.getAllCookies { c.resume(returning: $0) } }
    }
    func quotaPage() async throws -> QuotaPageCapture {
        guard product.permits(view?.url), let view else { throw AccountReadError.origin }
        if product == .geminiWeb || product == .antigravityWeb {
            _ = try await view.quotaJavaScript(QuotaPageCapture.openGoogleUsage)
        }
        let value = try await view.quotaJavaScript(QuotaPageCapture.script)
        guard let value = value as? [String: Any] else { throw AccountReadError.shape }
        let capture = QuotaPageCapture.parse(value, at: lastNavigationAt ?? Date())
        if let account = capture.account { rememberAccount(account) }
        return capture
    }
    func report(_ state: ConnectionState, _ message: String?) { self.state = state; self.message = message }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastNavigationAt = Date(); finishNavigation(true)
        if product.permits(webView.url), let url = webView.url {
            // Never persist a conversation URL. Only quota/settings routes are
            // restored. Gemini's app landing route contains no conversation ID.
            if url.path == "/" || url.path == "/app" || url.path.contains("usage") || url.path.contains("settings") || url.path == "/dashboard" {
                UserDefaults.standard.set(url.absoluteString, forKey: "account.page.v1.\(product.rawValue)")
            }
            if window?.isVisible == true, !refreshPending {
                refreshPending = true
                Task { try? await Task.sleep(nanoseconds: 2_000_000_000); refreshPending = false; NotificationCenter.default.post(name: .kenarAccountReady, object: product.group) }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishNavigation(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishNavigation(false) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if AccountNavigation.permitsLocalSubframe(url, isMainFrame: mainFrame) { decisionHandler(.allow); return }
        guard url.scheme == "https" else { decisionHandler(.cancel); return }
        if !mainFrame && url.host == "challenges.cloudflare.com" { decisionHandler(.allow); return }
        let host = url.host ?? ""
        let loginDomains = [product.host, "accounts.google.com", "auth.openai.com", "auth0.openai.com", "auth.workos.com", "auth.cursor.com", "login.cursor.com"]
        // Enterprise IdP navigation is permitted only while the user is
        // interacting with the visible login window. No API credentials are
        // attached to navigations or third-party origins.
        decisionHandler(loginDomains.contains(host) || window?.isVisible == true ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.request.url?.scheme == "https", window?.isVisible == true else { return nil }
        let popup = AccountLoginView(frame: .zero, configuration: configuration); popup.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("%@ girişi", product.title); window.contentView = popup; window.isReleasedWhenClosed = false
        popups.append(window); window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(popup)
        return popup
    }
}

extension AccountWebConnection: NSToolbarDelegate {
    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("usage"), .init("refresh"), .flexibleSpace] }
    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("usage"), .init("refresh")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier); item.target = self
        if itemIdentifier.rawValue == "usage" { item.label = L("Resmi kullanım ekranı"); item.action = #selector(openUsage) }
        else { item.label = L("Kenar’a aktar"); item.action = #selector(readUsage) }
        return item
    }
    @objc private func openUsage() { makeView().load(URLRequest(url: product.usageURL)) }
    @objc private func readUsage() { NotificationCenter.default.post(name: .kenarAccountReady, object: product.group) }
}
private final class AccountLoginView: WKWebView { override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } }
enum AccountReadError: Error { case origin, shape }
extension Notification.Name { static let kenarAccountReady = Notification.Name("Kenar.accountReady") }

extension WKWebView {
    /// Explicit callback bridge works with both SDK imports. A nil/default
    /// completion handler can select the synchronous Void overload even when
    /// written with `await`, silently discarding the script's result.
    @MainActor func quotaJavaScript(_ body: String, arguments: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            // JSON is also reliable for nested null values across WebKit SDK
            // versions; unsupported bridge object types must not erase usage.
            let wrapped = "return JSON.stringify(await (async () => {\n" + body + "\n})());"
            callAsyncJavaScript(wrapped, arguments: arguments, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    guard let json = value as? String, let data = json.data(using: .utf8), data.count <= 4_194_304,
                          let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { continuation.resume(throwing: AccountReadError.shape); return }
                    continuation.resume(returning: decoded)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
}
