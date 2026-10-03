import Foundation
import SQLite3

/// Reads only generation usage, timestamps and workspace identity. The CLI's
/// SQLite/protobuf layout is internal; reject unknown or malformed rows.
/// Field mapping was independently checked against installed agy metadata.
struct AntigravityIndexer {
    let store: AnalyticsStore
    var directory = AntigravityIntegration.directory
    func scan() -> Int {
        let root = directory.appendingPathComponent("conversations")
        let summariesURL = directory.appendingPathComponent("conversation_summaries.db")
        let workspaces = Self.workspaces(summariesURL)
        let resolver = TranscriptIndexer(store: store, roots: [:])
        var imported = 0
        for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "db" {
            let related = [file, URL(fileURLWithPath:file.path + "-wal"), summariesURL, URL(fileURLWithPath:summariesURL.path + "-wal")]
            let stats = related.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey]) }
            let size = stats.reduce(0) { $0 + ($1.fileSize ?? 0) }
            let modified = stats.compactMap(\.contentModificationDate).max()?.timeIntervalSince1970 ?? 0
            // Versioned cursor forces a re-import when the decoder changes.
            let cursor = "agy-generation-v1|" + file.path
            guard store.needsImport(path: cursor, size: size, modified: modified),
                  let events = Self.read(file, workspace: workspaces[file.deletingPathExtension().lastPathComponent], resolver: resolver) else { continue }
            store.importEvents(events, path: cursor, size: size, modified: modified)
            imported += events.count
        }
        return imported
    }
    static func read(_ file: URL, workspace: String?, resolver: TranscriptIndexer) -> [TokenEvent]? {
        guard let db = open(file) else { return nil }; defer { sqlite3_close(db) }
        var version: OpaquePointer?
        guard sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&version,nil) == SQLITE_OK else { return nil }
        let known = sqlite3_step(version) == SQLITE_ROW && (0...1).contains(sqlite3_column_int(version,0)); sqlite3_finalize(version)
        guard known else { return nil }
        var stepTimes: [Int:Date] = [:], steps: OpaquePointer?
        if sqlite3_prepare_v2(db,"SELECT idx,metadata FROM steps WHERE length(metadata)<=2097152",-1,&steps,nil) == SQLITE_OK {
            while sqlite3_step(steps) == SQLITE_ROW {
                if let blob = blob(steps,1), let message = try? UsageWire(blob), let stamp = message.message(1), let date = stamp.timestamp { stepTimes[Int(sqlite3_column_int64(steps,0))] = date }
            }
        }
        sqlite3_finalize(steps)
        var rows: OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT idx,data FROM gen_metadata WHERE length(data)<=2097152 ORDER BY idx",-1,&rows,nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(rows) }
        let session = file.deletingPathExtension().lastPathComponent
        let project = workspace.map(resolver.projectRoot) ?? "__antigravity_\(session)"
        var events: [TokenEvent] = []
        var status = sqlite3_step(rows)
        while status == SQLITE_ROW {
            if let data = blob(rows,1), let event = decode(data, index: sqlite3_column_int64(rows,0), session: session, project: project, stepTimes: stepTimes) { events.append(event) }
            status = sqlite3_step(rows)
        }
        return status == SQLITE_DONE ? events : nil
    }
    static func decode(_ data: Data, index: Int64, session: String, project: String, stepTimes: [Int:Date]) -> TokenEvent? {
        guard let outer = try? UsageWire(data), let generation = outer.message(1), let usage = generation.message(4),
              let model = generation.string(19), !model.isEmpty, model.count <= 256,
              let input = usage.counter(2), let output = usage.counter(3),
              let cacheWrite = usage.counter(4), let cacheRead = usage.counter(5),
              input + output + cacheWrite + cacheRead > 0 else { return nil }
        let date = generation.message(9)?.message(4)?.timestamp ?? outer.integers(2)?.compactMap { stepTimes[$0] }.max()
        guard let date else { return nil }
        // Field 3 already includes reasoning. Never add field 9 a second time.
        return TokenEvent(provider:"antigravity",key:"\(session)|\(index)",timestamp:date,session:session,project:project,model:model,input:input,output:output,cached:cacheRead,cacheWrite:cacheWrite)
    }
    static func workspaces(_ file: URL) -> [String:String] {
        guard let db = open(file) else { return [:] }; defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT conversation_id,workspace_uris FROM conversation_summaries",-1,&statement,nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }; var result: [String:String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement,0), let raw = sqlite3_column_text(statement,1) else { continue }
            let text = String(cString:raw); guard text.utf8.count <= 65536, let data = text.data(using:.utf8), let uris = try? JSONDecoder().decode([String].self,from:data) else { continue }
            let paths = Set(uris.compactMap { URL(string:$0) }.filter { $0.isFileURL && ($0.host.map { $0.isEmpty || $0 == "localhost" } ?? true) }.map(\.path))
            // A generation cannot reliably be assigned between multiple roots.
            if paths.count == 1, let path = paths.first { result[String(cString:id)] = path }
        }
        return result
    }
    private static func open(_ file: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path,&db,SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return nil }
        sqlite3_busy_timeout(db,1000); return db
    }
    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement,column))
        guard count > 0, count <= 2 * 1024 * 1024, let pointer = sqlite3_column_blob(statement,column) else { return nil }
        return Data(bytes:pointer,count:count)
    }
}

/// Bounded protobuf wire reader. Nested messages are decoded only at known
/// usage paths; prompts/tool payloads are never interpreted or retained.
struct UsageWire {
    enum Value { case integer(UInt64), bytes(Data) }
    enum Invalid: Error { case malformed }
    var fields: [Int:[Value]] = [:]
    init(_ data: Data) throws {
        guard data.count <= 2 * 1024 * 1024 else { throw Invalid.malformed }
        let bytes = Array(data); var position = 0, count = 0
        while position < bytes.count {
            count += 1; guard count <= 65536 else { throw Invalid.malformed }
            let tag = try Self.varint(bytes, at:&position), number = tag >> 3
            guard number > 0, number <= 536_870_911 else { throw Invalid.malformed }
            let value: Value
            switch tag & 7 {
            case 0: value = .integer(try Self.varint(bytes, at:&position))
            case 1,5:
                let size = tag & 7 == 1 ? 8 : 4
                guard size <= bytes.count-position else { throw Invalid.malformed }; position += size; continue
            case 2:
                let rawSize = try Self.varint(bytes,at:&position)
                guard rawSize <= UInt64(bytes.count-position) else { throw Invalid.malformed }
                let size = Int(rawSize); value = .bytes(Data(bytes[position..<position+size])); position += size
            default: throw Invalid.malformed
            }
            fields[Int(number),default:[]].append(value)
        }
    }
    static func varint(_ bytes: [UInt8], at position: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<10 {
            guard position < bytes.count else { throw Invalid.malformed }
            let byte = bytes[position]; position += 1
            guard index < 9 || byte <= 1 else { throw Invalid.malformed }
            value |= UInt64(byte & 127) << (index*7)
            if byte & 128 == 0 { return value }
        }
        throw Invalid.malformed
    }
    func message(_ field: Int) -> UsageWire? { if case .bytes(let data) = fields[field]?.last { return try? UsageWire(data) }; return nil }
    func string(_ field: Int) -> String? { if case .bytes(let data) = fields[field]?.last, data.count <= 1024 { return String(data:data,encoding:.utf8) }; return nil }
    func integer(_ field: Int) -> UInt64? { if case .integer(let value) = fields[field]?.last { return value }; return nil }
    func counter(_ field: Int) -> Int? {
        guard let values = fields[field] else { return 0 }
        guard values.count == 1, let value = integer(field), value <= 10_000_000_000 else { return nil }
        return Int(value)
    }
    var timestamp: Date? {
        guard let seconds = integer(1), seconds >= 1, seconds <= 253_402_300_799, let nanos = counter(2), nanos < 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970:Double(seconds)+Double(nanos)/1e9)
    }
    func integers(_ field: Int) -> [Int]? {
        var result: [Int] = []
        for value in fields[field] ?? [] {
            switch value {
            case .integer(let number): guard number <= UInt64(Int.max) else { return nil }; result.append(Int(number))
            case .bytes(let data):
                let bytes = Array(data); var position = 0
                while position < bytes.count {
                    guard let number = try? Self.varint(bytes,at:&position), number <= UInt64(Int.max), result.count < 65536 else { return nil }; result.append(Int(number))
                }
            }
        }
        return result
    }
}
