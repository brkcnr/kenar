import Foundation
@main enum InspectAntigravity {
    static func main() {
        guard CommandLine.arguments.count == 2,
              let store = AnalyticsStore(url: URL(fileURLWithPath:CommandLine.arguments[1])) else { exit(1) }
        print("Generations imported: \(AntigravityIndexer(store:store).scan())")
        for row in store.projects(provider:"antigravity",range:.all) {
            print("Project: \(row.title) · input=\(row.input) output=\(row.output) cacheWrite=\(row.cacheWrite) cacheRead=\(row.cached)")
        }
        if let error = store.lastError { fputs("\(error)\n",stderr); exit(1) }
    }
}
