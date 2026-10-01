import Foundation
import CryptoKit

/// Decodes an allow-list of numeric usage/identity fields. No content, tool
/// outputs, prompts, attachments or credentials are persisted in analytics.
final class TranscriptIndexer {
    let store: AnalyticsStore
    private let home: URL
    private let explicitRoots: [String: URL]?
    private var projectCache: [String: String] = [:]
    init(store: AnalyticsStore, home: URL = AppPaths.home, roots: [String: URL]? = nil) { self.store = store; self.home = home; explicitRoots = roots }
    func scan() -> Int {
        let roots = explicitRoots ?? [
            "claude": AppPaths.config("CLAUDE_CONFIG_DIR", fallback: ".claude").appendingPathComponent("projects"),
            "codex": AppPaths.config("CODEX_HOME", fallback: ".codex").appendingPathComponent("sessions"),
            "gemini": AppPaths.config("GEMINI_CLI_HOME", fallback: ".gemini").appendingPathComponent("tmp")
        ]
        var imported = 0
        var destinations = roots.map { ($0.key,$0.value) }
        if explicitRoots == nil { destinations.append(("codex",AppPaths.config("CODEX_HOME",fallback:".codex").appendingPathComponent("archived_sessions"))) }
        // Import providers with explicit cwd metadata before resolving older
        // Gemini hashes against those known paths.
        destinations.sort { $0.0 == "gemini" ? false : $1.0 == "gemini" }
        for (provider,root) in destinations {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey,.contentModificationDateKey,.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files {
                if ["subagents","tool-results","checkpoints"].contains(file.lastPathComponent) { files.skipDescendants(); continue }
                guard file.pathExtension == "jsonl" || (provider == "gemini" && file.pathExtension == "json") else { continue }
                if provider == "gemini" && (file.deletingLastPathComponent().lastPathComponent != "chats" || !file.lastPathComponent.hasPrefix("session-")) { continue }
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey]), let size = values.fileSize,
                      let date = values.contentModificationDate,
                      store.needsImport(path: file.path,size: size,modified: date.timeIntervalSince1970) else { continue }
                let result: [TokenEvent]?
                if provider == "gemini", file.pathExtension == "json" {
                    if size < 64 * 1024 * 1024, let data = try? Data(contentsOf: file), let session = try? JSONDecoder().decode(GeminiSession.self, from: data) {
                        let cwd = session.directories?.first ?? geminiProject(file: file,hash: session.projectHash)
                        result = session.messages.compactMap { geminiEvent($0,session: session.sessionId,project: cwd) }
                    } else { result = nil }
                } else { result = parseLines(file, provider: provider) }
                if let result {
                    store.importEvents(result,path: file.path,size: size,modified: date.timeIntervalSince1970); imported += result.count
                }
            }
        }
        return imported
    }
    // Full re-read of changed files also handles rewrites/rotations. Message keys
    // and MAX upserts deduplicate streaming records and overlapping archives.
    // Files are streamed in bounded chunks; incomplete final records are retried
    // on the next file change instead of being marked as consumed messages.
    private func parseLines(_ file: URL, provider: String) -> [TokenEvent]? {
        guard let reader = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? reader.close() }
        var buffer = Data(); var results: [TokenEvent] = []
        var session = file.deletingPathExtension().lastPathComponent
        var cwd = "__unknown__"; var model = "Bilinmiyor"
        var previous: CodexCounts?; var geminiHash: String?
        let decoder = JSONDecoder()
        do {
            while let chunk = try reader.read(upToCount: 256 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline)
                    guard line.count < 8 * 1024 * 1024 else { continue }
                    switch provider {
                    case "claude":
                        guard let record = try? decoder.decode(ClaudeRecord.self,from: line), record.type == "assistant", let usage = record.message?.usage,
                              let date = ClaudeProvider.isoDate(record.timestamp), let path = record.cwd, let sid = record.sessionId ?? record.session_id,
                              let model = record.message?.model, model != "<synthetic>" else { continue }
                        guard let input = usage.input_tokens, let output = usage.output_tokens else { continue }
                        let request = record.requestId ?? record.message?.id ?? record.uuid ?? "\(sid)|\(record.timestamp ?? "")|\(input)"
                        results.append(TokenEvent(provider: "claude",key: request,timestamp: date,session: sid,project: projectRoot(path),model: model,input: max(0,input),output: max(0,output),cached: max(0,usage.cache_read_input_tokens ?? 0),cacheWrite: max(0,usage.cache_creation_input_tokens ?? 0)))
                    case "codex":
                        guard let record = try? decoder.decode(CodexRecord.self,from: line), let payload = record.payload else { continue }
                        if record.type == "session_meta" { session = payload.id ?? session; cwd = payload.cwd ?? cwd }
                        if record.type == "turn_context" { cwd = payload.cwd ?? cwd; model = payload.model ?? model }
                        guard record.type == "event_msg", payload.type == "token_count", let total = payload.info?.total_token_usage,
                              let date = ClaudeProvider.isoDate(record.timestamp) else { continue }
                        let last = previous ?? CodexCounts()
                        // On compaction/reset, start from the new counters. Cached
                        // tokens are a subset of input for Codex, not extra input.
                        let input = max(0,total.input_tokens-last.input_tokens)
                        let output = max(0,total.output_tokens-last.output_tokens)
                        let cache = max(0,total.cached_input_tokens-last.cached_input_tokens)
                        previous = total
                        if input+output == 0 { continue }
                        results.append(TokenEvent(provider: "codex",key: "\(session)|\(total.input_tokens)|\(total.output_tokens)",timestamp: date,session: session,project: projectRoot(cwd),model: model,input: input,output: output,cached: cache))
                    case "gemini":
                        guard let record = try? decoder.decode(GeminiLine.self,from: line) else { continue }
                        if let sid = record.sessionId { session = sid }
                        geminiHash = record.projectHash ?? geminiHash
                        if let dirs = record.directories ?? record.set?.directories, let first = dirs.first { cwd = first }
                        if cwd == "__unknown__" { cwd = geminiProject(file: file,hash: geminiHash) }
                        if let event = geminiEvent(record.message,session: session,project: cwd) { results.append(event) }
                    default: break
                    }
                }
                if buffer.count > 8 * 1024 * 1024 { return nil }
            }
            return results
        } catch { return nil }
    }
    func projectRoot(_ path: String) -> String {
        guard !path.hasPrefix("__") else { return path }
        if let cached = projectCache[path] { return cached }
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<64 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { projectCache[path] = dir.path; return dir.path }
            let parent = dir.deletingLastPathComponent(); if parent.path == dir.path { break }; dir = parent
        }
        projectCache[path] = path; return path
    }
    private func geminiProject(file: URL, hash: String?) -> String {
        let root = file.deletingLastPathComponent().deletingLastPathComponent()
        let marker = root.appendingPathComponent(".project_root")
        if let path = try? String(contentsOf: marker,encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") { return path }
        let registry = (explicitRoots?["gemini"]?.deletingLastPathComponent() ?? AppPaths.config("GEMINI_CLI_HOME",fallback: ".gemini")).appendingPathComponent("projects.json")
        if let data = try? Data(contentsOf: registry), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let entries = object["projects"] as? [String: String] ?? object as? [String: String] ?? [:]
            for (path,id) in entries where id == root.lastPathComponent || path == root.lastPathComponent {
                let candidate = path.hasPrefix("/") ? path : id
                if candidate.hasPrefix("/") { return candidate }
            }
        }
        if let hash {
            for path in store.knownProjects() {
                let digest = SHA256.hash(data: Data(path.utf8)).map { String(format:"%02x",$0) }.joined()
                if digest == hash { return path }
            }
        }
        return "__gemini_\(hash ?? root.lastPathComponent)"
    }
    private func geminiEvent(_ message: GeminiMessage,session: String,project: String) -> TokenEvent? {
        guard message.type == "gemini", let id = message.id, let tokens = message.tokens, let date = ClaudeProvider.isoDate(message.timestamp) else { return nil }
        return TokenEvent(provider: "gemini",key: "\(session)|\(id)",timestamp: date,session: session,project: projectRoot(project),model: message.model ?? "Bilinmiyor",input: max(0,tokens.input ?? 0),output: max(0,(tokens.output ?? 0)+(tokens.thoughts ?? 0)),cached: max(0,tokens.cached ?? 0))
    }
}

// These Decodable structs intentionally have no content/tool/attachment fields.
private struct ClaudeRecord: Decodable {
    var type: String?; var timestamp: String?; var cwd: String?; var sessionId: String?; var session_id: String?; var requestId: String?; var uuid: String?; var message: Message?
    struct Message: Decodable { var id: String?; var model: String?; var usage: Usage? }
    struct Usage: Decodable { var input_tokens: Int?; var output_tokens: Int?; var cache_read_input_tokens: Int?; var cache_creation_input_tokens: Int? }
}
private struct CodexCounts: Decodable {
    var input_tokens: Int; var output_tokens: Int; var cached_input_tokens: Int
    init() { input_tokens=0;output_tokens=0;cached_input_tokens=0 }
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy: CodingKeys.self)
        input_tokens=try c.decodeIfPresent(Int.self,forKey: .input_tokens) ?? 0
        output_tokens=try c.decodeIfPresent(Int.self,forKey: .output_tokens) ?? 0
        cached_input_tokens=try c.decodeIfPresent(Int.self,forKey: .cached_input_tokens) ?? 0
    }
    enum CodingKeys: String,CodingKey { case input_tokens, output_tokens, cached_input_tokens }
}
private struct CodexRecord: Decodable {
    var type: String?; var timestamp: String?; var payload: Payload?
    struct Payload: Decodable { var id: String?; var type: String?; var cwd: String?; var model: String?; var info: Info? }
    struct Info: Decodable { var total_token_usage: CodexCounts? }
}
private struct GeminiMessage: Decodable {
    var id: String?; var type: String?; var timestamp: String?; var model: String?; var tokens: Tokens?
    struct Tokens: Decodable { var input: Int?; var output: Int?; var cached: Int?; var thoughts: Int? }
}
private struct GeminiSession: Decodable { var sessionId: String; var projectHash: String?; var directories: [String]?; var messages: [GeminiMessage] }
private struct GeminiLine: Decodable {
    var sessionId: String?; var projectHash: String?; var directories: [String]?; var set: Metadata?; var message: GeminiMessage
    struct Metadata: Decodable { var directories: [String]? }
    enum CodingKeys: String,CodingKey { case sessionId,projectHash,directories; case set = "$set" }
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy: CodingKeys.self)
        sessionId=try c.decodeIfPresent(String.self,forKey: .sessionId);projectHash=try c.decodeIfPresent(String.self,forKey: .projectHash)
        directories=try c.decodeIfPresent([String].self,forKey: .directories);set=try c.decodeIfPresent(Metadata.self,forKey: .set)
        message=try GeminiMessage(from: decoder)
    }
}
