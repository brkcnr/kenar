import Foundation

/// Prints quota values only, never tokens or raw response bodies.
@main enum AccountVerifier {
    static func main() async {
        let requested = Set(CommandLine.arguments.dropFirst())
        let providers: [UsageProvider] = [CodexProvider(),ClaudeProvider(),CursorProvider(),AntigravityProvider()]
        for provider in providers where requested.contains(provider.id) {
            let snapshot = await provider.fetch()
            print("\(snapshot.name): \(snapshot.error ?? "OK")")
            for window in snapshot.windows {
                print("  \(window.title): \(window.usedPercent.map { String(format:"%.1f%%",$0) } ?? "unknown") reset=\(window.resetsAt.map { ISO8601DateFormatter().string(from:$0) } ?? "unknown")")
            }
        }
    }
}
