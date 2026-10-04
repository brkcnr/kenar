import SwiftUI

struct AccountConnectionControls: View {
    let product: AccountProduct
    @ObservedObject var settings: Settings
    @ObservedObject private var connection: AccountWebConnection
    init(product: AccountProduct, settings: Settings) {
        self.product = product; self.settings = settings
        self.connection = AccountWebConnection.connection(product)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(product.title).fontWeight(.semibold)
                Spacer()
                Button(L(connection.isEnabled ? "Yeniden bağla" : "Bağla")) { connection.connect() }
                Button(L("Bağlantıyı kes")) { Task { await connection.disconnect() } }.disabled(!connection.isEnabled)
            }
            if product == .openai { Text(L("Codex / Work ve ChatGPT Chat ayrı gösterilir.")).font(.caption).foregroundStyle(.secondary) }
            if product == .geminiWeb || product == .antigravityWeb {
                Text(L("Gemini ve Antigravity ayrı kota kaynaklarıdır. Girişten sonra resmi kullanım kartını aç ve Kenar’a aktar düğmesine bas.")).font(.caption).foregroundStyle(.secondary)
                Text(L("Google web okuyucusu deneysel; giriş yapmak sayısal kota erişimini garanti etmez.")).font(.caption).foregroundStyle(.secondary)
            }
            if connection.isEnabled, !connection.workspaces.isEmpty {
                Picker(L("Çalışma alanı"), selection: Binding(get: { connection.selectedWorkspace }, set: { connection.selectedWorkspace = $0 })) {
                    Text(L("Seç")).tag("")
                    ForEach(connection.workspaces) { Text($0.name).tag($0.id) }
                }
            }
            if connection.isEnabled, let message = connection.message { Text(L(message)).font(.caption).foregroundStyle(connection.state == .failed || connection.state == .expired ? .orange : .secondary) }
            Text(L("Web girişi Kenar’ın kendi oturumunda saklanır; başka tarayıcının çerezleri okunmaz.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
