import AppKit
import SwiftUI
import Charts

@MainActor final class PanelState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var selected: String?
}

struct PanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: Settings
    @ObservedObject var state: PanelState
    @Environment(\.colorScheme) private var colorScheme
    var openSettings: () -> Void
    var openAnalytics: (Bool) -> Void
    var close: () -> Void
    private var providers: [ProviderSnapshot] { store.snapshots.filter { !settings.values.hiddenProviders.contains($0.id) } }
    private var compactProviders: [ProviderSnapshot] { store.compactProviders(hiddenProviders: settings.values.hiddenProviders) }
    private var shape: EdgeIslandShape { EdgeIslandShape(edge: settings.values.edge) }
    var body: some View {
        ZStack {
            IslandMaterial()
            if state.expanded {
                (colorScheme == .dark ? Color.black : Color.white).opacity(0.28 + settings.values.opacity * 0.42)
                content.transition(.opacity)
            } else {
                Color.black.opacity(0.94)
                compact.foregroundStyle(.white).environment(\.colorScheme, .dark).transition(.opacity)
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(state.expanded ? 0.05 : 0),lineWidth: 0.5))
        .preferredColorScheme(settings.scheme)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.16),value: state.expanded)
        .environment(\.locale, DisplayFormat.locale)
        .font(.system(size: settings.values.fontSize))
        .onExitCommand(perform: close)
        .contextMenu {
            Button(L("Şimdi yenile")) { store.refreshAll(userInitiated: true) }
            ForEach(providers.filter { $0.error != nil }) { snap in
                Button(L("Retry %@ connection", snap.name)) { store.retryConnection(providerID: snap.id) }
                    .disabled(store.isRefreshing)
            }
            Button(L("Ayarlar"), action: openSettings)
            Divider()
            Button(L("Kenar’dan çık")) { NSApplication.shared.terminate(nil) }
        }
    }
    private var compact: some View {
        VStack(spacing: 0) { compactItems }.padding(.vertical,24)
        .frame(maxWidth: .infinity,maxHeight: .infinity)
        .contentShape(shape)
        .onTapGesture { state.expanded = true }
        .help(Preview.isEnabled ? L("Kenar · Önizleme, örnek veriler") : compactProviders.isEmpty ? L("Kenar · Bağlantı bekleniyor; ayrıntıları aç") : L("Kenar · Kullanım panelini aç"))
        .accessibilityLabel(Preview.isEnabled ? L("Kenar önizleme adası · örnek veriler") : L("Kenar kullanım adası"))
    }
    @ViewBuilder private var compactItems: some View {
        if compactProviders.isEmpty { Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 42,height: 42).accessibilityLabel(L("Bağlantı bekleniyor; sağlayıcı ayrıntılarını aç")) }
        ForEach(compactProviders) { snap in
            VStack(spacing: 3) {
                ZStack {
                    Circle().stroke(.white.opacity(0.14),lineWidth: 1.5)
                    if let percent = snap.primary?.usedPercent {
                        Circle().trim(from: 0,to: min(max(percent/100,0),1))
                            .stroke(indicatorColor(snap),style: StrokeStyle(lineWidth: 1.5,lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    ProviderGlyph(id: snap.id,size: 13)
                }.frame(width: 24,height: 24)
                Text(value(snap)).font(.system(size: 9,weight: .medium)).monospacedDigit()
                    .foregroundStyle(snap.isStale ? .orange : .white.opacity(0.8))
            }.frame(width: 66,height: 42)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(snap.name), \(value(snap))\(snap.isStale ? L(", güncel değil") : "")\(Preview.isEnabled ? L(", örnek veri") : "")")
        }
        if Preview.isEnabled {
            Text(L("Örnek")).font(.system(size: 7)).foregroundStyle(.orange.opacity(0.85))
                .frame(width: 66,height: 12)
        }
    }
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Kenar").font(.system(size: 12,weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { state.pinned.toggle() } label: { Image(systemName: state.pinned ? "pin.fill" : "pin").foregroundStyle(state.pinned ? .primary : .secondary) }
                    .help(L("Paneli sabitle")).accessibilityLabel(state.pinned ? L("Sabitlemeyi kaldır") : L("Paneli sabitle"))
                Button(action: openSettings) { Image(systemName: "slider.horizontal.3") }.help(L("Ayarlar")).accessibilityLabel(L("Ayarlar"))
                Button(action: close) { Image(systemName: collapseIcon) }.help(L("Adaya daralt")).accessibilityLabel(L("Adaya daralt"))
            }.font(.system(size: 11)).buttonStyle(.borderless).foregroundStyle(.secondary).padding(.bottom,10)
            if Preview.isEnabled {
                Text(L("Önizleme · Örnek veriler")).font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity,alignment: .leading).padding(.bottom,7)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(providers) { snap in
                        providerRow(snap)
                        if state.selected == snap.id {
                            VStack(alignment: .leading,spacing: 10) {
                                if snap.products.isEmpty {
                                    ForEach(snap.windows) { window in metric(window,color: indicatorColor(snap)) }
                                } else {
                                    ForEach(snap.products) { product in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(product.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                            ForEach(snap.windows.filter { $0.scope?.product == product.id }) { window in metric(window,color: indicatorColor(snap)) }
                                            if let message = product.message { Text(L(message)).font(.system(size: 10)).foregroundStyle(product.state == .failed || product.state == .expired ? .orange : .secondary) }
                                            if product.source == "agy-bridge" || product.source == "codex-oauth" { Text(L("İsteğe bağlı yerel bağlantı")).font(.system(size: 9)).foregroundStyle(.tertiary) }
                                        }
                                    }
                                }
                                if snap.windows.isEmpty && snap.products.isEmpty { Text(L(snap.error ?? L("Kota verisi bekleniyor…"))).font(.system(size: 11)).foregroundStyle(.secondary) }
                                if snap.isStale { Text(L(snap.error ?? L("Bu ölçüm güncel değil."))).font(.system(size: 10)).foregroundStyle(.orange) }
                                if snap.error != nil {
                                    Button(L("Retry connection")) { store.retryConnection(providerID: snap.id) }
                                        .buttonStyle(.borderless).font(.system(size: 11)).disabled(store.isRefreshing)
                                }
                            }.padding(12).background(Color.primary.opacity(0.035),in: RoundedRectangle(cornerRadius: 12)).padding(.vertical,6)
                        }
                    }
                    if providers.isEmpty { Text(L("Ayarlardan görünür sağlayıcı seç.")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical,20) }
                }
            }.scrollIndicators(.hidden)
            Divider().opacity(0.45).padding(.top,8).padding(.bottom,10)
            HStack(spacing: 18) {
                Button { openAnalytics(false) } label: { Image(systemName: "clock.arrow.circlepath") }.help(L("Kullanım geçmişi")).accessibilityLabel(L("Kullanım geçmişi"))
                Button { openAnalytics(true) } label: { Image(systemName: "folder") }.help(L("Proje analizi")).accessibilityLabel(L("Proje analizi"))
                Spacer()
                if let error = store.storageError { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(L(error)).accessibilityLabel(L(error)) }
                Text(store.isRefreshing ? L("Yenileniyor") : Preview.isEnabled ? L("Örnek") : store.lastRefresh == nil ? L("Bekleniyor") : store.lastRefresh.map { DisplayFormat.date($0,timeOnly: true) } ?? "")
                    .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                Button { store.refreshAll(userInitiated: true) } label: { Image(systemName: "arrow.clockwise") }.disabled(store.isRefreshing).help(L("Şimdi yenile")).accessibilityLabel(L("Şimdi yenile"))
            }.font(.system(size: 11)).buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal,18).padding(.vertical,30)
    }
    private var collapseIcon: String {
        switch settings.values.edge { case .right: return "chevron.right"; case .left: return "chevron.left" }
    }
    private func value(_ snap: ProviderSnapshot) -> String {
        if snap.primary?.isUnlimited == true { return "∞" }
        return snap.primary?.usedPercent.map { DisplayFormat.percent($0) } ?? "—"
    }
    private func indicatorColor(_ snap: ProviderSnapshot) -> Color {
        if snap.isStale { return .orange }
        if let percent = snap.primary?.usedPercent {
            if percent >= 90 { return .red }
            if percent >= 75 { return .orange }
        }
        return state.expanded ? .primary.opacity(0.65) : .white.opacity(0.8)
    }
    private func providerRow(_ snap: ProviderSnapshot) -> some View {
        Button { state.selected = state.selected == snap.id ? nil : snap.id } label: {
            HStack(spacing: 12) {
                ProviderGlyph(id: snap.id,size: 19).frame(width: 24).foregroundStyle(.primary.opacity(0.9))
                VStack(alignment: .leading,spacing: 5) {
                    HStack {
                        Text(snap.name).font(.system(size: settings.values.fontSize,weight: .medium))
                        Spacer(minLength: 8)
                        Text(snap.primary?.isUnlimited == true ? L("Sınırsız") : value(snap)).font(.system(size: 12,weight: .medium)).monospacedDigit()
                        Image(systemName: state.selected == snap.id ? "chevron.up" : "chevron.down").font(.system(size: 7,weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    if let w = snap.primary,w.usedPercent != nil {
                        ProgressBar(fraction: w.fraction,color: indicatorColor(snap),height: 3)
                        TimelineView(.periodic(from: .now,by: 1)) { tick in
                            Text(snap.isStale ? L("Güncel değil") : [w.productTitle, w.countdown(at: tick.date) ?? L("Yenilenme bilinmiyor")].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 9)).foregroundStyle(snap.isStale ? .orange : .secondary).lineLimit(1)
                        }
                    } else {
                        Text(snap.error == nil ? snap.primary?.isUnlimited == true ? L("Kota sınırı yok") : snap.products.contains(where: { $0.state == .limited }) ? L("Kullanım yüzdesi paylaşılmıyor.") : L("Veri bekleniyor") : L("Bağlantıyı kontrol et"))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }.padding(.vertical,8).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L("%@, %@; kota ayrıntıları",snap.name,value(snap)))
    }
    private func metric(_ window: UsageWindow,color: Color) -> some View {
        VStack(alignment: .leading,spacing: 5) {
            HStack { Text(window.title).font(.system(size: 11,weight: .medium)).lineLimit(1); Spacer(); Text(window.isUnlimited ? L("Sınırsız") : window.usedPercent.map { DisplayFormat.percent($0) } ?? L("Bilinmiyor")).font(.system(size: 11)).monospacedDigit() }
            if window.usedPercent != nil { ProgressBar(fraction: window.fraction,color: color,height: 3) }
            TimelineView(.periodic(from: .now,by: 1)) { tick in Text(window.issue ?? window.countdown(at: tick.date) ?? L("Yenilenme zamanı bilinmiyor")).font(.system(size: 9)).foregroundStyle(.secondary) }
            if window.unit != "quota" { Text(window.unit == "REQUESTS" ? L("İstek kotası") : L("Ölçüm: %@",window.unit)).font(.system(size: 9)).foregroundStyle(.secondary) }
        }.frame(minHeight: 48,alignment: .top)
    }
}

struct ProgressBar: View {
    var fraction: Double; var color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: proxy.size.width * min(max(fraction,0),1))
            }
        }.frame(height: height).accessibilityValue(DisplayFormat.percent(fraction * 100))
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var screens = NSScreen.screens
    @State private var login = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @State private var tab = 0
    @State private var agySetupMessage: String?
    @State private var claudeSetupMessage: String?
    @ObservedObject private var claudeWeb = ClaudeWebConnection.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading) { Text(L("Kenar Ayarları")).font(.title2.weight(.semibold)); Text(L("Paneli çalışma biçimine göre düzenle.")).foregroundStyle(.secondary) }; Spacer() }
            Picker(L("Bölüm"),selection: $tab) { Text(L("Görünüm")).tag(0); Text(L("Bildirimler")).tag(1); Text(L("Sağlayıcılar")).tag(2) }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading,spacing: 18) {
                    if tab == 0 { appearance }
                    if tab == 1 { notifications }
                    if tab == 2 { providers }
                }.padding(4)
            }
            Divider()
            HStack { Text("\(settings.language.title) · Kenar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")").font(.caption).foregroundStyle(.secondary); Spacer(); Button(L("Kenar’dan çık")) { NSApp.terminate(nil) } }
        }.padding(24).frame(width: 480,height: 600).preferredColorScheme(settings.scheme)
        .environment(\.locale, DisplayFormat.locale)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in screens = NSScreen.screens }
        .onChange(of: settings.values.hiddenProviders) { _ in Notifier.shared.preferencesChanged() }
    }
    private var appearance: some View {
        VStack(alignment: .leading,spacing: 16) {
            Picker(L("Dil"),selection: Binding(get: { settings.language },set: { settings.values.language = $0 })) {
                ForEach(AppLanguage.allCases,id: \.self) { language in Text(language.title).tag(language) }
            }
            Picker(L("Monitör"),selection: Binding(get: { settings.values.displayID ?? 0 },set: { settings.values.displayID = $0 == 0 ? nil : $0 })) {
                Text(L("Ana monitör")).tag(UInt32(0))
                ForEach(screens,id: \.self) { screen in Text(screen.localizedName).tag(DisplayGeometry.screenID(screen) ?? 0) }
            }
            Picker(L("Ekran kenarı"),selection: $settings.values.edge) { ForEach(PanelEdge.allCases,id: \.self) { Text($0.title).tag($0) } }
            Picker(L("Tema"),selection: $settings.values.theme) { ForEach(PanelTheme.allCases,id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            slider(L("Panel genişliği"), value: $settings.values.width, range: 260...440, suffix: "pt")
            slider(L("Yüzey yoğunluğu"), value: $settings.values.opacity, range: 0.3...1, suffix: "%", multiplier: 100)
            slider(L("Yazı boyutu"), value: $settings.values.fontSize, range: 12...16, suffix: "pt")
            Picker(L("Vurgu rengi"),selection: $settings.values.accent) { Text(L("Turkuaz")).tag("teal"); Text(L("Mavi")).tag("blue"); Text(L("Mor")).tag("purple"); Text(L("Turuncu")).tag("orange") }
            Toggle(L("Girişte başlat"),isOn: $login).onChange(of: login) { enabled in
                if !LaunchAtLogin.set(enabled) { loginError = L("Girişte başlatma değiştirilemedi. Uygulamayı Applications klasöründen çalıştırıp tekrar dene."); login = LaunchAtLogin.isEnabled }
            }
            if let loginError { Text(L(loginError)).font(.caption).foregroundStyle(.orange) }
        }
    }
    private func slider(_ title: String,value: Binding<Double>,range: ClosedRange<Double>,suffix: String,multiplier: Double = 1) -> some View {
        VStack(alignment: .leading,spacing: 6) { HStack { Text(title); Spacer(); Text(suffix == "%" ? DisplayFormat.percent(Int(value.wrappedValue*multiplier)) : "\(Int(value.wrappedValue*multiplier)) \(suffix)").foregroundStyle(.secondary).monospacedDigit() }; Slider(value: value,in: range) }
    }
    private var notifications: some View {
        VStack(alignment: .leading,spacing: 16) {
            Toggle(L("Kullanım uyarıları"),isOn: $settings.values.notifications).onChange(of: settings.values.notifications) { _ in Notifier.shared.preferencesChanged() }
            Toggle(L("Yenilenme zamanı bildirimi"),isOn: $settings.values.resetNotifications).onChange(of: settings.values.resetNotifications) { _ in Notifier.shared.preferencesChanged() }
            Text(L("Her eşik, aynı kota döneminde yalnızca bir kez bildirilir.")).font(.caption).foregroundStyle(.secondary)
            ForEach(AccountGroup.ids,id: \.self) { id in
                VStack(alignment: .leading,spacing: 6) {
                    Text(AccountGroup.name(id)).fontWeight(.semibold)
                    HStack {
                        ForEach(0..<3,id: \.self) { index in
                            Stepper(value: Binding(get: { settings.values.thresholds[id]?[index] ?? [75,90,100][index] },set: { new in var list = settings.values.thresholds[id] ?? [75,90,100]; list[index] = new; settings.values.thresholds[id] = list }), in: 1...100) {
                                Text(DisplayFormat.percent(settings.values.thresholds[id]?[index] ?? [75,90,100][index])).monospacedDigit()
                            }
                        }
                    }
                }
            }
            Button(L("Bildirim göndererek test et")) { Notifier.shared.requestAuthorizationIfNeeded(); Notifier.shared.test() }.disabled(!settings.values.notifications)
            Text(L("Bildirim görünmüyorsa Sistem Ayarları → Bildirimler → Kenar bölümünü kontrol et.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var providers: some View {
        VStack(alignment: .leading,spacing: 16) {
            ForEach(AccountGroup.ids,id: \.self) { id in
                Toggle(L("%@ göster",AccountGroup.name(id)),isOn: Binding(get: { !settings.values.hiddenProviders.contains(id) },set: { enabled in settings.values.hiddenProviders.removeAll { $0 == id }; if !enabled { settings.values.hiddenProviders.append(id) } }))
            }
            Divider()
            Text(L("Claude hesabı")).fontWeight(.semibold)
            Text(L("Aynı hesaptaki Web, Desktop, Code ve Cowork ortak kotayı kullanır. Ayrı sağlayıcılar olarak tekrar sayılmaz.")).font(.caption).foregroundStyle(.secondary)
            Picker(L("Claude bağlantısı"),selection:Binding(get:{ settings.values.claudeSource ?? "automatic" },set:{ settings.values.claudeSource = $0; NotificationCenter.default.post(name:.kenarConnectionsChanged,object:nil) })) {
                Text(L("Otomatik · Code aktarımı ve OAuth")).tag("automatic")
                Text(L("Claude hesabı · Web girişi")).tag("web")
                Text(L("Code kimlik bilgileri")).tag("oauth")
            }
            HStack {
                Button(L(settings.values.claudeSource == "web" ? "Yeniden bağla" : "Bağla")) { claudeWeb.connect() }
                Button(L("Bağlantıyı kes")) { Task { await claudeWeb.disconnect() } }.disabled(settings.values.claudeSource == "disconnected")
                Button(L("Code kota aktarımını bağla")) {
                    do {
                        let launcher = try ClaudeQuotaBridge.install(executable:Bundle.main.executableURL!)
                        claudeSetupMessage = L("Code bağlantısı hazır: %@. Ayarlar otomatik yenilenir; kota alanları ilk model yanıtından sonra gelir.",launcher.path)
                        settings.values.claudeSource = "automatic"
                        NotificationCenter.default.post(name:.kenarConnectionsChanged,object:nil)
                    } catch { claudeSetupMessage = error.localizedDescription }
                }
            }
            if settings.values.claudeSource == "web", !claudeWeb.workspaces.isEmpty {
                Picker(L("Çalışma alanı"),selection:Binding(get:{ settings.values.claudeWorkspace ?? "" },set:{ settings.values.claudeWorkspace = $0; NotificationCenter.default.post(name:.kenarConnectionsChanged,object:nil) })) {
                    Text(L("Seç")).tag("")
                    ForEach(claudeWeb.workspaces) { Text($0.name).tag($0.id) }
                }
            }
            if settings.values.claudeSource == "web", let message = claudeWeb.connectionMessage { Text(message).font(.caption).textSelection(.enabled) }
            if let claudeSetupMessage { Text(claudeSetupMessage).font(.caption).textSelection(.enabled) }
            Text(L("Web girişi Kenar’ın kendi oturumunda saklanır; başka tarayıcının çerezleri okunmaz.")).font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(AccountProduct.allCases) { product in
                AccountConnectionControls(product: product, settings: settings)
                Divider()
            }
            DisclosureGroup(L("İsteğe bağlı CLI bağlantıları")) {
                VStack(alignment: .leading, spacing: 12) {
                    sourcePicker("OpenAI", key: "openai", alternative: "codex", title: "Codex OAuth")
                    sourcePicker("Cursor", key: "cursor", alternative: "cli", title: "Cursor CLI")
                    sourcePicker("Antigravity", key: "antigravity-web", alternative: "bridge", title: "agy status line")
                    Button(L("Antigravity’yi bağla")) {
                        do {
                            let launcher = try AntigravityIntegration.install(executable: Bundle.main.executableURL!)
                            agySetupMessage = L("Açık agy oturumunda çalıştır: /statusline %@. Ardından /usage ile kotayı yenile.", launcher.path)
                            var choices = settings.values.accountConnections ?? [:]; choices["antigravity-web"] = "bridge"; settings.values.accountConnections = choices
                            NotificationCenter.default.post(name: .kenarConnectionsChanged, object: "antigravity")
                        } catch { agySetupMessage = error.localizedDescription }
                    }
                    if let agySetupMessage { Text(agySetupMessage).font(.caption).textSelection(.enabled) }
                    Text(L("agy aktarımı açık CLI gerektirir. Hesap bağlantıları ayrı çalışır; diğer uygulamalardaki oturumlar değiştirilmez.")).font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
            Divider()
            Text(L("Brink temelinde geliştirilmiştir · MIT lisansı")).font(.caption)
            Link(L("Kaynak proje"),destination: URL(string:"https://github.com/semihtalii/brink")!)
        }
    }
    private func sourcePicker(_ label: String, key: String, alternative: String, title: String) -> some View {
        Picker(label, selection: Binding(get: { settings.values.accountConnections?[key] ?? "disconnected" }, set: { value in
            var choices = settings.values.accountConnections ?? [:]; choices[key] = value; settings.values.accountConnections = choices
            let group = key == "openai" ? "codex" : key == "cursor" ? "cursor" : "antigravity"
            NotificationCenter.default.post(name: .kenarConnectionsChanged, object: group)
        })) {
            Text(L("Hesap bağlantısı")).tag("web")
            Text(title).tag(alternative)
            Text(L("Bağlantı kapalı")).tag("disconnected")
        }
    }

}

struct AnalyticsView: View {
    let store: AnalyticsStore?
    @State var tab: Int
    @State private var provider = "codex"
    @State private var meter = ""
    @State private var account = ""
    @State private var days = 7
    @State private var range: AnalysisRange = .week
    @State private var points: [QuotaPoint] = []
    @State private var rows: [ProjectRow] = []
    @State private var attribution: [Attribution] = []
    @State private var loading = false
    @State private var generation = UUID()
    @ObservedObject var settings: Settings
    private var accounts: [String] { Array(Set(points.map(\.account))).sorted() }
    private var accountPoints: [QuotaPoint] { points.filter { account.isEmpty || $0.account == account } }
    private var meters: [String] { Array(Set(accountPoints.map(\.meter))).sorted() }
    private var plotted: [QuotaPoint] { QuotaSeries.downsample(accountPoints.filter { $0.meter == meter }) }
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            HStack { VStack(alignment: .leading,spacing: 4) { Text(L("Kullanım ve Projeler")).font(.title2.weight(.semibold)); Text(L("Hesap kotası ve bu Mac’teki token tüketimi")).foregroundStyle(.secondary) }; Spacer(); if loading { ProgressView().controlSize(.small) } }
            HStack {
                Picker(L("Sağlayıcı"),selection: $provider) { Text("OpenAI").tag("codex"); Text("Claude").tag("claude"); Text("Cursor").tag("cursor"); Text("Google").tag("antigravity"); Text("Gemini (legacy)").tag("gemini") }.frame(width: 180)
                Spacer()
                Picker(L("Görünüm"),selection: $tab) { Text(L("Geçmiş")).tag(0); Text(L("Proje analizi")).tag(1) }.pickerStyle(.segmented).frame(width: 240)
            }
            if Preview.isEnabled { Label(L("ÖNİZLEME · Örnek veriler; geçmiş kaydedilmez."),systemImage: "eye").foregroundStyle(.orange) }
            else if store == nil { Text(L("Yerel veritabanı açılamadı. Uygulamanın veri klasörüne yazabildiğini kontrol et.")).foregroundStyle(.orange) }
            if tab == 0 { history } else { projects }
            Spacer(minLength: 0)
            Divider()
            Text(L("Veriler bu Mac’te saklanır · Kota geçmişi 90 gün · Konuşma içeriği kaydedilmez")).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 720,minHeight: 550).preferredColorScheme(settings.scheme)
        .environment(\.locale, DisplayFormat.locale)
        .onAppear(perform: load).onChange(of: provider) { _ in meter = ""; load() }.onChange(of: days) { _ in load() }
        .onChange(of: account) { _ in meter = meters.first ?? ""; loadAttribution() }.onChange(of: range) { _ in load() }.onChange(of: meter) { _ in loadAttribution() }
        .onReceive(NotificationCenter.default.publisher(for: .kenarDataChanged)) { _ in load() }
    }
    private var history: some View {
        VStack(alignment: .leading,spacing: 16) {
            if !accounts.isEmpty {
                Picker(L("Hesap"), selection: $account) {
                    Text(L("Tüm hesaplar")).tag("")
                    ForEach(accounts, id: \.self) { id in Text(id == "legacy-unassigned" ? L("Eski kayıtlar · Hesap bilinmiyor") : L("Hesap %@", String(id.suffix(8)))).tag(id) }
                }
            }
            HStack {
                Picker(L("Dönem"),selection: $days) { Text(L("Bugün")).tag(1); Text(L("7 gün")).tag(7); Text(L("30 gün")).tag(30); Text(L("90 gün")).tag(90) }.pickerStyle(.segmented)
                if !meters.isEmpty { Picker(L("Model / Kota"),selection: $meter) { ForEach(meters,id: \.self) { value in Text(L(points.first { $0.meter == value }?.title ?? value)).tag(value) } }.frame(width: 220) }
            }
            if plotted.isEmpty { empty(L("Henüz kota ölçümü yok"), detail: L("Başarılı yenilemeler geldikçe günlük ve haftalık geçmiş burada oluşacak.")) }
            else {
                Chart(plotted) { point in
                    LineMark(x: .value(L("Zaman"),point.date),y: .value(L("Kullanım"),point.percent),series: .value(L("Kota dönemi"),point.period)).foregroundStyle(settings.color)
                    PointMark(x: .value(L("Zaman"),point.date),y: .value(L("Kullanım"),point.percent)).foregroundStyle(settings.color).symbolSize(12)
                }.chartYScale(domain: 0...max(100,plotted.map(\.percent).max() ?? 100)).chartYAxisLabel(L("Kullanılan kota (%)")).frame(height: 260)
                Text(L("Çizgiler farklı kota dönemleri arasında bağlanmaz. Kota yenilenmesi tüketim artışı sayılmaz.")).font(.caption).foregroundStyle(.secondary)
                HStack { Text(L("%d ölçüm",points.filter { $0.meter == meter }.count)); Spacer(); if let latest = plotted.last { Text(L("Son ölçüm: %@ · %@",DisplayFormat.percent(latest.percent),DisplayFormat.date(latest.date))) } }.font(.caption)
            }
        }
    }
    private var projects: some View {
        VStack(alignment: .leading,spacing: 14) {
            Picker(L("Aralık"),selection: $range) { ForEach(AnalysisRange.allCases,id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            if provider == "cursor" { empty(L("Cursor proje kırılımı sunmuyor"), detail: L("Bağlı kullanım kaynağı hesap toplamını veriyor. Toplam kullanım geçmişini Geçmiş sekmesinde görebilirsin.")) }
            else if rows.isEmpty { empty(L("Bu aralıkta yerel token kaydı yok"),detail: L("Claude Code, Codex, Antigravity ve eski Gemini CLI oturumlarının yerel token kayıtları otomatik aktarılır.")) }
            else {
                Text(range == .session ? L("Bu sağlayıcının en son yerel oturumu") : L("Yerel token tüketimi")).font(.headline)
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(rows) { row in
                            VStack(alignment: .leading,spacing: 6) {
                                HStack { Label(row.title,systemImage: "folder").fontWeight(.medium); Spacer(); Text(DisplayFormat.number(row.tokens)).monospacedDigit(); Text("token").foregroundStyle(.secondary) }
                                ProgressBar(fraction: Double(row.tokens)/Double(max(1,rows.map(\.tokens).reduce(0,+))),color: settings.color)
                                HStack { Text(L("Girdi %@ · Çıktı %@ · Önbellek okuma %@%@",DisplayFormat.number(row.input),DisplayFormat.number(row.output),DisplayFormat.number(row.cached),row.cacheWrite > 0 ? L(" · Yazma %@",DisplayFormat.number(row.cacheWrite)) : "")).font(.caption).foregroundStyle(.secondary) }
                            }.padding(12).background(Color.primary.opacity(0.04),in: RoundedRectangle(cornerRadius: 10)).help(row.project)
                        }
                        Text(L("Web kullanımı yerel proje tokenlarına eklenmez; bu ekran yalnızca bu Mac’teki oturum kayıtlarını gösterir.")).font(.caption).foregroundStyle(.secondary)
                        Text(L("Tokenlar sağlayıcılar arasında aynı kota veya maliyet anlamına gelmez. Önbellek okuması ayrıca gösterilir; Claude ve Antigravity’nin ayrı önbellek okuma sayaçları toplamın dışında tutulur.")).font(.caption).foregroundStyle(.secondary)
                        if provider == "antigravity" {
                            Text(L("Antigravity toplamı çağrı kayıtlarından hesaplanır; reasoning çıktı içinde sayılır. Proje, oturumun çalışma dizinine göre belirlenir. Kota grubu ile model eşlemesi doğrulanmadığından kota payı tahmini gösterilmez.")).font(.caption).foregroundStyle(.secondary)
                        } else if range != .session && !plotted.contains(where: { $0.source == "web-account" }) { attributionView }
                    }
                }
            }
        }
    }
    private var attributionView: some View {
        VStack(alignment: .leading,spacing: 8) {
            Divider()
            HStack { Text(L("İlişkilendirilen kota payı · Tahmin")).font(.headline)
                if !meters.isEmpty { Picker(L("Kota"),selection: $meter) { ForEach(meters,id: \.self) { value in Text(L(points.first { $0.meter == value }?.title ?? value)).tag(value) } }.frame(maxWidth: 220) }
            }
            Text(L("Gözlenen kota artışları, aynı aralıktaki tokenlara göre dağıtılır. Bu değerler hesabın kesin proje faturası değildir; farklı dönemlerdeki yüzde puanları toplanır.")).font(.caption).foregroundStyle(.secondary)
            ForEach(attribution,id: \.project) { row in
                HStack { Text(row.project == "__elsewhere__" ? L("Başka kullanım / açıklanamayan") : row.project.hasPrefix("__") ? L("Projesi çözümlenemedi") : URL(fileURLWithPath: row.project).lastPathComponent); Spacer(); Text(L("%.1f yüzde puanı",row.percentagePoints)).monospacedDigit() }
            }
            if attribution.isEmpty { Text(L("Henüz ilişkilendirilebilir kota artışı gözlenmedi.")).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func empty(_ title: String,detail: String) -> some View {
        VStack(spacing: 12) { Image(systemName: "chart.bar.xaxis").font(.system(size: 32)).foregroundStyle(settings.color); Text(title).font(.headline); Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440) }.frame(maxWidth: .infinity,minHeight: 240)
    }
    private func load() {
        if Preview.isEnabled {
            let start = days == 1 ? Calendar.current.startOfDay(for: Date()) : Date().addingTimeInterval(-Double(days)*86400)
            points = Preview.history(provider: provider).filter { $0.date >= start }
            rows = [ProjectRow(project:"/örnek/kenar",input:24000,output:6800,cached:12000,cacheWrite:0),ProjectRow(project:"/örnek/website",input:14500,output:4200,cached:7500,cacheWrite:0),ProjectRow(project:"/örnek/mobile",input:8000,output:2100,cached:3500,cacheWrite:0)]
            if !meters.contains(meter) { meter = meters.first ?? "" }
            loading = false; return
        }
        guard let store else { return }
        loading = true; let provider = provider; let range = range; let request = UUID(); generation = request
        let start = days == 1 ? Calendar.current.startOfDay(for: Date()) : Date().addingTimeInterval(-Double(days)*86400)
        Task {
            let result = await Task.detached(priority: .utility) { (store.points(provider: provider,since: start),store.projects(provider: provider,range: range)) }.value
            guard generation == request else { return }
            points = result.0; rows = result.1; loading = false
            if !meters.contains(meter) { meter = meters.first ?? "" }; loadAttribution()
        }
    }
    private func loadAttribution() {
        guard let store, !meter.isEmpty else { attribution = []; return }
        let provider = provider; let meter = meter; let requestedRange = range
        let start = range.start() ?? .distantPast
        Task {
            let values = await Task.detached(priority: .utility) { store.attribution(provider: provider,meter: meter,since: start) }.value
            guard self.provider == provider, self.meter == meter, self.range == requestedRange else { return }; attribution = values
        }
    }
}
