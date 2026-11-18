import Combine
import Foundation
#if os(iOS)
import ActivityKit
import UIKit
#endif

@MainActor
protocol ConnectionActivityDriver: AnyObject {
    var isSupported: Bool { get }
    var activitiesEnabled: Bool { get }
    func removeOrphans() async
    func start(_ snapshot: TunnelActivitySnapshot) throws -> String
    func isActive(_ id: String) -> Bool
    func update(_ id: String, snapshot: TunnelActivitySnapshot) async
    func end(_ id: String) async
}

/// One serial worker owns ActivityKit mutations. A newer stop/disable/session
/// supersedes pending updates before any subsequent request can create a card.
@MainActor
final class ConnectionActivityController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var message = "连接后自动显示锁屏状态。"
    @Published private(set) var hasActivity = false
    var isSupported: Bool { driver.isSupported }
    var canRestore: Bool { enabled && desired != nil && !hasActivity && driver.isSupported }

    private let defaults: UserDefaults
    private let driver: ConnectionActivityDriver
    private var desired: TunnelActivitySnapshot?
    private var foreground = false
    private var activityID: String?
    private var sessionID: UUID?
    private var attemptedSession: UUID?
    private var revision: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var needsCleanup = true

    init(defaults: UserDefaults = .standard, driver: ConnectionActivityDriver? = nil) {
        self.defaults = defaults
        self.driver = driver ?? SystemConnectionActivityDriver()
        enabled = defaults.object(forKey: "connectionLiveActivity") as? Bool ?? true
        schedule()
    }

    func receive(_ snapshot: TunnelActivitySnapshot?) {
        guard desired != snapshot else { return }
        desired = snapshot
        schedule()
    }
    func setForeground(_ value: Bool) {
        foreground = value
        schedule()
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        defaults.set(value, forKey: "connectionLiveActivity")
        if value { attemptedSession = nil }
        schedule()
    }
    func restore() {
        guard canRestore else { return }
        attemptedSession = nil
        schedule()
    }

    private func schedule() {
        revision &+= 1
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }
    private func drain() async {
        if needsCleanup {
            needsCleanup = false
            // This process has no running tunnel yet. Do not adopt a previous
            // process's card and imply that its connection still exists.
            await driver.removeOrphans()
        }
        while true {
            let ticket = revision
            await reconcile()
            if ticket == revision { worker = nil; return }
        }
    }
    private func reconcile() async {
        guard driver.isSupported else {
            message = "锁屏实时活动需要 iOS 16.2 或更高版本。"; return
        }
        guard enabled, let snapshot = desired else {
            if let id = activityID { await driver.end(id) }
            activityID = nil; sessionID = nil; hasActivity = false
            if desired == nil { attemptedSession = nil }
            message = enabled ? "连接后自动显示锁屏状态。" : "锁屏连接状态已关闭。"
            return
        }
        if let id = activityID, sessionID != snapshot.sessionID {
            await driver.end(id)
            activityID = nil; sessionID = nil; hasActivity = false
            // Re-read the latest desired state after this suspension point.
            revision &+= 1
            return
        }
        if let id = activityID {
            guard driver.isActive(id) else {
                activityID = nil; hasActivity = false
                message = "卡片已被移除或已到系统时限，可手动恢复。"
                return
            }
            await driver.update(id, snapshot: snapshot)
            hasActivity = driver.isActive(id)
            message = hasActivity ? "锁屏连接状态已显示。" : "卡片已被移除或已到系统时限，可手动恢复。"
            return
        }
        guard driver.activitiesEnabled else {
            message = "系统未允许实时活动，请在 iPhone 设置中开启本应用的实时活动。"; return
        }
        guard attemptedSession != snapshot.sessionID else { return }
        guard foreground else {
            message = "返回应用前台后显示锁屏状态。"; return
        }
        attemptedSession = snapshot.sessionID
        do {
            activityID = try driver.start(snapshot)
            sessionID = snapshot.sessionID
            hasActivity = true
            message = "锁屏连接状态已显示。"
        } catch {
            hasActivity = false
            message = "系统暂未创建卡片，可点击“恢复锁屏卡片”重试。"
        }
    }
}

@MainActor
private final class SystemConnectionActivityDriver: ConnectionActivityDriver {
    var isSupported: Bool {
        #if os(iOS)
        if #available(iOS 16.2, *) { return true }
        #endif
        return false
    }
    var activitiesEnabled: Bool {
        #if os(iOS)
        if #available(iOS 16.2, *) { return ActivityAuthorizationInfo().areActivitiesEnabled }
        #endif
        return false
    }
    func removeOrphans() async {
        #if os(iOS)
        if #available(iOS 16.2, *) {
            let lease = ActivityMutationLease()
            defer { lease.finish() }
            for activity in Activity<ConnectionActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }
    func start(_ snapshot: TunnelActivitySnapshot) throws -> String {
        #if os(iOS)
        if #available(iOS 16.2, *) {
            return try Activity.request(
                attributes: ConnectionActivityAttributes(sessionID: snapshot.sessionID, slot: snapshot.slot, startedAt: snapshot.startedAt),
                content: ActivityContent(state: snapshot.content, staleDate: snapshot.content.staleDate), pushType: nil).id
        }
        #endif
        throw CocoaError(.featureUnsupported)
    }
    func isActive(_ id: String) -> Bool {
        #if os(iOS)
        if #available(iOS 16.2, *), let activity = Activity<ConnectionActivityAttributes>.activities.first(where: { $0.id == id }) {
            return activity.activityState == .active || activity.activityState == .stale
        }
        #endif
        return false
    }
    func update(_ id: String, snapshot: TunnelActivitySnapshot) async {
        #if os(iOS)
        if #available(iOS 16.2, *), let activity = Activity<ConnectionActivityAttributes>.activities.first(where: { $0.id == id }) {
            let lease = ActivityMutationLease()
            defer { lease.finish() }
            await activity.update(ActivityContent(state: snapshot.content, staleDate: snapshot.content.staleDate))
        }
        #endif
    }
    func end(_ id: String) async {
        #if os(iOS)
        if #available(iOS 16.2, *), let activity = Activity<ConnectionActivityAttributes>.activities.first(where: { $0.id == id }) {
            let lease = ActivityMutationLease()
            defer { lease.finish() }
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }
}

#if os(iOS)
/// Finite time to finish an ActivityKit mutation when entering the background.
/// This is not a keep-alive service and never extends tunnel ownership.
@MainActor
private final class ActivityMutationLease {
    private var token: UIBackgroundTaskIdentifier = .invalid
    init() {
        token = UIApplication.shared.beginBackgroundTask(withName: "FRPC status update") { [weak self] in self?.finish() }
    }
    func finish() {
        guard token != .invalid else { return }
        let current = token; token = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}
#endif
