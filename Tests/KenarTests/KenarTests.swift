#if !KENAR_STANDALONE_TESTS
import XCTest
@testable import Kenar
#endif
import AppKit
import SQLite3
import Security
import WebKit

final class KenarTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kenar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try FileManager.default.removeItem(at: dir) } }
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func database() throws -> AnalyticsStore { try XCTUnwrap(AnalyticsStore(url: dir.appendingPathComponent("analytics.sqlite"))) }
    private func snapshot(_ percent: Double, reset: Date? = nil, id: String = "codex", meter: String = "session") -> ProviderSnapshot {
        ProviderSnapshot(id: id,name: id,systemImage: "circle",windows: [UsageWindow(label: meter,usedPercent: percent,resetsAt: reset)],error: nil,updatedAt: Date())
    }
    private func wireInteger(_ field: Int, _ value: UInt64) -> Data {
        func v(_ value: UInt64) -> Data { var n=value, b=[UInt8](); repeat { var byte=UInt8(n&127); n >>= 7; if n != 0 { byte |= 128 }; b.append(byte) } while n != 0; return Data(b) }
        return v(UInt64(field << 3)) + v(value)
    }
    private func wireBytes(_ field: Int, _ value: Data) -> Data {
        let tag=UInt64((field << 3)|2), length=UInt64(value.count)
        var b=[UInt8]()
        for initial in [tag,length] { var n=initial; repeat { var x=UInt8(n&127); n >>= 7; if n != 0 { x |= 128 }; b.append(x) } while n != 0 }
        return Data(b)+value
    }
    private func generation(input: UInt64 = 120, output: UInt64 = 80, timestamp: Date? = Date(), reference: UInt64 = 1) -> Data {
        let usage = wireInteger(2,input)+wireInteger(3,output)+wireInteger(4,10)+wireInteger(5,70)+wireInteger(9,55)+wireInteger(10,25)
        var inner=wireBytes(4,usage)+wireBytes(19,data("gemini-future"))
        if let timestamp { inner += wireBytes(9,wireBytes(4,wireInteger(1,UInt64(timestamp.timeIntervalSince1970))+wireInteger(2,0))) }
        return wireInteger(2,reference)+wireBytes(1,inner)+wireBytes(500,data("PRIVATE_CONTENT_NEVER_IMPORT"))
    }
    private func agyDatabase(_ name: String, workspace: URL? = nil) throws -> (URL, OpaquePointer) {
        let folder = dir.appendingPathComponent("agy/conversations"); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let file=folder.appendingPathComponent(name+".db"); var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path,&handle),SQLITE_OK); let db=try XCTUnwrap(handle)
        XCTAssertEqual(sqlite3_exec(db,"PRAGMA user_version=1; CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB,size INTEGER); CREATE TABLE steps(idx INTEGER PRIMARY KEY,metadata BLOB)",nil,nil,nil),SQLITE_OK)
        if let workspace {
            let summary=dir.appendingPathComponent("agy/conversation_summaries.db"); var summaryDB: OpaquePointer?
            XCTAssertEqual(sqlite3_open(summary.path,&summaryDB),SQLITE_OK); defer { sqlite3_close(summaryDB) }
            XCTAssertEqual(sqlite3_exec(summaryDB,"CREATE TABLE IF NOT EXISTS conversation_summaries(conversation_id TEXT,workspace_uris TEXT)",nil,nil,nil),SQLITE_OK)
            var st:OpaquePointer?;XCTAssertEqual(sqlite3_prepare_v2(summaryDB,"INSERT INTO conversation_summaries VALUES(?,?)",-1,&st,nil),SQLITE_OK)
            defer { sqlite3_finalize(st) };let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
            sqlite3_bind_text(st,1,name,-1,transient)
            let uris=String(data:try JSONEncoder().encode([workspace.absoluteString]),encoding:.utf8)!
            sqlite3_bind_text(st,2,uris,-1,transient);XCTAssertEqual(sqlite3_step(st),SQLITE_DONE)
        }
        return (file,db)
    }
    private func insertGeneration(_ blob:Data,index:Int,into db:OpaquePointer) {
        var st:OpaquePointer?;XCTAssertEqual(sqlite3_prepare_v2(db,"INSERT INTO gen_metadata VALUES(?,?,?)",-1,&st,nil),SQLITE_OK);defer{sqlite3_finalize(st)}
        sqlite3_bind_int(st,1,Int32(index)); let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(st,2,$0.baseAddress,Int32(blob.count),transient) };sqlite3_bind_int(st,3,Int32(blob.count))
        XCTAssertEqual(sqlite3_step(st),SQLITE_DONE)
    }
    func testAntigravityGenerationDecoderIncludesReasoningOnce() throws {
        let event=try XCTUnwrap(AntigravityIndexer.decode(generation(),index:3,session:"s",project:"/p",stepTimes:[:]))
        XCTAssertEqual(event.input,120);XCTAssertEqual(event.output,80);XCTAssertEqual(event.cached,70);XCTAssertEqual(event.cacheWrite,10)
        XCTAssertEqual(event.total,210);XCTAssertEqual(event.key,"s|3")
    }
    func testAntigravityGenerationDatesReferencedStepsAndRejectsBadUsage() throws {
        let now=Date(), blob=generation(timestamp:nil)
        XCTAssertNil(AntigravityIndexer.decode(blob,index:0,session:"s",project:"/p",stepTimes:[:]))
        XCTAssertEqual(AntigravityIndexer.decode(blob,index:0,session:"s",project:"/p",stepTimes:[1:now])?.timestamp,now)
        XCTAssertNil(AntigravityIndexer.decode(generation(input:UInt64.max),index:0,session:"s",project:"/p",stepTimes:[:]))
        XCTAssertNil(AntigravityIndexer.decode(Data([10]),index:0,session:"s",project:"/p",stepTimes:[:]))
        XCTAssertNil(try? UsageWire(Data(repeating:255,count:11)))
    }
    func testAntigravityDatabaseImportIsPrivateAndDeduplicated() throws {
        let project=dir.appendingPathComponent("repo"), nested=project.appendingPathComponent("src")
        try FileManager.default.createDirectory(at:project.appendingPathComponent(".git"),withIntermediateDirectories:true)
        let (_,writer)=try agyDatabase("one",workspace:nested);defer{sqlite3_close(writer)}
        insertGeneration(generation(),index:0,into:writer)
        let db=try database(), indexer=AntigravityIndexer(store:db,directory:dir.appendingPathComponent("agy"))
        XCTAssertEqual(indexer.scan(),1);XCTAssertEqual(indexer.scan(),0)
        XCTAssertEqual(db.projects(provider:"antigravity",range:.all).first?.project,project.path)
        XCTAssertEqual(db.projects(provider:"antigravity",range:.all).first?.tokens,210)
        let raw=try Data(contentsOf:dir.appendingPathComponent("analytics.sqlite"))
        XCTAssertFalse(String(decoding:raw,as:UTF8.self).contains("PRIVATE_CONTENT_NEVER_IMPORT"))
    }
    func testAntigravityWALUpdatesAndProjectSeparation() throws {
        let a=dir.appendingPathComponent("a"),b=dir.appendingPathComponent("b")
        let (_,first)=try agyDatabase("a",workspace:a),(_,second)=try agyDatabase("b",workspace:b)
        defer{sqlite3_close(first);sqlite3_close(second)}
        XCTAssertEqual(sqlite3_exec(first,"PRAGMA journal_mode=WAL",nil,nil,nil),SQLITE_OK)
        insertGeneration(generation(input:100),index:0,into:first);insertGeneration(generation(input:200),index:0,into:second)
        let db=try database(), indexer=AntigravityIndexer(store:db,directory:dir.appendingPathComponent("agy"))
        _ = indexer.scan();insertGeneration(generation(input:300),index:1,into:first);_ = indexer.scan();_ = indexer.scan()
        let rows=db.projects(provider:"antigravity",range:.all)
        XCTAssertEqual(rows.count,2);XCTAssertEqual(rows.first{$0.project==a.path}?.input,400);XCTAssertEqual(rows.first{$0.project==b.path}?.input,200)
        XCTAssertEqual(db.projects(provider:"antigravity",range:.session).count,1)
    }
    func testAntigravityWorkspaceUnknownAndSchemaVersion() throws {
        let (file,writer)=try agyDatabase("unknown");defer{sqlite3_close(writer)}
        insertGeneration(generation(),index:0,into:writer)
        let db=try database(),resolver=TranscriptIndexer(store:db,roots:[:])
        XCTAssertEqual(AntigravityIndexer.read(file,workspace:nil,resolver:resolver)?.first?.project,"__antigravity_unknown")
        XCTAssertEqual(sqlite3_exec(writer,"PRAGMA user_version=2",nil,nil,nil),SQLITE_OK)
        XCTAssertNil(AntigravityIndexer.read(file,workspace:nil,resolver:resolver))
    }
    func testClaudeQuotaBridgeParsesAccountQuotaWithoutContext() throws {
        let now=Date(timeIntervalSince1970:1_800_000_000)
        let sample=try XCTUnwrap(ClaudeQuotaBridge.capture(data(#"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1800001000},"seven_day":{"used_percentage":31}},"context_window":{"used_percentage":99}}"#),at:now))
        XCTAssertEqual(try XCTUnwrap(sample.windows[0].usedPercent),31,accuracy:0.0001)
        XCTAssertEqual(try XCTUnwrap(sample.windows[1].usedPercent),1,accuracy:0.0001)
        XCTAssertEqual(sample.windows.last?.resetsAt,now.addingTimeInterval(1000))
        XCTAssertNil(ClaudeQuotaBridge.capture(data(#"{"rate_limits":{"five_hour":{"used_percentage":true}},"context_window":{"used_percentage":50}}"#)))
        XCTAssertNil(ClaudeQuotaBridge.capture(data(#"{"context_window":{"used_percentage":50}}"#)))
    }
    func testClaudeBridgeFreshnessAndPrivacy() throws {
        let now=Date(),file=dir.appendingPathComponent("claude-usage.json")
        let payload=data(#"{"rate_limits":{"five_hour":{"used_percentage":12}},"session_id":"PRIVATE_SESSION","transcript_path":"PRIVATE_TRANSCRIPT","context_window":{"total_input_tokens":100000}}"#)
        try ClaudeQuotaBridge.receive(payload,directory:dir,at:now)
        let fresh=try XCTUnwrap(ClaudeQuotaBridge.snapshot(at:now,sourceURL:file))
        XCTAssertEqual(fresh.primary?.usedPercent ?? -1,12,accuracy:0.001)
        XCTAssertEqual(fresh.primary?.id,"Current session");XCTAssertNil(fresh.primary?.modelID)
        XCTAssertNil(ClaudeQuotaBridge.snapshot(at:now.addingTimeInterval(301),sourceURL:file))
        XCTAssertFalse(try String(contentsOf:file,encoding:.utf8).contains("PRIVATE_"))
        let expired = try JSONSerialization.data(withJSONObject:["rate_limits":["five_hour":["used_percentage":12,"resets_at":now.addingTimeInterval(-1).timeIntervalSince1970]]])
        try ClaudeQuotaBridge.receive(expired,directory:dir,at:now)
        XCTAssertNil(ClaudeQuotaBridge.snapshot(at:now,sourceURL:file))
    }
    func testClaudeStatusLineSetupKeepsCustomSettings() throws {
        let config=dir.appendingPathComponent("settings.json")
        try data(#"{"theme":"dark","model":"preferred"}"#).write(to:config)
        let executable=URL(fileURLWithPath:"/Applications/Kenar.app/Contents/MacOS/Kenar")
        let script=try ClaudeQuotaBridge.install(directory:dir,executable:executable)
        XCTAssertTrue(try String(contentsOf:script,encoding:.utf8).contains("--claude-statusline"))
        let object=try JSONSerialization.jsonObject(with:Data(contentsOf:config)) as! [String:Any]
        XCTAssertEqual(object["model"] as? String,"preferred")
        XCTAssertEqual((object["statusLine"] as? [String:Any])?["refreshInterval"] as? Int,60)
        try data(#"{"statusLine":{"command":"custom"}}"#).write(to:config)
        do{_ = try ClaudeQuotaBridge.install(directory:dir,executable:executable);XCTAssertTrue(false)}catch{}
    }
    @MainActor func testClaudeWebWorkspaceParsingAndPreferences() throws {
        let workspaces=ClaudeWebConnection.parseWorkspaces(data(#"[{"uuid":"a3a72d29-3a92-45ec-b72b-e8e1f97345b1","name":"Personal","accessToken":"NEVER_STORE"},{"uuid":"not-an-id","name":"bad"}]"#))
        XCTAssertEqual(workspaces.count,1);XCTAssertEqual(workspaces.first?.name,"Personal")
        let domain="KenarTests.\(UUID().uuidString)"
        let isolated=UserDefaults(suiteName:domain)!;defer{isolated.removePersistentDomain(forName:domain)}
        let settings=Settings(defaults:isolated);settings.values.claudeSource="web";settings.values.claudeWorkspace=workspaces[0].id
        let restored=Settings(defaults:isolated)
        XCTAssertEqual(restored.values.claudeSource,"web");XCTAssertEqual(restored.values.claudeWorkspace,workspaces[0].id)
    }
    @MainActor func testClaudeSourceChangesDiscardInflightResult() async throws {
        let provider=SourceChangeProvider(),db=try database()
        let store=UsageStore(providers:[provider],analytics:db,quotaObserver:{_ in})
        store.refreshAll();try await Task.sleep(nanoseconds:1_000_000);store.connectionsChanged()
        for _ in 0..<300 where store.isRefreshing { try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertFalse(store.isRefreshing);XCTAssertEqual(store.snapshots.first?.primary?.usedPercent,40)
        XCTAssertEqual(db.points(provider:"claude",since:.distantPast).map(\.percent),[40])
    }
    func testAntigravityOfficialQuotaAndResetHints() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = try XCTUnwrap(AntigravitySample.capture(data(#"{"product":"antigravity","quota":{"gemini-weekly":{"remaining_fraction":0.9378,"reset_time":"2026-10-04T00:00:00Z","reset_in_seconds":20},"future-model":{"remaining_fraction":0.25,"reset_in_seconds":60}}}"#), at: now))
        XCTAssertEqual(sample.windows.map(\.id), ["future-model", "gemini-weekly"])
        XCTAssertEqual(sample.windows[0].usedPercent!, 75, accuracy: 0.001)
        XCTAssertEqual(sample.windows[1].usedPercent!, 6.22, accuracy: 0.001)
        XCTAssertEqual(sample.windows[0].resetsAt, now.addingTimeInterval(60))
        XCTAssertEqual(sample.windows[1].resetsAt, ClaudeProvider.isoDate("2026-10-04T00:00:00Z"))
    }
    func testAntigravityMissingAndMalformedFieldsStayUnknown() throws {
        let sample = try XCTUnwrap(AntigravitySample.capture(data(#"{"quota":{"new":{"remaining_fraction":"bad","reset_time":false},"missing":{},"invalid":{"remaining_fraction":1.2,"reset_in_seconds":-1}}}"#)))
        XCTAssertEqual(sample.windows.count, 3)
        XCTAssertTrue(sample.windows.allSatisfy { $0.usedPercent == nil && $0.resetsAt == nil })
        XCTAssertNil(AntigravitySample.capture(data("broken")))
        XCTAssertNil(AntigravitySample.capture(data(#"{"product":"other","quota":{}}"#)))
        XCTAssertNil(AntigravitySample.capture(data(#"{"context_window":{"used_percentage":90}}"#)))
        let url = dir.appendingPathComponent("sample.json")
        let poisoned = AntigravitySample(receivedAt: Date(timeIntervalSince1970: 1e100), buckets: [])
        try JSONEncoder().encode(poisoned).write(to: url)
        XCTAssertNil(AntigravitySample.read(url))
        let duplicate = AntigravitySample(receivedAt: Date(), buckets: [.init(id:"x"), .init(id:"x")])
        try JSONEncoder().encode(duplicate).write(to: url)
        XCTAssertNil(AntigravitySample.read(url))
    }
    func testAntigravityBridgePrivacyAndRepaintDeduplication() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = data(#"{"quota":{"new":{"remaining_fraction":0.5,"reset_time":"2026-10-04T00:00:00Z"}},"email":"PRIVATE_EMAIL","conversation_id":"PRIVATE_SESSION","context_window":{"used_percentage":99},"prompt":"PRIVATE_PROMPT","access_token":"PRIVATE_TOKEN"}"#)
        XCTAssertTrue(try AntigravitySample.receive(payload, directory: dir, at: now))
        let file = dir.appendingPathComponent("antigravity-usage.json")
        let raw = try String(contentsOf: file, encoding: .utf8)
        for value in ["PRIVATE_EMAIL", "PRIVATE_SESSION", "PRIVATE_PROMPT", "PRIVATE_TOKEN", "context_window", "used_percentage"] { XCTAssertFalse(raw.contains(value)) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try AntigravitySample.receive(payload, directory: dir, at: now.addingTimeInterval(1)))
        XCTAssertEqual(AntigravitySample.read(file)?.receivedAt, now)
        XCTAssertTrue(try AntigravitySample.receive(payload, directory: dir, at: now.addingTimeInterval(120)))
        XCTAssertEqual(AntigravitySample.read(file)?.receivedAt, now.addingTimeInterval(120))
        XCTAssertTrue(try AntigravitySample.receive(data(#"{"quota":{"new":{"remaining_fraction":0.4}}}"#), directory: dir, at: now.addingTimeInterval(121)))
        XCTAssertEqual(AntigravitySample.read(file)?.windows.first?.usedPercent, 60)
    }
    func testAntigravityMissingAndStaleSource() throws {
        let now = Date(), file = dir.appendingPathComponent("antigravity-usage.json")
        XCTAssertNotNil(AntigravityProvider.snapshot(at: now, sourceURL: file).error)
        XCTAssertTrue(AntigravityProvider.snapshot(at: now, sourceURL: file).windows.isEmpty)
        try AntigravitySample.receive(data(#"{"quota":{"future":{"remaining_fraction":0.9}}}"#), directory: dir, at: now)
        let fresh = AntigravityProvider.snapshot(at: now, sourceURL: file)
        XCTAssertNil(fresh.error); XCTAssertTrue(fresh.hasActiveConnection(at: now))
        let stale = AntigravityProvider.snapshot(at: now.addingTimeInterval(301), sourceURL: file)
        XCTAssertNotNil(stale.error); XCTAssertFalse(stale.hasActiveConnection(at: now.addingTimeInterval(301)))
        XCTAssertEqual(stale.updatedAt, now); XCTAssertEqual(stale.windows.map(\.usedPercent), fresh.windows.map(\.usedPercent))
    }
    func testAntigravityInstallerPreservesSettingsAndCanReconnect() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try data(#"{"colorScheme":"dark","trustedWorkspaces":["/project"]}"#).write(to: settings)
        let executable = URL(fileURLWithPath: "/Applications/My Kenar's.app/Contents/MacOS/Kenar")
        let launcher = try AntigravityIntegration.install(directory: dir, executable: executable)
        let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String:Any]
        XCTAssertEqual(configuration["colorScheme"] as? String, "dark")
        XCTAssertEqual(configuration["trustedWorkspaces"] as? [String], ["/project"])
        XCTAssertEqual((configuration["statusLine"] as? [String:Any])?["stack_with_default"] as? Bool, true)
        XCTAssertTrue(try String(contentsOf: launcher, encoding: .utf8).contains("'\\''"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        var slashConfiguration = configuration
        slashConfiguration["statusLine"] = ["command":launcher.path]
        try JSONSerialization.data(withJSONObject: slashConfiguration).write(to: settings)
        XCTAssertEqual(try AntigravityIntegration.install(directory: dir, executable: executable), launcher)
    }
    func testAntigravityInstallerRefusesCustomOrBrokenSettings() throws {
        let settings = dir.appendingPathComponent("settings.json")
        let executable = URL(fileURLWithPath: "/Applications/Kenar.app/Contents/MacOS/Kenar")
        for original in [#"{"statusLine":{"command":"my-custom-command"}}"#, "broken"] {
            try data(original).write(to: settings)
            do { _ = try AntigravityIntegration.install(directory: dir, executable: executable); XCTAssertTrue(false, "existing settings must be preserved") } catch {}
            XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("kenar-statusline.sh").path))
        }
        try FileManager.default.removeItem(at: settings)
        let target = dir.appendingPathComponent("target.json")
        try data("{}").write(to: target)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
        do { _ = try AntigravityIntegration.install(directory: dir, executable: executable); XCTAssertTrue(false) } catch {}
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "{}")
    }
    @MainActor func testAntigravityPreferenceMigration() throws {
        let domain = "KenarTests.\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: domain)!
        defer { isolated.removePersistentDomain(forName: domain) }
        var old = Preferences(); old.thresholds.removeValue(forKey:"antigravity")
        old.thresholds["gemini"] = [60,80]; old.hiddenProviders = ["gemini", "cursor"]; old.width = 370
        isolated.set(try JSONEncoder().encode(old), forKey:"preferences.v1")
        let migrated = Settings(defaults: isolated)
        XCTAssertEqual(migrated.values.thresholds["antigravity"], [60,80])
        XCTAssertEqual(migrated.values.width, 370)
        XCTAssertEqual(migrated.values.hiddenProviders, ["gemini", "cursor", "antigravity"])
        migrated.values.hiddenProviders.removeAll { $0 == "antigravity" }
        XCTAssertFalse(Settings(defaults: isolated).values.hiddenProviders.contains("antigravity"))
    }
    @MainActor func testAntigravityReplayDoesNotDuplicateHistory() async throws {
        let now = Date(), db = try database()
        try AntigravitySample.receive(data(#"{"quota":{"new":{"remaining_fraction":0.5}}}"#), directory: dir, at: now)
        let provider = AntigravityProvider(sourceURL: dir.appendingPathComponent("antigravity-usage.json"))
        var observed = [Date?]()
        let store = UsageStore(providers: [provider], analytics: db, quotaObserver: { observed.append($0.updatedAt) })
        for _ in 0..<2 {
            store.refreshAll()
            for _ in 0..<200 where store.isRefreshing { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertFalse(store.isRefreshing)
        }
        let points = db.points(provider:"antigravity", since: .distantPast)
        XCTAssertEqual(points.count, 1); XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(points.first?.date.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.01)
        let reopened = UsageStore(providers: [provider], analytics: db, quotaObserver: { _ in })
        reopened.refreshAll()
        for _ in 0..<200 where reopened.isRefreshing { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(reopened.isRefreshing)
        XCTAssertEqual(db.points(provider: "antigravity", since: .distantPast).count, 1)
    }
    func testGeminiModelsAndMissingQuota() {
        let windows = LegacyGeminiQuota.parseUsage(data(#"{"buckets":[{"modelId":"gemini-new-model","remainingFraction":0.58,"tokenType":"REQUESTS","resetTime":"2026-10-02T00:00:00Z"},{"modelId":"unknown-quota","tokenType":"TOKENS"}]}"#))
        XCTAssertEqual(windows.count,2); XCTAssertEqual(windows[0].usedPercent!,42,accuracy: 0.001)
        XCTAssertEqual(windows[0].modelID,"gemini-new-model"); XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertNil(windows[1].usedPercent); XCTAssertEqual(windows[1].unit,"TOKENS")
    }
    func testGeminiInvalidFractionsAndMalformedResponse() {
        XCTAssertTrue(LegacyGeminiQuota.parseUsage(data("broken")).isEmpty)
        let windows = LegacyGeminiQuota.parseUsage(data(#"{"buckets":[{"modelId":"x","remainingFraction":1.2},{"modelId":"y","remainingFraction":-0.1}]}"#))
        XCTAssertTrue(windows.allSatisfy { $0.usedPercent == nil })
    }
    func testGeminiMultipleQuotaTypesHaveStableIDs() {
        let windows = LegacyGeminiQuota.parseUsage(data(#"{"buckets":[{"modelId":"x","tokenType":"REQUESTS","remainingFraction":1},{"modelId":"x","tokenType":"TOKENS","remainingFraction":0.5}]}"#))
        XCTAssertEqual(Set(windows.map(\.id)).count,2)
    }
    func testClaudeLegacyAndNewModels() {
        XCTAssertEqual(ClaudeProvider.parseUsage(data(#"{"five_hour":{"utilization":68},"seven_day":{"utilization":31}}"#)).map(\.usedPercent),[68,31])
        let w = ClaudeProvider.parseUsage(data(#"{"limits":[{"kind":"weekly_scoped","percent":12,"scope":{"model":{"display_name":"Future model"}}}]}"#))
        XCTAssertEqual(w.first?.label,"Future model")
    }
    func testPreviewUsesProviderSpecificQuotaSchemas() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = Preview.sampleSnapshots(at: now)
        let codex = try XCTUnwrap(samples.first { $0.id == "codex" })
        let claude = try XCTUnwrap(samples.first { $0.id == "claude" })
        let cursor = try XCTUnwrap(samples.first { $0.id == "cursor" })
        let antigravity = try XCTUnwrap(samples.first { $0.id == "antigravity" })
        XCTAssertEqual(codex.windows.map(\.label), ["Current session", "Weekly"])
        XCTAssertEqual(claude.windows.map(\.label), ["Current session", "All models", "Fable"])
        XCTAssertNotEqual(codex.primary?.resetsAt, claude.primary?.resetsAt)
        XCTAssertEqual(cursor.primary?.label, "Included usage")
        XCTAssertTrue(cursor.windows.allSatisfy { $0.label != "Weekly" })
        XCTAssertTrue(antigravity.windows.map(\.id) == ["gemini-weekly", "claude-weekly"])
        XCTAssertTrue(samples.allSatisfy { $0.isDemo && $0.error == nil && $0.updatedAt == now })
    }
    func testCodexResetPrefersAbsoluteTimestamp() {
        let absolute = Date().addingTimeInterval(600).timeIntervalSince1970
        XCTAssertEqual(CodexProvider.resetDate(["resets_at":absolute,"resets_in_seconds":50])!.timeIntervalSince1970,absolute,accuracy: 0.01)
        let windows = CodexProvider.parseUsage(data(#"{"rate_limit":{"primary_window":{"used_percent":42},"secondary_window":{"used_percent":31}}}"#))
        XCTAssertEqual(windows.map(\.usedPercent),[42,31])
        XCTAssertEqual(CodexProvider.resetDate(["reset_at":absolute,"reset_after_seconds":50])!.timeIntervalSince1970,absolute,accuracy:0.01)
    }
    func testCursorUnlimitedHasNoFakeZero() {
        let windows = CursorProvider.parseUsage(data(#"{"isUnlimited":true}"#))
        XCTAssertTrue(windows.first!.isUnlimited); XCTAssertNil(windows.first!.usedPercent)
    }
    func testClaudeKeychainFailuresAreNotMissingLogin() {
        XCTAssertEqual(ClaudeCredentialStore.Failure.keychainStatus(errSecItemNotFound), .notFound)
        XCTAssertEqual(ClaudeCredentialStore.Failure.keychainStatus(errSecInteractionNotAllowed), .accessRequired)
        XCTAssertEqual(ClaudeCredentialStore.Failure.keychainStatus(errSecAuthFailed), .accessDenied)
        XCTAssertEqual(ClaudeCredentialStore.Failure.keychainStatus(100001), .accessDenied)
        XCTAssertEqual(ClaudeCredentialStore.Failure.keychainStatus(-9999), .keychainError(-9999))
        XCTAssertNotEqual(ClaudeCredentialStore.Failure.accessRequired.message, ClaudeCredentialStore.Failure.notFound.message)
    }
    func testClaudeBackgroundKeychainReadCannotShowPermissionUI() {
        let quiet = ClaudeCredentialStore.keychainQuery(allowInteraction: false)
        let manual = ClaudeCredentialStore.keychainQuery(allowInteraction: true)
        XCTAssertEqual(quiet[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertEqual(manual[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIAllow as String)
    }
    func testClaudeRejectedTokenWaitsForRotationWithoutInteraction() throws {
        let source = dir.appendingPathComponent("source"), cache = dir.appendingPathComponent("cache")
        let old = data(#"{"claudeAiOauth":{"accessToken":"rejected-access","expiresAt":9999999999999}}"#)
        let fresh = data(#"{"claudeAiOauth":{"accessToken":"rotated-access","expiresAt":9999999999999}}"#)
        var current = old, interaction = [Bool]()
        let store = ClaudeCredentialStore(sourceURL: source, cacheURL: cache, readFile: { $0 == cache ? old : nil }, readKeychain: { allow in
            interaction.append(allow); return .init(data: current, status: errSecSuccess)
        })
        XCTAssertEqual(try store.load().get().accessToken, "rejected-access")
        store.invalidate(rejectedAccessToken: "rejected-access")
        for _ in 0..<2 {
            if case .failure = store.load(forceSourceRead: true) {} else { XCTAssertTrue(false, "HTTP 401 tokens must not trigger repeated quota requests") }
        }
        current = fresh
        XCTAssertEqual(try store.load(forceSourceRead: true).get().accessToken, "rotated-access")
        XCTAssertEqual(interaction, [false, false, false])
        XCTAssertEqual(try store.load().get().accessToken, "rotated-access")
    }
    @MainActor func testClaudeAutomaticRecoveryIsSilentAndProviderSpecific() async throws {
        let probe = RecoveryProbeSpy(), claude = RetryProviderSpy(id: "claude"), codex = RetryProviderSpy(id: "codex")
        let store = UsageStore(providers: [claude, codex], analytics: nil, credentialProbe: { probe.read() })
        var failed = snapshot(12, id: "claude")
        failed.error = "Keychain blocked"; failed.needsCredentialRecovery = true
        store.snapshots = [failed, snapshot(39)]
        let now = Date()
        store.checkCredentialRecovery(at: now)
        store.checkCredentialRecovery(at: now) // no overlapping probes
        for _ in 0..<100 where store.probingCredentials || store.isRefreshing { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(probe.count, 1)
        let initial = await claude.calls(); XCTAssertEqual(initial, [])
        probe.available = true
        store.checkCredentialRecovery(at: now.addingTimeInterval(4))
        XCTAssertEqual(probe.count, 1)
        store.checkCredentialRecovery(at: now.addingTimeInterval(5))
        for _ in 0..<100 where store.probingCredentials || store.isRefreshing { try await Task.sleep(nanoseconds: 1_000_000) }
        let recovered = await claude.calls(), unrelated = await codex.calls()
        XCTAssertEqual(recovered, [false]); XCTAssertEqual(unrelated, [])
        XCTAssertEqual(probe.count, 2)
        XCTAssertEqual(store.snapshots.first?.windows.first?.usedPercent, 12) // retain stale values on an API failure
    }
    @MainActor func testClaudeRecoveryDoesNotPollHealthyOrRateLimitedAccounts() async throws {
        let probe = RecoveryProbeSpy(), store = UsageStore(providers: [], analytics: nil, credentialProbe: { probe.read() })
        var claude = snapshot(12, id: "claude")
        for error in [nil, "Rate limited", "Offline"] as [String?] {
            claude.error = error; store.snapshots = [claude]
            store.checkCredentialRecovery()
        }
        await Task.yield()
        XCTAssertEqual(probe.count, 0)
    }
    func testClaudeLoginRecoveryHasNoNegativeCache() throws {
        let now = Date(), fixture = data(#"{"claudeAiOauth":{"accessToken":"fixture-access","expiresAt":9999999999999}}"#)
        var available = false, reads = 0, interaction = [Bool]()
        let store = ClaudeCredentialStore(sourceURL: dir.appendingPathComponent("source"), cacheURL: dir.appendingPathComponent("cache"), readFile: { _ in nil }, readKeychain: { allow in
            reads += 1; interaction.append(allow)
            return .init(data: available ? fixture : nil, status: available ? errSecSuccess : errSecInteractionNotAllowed)
        })
        if case .failure(let failure) = store.load(now: now) { XCTAssertEqual(failure, .accessRequired) }
        else { XCTAssertTrue(false, "A blocked read cannot create a successful connection") }
        available = true
        let creds = try store.load(forceSourceRead: true, allowInteraction: true, now: now).get()
        XCTAssertEqual(creds.accessToken, "fixture-access")
        XCTAssertEqual(reads, 2); XCTAssertEqual(interaction, [false, true])
        _ = try store.load(now: now).get(); XCTAssertEqual(reads, 2)
    }
    func testClaudeExplicitRetryReadsRotatedSourceInsteadOfCache() throws {
        let now = Date(), source = dir.appendingPathComponent("source"), cache = dir.appendingPathComponent("cache")
        let cached = data(#"{"claudeAiOauth":{"accessToken":"old-access","expiresAt":9999999999999}}"#)
        let fresh = data(#"{"claudeAiOauth":{"accessToken":"new-access","expiresAt":9999999999999}}"#)
        var reads = 0
        let store = ClaudeCredentialStore(sourceURL: source, cacheURL: cache, readFile: { $0 == cache ? cached : nil }, readKeychain: { _ in
            reads += 1; return .init(data: fresh, status: errSecSuccess)
        })
        XCTAssertEqual(try store.load(now: now).get().accessToken, "old-access")
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(try store.load(forceSourceRead: true, allowInteraction: true, now: now).get().accessToken, "new-access")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try store.load(now: now).get().accessToken, "new-access")
    }
    func testClaudeFailedExplicitCheckCannotReviveOldCache() throws {
        let source = dir.appendingPathComponent("source"), cache = dir.appendingPathComponent("cache")
        let fixture = data(#"{"claudeAiOauth":{"accessToken":"old-access","expiresAt":9999999999999}}"#)
        var reads = 0
        let store = ClaudeCredentialStore(sourceURL: source, cacheURL: cache, readFile: { $0 == cache ? fixture : nil }, readKeychain: { _ in
            reads += 1; return .init(data: nil, status: errSecItemNotFound)
        })
        _ = try store.load().get()
        for force in [true, false] {
            if case .failure(let failure) = store.load(forceSourceRead: force) { XCTAssertEqual(failure, .notFound) }
            else { XCTAssertTrue(false, "A failed explicit check cannot resurrect a cached login") }
        }
        XCTAssertEqual(reads, 2)
    }
    @MainActor func testRetryOnlyFetchesSelectedProviderWithInteractiveIntent() async throws {
        let claude = RetryProviderSpy(id: "claude"), codex = RetryProviderSpy(id: "codex")
        let store = UsageStore(providers: [claude, codex], analytics: nil)
        store.retryConnection(providerID: "claude")
        for _ in 0..<100 where store.isRefreshing { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(store.isRefreshing)
        let firstClaude = await claude.calls(), firstCodex = await codex.calls()
        XCTAssertEqual(firstClaude, [true]); XCTAssertEqual(firstCodex, [])
        store.refreshAll()
        for _ in 0..<100 where store.isRefreshing { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(store.isRefreshing)
        let allClaude = await claude.calls(), allCodex = await codex.calls()
        XCTAssertEqual(allClaude, [true, false]); XCTAssertEqual(allCodex, [false])
    }
    func testClaudeExpiredAndMalformedCredentialsStayDistinct() {
        let source = dir.appendingPathComponent("source"), cache = dir.appendingPathComponent("cache")
        for (fixture, expected) in [(data(#"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1000}}"#), ClaudeCredentialStore.Failure.expired), (data(#"{"claudeAiOauth":{"accessToken":"  "}}"#), .invalidData)] {
            let store = ClaudeCredentialStore(sourceURL: source, cacheURL: cache, readFile: { $0 == source ? fixture : nil }, readKeychain: { _ in .init(data: nil, status: errSecItemNotFound) })
            if case .failure(let failure) = store.load() { XCTAssertEqual(failure, expected) }
            else { XCTAssertTrue(false, "Expired or malformed credentials cannot connect") }
        }
        XCTAssertNil(ClaudeProvider.parseCredentialsJSON(data(#"{"claudeAiOauth":{"accessToken":""}}"#)))
    }
    func testMissingLoginNeverShowsDemoValues() {
        let snapshot = ClaudeProvider.demoSnapshot(name:"Codex",systemImage:"terminal",note:"login required")
        XCTAssertTrue(snapshot.windows.isEmpty); XCTAssertFalse(snapshot.isDemo)
    }
    func testInvalidPercentAndUnknownReset() {
        XCTAssertNil(UsageWindow(label:"x",usedPercent: .nan,resetsAt:nil).usedPercent)
        XCTAssertNil(UsageWindow(label:"x",usedPercent: -1,resetsAt:nil).usedPercent)
        XCTAssertNil(UsageWindow(label:"x",usedPercent: nil,resetsAt:nil).resetText)
    }
    func testCountdownExpiresWithoutClaimingFreshQuota() {
        let now=Date(); let w=UsageWindow(label:"x",usedPercent:90,resetsAt:now.addingTimeInterval(8280))
        XCTAssertEqual(w.countdown(at:now),"Yenilenme: 2 sa 18 dk")
        XCTAssertEqual(w.countdown(at:now.addingTimeInterval(9000)),"Yenilenme kontrol ediliyor…")
    }
    func testNotificationRestartDeduplication() throws {
        var ledger=NotificationLedger(); let reset=Date().addingTimeInterval(600)
        XCTAssertEqual(ledger.observe(key:"codex|session",used:91,reset:reset,thresholds:[75,90,100]).crossed,[75,90])
        let saved=try JSONEncoder().encode(ledger); ledger=try JSONDecoder().decode(NotificationLedger.self,from:saved)
        XCTAssertEqual(ledger.observe(key:"codex|session",used:93,reset:reset,thresholds:[75,90,100]).crossed,[])
        XCTAssertEqual(ledger.observe(key:"codex|session",used:100,reset:reset,thresholds:[75,90,100]).crossed,[100])
    }
    func testNotificationNewPeriodAndResetTolerance() {
        var ledger=NotificationLedger(); let reset=Date().addingTimeInterval(600)
        let first=ledger.observe(key:"x",used:90,reset:reset,thresholds:[75,90])
        let nearby=ledger.observe(key:"x",used:90,reset:reset.addingTimeInterval(10),thresholds:[75,90])
        XCTAssertEqual(nearby.period,first.period); XCTAssertTrue(nearby.crossed.isEmpty)
        let fresh=ledger.observe(key:"x",used:90,reset:reset.addingTimeInterval(18000),thresholds:[75,90])
        XCTAssertTrue(fresh.renewed); XCTAssertEqual(fresh.crossed,[75,90])
    }
    func testNotificationProvidersAndMetersAreIndependent() {
        var ledger=NotificationLedger()
        XCTAssertEqual(ledger.observe(key:"a|session",used:80,reset:nil,thresholds:[75]).crossed,[75])
        XCTAssertEqual(ledger.observe(key:"a|weekly",used:80,reset:nil,thresholds:[75]).crossed,[75])
        XCTAssertEqual(ledger.observe(key:"b|session",used:80,reset:nil,thresholds:[75]).crossed,[75])
    }
    func testHistorySeparatesResetPeriodsAndPrunesOldSamples() throws {
        let db=try database(); let now=Date(); let reset=now.addingTimeInterval(1000)
        db.record(snapshot(40,reset:reset),now:now.addingTimeInterval(-100*86400))
        db.record(snapshot(42,reset:reset),now:now)
        db.record(snapshot(50,reset:reset.addingTimeInterval(10)),now:now.addingTimeInterval(30))
        db.record(snapshot(2,reset:reset.addingTimeInterval(18000)),now:now.addingTimeInterval(60))
        let points=db.points(provider:"codex",since:.distantPast)
        XCTAssertEqual(points.count,3); XCTAssertEqual(points[0].period,points[1].period); XCTAssertNotEqual(points[1].period,points[2].period)
    }
    func testFailedAndDemoSnapshotsNeverEnterHistory() throws {
        let db=try database(); var failed=snapshot(42); failed.error="offline"; db.record(failed)
        var demo=snapshot(42); demo.isDemo=true; db.record(demo)
        XCTAssertTrue(db.points(provider:"codex",since:.distantPast).isEmpty)
    }
    func testStreamingEventsKeepMaximumAndDoNotMixProviders() throws {
        let db=try database(); let now=Date()
        var event=TokenEvent(provider:"claude",key:"r1",timestamp:now,session:"s",project:"/a",model:"m",input:100,output:10,cached:5)
        db.importEvents([event],path:"fixture",size:1,modified:1)
        event.output=20; db.importEvents([event],path:"fixture",size:2,modified:2)
        event.provider="codex"; db.importEvents([event],path:"fixture2",size:2,modified:2)
        XCTAssertEqual(db.projects(provider:"claude",range:.all).first?.tokens,120)
        XCTAssertEqual(db.projects(provider:"codex",range:.all).first?.tokens,120)
    }
    func testLatestSessionAndDifferentProjects() throws {
        let db=try database();let now=Date()
        db.importEvents([TokenEvent(provider:"codex",key:"old",timestamp:now.addingTimeInterval(-100),session:"old",project:"/a",model:"m",input:10,output:0,cached:0),TokenEvent(provider:"codex",key:"new",timestamp:now,session:"new",project:"/b",model:"m",input:20,output:0,cached:0)],path:"fixture",size:1,modified:1)
        XCTAssertEqual(db.projects(provider:"codex",range:.all).count,2)
        XCTAssertEqual(db.projects(provider:"codex",range:.session).map(\.project),["/b"])
    }
    func testAttributionDoesNotAssignBaselineOrResetAndKeepsElsewhere() throws {
        let db=try database();let now=Date();let reset=now.addingTimeInterval(1000)
        db.record(snapshot(40,reset:reset),now:now)
        db.importEvents([TokenEvent(provider:"codex",key:"turn",timestamp:now.addingTimeInterval(10),session:"s",project:"/a",model:"m",input:100,output:0,cached:0)],path:"fixture",size:1,modified:1)
        db.record(snapshot(50,reset:reset),now:now.addingTimeInterval(20))
        db.record(snapshot(55,reset:reset),now:now.addingTimeInterval(30))
        db.record(snapshot(2,reset:reset.addingTimeInterval(18000)),now:now.addingTimeInterval(40))
        let rows=db.attribution(provider:"codex",meter:"session",since:.distantPast)
        XCTAssertEqual(rows.first { $0.project=="/a" }?.percentagePoints,10)
        XCTAssertEqual(rows.first { $0.project=="__elsewhere__" }?.percentagePoints,5)
        XCTAssertEqual(rows.map(\.percentagePoints).reduce(0,+),15)
    }
    func testAllEdgesFitNegativeOriginDisplayAndLargeContent() {
        let visible=NSRect(x:-1920,y:40,width:1920,height:1040)
        for edge in PanelEdge.allCases {
            let frame=DisplayGeometry.frame(edge:edge,visible:visible,size:NSSize(width:440,height:2000),expanded:true)
            XCTAssertTrue(visible.contains(frame),"\(edge)")
            let closed=DisplayGeometry.frame(edge:edge,visible:visible,size:.zero,expanded:false)
            XCTAssertTrue(visible.contains(closed)); XCTAssertEqual(min(closed.width,closed.height),66)
            switch edge {
            case .right: XCTAssertEqual(frame.maxX,visible.maxX); XCTAssertEqual(closed.maxX,visible.maxX)
            case .left: XCTAssertEqual(frame.minX,visible.minX); XCTAssertEqual(closed.minX,visible.minX)
            }
            let reduced=DisplayGeometry.frame(edge:edge,visible:visible,size:.zero,expanded:false,compactSize:NSSize(width:66,height:78))
            XCTAssertTrue(visible.contains(reduced)); XCTAssertEqual(max(reduced.width,reduced.height),78)
        }
    }
    func testIslandOutlineAttachesToChosenEdge() {
        let rect=CGRect(x:10,y:20,width:300,height:344)
        for edge in PanelEdge.allCases {
            let path=EdgeIslandShape(edge:edge).path(in:rect)
            let attached: CGPoint
            switch edge {
            case .right: attached=CGPoint(x:rect.maxX-1,y:rect.midY)
            case .left: attached=CGPoint(x:rect.minX+1,y:rect.midY)
            }
            XCTAssertTrue(path.contains(attached),"\(edge) must join the edge")
            XCTAssertTrue(path.contains(CGPoint(x:rect.midX,y:rect.midY)))
            XCTAssertFalse(path.contains(CGPoint(x:rect.minX+1,y:rect.minY+1)))
        }
    }
    @MainActor func testIslandWidthMigrationKeepsCustomSettings() throws {
        let domain="KenarTests.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        var old=Preferences();old.width=340
        defaults.set(try JSONEncoder().encode(old),forKey:"preferences.v1")
        XCTAssertEqual(Settings(defaults:defaults).values.width,300)
        XCTAssertEqual(Settings(defaults:defaults).values.width,300)
        defaults.removeObject(forKey:"island-layout.v1")
        old.width=370;old.edge = .left;old.hiddenProviders=["cursor"]
        defaults.set(try JSONEncoder().encode(old),forKey:"preferences.v1")
        let migrated=Settings(defaults:defaults)
        XCTAssertEqual(migrated.values.width,370);XCTAssertEqual(migrated.values.edge,.left)
        XCTAssertEqual(migrated.values.hiddenProviders,["cursor"])
    }
    @MainActor func testLegacyVerticalEdgeMigrationKeepsPreferences() throws {
        let domain="KenarTests.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        var old=Preferences();old.width=370;old.fontSize=15;old.hiddenProviders=["cursor"]
        old.thresholds["codex"]=[70,85,100]
        for edge in ["top","bottom"] {
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any]
            object["edge"]=edge;object.removeValue(forKey:"language")
            defaults.set(try JSONSerialization.data(withJSONObject:object),forKey:"preferences.v1")
            let restored=Settings(defaults:defaults)
            XCTAssertEqual(restored.values.edge,.right);XCTAssertEqual(restored.values.width,370)
            let saved=try JSONDecoder().decode(Preferences.self,from:defaults.data(forKey:"preferences.v1")!)
            XCTAssertEqual(saved.edge,.right)
            XCTAssertEqual(restored.values.fontSize,15);XCTAssertEqual(restored.values.hiddenProviders,["cursor"])
            XCTAssertEqual(restored.values.thresholds["codex"],[70,85,100]);XCTAssertEqual(restored.language,.turkish)
        }
        XCTAssertEqual(PanelEdge.allCases,[.right,.left])
    }
    func testHoverExitRespondsImmediatelyAndRespectsPin() {
        let island=CGRect(x:934,y:200,width:66,height:204)
        let activation=island.insetBy(dx:-5,dy:-5)
        let panel=CGRect(x:700,y:150,width:300,height:346)
        XCTAssertEqual(PanelInteraction.action(mouse:CGPoint(x:970,y:250),activation:activation,panel:island,expanded:false,pinned:false,suppressed:false),.expand)
        // First poll after leaving must collapse, with no prior timestamp/cooldown.
        XCTAssertEqual(PanelInteraction.action(mouse:CGPoint(x:690,y:250),activation:activation,panel:panel,expanded:true,pinned:false,suppressed:false),.collapse)
        XCTAssertEqual(PanelInteraction.action(mouse:CGPoint(x:696,y:250),activation:activation,panel:panel,expanded:true,pinned:false,suppressed:false),.none)
        XCTAssertEqual(PanelInteraction.action(mouse:CGPoint(x:690,y:250),activation:activation,panel:panel,expanded:true,pinned:true,suppressed:false),.none)
        XCTAssertEqual(PanelInteraction.action(mouse:CGPoint(x:970,y:250),activation:activation,panel:island,expanded:false,pinned:false,suppressed:true),.none)
    }
    @MainActor func testEnglishLanguagePersistenceAndFormatting() throws {
        let previous=L10n.override; defer { L10n.override=previous }
        let domain="KenarTests.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        let settings=Settings(defaults:defaults);settings.values.language = .english
        XCTAssertEqual(Settings(defaults:defaults).language,.english)
        L10n.override=settings.language.rawValue
        XCTAssertEqual(L("Kenar Ayarları"),"Kenar Settings")
        XCTAssertEqual(L("Proje analizi"),"Project analysis")
        XCTAssertEqual(L("Bildirimler çalışıyor. Kullanım eşiklerini sağlayıcı bazında ayarlayabilirsin."),"Notifications are working. You can adjust alert thresholds for each provider.")
        XCTAssertEqual(DisplayFormat.percent(42),"42%")
        XCTAssertEqual(DisplayFormat.number(12345),"12,345")
        XCTAssertEqual(DisplayFormat.locale.identifier,"en_US")
        let now=Date();let window=UsageWindow(label:"Weekly",usedPercent:42,resetsAt:now.addingTimeInterval(8280))
        XCTAssertEqual(window.title,"Weekly");XCTAssertEqual(window.countdown(at:now),"Resets in 2 h 18 min")
        L10n.override="tr"
        XCTAssertEqual(L("Kenar Ayarları"),"Kenar Ayarları")
        XCTAssertEqual(DisplayFormat.percent(42),"%42")
        XCTAssertEqual(window.title,"Haftalık")
        XCTAssertEqual(DisplayFormat.locale.identifier,"tr_TR")
    }
    @MainActor func testOfflinePreservesLastSuccessfulMeasurement() async {
        let previous=snapshot(42); var failed=snapshot(0); failed.windows=[];failed.updatedAt=nil;failed.error="offline"
        let merged=UsageStore.merging(failed,with:previous)
        XCTAssertEqual(merged.primary?.usedPercent,42);XCTAssertEqual(merged.updatedAt,previous.updatedAt);XCTAssertTrue(merged.isStale)
    }
    func testCompactIslandZeroSessionDoesNotUseWeeklyQuota() {
        let windows = CodexProvider.parseUsage(data(#"{"rate_limit":{"primary_window":{"used_percent":0},"secondary_window":{"used_percent":24}}}"#))
        let codex = ProviderSnapshot(id: "codex", name: "OpenAI", systemImage: "circle", windows: windows)
        XCTAssertEqual(codex.compactSession?.usedPercent, 0)
        XCTAssertEqual(codex.primary?.usedPercent, 24)
        XCTAssertEqual(codex.windows.count, 2)

        let claude = ProviderSnapshot(id: "claude", name: "Claude", systemImage: "circle",
            windows: ClaudeProvider.parseUsage(data(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":100}}"#)))
        XCTAssertEqual(claude.compactSession?.usedPercent, 0)
        XCTAssertEqual(claude.primary?.usedPercent, 100)
        var ledger = NotificationLedger()
        let weekly = claude.windows[1]
        XCTAssertEqual(ledger.observe(key: weekly.identity(provider: claude.id), used: weekly.usedPercent!, reset: nil, thresholds: [75,90,100]).crossed, [75,90,100])
        XCTAssertTrue(ledger.observe(key: weekly.identity(provider: claude.id), used: weekly.usedPercent!, reset: nil, thresholds: [75,90,100]).crossed.isEmpty)
    }
    func testCompactIslandMissingOrUnreadableSessionDoesNotFallBack() {
        var snap = ProviderSnapshot(id: "codex", name: "OpenAI", systemImage: "circle",
            windows: [UsageWindow(label: "Weekly", usedPercent: 90, resetsAt: nil)])
        XCTAssertNil(snap.compactSession)
        var session = UsageWindow(label: "Current session", usedPercent: nil, resetsAt: nil)
        snap.windows.insert(session, at: 0)
        XCTAssertNil(snap.compactSession?.usedPercent)
        session.usedPercent = 0; session.issue = "Unavailable"; snap.windows[0] = session
        XCTAssertNil(snap.compactSession)
        session.issue = nil; session.measuredAt = Date().addingTimeInterval(-301); snap.windows[0] = session
        XCTAssertNil(snap.compactSession)
        session.measuredAt = Date().addingTimeInterval(60); snap.windows[0] = session
        XCTAssertNil(snap.compactSession)
        session.measuredAt = Date(); snap.windows[0] = session
        XCTAssertEqual(snap.compactSession?.usedPercent, 0)
    }
    @MainActor func testCompactIslandOnlyShowsConnectedProviders() {
        let now=Date()
        let store=UsageStore(providers:[],analytics:nil)
        var codex=snapshot(42);codex.updatedAt=now
        var claude=snapshot(0,id:"claude");claude.windows=[];claude.updatedAt=nil;claude.error="Oturum yok"
        var failed=snapshot(0);failed.windows=[];failed.updatedAt=nil;failed.error="offline"
        let cached=UsageStore.merging(failed,with:codex)
        var cursor=snapshot(0,id:"cursor");cursor.updatedAt=now
        cursor.windows=[UsageWindow(label:"Unlimited",usedPercent:nil,resetsAt:nil,isUnlimited:true)]
        var gemini=snapshot(0,id:"gemini");gemini.updatedAt=now
        gemini.windows=[UsageWindow(label:"Unknown quota",usedPercent:nil,resetsAt:nil)]
        store.snapshots=[cached,claude,cursor,gemini]
        XCTAssertEqual(store.compactProviders(hiddenProviders:[],at:now).map(\.id),["cursor"])
        XCTAssertEqual(store.compactProviders(hiddenProviders:["cursor"],at:now).map(\.id),[])
        XCTAssertEqual(store.snapshots.count,4)
        XCTAssertEqual(store.snapshots.first?.primary?.usedPercent,42)
        // All rows remain available to the expanded panel, including cached errors.
        XCTAssertEqual(store.snapshots.first?.error,"offline")
        var pending=codex;pending.updatedAt=nil
        XCTAssertFalse(pending.hasActiveConnection(at:now))
    }
    @MainActor func testCompactIslandTracksExpiryAndRecovery() {
        let now=Date()
        let store=UsageStore(providers:[],analytics:nil)
        var connected=snapshot(42);connected.updatedAt=now
        store.snapshots=[connected]
        store.updateConnectionHealth(at:now)
        XCTAssertEqual(store.connectionRevision,1)
        XCTAssertEqual(store.compactProviders(hiddenProviders:[],at:now).count,1)
        store.updateConnectionHealth(at:now.addingTimeInterval(300))
        XCTAssertEqual(store.connectionRevision,1)
        store.updateConnectionHealth(at:now.addingTimeInterval(301))
        XCTAssertEqual(store.connectionRevision,2)
        XCTAssertTrue(store.compactProviders(hiddenProviders:[],at:now.addingTimeInterval(301)).isEmpty)
        connected.updatedAt=now.addingTimeInterval(302);store.snapshots=[connected]
        store.updateConnectionHealth(at:now.addingTimeInterval(302))
        XCTAssertEqual(store.connectionRevision,3)
        XCTAssertEqual(store.compactProviders(hiddenProviders:[],at:now.addingTimeInterval(302)).count,1)
        connected.error="Oturum süresi doldu";store.snapshots=[connected]
        store.updateConnectionHealth(at:now.addingTimeInterval(303))
        XCTAssertEqual(store.connectionRevision,4)
        XCTAssertTrue(store.compactProviders(hiddenProviders:[],at:now.addingTimeInterval(303)).isEmpty)
        XCTAssertEqual(store.snapshots.count,1)
    }
    func testTranscriptImportAllThreeProvidersAndPrivacy() throws {
        let db=try database();let roots=["claude":dir.appendingPathComponent("claude"),"codex":dir.appendingPathComponent("codex"),"gemini":dir.appendingPathComponent("gemini")]
        let project=dir.appendingPathComponent("repo");try FileManager.default.createDirectory(at:project.appendingPathComponent(".git"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:project.appendingPathComponent("src"),withIntermediateDirectories:true)
        let stamp=ISO8601DateFormatter().string(from:Date())
        func json(_ obj:[String:Any]) throws -> String { String(data:try JSONSerialization.data(withJSONObject:obj),encoding:.utf8)! }
        for root in roots.values { try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true) }
        let claude=try json(["type":"assistant","timestamp":stamp,"cwd":project.appendingPathComponent("src").path,"sessionId":"c","requestId":"r","message":["model":"m","content":"NEVER_STORE_THIS_SECRET","usage":["input_tokens":100,"output_tokens":20,"cache_read_input_tokens":10]]])
        try (claude+"\n"+claude+"\n").write(to:roots["claude"]!.appendingPathComponent("s.jsonl"),atomically:true,encoding:.utf8)
        let codex=[try json(["type":"session_meta","payload":["id":"x","cwd":project.path]]),try json(["type":"event_msg","timestamp":stamp,"payload":["type":"token_count","info":["total_token_usage":["input_tokens":200,"output_tokens":50,"cached_input_tokens":40]]]]),try json(["type":"event_msg","timestamp":stamp,"payload":["type":"token_count","info":["total_token_usage":["input_tokens":300,"output_tokens":80,"cached_input_tokens":50]]]])].joined(separator:"\n")+"\n"
        try codex.write(to:roots["codex"]!.appendingPathComponent("s.jsonl"),atomically:true,encoding:.utf8)
        let chats=roots["gemini"]!.appendingPathComponent("project/chats");try FileManager.default.createDirectory(at:chats,withIntermediateDirectories:true)
        let gemini=try json(["sessionId":"g","projectHash":"hash","directories":[project.path],"messages":[["id":"message1","type":"gemini","timestamp":stamp,"model":"gemini-future","content":"NEVER_STORE_THIS_SECRET","tokens":["input":150,"output":40,"thoughts":10,"cached":20]]]])
        try gemini.write(to:chats.appendingPathComponent("session-legacy.json"),atomically:true,encoding:.utf8)
        let indexer=TranscriptIndexer(store:db,roots:roots)
        XCTAssertGreaterThan(indexer.scan(),0);XCTAssertEqual(indexer.scan(),0)
        XCTAssertEqual(db.projects(provider:"claude",range:.all).first?.project,project.path)
        XCTAssertEqual(db.projects(provider:"claude",range:.all).first?.tokens,120)
        XCTAssertEqual(db.projects(provider:"codex",range:.all).first?.tokens,380)
        XCTAssertEqual(db.projects(provider:"gemini",range:.all).first?.tokens,200)
        for name in ["analytics.sqlite","analytics.sqlite-wal"] {
            if let bytes=try? Data(contentsOf:dir.appendingPathComponent(name)) { XCTAssertNil(bytes.range(of:Data("NEVER_STORE_THIS_SECRET".utf8))) }
        }
    }
    func testGeminiJSONLStreamingAndIncompleteLine() throws {
        let db=try database();let root=dir.appendingPathComponent("gemini");let chats=root.appendingPathComponent("project/chats")
        try FileManager.default.createDirectory(at:chats,withIntermediateDirectories:true)
        let file=chats.appendingPathComponent("session-modern.jsonl")
        let stamp=ISO8601DateFormatter().string(from:Date())
        let header=#"{"sessionId":"g","projectHash":"p","directories":["/fixture"]}"#
        let message="{\"id\":\"r\",\"type\":\"gemini\",\"timestamp\":\"\(stamp)\",\"tokens\":{\"input\":100,\"output\":20,\"cached\":5}}"
        try (header+"\n"+message).write(to:file,atomically:true,encoding:.utf8)
        let indexer=TranscriptIndexer(store:db,roots:["gemini":root]);_=indexer.scan()
        XCTAssertTrue(db.projects(provider:"gemini",range:.all).isEmpty)
        try (header+"\n"+message+"\n"+message+"\n").write(to:file,atomically:true,encoding:.utf8);_=indexer.scan()
        XCTAssertEqual(db.projects(provider:"gemini",range:.all).first?.tokens,120)
    }
    func testRepeatedGeminiBucketsSelectMostConstrainedQuota() {
        let windows=LegacyGeminiQuota.parseUsage(data(#"{"buckets":[{"modelId":"gemini-new","tokenType":"REQUESTS","remainingFraction":0.9,"resetTime":"2026-10-02T00:00:00Z"},{"modelId":"gemini-new","tokenType":"REQUESTS","remainingFraction":0.2,"resetTime":"2026-10-03T00:00:00Z"}]}"#))
        XCTAssertEqual(windows.count,1);XCTAssertEqual(windows[0].usedPercent!,80,accuracy:0.001)
        XCTAssertEqual(windows[0].resetText != nil,true)
    }
    func testCredentialsCannotFollowCrossOriginRedirect() {
        let origin=URL(string:"https://cursor.com/api/usage-summary")
        XCTAssertTrue(ProviderHTTP.permitsRedirect(from:origin,to:URL(string:"https://cursor.com/new")))
        XCTAssertFalse(ProviderHTTP.permitsRedirect(from:origin,to:URL(string:"https://other.example/new")))
        XCTAssertFalse(ProviderHTTP.permitsRedirect(from:origin,to:URL(string:"http://cursor.com/new")))
        XCTAssertFalse(ProviderHTTP.permitsRedirect(from:origin,to:URL(string:"https://cursor.com:8443/new")))
    }
    func testChartDownsamplingPreservesExtremaAndPeriods() {
        let now=Date()
        let points: [QuotaPoint]=(0..<3000).map { index in
            let percent: Double = index == 1111 ? 100 : (index == 2222 ? 0 : 40)
            let period = index < 2000 ? "a" : "b"
            return QuotaPoint(id:Int64(index),provider:"codex",meter:"s",title:"s",model:"",unit:"quota",date:now.addingTimeInterval(Double(index)),percent:percent,reset:nil,period:period)
        }
        let result=QuotaSeries.downsample(points)
        XCTAssertTrue(result.count<points.count);XCTAssertNotNil(result.first { $0.id == 1111 });XCTAssertNotNil(result.first { $0.id == 2222 })
        XCTAssertEqual(result.first?.id,0);XCTAssertEqual(result.last?.id,2999)
        XCTAssertNotNil(result.first { $0.id == 1999 });XCTAssertNotNil(result.first { $0.id == 2000 })
    }
    func testScopedQuotaAttributionExcludesOtherModels() throws {
        let db=try database();let now=Date();let reset=now.addingTimeInterval(1000)
        var sample=snapshot(10,reset:reset,id:"gemini",meter:"pro");sample.windows[0].modelID="gemini-pro"
        db.record(sample,now:now)
        db.importEvents([TokenEvent(provider:"gemini",key:"pro",timestamp:now.addingTimeInterval(10),session:"s",project:"/pro",model:"gemini-pro-preview",input:100,output:0,cached:0),TokenEvent(provider:"gemini",key:"flash",timestamp:now.addingTimeInterval(10),session:"s",project:"/flash",model:"gemini-flash",input:100,output:0,cached:0)],path:"fixture",size:1,modified:1)
        sample.windows[0].usedPercent=20;db.record(sample,now:now.addingTimeInterval(20))
        let rows=db.attribution(provider:"gemini",meter:"pro",since:.distantPast)
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].project,"/pro");XCTAssertEqual(rows[0].percentagePoints,10)
        XCTAssertEqual(db.knownProjects().count,2)
    }
    func testFailedImportRollsBackCursorAndCanBeRetried() throws {
        let db=try database();var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("analytics.sqlite").path,&connection),SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,"CREATE TRIGGER fail_event BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'fixture failure'); END",nil,nil,nil),SQLITE_OK)
        let event=TokenEvent(provider:"codex",key:"retry",timestamp:Date(),session:"s",project:"/a",model:"m",input:10,output:5,cached:0)
        db.importEvents([event],path:"retry.jsonl",size:10,modified:1)
        XCTAssertTrue(db.needsImport(path:"retry.jsonl",size:10,modified:1));XCTAssertNotNil(db.lastError)
        XCTAssertEqual(sqlite3_exec(connection,"DROP TRIGGER fail_event",nil,nil,nil),SQLITE_OK)
        db.importEvents([event],path:"retry.jsonl",size:10,modified:1)
        XCTAssertFalse(db.needsImport(path:"retry.jsonl",size:10,modified:1))
        XCTAssertEqual(db.projects(provider:"codex",range:.all).first?.tokens,15)
    }
    @MainActor func testQuotaDOMExcludesConversationAndMarketingPercentages() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame:NSRect(x:0,y:0,width:700,height:700),configuration:configuration)
        let host=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        host.isReleasedWhenClosed = false; host.contentView=page
        defer { host.close() }
        page.loadHTMLString("""
            <html><body>
            <section><h2>Model quotas</h2><div>Gemini Models</div><div>Weekly limit</div><div>80% remaining</div><div>Five-hour limit</div><div>25% used</div><div>Other model available 100%</div></section>
            <section class="conversation-container"><h2>Usage limits</h2><div>PRIVATE_CHAT 70% used</div></section>
            <section><h2>Upgrade</h2><div>Save 50% used for marketing</div></section>
            </body></html>
            """,baseURL:URL(string:"https://gemini.google.com"))
        func pump() { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        for _ in 0..<100 { pump(); if page.url != nil && !page.isLoading { break }; try await Task.sleep(nanoseconds:50_000_000) }
        let result = try await page.quotaJavaScript(QuotaPageCapture.script)
        let value = try XCTUnwrap(result as? [String:Any])
        let raw = String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
        XCTAssertFalse(raw.contains("PRIVATE_CHAT")); XCTAssertFalse(raw.contains("marketing"))
        let capture = QuotaPageCapture.parse(value,at:Date())
        XCTAssertEqual(capture.windows.map(\.usedPercent),[20,25])
        XCTAssertEqual(capture.windows.map(\.label),["Gemini Models · Weekly limit","Gemini Models · Five-hour limit"])
    }
    @MainActor func testProviderConnectionChangeDiscardsOnlyItsInflightQuota() async throws {
        let changed = GenericSourceChangeProvider(id:"cursor"), other=GenericSourceChangeProvider(id:"codex"), db=try database()
        let store=UsageStore(providers:[changed,other],analytics:db,quotaObserver:{_ in})
        store.refreshAll(); try await Task.sleep(nanoseconds:1_000_000); store.connectionsChanged(providerID:"cursor")
        for _ in 0..<500 where store.isRefreshing { try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertFalse(store.isRefreshing)
        XCTAssertFalse(db.points(provider:"cursor",since:.distantPast).contains { $0.percent == 80 })
        XCTAssertTrue(db.points(provider:"codex",since:.distantPast).contains { $0.percent == 80 })
        XCTAssertEqual(store.snapshots.first { $0.id == "cursor" }?.primary?.usedPercent,40)
    }
    func testAccountScopeSeparatesAccountsProductsAndWorkspaces() throws {
        let scope = QuotaScope(account: "a", workspace: "one", product: "codex-work", pool: "session", source: "web-account")
        var changed = scope
        changed.account = "b"
        XCTAssertNotEqual(scope.key(provider: "codex", window: "session"), changed.key(provider: "codex", window: "session"))
        changed = scope; changed.workspace = "two"
        XCTAssertNotEqual(scope.key(provider: "codex", window: "session"), changed.key(provider: "codex", window: "session"))
        changed = scope; changed.product = "chatgpt-chat"
        XCTAssertNotEqual(scope.key(provider: "codex", window: "session"), changed.key(provider: "codex", window: "session"))
        changed = scope; changed.source = "codex-oauth"
        XCTAssertEqual(scope.key(provider: "codex", window: "session"), changed.key(provider: "codex", window: "session"))
        XCTAssertEqual(try JSONDecoder().decode(QuotaScope.self, from: JSONEncoder().encode(scope)), scope)
        XCTAssertFalse(QuotaScope.accountID("private-account-id").contains("private-account-id"))
        var ledger = NotificationLedger()
        let key = scope.key(provider: "codex", window: "session")
        XCTAssertEqual(ledger.observe(key: key, used: 92, reset: nil, thresholds: [75,90,100]).crossed, [75,90])
        var restored = try JSONDecoder().decode(NotificationLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertTrue(restored.observe(key: key, used: 93, reset: nil, thresholds: [75,90,100]).crossed.isEmpty)
    }
    func testCursorNamedPoolsAreSeparateAndUnknownIsNotZero() {
        let windows = CursorProvider.parseUsage(data(#"{"billingCycleEnd":"2026-11-01T00:00:00Z","individualUsage":{"plan":{"cursorModels":{"totalPercentUsed":30},"otherModels":{"usedPercent":75},"totalPercentUsed":99,"autoPercentUsed":40}}}"#))
        XCTAssertEqual(windows.map(\.label), ["Cursor Models", "Other Models"])
        XCTAssertEqual(windows.map(\.usedPercent), [30,75])
        let unknown = CursorProvider.parseUsage(data(#"{"cursorModels":{},"otherModels":{"isUnlimited":true}}"#))
        XCTAssertNil(unknown.first?.usedPercent); XCTAssertTrue(unknown.last?.isUnlimited == true)
    }
    func testUsageCaptureRejectsAvailabilityAndInvalidPercentages() {
        let capture = QuotaPageCapture.parse(["signedIn":true, "foundUsage":true, "meters":[
            ["label":"Weekly", "percent":80, "direction":"remaining"],
            ["label":"Session", "percent":25, "direction":"used"],
            ["label":"Availability", "percent":100, "direction":"available"],
            ["label":"Boolean", "percent":true, "direction":"used"],
            ["label":"Bad", "percent":110, "direction":"remaining"]]], at: Date())
        XCTAssertEqual(capture.windows.map(\.usedPercent), [20,25])
        XCTAssertTrue(capture.signedIn); XCTAssertTrue(capture.foundUsage)
        XCTAssertTrue(QuotaPageCapture.parse(["models":["available":true]], at:Date()).windows.isEmpty)
    }
    @MainActor func testAccountOriginsAndWorkspaceMetadata() {
        XCTAssertTrue(AccountNavigation.permitsLocalSubframe(URL(string:"about:blank")!,isMainFrame:false))
        XCTAssertTrue(AccountNavigation.permitsLocalSubframe(URL(string:"about:srcdoc")!,isMainFrame:false))
        XCTAssertFalse(AccountNavigation.permitsLocalSubframe(URL(string:"about:blank")!,isMainFrame:true))
        XCTAssertFalse(AccountNavigation.permitsLocalSubframe(URL(string:"file:///tmp/test")!,isMainFrame:false))

        for product in AccountProduct.allCases {
            XCTAssertTrue(product.permits(product.usageURL))
            XCTAssertFalse(product.permits(URL(string:"http://" + product.host)))
            XCTAssertFalse(product.permits(URL(string:"https://" + product.host + ".attacker.test")))
            XCTAssertFalse(product.permits(URL(string:"https://" + product.host + ":444/")))
        }
        let choices = WebAccountReaders.parseOpenAIWorkspaces(data(#"{"accounts":{"account-a":{"account":{"name":"Personal"}},"account-b":{"account":{"name":"Team"}}},"accessToken":"NEVER_STORE"}"#))
        XCTAssertEqual(choices.map(\.id), ["account-a", "account-b"])
        XCTAssertEqual(choices.map(\.name), ["Personal", "Team"])
    }
    func testHistoryMigrationPreservesLegacyAndBacksUpWAL() throws {
        let url = dir.appendingPathComponent("old.sqlite"); var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection,"PRAGMA journal_mode=WAL; PRAGMA user_version=1; CREATE TABLE quota(id INTEGER PRIMARY KEY,provider TEXT,meter TEXT,label TEXT,model TEXT,unit TEXT,ts REAL,pct REAL,reset REAL,period TEXT); INSERT INTO quota VALUES(1,'codex','session','Session','','quota',1800000000,42,NULL,'old-period');",nil,nil,nil), SQLITE_OK)
        let migrated = try XCTUnwrap(AnalyticsStore(url:url))
        let points = migrated.points(provider:"codex", since:.distantPast)
        XCTAssertEqual(points.count,1); XCTAssertEqual(points.first?.account,"legacy-unassigned")
        XCTAssertEqual(points.first?.period,"old-period"); XCTAssertEqual(points.first?.percent,42)
        XCTAssertTrue(FileManager.default.fileExists(atPath:dir.appendingPathComponent("old.pre-1.5.sqlite").path))
        var backup: OpaquePointer?; XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("old.pre-1.5.sqlite").path,&backup),SQLITE_OK)
        var st: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(backup,"SELECT COUNT(*) FROM quota",-1,&st,nil),SQLITE_OK)
        XCTAssertEqual(sqlite3_step(st),SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(st,0),1)
        sqlite3_finalize(st); sqlite3_close(backup); sqlite3_close(connection)
    }
    func testFutureHistorySchemaIsNotDowngraded() throws {
        let url=dir.appendingPathComponent("future.sqlite"); var connection:OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path,&connection),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection,"PRAGMA user_version=99",nil,nil,nil),SQLITE_OK)
        XCTAssertNil(AnalyticsStore(url:url))
        var st:OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(connection,"PRAGMA user_version",-1,&st,nil),SQLITE_OK)
        XCTAssertEqual(sqlite3_step(st),SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(st,0),99)
        sqlite3_finalize(st); sqlite3_close(connection)
    }
    func testScopedHistoryIsIndependentAndReplayIsDeduplicated() throws {
        let db=try database(), now=Date()
        var a=snapshot(20,id:"antigravity"); a.windows[0].scope=QuotaScope(account:"a",product:"gemini-web",pool:"session",source:"web-account")
        a.windows[0].measuredAt=now
        db.record(a,now:now); db.record(a,now:now.addingTimeInterval(5))
        var b=a; b.windows[0].scope?.account="b"; b.windows[0].usedPercent=80
        db.record(b,now:now)
        var c=a; c.windows[0].scope?.product="antigravity"; c.windows[0].usedPercent=40
        db.record(c,now:now)
        let points=db.points(provider:"antigravity",since:.distantPast)
        XCTAssertEqual(points.count,3); XCTAssertEqual(Set(points.map(\.meter)).count,3)
        XCTAssertEqual(Set(points.map(\.period)).count,3)
    }
    @MainActor func testFailedAccountCannotReviveAnotherAccountsQuota() {
        var previous=snapshot(90); previous.scopeWindows(account:"a",product:"codex-work",source:"web-account")
        previous.products=[ProductConnection(id:"codex-work",title:"Codex / Work",state:.connected,source:"web-account",account:"a")]
        var failed=snapshot(0); failed.windows=[]; failed.updatedAt=nil; failed.error="offline"
        failed.products=[ProductConnection(id:"codex-work",title:"Codex / Work",state:.failed,source:"web-account",account:"b")]
        XCTAssertTrue(UsageStore.merging(failed,with:previous).windows.isEmpty)
        failed.products[0].account="a"
        XCTAssertEqual(UsageStore.merging(failed,with:previous).primary?.usedPercent,90)
        var chat = UsageWindow(label:"chat",usedPercent:30,resetsAt:nil)
        chat.scope = QuotaScope(account:"a",product:"chatgpt-chat",pool:"chat",source:"web-account")
        previous.windows.append(chat)
        failed.products.append(ProductConnection(id:"chatgpt-chat",title:"ChatGPT Chat",state:.failed,source:"web-account",account:"b"))
        XCTAssertEqual(UsageStore.merging(failed,with:previous).windows.count,1)
    }
    @MainActor func testPartialGoogleFailureKeepsProductsSeparate() {
        var old=snapshot(95,id:"antigravity"); old.scopeWindows(account:"a",product:"antigravity",source:"web-account")
        var fresh=snapshot(10,id:"antigravity"); fresh.scopeWindows(account:"b",product:"gemini-web",source:"web-account")
        fresh.products=[ProductConnection(id:"gemini-web",title:"Gemini",state:.connected,source:"web-account",account:"b"),ProductConnection(id:"antigravity",title:"Antigravity",state:.failed,message:"offline",source:"web-account",account:"a")]
        let merged=UsageStore.merging(fresh,with:old)
        XCTAssertEqual(merged.windows.count,2); XCTAssertEqual(merged.primary?.usedPercent,10)
        XCTAssertEqual(merged.windows.last?.issue,"offline"); XCTAssertTrue(merged.hasActiveConnection())
    }
    func testWebAccountUsageIsNotAssignedToLocalProjectTokens() throws {
        let db=try database(), now=Date()
        var sample=snapshot(10); sample.scopeWindows(account:"a",product:"codex-work",source:"web-account")
        sample.windows[0].measuredAt=now; db.record(sample,now:now)
        db.importEvents([TokenEvent(provider:"codex",key:"local",timestamp:now.addingTimeInterval(10),session:"s",project:"/local",model:"m",input:100,output:0,cached:0)],path:"local",size:1,modified:1)
        sample.windows[0].usedPercent=30; sample.windows[0].measuredAt=now.addingTimeInterval(20); db.record(sample,now:now.addingTimeInterval(20))
        let result=db.attribution(provider:"codex",meter:sample.windows[0].historyMeter,since:.distantPast)
        XCTAssertEqual(result.first?.project,"__elsewhere__"); XCTAssertEqual(result.first?.percentagePoints,20)
        XCTAssertEqual(db.projects(provider:"codex",range:.all).first?.tokens,100)
    }
    @MainActor func testAccountPreferencesSurviveAndPreserveLegacyLayout() throws {
        let domain="KenarTests.\(UUID().uuidString)"; let defaults=UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        var legacy=Preferences(); legacy.width=375; legacy.edge = .left; legacy.hiddenProviders=["cursor"]; legacy.claudeSource="web"; legacy.claudeWorkspace="existing-workspace"
        defaults.set(try JSONEncoder().encode(legacy),forKey:"preferences.v1")
        let settings=Settings(defaults:defaults)
        XCTAssertEqual(settings.values.width,375); XCTAssertEqual(settings.values.edge,.left)
        XCTAssertEqual(settings.values.hiddenProviders,["cursor"]); XCTAssertEqual(settings.values.claudeWorkspace,"existing-workspace")
        settings.values.accountConnections?["openai"]="web"; settings.values.accountWorkspaces=["openai":"team"]
        let restored=Settings(defaults:defaults)
        XCTAssertEqual(restored.values.accountConnections?["openai"],"web"); XCTAssertEqual(restored.values.accountWorkspaces?["openai"],"team")
    }

}

private actor RetryProviderSpy: UsageProvider {
    nonisolated let id: String
    private var intents: [Bool] = []
    init(id: String) { self.id = id }
    func fetch() async -> ProviderSnapshot { await fetch(userInitiated: false) }
    func fetch(userInitiated: Bool) async -> ProviderSnapshot {
        intents.append(userInitiated)
        return ProviderSnapshot(id: id, name: id, systemImage: "circle", windows: [], error: "fixture offline")
    }
    func calls() -> [Bool] { intents }
}

private final class RecoveryProbeSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false, reads = 0
    var available: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); defer { lock.unlock() }; enabled = newValue }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; reads += 1; return enabled }
}

private actor SourceChangeProvider: UsageProvider {
    nonisolated let id="claude"
    var attempts=0
    func fetch() async -> ProviderSnapshot {
        attempts += 1; let current=attempts
        if current == 1 { try? await Task.sleep(nanoseconds:20_000_000) }
        return ProviderSnapshot(id:id,name:"Claude",systemImage:"asterisk",windows:[UsageWindow(label:"session",usedPercent:current == 1 ? 10 : 40,resetsAt:nil)],error:nil,updatedAt:Date())
    }
}

private actor GenericSourceChangeProvider: UsageProvider {
    nonisolated let id:String
    private var attempts=0
    init(id:String) { self.id=id }
    func fetch() async -> ProviderSnapshot {
        attempts += 1; let attempt=attempts
        try? await Task.sleep(nanoseconds:20_000_000)
        return ProviderSnapshot(id:id,name:id,systemImage:"circle",windows:[UsageWindow(label:"Session",usedPercent:attempt == 1 ? 80 : 40,resetsAt:nil)],error:nil,updatedAt:Date())
    }
}
