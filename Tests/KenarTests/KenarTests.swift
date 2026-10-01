#if !KENAR_STANDALONE_TESTS
import XCTest
@testable import Kenar
#endif
import AppKit
import SQLite3
import Security

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
    func testGeminiModelsAndMissingQuota() {
        let windows = GeminiProvider.parseUsage(data(#"{"buckets":[{"modelId":"gemini-new-model","remainingFraction":0.58,"tokenType":"REQUESTS","resetTime":"2026-10-02T00:00:00Z"},{"modelId":"unknown-quota","tokenType":"TOKENS"}]}"#))
        XCTAssertEqual(windows.count,2); XCTAssertEqual(windows[0].usedPercent!,42,accuracy: 0.001)
        XCTAssertEqual(windows[0].modelID,"gemini-new-model"); XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertNil(windows[1].usedPercent); XCTAssertEqual(windows[1].unit,"TOKENS")
    }
    func testGeminiInvalidFractionsAndMalformedResponse() {
        XCTAssertTrue(GeminiProvider.parseUsage(data("broken")).isEmpty)
        let windows = GeminiProvider.parseUsage(data(#"{"buckets":[{"modelId":"x","remainingFraction":1.2},{"modelId":"y","remainingFraction":-0.1}]}"#))
        XCTAssertTrue(windows.allSatisfy { $0.usedPercent == nil })
    }
    func testGeminiMultipleQuotaTypesHaveStableIDs() {
        let windows = GeminiProvider.parseUsage(data(#"{"buckets":[{"modelId":"x","tokenType":"REQUESTS","remainingFraction":1},{"modelId":"x","tokenType":"TOKENS","remainingFraction":0.5}]}"#))
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
        let gemini = try XCTUnwrap(samples.first { $0.id == "gemini" })
        XCTAssertEqual(codex.windows.map(\.label), ["Current session", "Weekly"])
        XCTAssertEqual(claude.windows.map(\.label), ["Current session", "All models", "Fable"])
        XCTAssertNotEqual(codex.primary?.resetsAt, claude.primary?.resetsAt)
        XCTAssertEqual(cursor.primary?.label, "Included usage")
        XCTAssertTrue(cursor.windows.allSatisfy { $0.label != "Weekly" })
        XCTAssertTrue(gemini.windows.allSatisfy { $0.modelID != nil && $0.unit == "REQUESTS" })
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
        XCTAssertEqual(store.compactProviders(hiddenProviders:[],at:now).map(\.id),["cursor","gemini"])
        XCTAssertEqual(store.compactProviders(hiddenProviders:["cursor"],at:now).map(\.id),["gemini"])
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
        let windows=GeminiProvider.parseUsage(data(#"{"buckets":[{"modelId":"gemini-new","tokenType":"REQUESTS","remainingFraction":0.9,"resetTime":"2026-10-02T00:00:00Z"},{"modelId":"gemini-new","tokenType":"REQUESTS","remainingFraction":0.2,"resetTime":"2026-10-03T00:00:00Z"}]}"#))
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
