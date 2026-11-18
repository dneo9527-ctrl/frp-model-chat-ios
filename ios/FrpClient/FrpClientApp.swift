import SwiftUI
import UIKit

@main
struct FrpClientApp: App {
    init() {
        UITextView.appearance().backgroundColor = .clear
        UITableView.appearance().backgroundColor = .clear
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-activity-only") { SyntheticActivityRoot() }
                else if ProcessInfo.processInfo.arguments.contains("--ui-fixture-only") { SyntheticChatRoot() }
                else { LiveChatRoot() }
                #else
                LiveChatRoot()
                #endif
            }
                .tint(AppTheme.accent)
        }
    }
}

private struct LiveChatRoot: View {
    @StateObject private var controller = FrpcController()
    @StateObject private var chat = ChatController()
    @StateObject private var activity = ConnectionActivityController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        RootTabView()
                .environmentObject(controller)
                .environmentObject(chat)
                .environmentObject(controller.keepAlive)
                .environmentObject(activity)
                .onAppear { activity.setForeground(scenePhase == .active) }
                .onChange(of: scenePhase) { activity.setForeground($0 == .active) }
                .onReceive(controller.$connectionActivity) { activity.receive($0) }
                .onReceive(controller.$chatConnection) { connection in
                    if let connection {
                        chat.updateConnection(connection)
                    } else {
                        chat.clearConnection()
                    }
                }
    }
}

#if DEBUG
/// Creates real ActivityKit cards with synthetic, non-network state only.
private struct SyntheticActivityRoot: View {
    @StateObject private var activity = ConnectionActivityController(defaults: UserDefaults(suiteName: "FrpModelChat.ActivityAcceptance")!)
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: TunnelActivitySnapshot?
    var body: some View {
        NavigationView {
            Form {
                Text("仅实时活动验收 · 无真实配置或网络")
                Text(activity.message).accessibilityIdentifier("activity-test-status")
                Text(activity.hasActivity ? "ActivityKit 卡片存在" : "ActivityKit 无卡片")
                Button("验收：已连接") { change(.connected) }
                Button("验收：重连") { change(.reconnecting) }
                Button("验收：过期") { change(.connected, expired: true) }
                Button("验收：停止") { snapshot = nil; activity.receive(nil) }
                Button("验收：恢复") { activity.restore() }
            }.navigationTitle("FRPC 实时活动验收")
        }
        .onAppear { activity.setEnabled(true); activity.setForeground(scenePhase == .active) }
        .onChange(of: scenePhase) { activity.setForeground($0 == .active) }
    }
    private func change(_ phase: TunnelActivityPhase, expired: Bool = false) {
        var next = snapshot ?? TunnelActivitySnapshot(sessionID: UUID(), slot: 0, startedAt: Date(),
            content: TunnelActivityContent(phase: phase, confirmedAt: nil, updatedAt: Date()))
        let stamp = Date().addingTimeInterval(expired ? -120 : 0)
        next.content = TunnelActivityContent(phase: phase, confirmedAt: phase == .connected ? stamp : nil, updatedAt: stamp)
        snapshot = next
        activity.receive(next)
    }
}

/// Memory-only UI acceptance data. Release builds contain no fixture route/data.
private struct SyntheticChatRoot: View {
    @StateObject private var controller: FrpcController
    @StateObject private var chat: ChatController
    @StateObject private var activity = ConnectionActivityController(defaults: UserDefaults(suiteName: "FrpModelChat.SyntheticActivity")!)
    init() {
        let store = SyntheticHistoryStore()
        let chat = ChatController(transport: SyntheticChatTransport(), store: store)
        let empty = ProcessInfo.processInfo.arguments.contains("--ui-empty-models")
        chat.updateConnection(ChatConnection(slot: 0, identity: "ui-fixture-only", endpoint: URL(string: "http://127.0.0.1:11434")!,
                                             models: empty ? [] : [store.model], isReady: true, generation: 1))
        let defaults = UserDefaults(suiteName: "FrpModelChat.SyntheticUI")!
        defaults.removePersistentDomain(forName: "FrpModelChat.SyntheticUI")
        _controller = StateObject(wrappedValue: FrpcController(store: SyntheticConfigStore(), defaults: defaults, monitorNetwork: false))
        _chat = StateObject(wrappedValue: chat)
    }
    var body: some View {
        RootTabView().environmentObject(controller).environmentObject(chat).environmentObject(controller.keepAlive).environmentObject(activity)
            .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--ui-large-type") ? .accessibility5 : .large)
            .overlay(alignment: .top) { SyntheticUIBanner() }
    }
}

private struct SyntheticUIBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Text("仅界面测试 · 无真实网络与用户存储")
            .font(.system(size: 8)).foregroundColor(.secondary).allowsHitTesting(false)
            .accessibilityLabel(colorScheme == .dark ? "界面配色：深色" : "界面配色：浅色")
    }
}

private final class SyntheticHistoryStore: ChatHistoryStore {
    let model = "qwen3-extremely-long-local-model-name:latest"
    private var failRenameOnce = true
    private var document: ChatHistoryDocument
    init() {
        let conversation = ChatConversation(slot: 0, identity: "ui-fixture-only", title: "界面验收会话",
                                           model: model, messages: [ChatMessage(role: .user, content: "请给一段代码示例"),
                                                                   ChatMessage(role: .assistant, content: "# 代码示例\n- 原生排版\n```swift\nprint(\"hello\")\n```")])
        document = ChatHistoryDocument(conversations: [conversation])
    }
    func load() throws -> ChatHistoryDocument? { document }
    func save(_ next: ChatHistoryDocument) throws {
        if failRenameOnce, next.conversations.first?.title != document.conversations.first?.title {
            failRenameOnce = false
            throw ChatHistoryError.invalidData
        }
        document = next
    }
}

private struct SyntheticConfigStore: ConfigStore {
    func load() throws -> String? { nil }
    func save(_ value: String) throws {}
}
private final class SyntheticChatTransport: ChatTransport {
    private final class Token: ChatCancellable { func cancel() {} }
    func start(request: ChatRequest, onEvent: @escaping (ChatStreamEvent) -> Void) -> ChatCancellable {
        onEvent(.failed(.network)); return Token()
    }
}
#endif
