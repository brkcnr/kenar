import Foundation
import SQLite3

struct TokenEvent {
    var provider: String; var key: String; var timestamp: Date; var session: String; var project: String; var model: String
    var input: Int; var output: Int; var cached: Int; var cacheWrite: Int = 0
    var total: Int { input + output + cacheWrite }
}
struct QuotaPoint: Identifiable {
    var id: Int64; var provider: String; var meter: String; var title: String; var model: String; var unit: String
    var date: Date; var percent: Double; var reset: Date?; var period: String
}
struct ProjectRow: Identifiable {
    var id: String { project }; var project: String; var input: Int; var output: Int; var cached: Int; var cacheWrite: Int
    var tokens: Int { input + output + cacheWrite }
    var title: String { project.hasPrefix("__") ? L("Projesi çözümlenemedi") : URL(fileURLWithPath: project).lastPathComponent }
}
struct Attribution { var project: String; var percentagePoints: Double }
enum QuotaSeries {
    /// Preserve first/last and extrema in each time bucket and quota period.
    /// This bounds chart rendering without losing visible peaks or reset gaps.
    static func downsample(_ points: [QuotaPoint]) -> [QuotaPoint] {
        guard points.count > 1600, let first = points.first, let last = points.last else { return points }
        let width = max(1,last.date.timeIntervalSince(first.date) / 400)
        let groups = Dictionary(grouping: points) { point in "\(point.period)|\(Int(point.date.timeIntervalSince(first.date)/width))" }
        var retained: [Int64: QuotaPoint] = [:]
        for group in groups.values {
            for point in [group.first,group.last,group.min { $0.percent < $1.percent },group.max { $0.percent < $1.percent }].compactMap({ $0 }) { retained[point.id] = point }
        }
        return retained.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}
enum AnalysisRange: String, CaseIterable {
    case session, week, month, all
    var title: String { switch self { case .session: return L("Oturum"); case .week: return L("Hafta"); case .month: return L("Ay"); case .all: return L("Tümü") } }
    func start(now: Date = Date()) -> Date? { switch self {
        case .session: return nil
        case .week: return Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: return Calendar.current.dateInterval(of: .month, for: now)?.start
        case .all: return nil
    } }
}

/// Only token metadata and quota measurements enter this database.
/// All SQLite statements and errors are confined to the serial queue.
final class AnalyticsStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "local.kenar.analytics", qos: .utility)
    private var error: String?
    var lastError: String? { queue.sync { error } }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init?(url: URL) {
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return nil }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return nil }
        sqlite3_busy_timeout(db, 5000)
        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS quota(id INTEGER PRIMARY KEY,provider TEXT,meter TEXT,label TEXT,model TEXT,unit TEXT,ts REAL,pct REAL,reset REAL,period TEXT);
        CREATE INDEX IF NOT EXISTS quota_lookup ON quota(provider,meter,ts);
        CREATE TABLE IF NOT EXISTS events(provider TEXT,key TEXT,ts REAL,session TEXT,project TEXT,model TEXT,input INTEGER,output INTEGER,cached INTEGER,cache_write INTEGER,PRIMARY KEY(provider,key));
        CREATE INDEX IF NOT EXISTS events_time ON events(provider,ts);
        CREATE TABLE IF NOT EXISTS cursors(path TEXT PRIMARY KEY,size INTEGER,mtime REAL);
        PRAGMA user_version=1;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { if let db { sqlite3_close(db) } }
    private func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { error = L("SQLite sorgusu hazırlanamadı."); return nil }
        return st
    }
    private func bind(_ st: OpaquePointer?, _ index: Int32, _ value: String) { sqlite3_bind_text(st, index, value, -1, Self.transient) }
    private func text(_ st: OpaquePointer?, _ index: Int32) -> String { sqlite3_column_text(st, index).map { String(cString: $0) } ?? "" }
    @discardableResult private func step(_ st: OpaquePointer?) -> Bool {
        guard sqlite3_step(st) == SQLITE_DONE else { error = L("SQLite yazma işlemi tamamlanamadı."); return false }
        return true
    }

    func record(_ snap: ProviderSnapshot, now: Date = Date()) {
        guard !snap.isDemo, snap.error == nil else { return }
        queue.sync {
            for w in snap.windows {
                guard let pct = w.usedPercent, !w.isUnlimited else { continue }
                let previous = pointsLocked(provider: snap.id, meter: w.id, since: .distantPast, limit: 1).last
                // agy republishes one captured sample; reopening Kenar must
                // not append that same measurement or an older sample again.
                if ["antigravity","claude"].contains(snap.id), let previous, previous.date.timeIntervalSince(now) >= -0.001 { continue }
                let changed = previous?.reset.flatMap { old in w.resetsAt.map { abs(old.timeIntervalSince($0)) > 120 } } ?? false
                let drop = previous != nil && w.resetsAt == nil && previous?.reset == nil && pct < (previous?.percent ?? 0) - 1
                let period = changed || drop || previous == nil ? UUID().uuidString : previous!.period
                guard let st = prepare("INSERT INTO quota(provider,meter,label,model,unit,ts,pct,reset,period) VALUES(?,?,?,?,?,?,?,?,?)") else { continue }
                bind(st,1,snap.id); bind(st,2,w.id); bind(st,3,w.title); bind(st,4,w.modelID ?? ""); bind(st,5,w.unit)
                sqlite3_bind_double(st,6,now.timeIntervalSince1970); sqlite3_bind_double(st,7,pct)
                if let reset = w.resetsAt { sqlite3_bind_double(st,8,reset.timeIntervalSince1970) } else { sqlite3_bind_null(st,8) }
                bind(st,9,period); step(st); sqlite3_finalize(st)
            }
            if let st = prepare("DELETE FROM quota WHERE ts < ?") {
                sqlite3_bind_double(st,1,now.addingTimeInterval(-90 * 86400).timeIntervalSince1970); step(st); sqlite3_finalize(st)
            }
        }
    }
    private func pointsLocked(provider: String, meter: String? = nil, since: Date, limit: Int? = nil) -> [QuotaPoint] {
        let sql = "SELECT id,provider,meter,label,model,unit,ts,pct,reset,period FROM quota WHERE provider=? AND ts>=?" + (meter == nil ? "" : " AND meter=?") + " ORDER BY ts DESC,id DESC" + (limit.map { " LIMIT \($0)" } ?? "")
        guard let st = prepare(sql) else { return [] }; defer { sqlite3_finalize(st) }
        bind(st,1,provider); sqlite3_bind_double(st,2,since.timeIntervalSince1970); if let meter { bind(st,3,meter) }
        var rows: [QuotaPoint] = []
        while sqlite3_step(st) == SQLITE_ROW {
            rows.append(QuotaPoint(id: sqlite3_column_int64(st,0), provider: text(st,1), meter: text(st,2), title: text(st,3), model: text(st,4), unit: text(st,5), date: Date(timeIntervalSince1970: sqlite3_column_double(st,6)), percent: sqlite3_column_double(st,7), reset: sqlite3_column_type(st,8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(st,8)), period: text(st,9)))
        }
        return rows.reversed()
    }
    func points(provider: String, since: Date) -> [QuotaPoint] { queue.sync { pointsLocked(provider: provider, since: since) } }
    func knownProjects() -> [String] { queue.sync {
        guard let st = prepare("SELECT DISTINCT project FROM events") else { return [] }
        defer { sqlite3_finalize(st) }
        var paths: [String] = []
        while sqlite3_step(st) == SQLITE_ROW { let path = text(st,0); if path.hasPrefix("/") { paths.append(path) } }
        return paths
    } }
    func importEvents(_ events: [TokenEvent], path: String, size: Int, modified: Double) {
        queue.sync {
            guard sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil) == SQLITE_OK else { error = L("Yerel kayıt işlemi başlatılamadı."); return }
            var success = true
            for e in events {
                guard let st = prepare("INSERT INTO events VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(provider,key) DO UPDATE SET input=MAX(input,excluded.input),output=MAX(output,excluded.output),cached=MAX(cached,excluded.cached),cache_write=MAX(cache_write,excluded.cache_write),project=excluded.project") else { success = false; break }
                bind(st,1,e.provider); bind(st,2,e.key); sqlite3_bind_double(st,3,e.timestamp.timeIntervalSince1970)
                bind(st,4,e.session); bind(st,5,e.project); bind(st,6,e.model)
                sqlite3_bind_int64(st,7,Int64(e.input)); sqlite3_bind_int64(st,8,Int64(e.output)); sqlite3_bind_int64(st,9,Int64(e.cached)); sqlite3_bind_int64(st,10,Int64(e.cacheWrite))
                success = step(st) && success; sqlite3_finalize(st)
            }
            guard success else { sqlite3_exec(db,"ROLLBACK",nil,nil,nil); return }
            if let st = prepare("INSERT INTO cursors VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET size=excluded.size,mtime=excluded.mtime") {
                bind(st,1,path); sqlite3_bind_int64(st,2,Int64(size)); sqlite3_bind_double(st,3,modified); success = step(st); sqlite3_finalize(st)
            } else { success = false }
            guard success else { sqlite3_exec(db,"ROLLBACK",nil,nil,nil); return }
            if sqlite3_exec(db,"COMMIT",nil,nil,nil) != SQLITE_OK { error = L("Yerel kayıt işlemi tamamlanamadı."); sqlite3_exec(db,"ROLLBACK",nil,nil,nil) }
        }
    }
    func needsImport(path: String, size: Int, modified: Double) -> Bool { queue.sync {
        guard let st = prepare("SELECT size,mtime FROM cursors WHERE path=?") else { return true }; defer { sqlite3_finalize(st) }
        bind(st,1,path)
        return sqlite3_step(st) != SQLITE_ROW || Int(sqlite3_column_int64(st,0)) != size || sqlite3_column_double(st,1) != modified
    } }
    func projects(provider: String, range: AnalysisRange, now: Date = Date()) -> [ProjectRow] { queue.sync {
        var sql = "SELECT project,SUM(input),SUM(output),SUM(cached),SUM(cache_write) FROM events WHERE provider=?"
        if range == .session { sql += " AND session=(SELECT session FROM events WHERE provider=? ORDER BY ts DESC LIMIT 1)" }
        else if range.start(now: now) != nil { sql += " AND ts>=?" }
        sql += " GROUP BY project ORDER BY SUM(input+output+cache_write) DESC"
        guard let st = prepare(sql) else { return [] }; defer { sqlite3_finalize(st) }; bind(st,1,provider)
        if range == .session { bind(st,2,provider) }
        else if let start = range.start(now: now) { sqlite3_bind_double(st,2,start.timeIntervalSince1970) }
        var rows: [ProjectRow] = []
        while sqlite3_step(st) == SQLITE_ROW { rows.append(ProjectRow(project: text(st,0), input: Int(sqlite3_column_int64(st,1)), output: Int(sqlite3_column_int64(st,2)), cached: Int(sqlite3_column_int64(st,3)), cacheWrite: Int(sqlite3_column_int64(st,4)))) }
        return rows
    } }
    /// Estimates only observable rises, never treats the first sample or a reset
    /// as consumption. Unexplained rises remain visible rather than assigned.
    func attribution(provider: String, meter: String, since: Date) -> [Attribution] { queue.sync {
        let points = pointsLocked(provider: provider,meter: meter,since: since)
        var totals: [String: Double] = [:]
        for (a,b) in zip(points,points.dropFirst()) where a.period == b.period && b.percent > a.percent {
            let scoped = !b.model.isEmpty
            let sql = "SELECT project,SUM(input+output+cache_write) FROM events WHERE provider=? AND ts>? AND ts<=?" + (scoped ? " AND (model=? OR model LIKE ?)" : "") + " GROUP BY project"
            guard let st = prepare(sql) else { continue }
            bind(st,1,provider); sqlite3_bind_double(st,2,a.date.timeIntervalSince1970); sqlite3_bind_double(st,3,b.date.timeIntervalSince1970)
            if scoped { bind(st,4,b.model); bind(st,5,b.model + "-%") }
            var weights: [String: Double] = [:]
            while sqlite3_step(st) == SQLITE_ROW { weights[text(st,0)] = sqlite3_column_double(st,1) }
            sqlite3_finalize(st)
            let sum = weights.values.reduce(0,+); let delta = b.percent-a.percent
            if sum > 0 { for (project,weight) in weights { totals[project,default:0] += delta*weight/sum } }
            else { totals["__elsewhere__",default:0] += delta }
        }
        return totals.map { Attribution(project: $0.key, percentagePoints: $0.value) }.sorted { $0.percentagePoints > $1.percentagePoints }
    } }
}
