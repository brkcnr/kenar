import Foundation

struct OpenAIAccountProvider: UsageProvider {
    let id = "codex"
    func fetch() async -> ProviderSnapshot { await fetch(userInitiated: false) }
    func fetch(userInitiated: Bool) async -> ProviderSnapshot {
        let source = await MainActor.run { Settings.shared.values.accountConnections?["openai"] ?? "codex" }
        if source == "codex" {
            var snapshot = await CodexProvider().fetch()
            snapshot.name = "OpenAI"
            snapshot.products = [ProductConnection(id: "codex-work", title: "Codex / Work", state: snapshot.error == nil ? .connected : .failed, message: snapshot.error, source: "codex-oauth", account: snapshot.windows.first?.scope?.account, updatedAt: snapshot.updatedAt),
                ProductConnection(id: "chatgpt-chat", title: "ChatGPT Chat", state: .disconnected, message: L("ChatGPT sohbet kotası için OpenAI hesap bağlantısını kullan."), source: "web-account")]
            return snapshot
        }
        return await WebAccountReaders.openAI()
    }
}

struct GoogleAccountProvider: UsageProvider {
    let id = "antigravity"
    func fetch() async -> ProviderSnapshot { await WebAccountReaders.google() }
}

@MainActor enum WebAccountReaders {
    private static func failure(_ status: Int) -> String {
        switch status {
        case 401: return L("Oturum sona erdi. Hesabını yeniden bağla.")
        case 403: return L("Erişim doğrulaması gerekiyor. Hesap penceresini aç.")
        case 429: return L("Sorgu sınırına ulaşıldı; sonraki yenilemede tekrar denenecek.")
        default: return L("HTTP %d", status)
        }
    }
    static func cursor() async -> ProviderSnapshot {
        let connection = AccountWebConnection.connection(.cursor)
        var snapshot = ProviderSnapshot(id: "cursor", name: "Cursor", systemImage: "cursorarrow", windows: [], error: nil)
        var product = ProductConnection(id: "cursor", title: "Cursor", state: .disconnected, source: "web-account")
        defer { snapshot.products = [product]; connection.report(product.state, product.message) }
        // Populate the identity before a request, so offline measurements can
        // be preserved only for this same session/account.
        let cookies = await connection.cookies()
        let cookie = cookies.first { $0.name == "WorkosCursorSessionToken" && ["cursor.com", ".cursor.com"].contains($0.domain) && ($0.expiresDate.map { $0 > Date() } ?? true) }
        let parts = cookie?.value.removingPercentEncoding?.components(separatedBy: "::") ?? []
        let user = parts.count == 2 && parts[0].count <= 128 && !parts[0].isEmpty ? parts[0] : nil
        var account = user.map(QuotaScope.accountID) ?? connection.knownAccount ?? QuotaScope.accountID(connection.sessionIdentity)
        product.account = account
        guard await connection.prepare(refresh: true) else {
            product.message = connection.message ?? L("Ayarlardan Cursor hesabını bağla."); snapshot.error = product.message
            snapshot.products = [product]; return snapshot
        }
        do {
            let response = try await connection.request("/api/usage-summary")
            guard response.status == 200 else {
                product.state = response.status == 401 ? .expired : .failed; product.message = failure(response.status); snapshot.error = product.message
                snapshot.products = [product]; return snapshot
            }
            let currentCookies = await connection.cookies()
            if let current = currentCookies.first(where: { $0.name == "WorkosCursorSessionToken" && ["cursor.com", ".cursor.com"].contains($0.domain) }),
               let value = current.value.removingPercentEncoding {
                let pieces = value.components(separatedBy: "::")
                if pieces.count == 2, !pieces[0].isEmpty, pieces[0].count <= 128 { account = QuotaScope.accountID(pieces[0]); product.account = account; connection.rememberAccount(account) }
            }
            snapshot.windows = CursorProvider.parseUsage(response.data)
            if snapshot.windows.isEmpty {
                let capture = try await connection.quotaPage(); snapshot.windows = capture.windows
            }
            if snapshot.windows.isEmpty {
                product.state = .limited; product.message = L("Kenar bu kaynaktan sayısal kota okuyamadı. Resmi kullanım ekranını kontrol et.")
            } else {
                product.state = snapshot.windows.contains { $0.usedPercent != nil || $0.isUnlimited || $0.resetsAt != nil } ? .connected : .limited; snapshot.updatedAt = Date()
                snapshot.scopeWindows(account: account, product: "cursor", source: "web-account")
            }
        } catch { product.state = .failed; product.message = L("Hesaba bağlanılamadı. Ağ bağlantısını kontrol et."); snapshot.error = product.message }
        snapshot.products = [product]
        return snapshot
    }
    static func openAI() async -> ProviderSnapshot {
        let connection = AccountWebConnection.connection(.openai)
        var snapshot = ProviderSnapshot(id: "codex", name: "OpenAI", systemImage: "terminal", windows: [], error: nil)
        let provisional = connection.knownAccount ?? QuotaScope.accountID(connection.sessionIdentity)
        var work = ProductConnection(id: "codex-work", title: "Codex / Work", state: .disconnected, source: "web-account", account: provisional)
        var chat = ProductConnection(id: "chatgpt-chat", title: "ChatGPT Chat", state: .disconnected, source: "web-account", account: provisional)
        guard await connection.prepare(refresh: false) else {
            snapshot.error = connection.message ?? L("Ayarlardan OpenAI hesabını bağla.")
            work.message = snapshot.error; chat.message = snapshot.error; snapshot.products = [work, chat]; return snapshot
        }
        do {
            let session = try await connection.request("/api/auth/session")
            guard session.status == 200, let root = (try? JSONSerialization.jsonObject(with: session.data)) as? [String: Any], let token = root["accessToken"] as? String, !token.isEmpty else {
                work.state = .expired; chat.state = .expired; snapshot.error = L("Oturum sona erdi. Hesabını yeniden bağla.")
                work.message = snapshot.error; chat.message = snapshot.error; snapshot.products = [work, chat]
                connection.report(.expired, snapshot.error); return snapshot
            }
            let user = (root["user"] as? [String: Any])?["id"] as? String
            let account = QuotaScope.accountID(user ?? connection.sessionIdentity); work.account = account; chat.account = account
            connection.rememberAccount(account)
            let choices = try await connection.request("/backend-api/accounts/check/v4-2023-04-27", bearer: token)
            if choices.status == 200 { connection.workspaces = parseOpenAIWorkspaces(choices.data) }
            let selected = connection.selectedWorkspace
            let workspace = connection.workspaces.first { $0.id == selected }?.id ?? (connection.workspaces.count == 1 ? connection.workspaces.first?.id : nil)
            if connection.workspaces.count > 1 && workspace == nil {
                snapshot.error = L("Çalışma alanını Kenar ayarlarından seç."); work.message = snapshot.error
            } else {
                let usage = try await connection.request("/backend-api/wham/usage", bearer: token, workspace: workspace)
                if usage.status == 200 {
                    snapshot.windows = CodexProvider.parseUsage(usage.data)
                    work.state = snapshot.windows.isEmpty ? .limited : .connected
                    work.message = snapshot.windows.isEmpty ? L("Kullanım yüzdesi paylaşılmıyor.") : nil
                    snapshot.updatedAt = Date(); snapshot.scopeWindows(account: account, product: "codex-work", source: "web-account", workspace: workspace ?? "")
                } else { work.state = usage.status == 401 ? .expired : .failed; work.message = failure(usage.status) }
            }
            // Ordinary Chat does not inherit wham/Codex usage. A narrowly scoped
            // official usage card may provide meters; otherwise keep it unknown.
            let capture = try? await connection.quotaPage()
            // Generic "Usage" cards can contain agentic usage. Only explicit
            // ChatGPT Chat/model quota labels belong to the ordinary Chat pool.
            let chatWindows = (capture?.windows ?? []).filter { $0.label.lowercased().contains("chatgpt chat") }
            chat.state = chatWindows.isEmpty ? .limited : .connected
            chat.message = chatWindows.isEmpty ? L("Kullanım yüzdesi paylaşılmıyor. Codex / Work kotasından ayrıdır.") : nil
            for var window in chatWindows {
                window.scope = QuotaScope(account: account, workspace: workspace ?? "", product: "chatgpt-chat", pool: window.id, source: "web-account")
                snapshot.windows.append(window)
            }
            if snapshot.windows.isEmpty && work.state == .failed { snapshot.error = work.message }
            work.updatedAt = snapshot.updatedAt; chat.updatedAt = capture?.measuredAt
            snapshot.products = [work, chat]; connection.report(work.state, work.message ?? chat.message)
        } catch {
            work.state = .failed; chat.state = .failed; snapshot.error = L("Hesaba bağlanılamadı. Ağ bağlantısını kontrol et.")
            work.message = snapshot.error; chat.message = snapshot.error; snapshot.products = [work, chat]; connection.report(.failed, snapshot.error)
        }
        return snapshot
    }
    static func parseOpenAIWorkspaces(_ data: Data) -> [AccountWorkspace] {
        guard data.count <= 2_097_152, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let accounts = root["accounts"] as? [String: Any] else { return [] }
        return accounts.keys.sorted().prefix(128).compactMap { id in
            guard id.count <= 128, let container = accounts[id] as? [String: Any] else { return nil }
            let account = container["account"] as? [String: Any] ?? container
            return AccountWorkspace(id: id, name: String((account["name"] as? String ?? account["account_type"] as? String ?? id).prefix(160)))
        }
    }
    static func google() async -> ProviderSnapshot {
        async let gemini = googleProduct(.geminiWeb)
        async let antigravity = googleProduct(.antigravityWeb)
        let results = await [gemini, antigravity]
        var snapshot = ProviderSnapshot(id: "antigravity", name: "Google", systemImage: "sparkles", windows: results.flatMap(\.windows), error: nil)
        snapshot.products = results.flatMap(\.products)
        snapshot.updatedAt = results.compactMap(\.updatedAt).max()
        if snapshot.windows.isEmpty, snapshot.products.allSatisfy({ [.disconnected, .expired, .failed].contains($0.state) }) {
            snapshot.error = L("Ayarlardan Gemini veya Antigravity hesabını bağla.")
        }
        return snapshot
    }
    private static func googleProduct(_ product: AccountProduct) async -> ProviderSnapshot {
        let productID = product == .geminiWeb ? "gemini-web" : "antigravity"
        let connection = AccountWebConnection.connection(product)
        let source = Settings.shared.values.accountConnections?[product.rawValue] ?? "disconnected"
        if product == .antigravityWeb && source == "bridge" {
            var snapshot = await AntigravityProvider().fetch()
            let account = QuotaScope.accountID("local-agy-bridge")
            snapshot.scopeWindows(account: account, product: "antigravity", source: "agy-bridge")
            if let error = snapshot.error { for i in snapshot.windows.indices { snapshot.windows[i].issue = error } }
            snapshot.products = [ProductConnection(id: "antigravity", title: "Antigravity", state: snapshot.error == nil ? .connected : .failed, message: snapshot.error ?? L("Yerel agy aktarımı · CLI oturumu gerekir."), source: "agy-bridge", account: account, updatedAt: snapshot.updatedAt)]
            return snapshot
        }
        var snapshot = ProviderSnapshot(id: "antigravity", name: "Google", systemImage: "sparkles", windows: [], error: nil)
        var account = connection.knownAccount ?? QuotaScope.accountID(connection.sessionIdentity)
        var status = ProductConnection(id: productID, title: product.title, state: .disconnected, source: "web-account", account: account)
        guard await connection.prepare(refresh: true) else {
            status.message = connection.message ?? L("Ayarlardan hesabını bağla."); snapshot.products = [status]; return snapshot
        }
        do {
            let page = try await connection.quotaPage()
            if let current = page.account { account = current; status.account = current }
            if !page.windows.isEmpty {
                snapshot.windows = page.windows; snapshot.updatedAt = page.measuredAt
                snapshot.scopeWindows(account: account, product: productID, source: "web-account")
                status.state = .connected; status.updatedAt = snapshot.updatedAt
            } else if page.signedIn || page.foundUsage {
                status.state = .limited; status.message = L("Kenar bu kaynaktan sayısal kota okuyamadı. Resmi kullanım ekranını kontrol et.")
            } else {
                status.state = .disconnected; status.message = L("Girişini tamamla, ardından resmi kullanım ekranını aç.")
            }
        } catch { status.state = .failed; status.message = L("Hesaba bağlanılamadı. Ağ bağlantısını kontrol et.") }
        snapshot.products = [status]; connection.report(status.state, status.message); return snapshot
    }
}
