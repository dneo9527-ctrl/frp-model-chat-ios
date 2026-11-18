import Foundation

@MainActor private final class Driver: ConnectionActivityDriver {
    var isSupported = true
    var activitiesEnabled = true
    var active: Set<String> = []
    var starts = 0, updates = 0, ends = 0
    var cleanupGate: CheckedContinuation<Void, Never>?
    var blockCleanup = false
    var updateGate: CheckedContinuation<Void, Never>?
    var blockUpdate = false
    var startFails = false
    func removeOrphans() async {
        if blockCleanup { await withCheckedContinuation { cleanupGate = $0 } }
        active.removeAll()
    }
    func start(_ snapshot: TunnelActivitySnapshot) throws -> String {
        starts += 1
        if startFails { throw CocoaError(.featureUnsupported) }
        let id = String(starts); active.insert(id); return id
    }
    func isActive(_ id: String) -> Bool { active.contains(id) }
    func update(_ id: String, snapshot: TunnelActivitySnapshot) async {
        updates += 1
        if blockUpdate { await withCheckedContinuation { updateGate = $0 } }
    }
    func end(_ id: String) async { ends += 1; active.remove(id) }
}

@main struct ActivityTests {
    @MainActor static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("Startup cleanup serializes with a new connection", startup),
            ("A stop supersedes an in-flight update", stopRace),
            ("Dismissal stays dismissed until explicit restore", dismissal),
            ("Background creation waits for foreground", background),
            ("Disable ends the card; re-enable restores once", disable),
            ("Denied and failed requests do not retry on every probe", denied),
            ("A new run gets a new card", newRun),
            ("Connected freshness uses the last health response", freshness)
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("Live Activity policy tests: \(tests.count - failures)/\(tests.count) passed")
        exit(failures == 0 ? 0 : 1)
    }
    @MainActor private static func fixture(_ driver: Driver) -> ConnectionActivityController {
        let defaults = UserDefaults(suiteName: "ActivityTests.\(UUID())")!
        return ConnectionActivityController(defaults: defaults, driver: driver)
    }
    static func snap() -> TunnelActivitySnapshot {
        TunnelActivitySnapshot(sessionID: UUID(), slot: 0, startedAt: Date(),
            content: TunnelActivityContent(phase: .connected, confirmedAt: Date(), updatedAt: Date()))
    }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    @MainActor static func settle() async { for _ in 0..<10 { try? await Task.sleep(nanoseconds: 1_000_000) } }
    @MainActor static func startup() async throws {
        let d = Driver(); d.blockCleanup = true; d.active = ["orphan"]
        let c = fixture(d); c.setForeground(true); c.receive(snap()); await settle()
        try check(d.starts == 0, "request raced orphan cleanup")
        d.cleanupGate?.resume(); await settle()
        try check(d.starts == 1 && d.active == ["1"] && c.hasActivity, "new activity lost")
    }
    @MainActor static func stopRace() async throws {
        let d = Driver(), c = fixture(d); c.setForeground(true); var s = snap(); c.receive(s); await settle()
        d.blockUpdate = true; s.content.phase = .reconnecting; c.receive(s); await settle()
        c.receive(nil); d.updateGate?.resume(); await settle()
        try check(d.active.isEmpty && !c.hasActivity && d.starts == 1 && d.ends == 1, "stop resurrected activity")
    }
    @MainActor static func dismissal() async throws {
        let d = Driver(), c = fixture(d); c.setForeground(true); var s = snap(); c.receive(s); await settle()
        d.active.removeAll(); s.content.updatedAt = Date(); c.receive(s); await settle()
        s.content.updatedAt = Date(); c.receive(s); c.setForeground(true); await settle()
        try check(d.starts == 1 && !c.hasActivity && c.canRestore, "dismissal automatically recreated")
        c.restore(); await settle()
        try check(d.starts == 2 && c.hasActivity, "explicit restore failed")
    }
    @MainActor static func background() async throws {
        let d = Driver(), c = fixture(d); c.receive(snap()); await settle()
        try check(d.starts == 0, "background created card")
        c.setForeground(true); await settle(); try check(d.starts == 1, "foreground failed")
        c.setForeground(false); c.receive(nil); await settle(); try check(d.active.isEmpty, "background end ignored")
    }
    @MainActor static func disable() async throws {
        let d = Driver(), c = fixture(d); c.setForeground(true); c.receive(snap()); await settle()
        c.setEnabled(false); await settle(); try check(d.active.isEmpty, "disabled card retained")
        c.setEnabled(true); await settle(); try check(d.starts == 2 && c.hasActivity, "enable failed")
    }
    @MainActor static func denied() async throws {
        let d = Driver(), c = fixture(d); d.activitiesEnabled = false; c.setForeground(true); var s = snap(); c.receive(s); await settle()
        try check(d.starts == 0, "request ignored denied permission")
        d.activitiesEnabled = true; d.startFails = true; c.setForeground(true); await settle()
        s.content.updatedAt = Date(); c.receive(s); await settle(); try check(d.starts == 1, "automatic repeated failures")
        d.startFails = false; c.restore(); await settle(); try check(c.hasActivity, "explicit retry failed")
    }
    @MainActor static func newRun() async throws {
        let d = Driver(), c = fixture(d); c.setForeground(true); c.receive(snap()); await settle()
        c.receive(snap()); await settle(); try check(d.ends == 1 && d.starts == 2 && d.active == ["2"], "sessions overlapped")
    }
    static func freshness() async throws {
        let health = Date(timeIntervalSince1970: 1234)
        let s = TunnelActivityContent(phase: .connected, confirmedAt: health, updatedAt: health.addingTimeInterval(40))
        try check(s.staleDate == health.addingTimeInterval(60), "view refresh extended health")
        let data = try JSONEncoder().encode(s)
        try check(try JSONDecoder().decode(TunnelActivityContent.self, from: data) == s, "extension state roundtrip failed")
    }
}
