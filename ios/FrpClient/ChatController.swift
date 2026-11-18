import Foundation
import Combine

struct ChatConnection: Equatable {
    var slot: Int
    var identity: String
    var endpoint: URL
    var models: [String]
    var isReady: Bool
    var generation: UInt64
    var canContinue: Bool

    init(slot: Int, identity: String, endpoint: URL, models: [String], isReady: Bool,
         generation: UInt64, canContinue: Bool? = nil) {
        self.slot = slot; self.identity = identity; self.endpoint = endpoint
        self.models = models; self.isReady = isReady; self.generation = generation
        self.canContinue = canContinue ?? isReady
    }
}

/// Like FrpcController, this object is owned and used by the main thread.
/// Every transport callback is queued onto that thread and checked against the
/// active request ticket before it may mutate a conversation.
final class ChatController: ObservableObject {
    @Published private(set) var conversations: [ChatConversation] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var currentConversationID: UUID?
    @Published private(set) var connection: ChatConnection?
    @Published private(set) var isGenerating = false
    @Published private(set) var errorMessage = ""
    @Published private(set) var storageMessage = "聊天记录仅保存在本机。"
    @Published private(set) var historyActionError = ""
    @Published private(set) var hasUnsavedHistory = false
    @Published var draft = ""
    @Published var selectedModel = "" {
        didSet {
            guard oldValue != selectedModel, !updatingModel else { return }
            rememberSelectedModel()
        }
    }

    var availableModels: [String] { connection?.models ?? [] }
    var canSend: Bool {
        !storageBlocked && !isGenerating && connection?.isReady == true &&
        availableModels.contains(selectedModel) &&
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canRetryHistoryLoad: Bool { storageBlocked }
    var canRetryHistorySave: Bool { !storageBlocked && hasUnsavedHistory }
    var canEditHistory: Bool { !storageBlocked && connection != nil }

    private let transport: ChatTransport
    private let store: ChatHistoryStore
    private var document = ChatHistoryDocument()
    private var storageBlocked = false
    private var activeRequest: ChatCancellable?
    private var requestTicket: UInt64 = 0
    private var pendingConversationID: UUID?
    private var pendingAssistantID: UUID?
    private var updatingModel = false
    private var drafts: [String: String] = [:]
    private var selectedConversations: [String: UUID] = [:]
    private var responseBudget = OllamaNDJSONParser.maximumResponseBytes

    init(transport: ChatTransport = OllamaChatTransport(), store: ChatHistoryStore = FileChatHistoryStore()) {
        self.transport = transport
        self.store = store
        loadHistory()
    }

    /// Retry reads only. Unknown/corrupt files are never reset or overwritten.
    func retryHistoryLoad() {
        guard storageBlocked else { return }
        loadHistory()
        guard !storageBlocked else { return }
        refreshConversations()
        if let first = conversations.first { loadConversation(first) }
    }

    func retryHistorySave() {
        guard canRetryHistorySave else { return }
        updateCurrentDocument()
        persist()
    }

    private func loadHistory() {
        do {
            var saved = try store.load() ?? ChatHistoryDocument()
            try saved.validate()
            for i in saved.conversations.indices {
                for j in saved.conversations[i].messages.indices where saved.conversations[i].messages[j].status == .streaming {
                    saved.conversations[i].messages[j].status = .interrupted
                }
            }
            document = saved
            storageBlocked = false
            storageMessage = "聊天记录仅保存在本机。"
        } catch {
            storageBlocked = true
            storageMessage = "聊天记录暂不可读取，原文件已保留。请解锁设备后重试读取；持续失败时请保留原文件。"
        }
    }

    deinit { activeRequest?.cancel() }

    func updateConnection(_ next: ChatConnection) {
        // The App bridge can resubscribe during a SwiftUI update. Re-emitting
        // an identical snapshot would needlessly invalidate that same tree.
        guard connection != next else { return }
        guard (0..<3).contains(next.slot), !next.identity.isEmpty, next.identity.utf8.count <= 256 else {
            clearConnection()
            errorMessage = "连接配置无效，已停止生成。"
            return
        }
        let previous = connection
        let namespaceChanged = previous?.slot != next.slot || previous?.identity != next.identity
        let generationChanged = previous?.generation != next.generation || previous?.endpoint != next.endpoint
        if namespaceChanged, let previous {
            drafts[Self.key(previous)] = draft
            if let id = currentConversationID { selectedConversations[Self.key(previous)] = id }
        }
        let interrupted = isGenerating && (namespaceChanged || generationChanged || !next.canContinue)
        if namespaceChanged || generationChanged || !next.canContinue {
            stop(reason: isGenerating ? "连接已变化，已保留部分回复；请连接后重新发送。" : nil)
        }
        connection = next
        if namespaceChanged {
            draft = drafts[Self.key(next)] ?? ""
            currentConversationID = nil
            if !interrupted { errorMessage = "" }
            refreshConversations()
            let preferred = selectedConversations[Self.key(next)]
            if let first = conversations.first(where: { $0.id == preferred }) ?? conversations.first {
                loadConversation(first)
            } else {
                messages = []
                setModel(next.models.first ?? "")
            }
        } else if currentConversationID == nil && selectedModel.isEmpty {
            setModel(next.models.first ?? "")
        } else if !isGenerating, selectedModel.isEmpty {
            setModel(next.models.first ?? "")
        }
    }

    func clearError() { errorMessage = "" }

    func clearConnection() {
        guard connection != nil else { return }
        if let previous = connection {
            drafts[Self.key(previous)] = draft
            if let id = currentConversationID { selectedConversations[Self.key(previous)] = id }
        }
        stop(reason: isGenerating ? "连接暂不可用，已保留收到的文字。" : nil)
        connection = nil
        conversations = []; messages = []; currentConversationID = nil
        draft = ""; setModel("")
    }

    func newConversation() {
        guard canEditHistory else { return }
        stop(reason: nil)
        currentConversationID = nil
        messages = []
        draft = ""
        errorMessage = ""
        if !availableModels.contains(selectedModel) { setModel(availableModels.first ?? "") }
    }

    func selectConversation(_ id: UUID) {
        guard canEditHistory, let conversation = conversations.first(where: { $0.id == id }) else { return }
        stop(reason: nil)
        draft = ""
        loadConversation(conversation)
        errorMessage = ""
    }

    func matchingConversations(_ query: String) -> [ChatConversation] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return conversations }
        return conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(term) ||
            conversation.model.localizedCaseInsensitiveContains(term) ||
            conversation.messages.contains { $0.content.localizedCaseInsensitiveContains(term) }
        }
    }

    @discardableResult func renameConversation(_ id: UUID, title: String) -> Bool {
        if !historyActionError.isEmpty && errorMessage == historyActionError { errorMessage = "" }
        historyActionError = ""
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 40, clean.utf8.count <= 1024,
              !clean.contains(where: { $0.isNewline }) else {
            historyActionError = "请输入 1–40 个字符的单行会话名称。"; return false
        }
        guard canEditHistory, conversations.contains(where: { $0.id == id }),
              let index = document.conversations.firstIndex(where: { $0.id == id }) else {
            historyActionError = "此会话当前不可编辑，请返回会话列表后重试。"; return false
        }
        var renamed = document
        renamed.conversations[index].title = clean
        guard writeDocument(renamed) else {
            historyActionError = "名称未保存，请确认设备已解锁和可用空间后重试。"
            if !hasUnsavedHistory { storageMessage = historyActionError }
            return false
        }
        document = renamed
        hasUnsavedHistory = false
        refreshConversations()
        return true
    }

    /// The caller presents confirmation before this explicit user action.
    @discardableResult func deleteConversation(_ id: UUID) -> Bool {
        if !historyActionError.isEmpty && errorMessage == historyActionError { errorMessage = "" }
        historyActionError = ""
        guard canEditHistory, conversations.contains(where: { $0.id == id }) else { return false }
        if currentConversationID == id { stop(reason: nil) }
        var remaining = document
        remaining.conversations.removeAll { $0.id == id }
        guard writeDocument(remaining) else {
            historyActionError = "删除未保存，会话已保留；请稍后重试。"
            if !hasUnsavedHistory { storageMessage = historyActionError }
            errorMessage = historyActionError
            return false
        }
        document = remaining
        hasUnsavedHistory = false
        refreshConversations()
        if currentConversationID == id {
            if let first = conversations.first { loadConversation(first) }
            else { currentConversationID = nil; messages = []; draft = "" }
        }
        return true
    }

    func send() {
        guard canSend, let connection else { return }
        guard (try? OllamaChatTransport.chatURL(for: connection.endpoint)) != nil else {
            errorMessage = ChatTransportError.invalidEndpoint.localizedDescription; return
        }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.utf8.count <= 32_768 else {
            errorMessage = "单条消息过长，请缩短到 32 KB 以内。"; return
        }
        guard messages.count <= ChatHistoryDocument.maximumMessages - 2 else {
            errorMessage = "当前对话消息已达上限，请新建对话。"; return
        }
        guard currentConversationID != nil || document.conversations.count < ChatHistoryDocument.maximumConversations else {
            errorMessage = "本机会话数量已达上限，请先删除不再需要的对话。"; return
        }
        let existingText = document.conversations.reduce(0) { total, conversation in
            total + conversation.messages.reduce(0) { $0 + $1.content.utf8.count + $1.thinking.utf8.count }
        }
        responseBudget = min(OllamaNDJSONParser.maximumResponseBytes, 6_291_456 - existingText - content.utf8.count)
        guard responseBudget > 0 else {
            errorMessage = "本机聊天记录已达容量上限，请先删除不再需要的对话。"; return
        }
        let payload = contextMessages(adding: content)
        if currentConversationID == nil {
            let conversation = ChatConversation(slot: connection.slot, identity: connection.identity,
                                                 title: String(content.prefix(40)), model: selectedModel)
            currentConversationID = conversation.id
            selectedConversations[Self.key(connection)] = conversation.id
            document.conversations.append(conversation)
        }
        let user = ChatMessage(role: .user, content: content)
        let assistant = ChatMessage(role: .assistant, status: .streaming)
        messages.append(contentsOf: [user, assistant])
        draft = ""
        errorMessage = ""
        isGenerating = true
        pendingConversationID = currentConversationID
        pendingAssistantID = assistant.id
        requestTicket &+= 1
        let ticket = requestTicket
        updateCurrentDocument()
        persist()
        let request = ChatRequest(endpoint: connection.endpoint, model: selectedModel, messages: payload)
        activeRequest = transport.start(request: request) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.requestTicket == ticket, self.isGenerating else { return }
                self.receive(event)
            }
        }
    }

    func stop() { stop(reason: isGenerating ? "已停止生成，部分回复已保留。" : nil) }

    private func stop(reason: String?) {
        requestTicket &+= 1
        let request = activeRequest
        activeRequest = nil
        if isGenerating {
            finishAssistant(status: .interrupted)
            isGenerating = false
            updateCurrentDocument()
            persist()
        }
        pendingConversationID = nil
        pendingAssistantID = nil
        request?.cancel()
        if let reason { errorMessage = reason }
    }

    private func receive(_ event: ChatStreamEvent) {
        guard currentConversationID == pendingConversationID,
              let id = pendingAssistantID, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .delta(let content, let thinking):
            guard messages[index].content.utf8.count + content.utf8.count +
                    messages[index].thinking.utf8.count + thinking.utf8.count <= responseBudget else {
                stop(reason: ChatTransportError.tooLarge.localizedDescription); return
            }
            messages[index].content += content
            messages[index].thinking += thinking
            // Persist on completion/cancel, not per token; UI receives text as
            // it arrives without repeatedly writing private history to disk.
        case .completed:
            finishAssistant(status: .complete)
            finishRequest()
        case .failed(let error):
            finishAssistant(status: error == .cancelled || error == .interrupted || error == .network ? .interrupted : .failed)
            errorMessage = error.localizedDescription
            finishRequest()
        }
    }

    private func finishAssistant(status: ChatMessageStatus) {
        guard let id = pendingAssistantID, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].status = status
    }

    private func finishRequest() {
        isGenerating = false
        activeRequest = nil
        pendingConversationID = nil
        pendingAssistantID = nil
        updateCurrentDocument()
        persist()
    }

    private func contextMessages(adding current: String) -> [ChatPayloadMessage] {
        // Include only complete user/assistant rounds. An interrupted request
        // is displayed locally but is never silently submitted a second time.
        var rounds: [[ChatPayloadMessage]] = []
        var user: ChatMessage?
        for message in messages {
            if message.role == .user { user = message }
            else {
                if let pending = user, message.status == .complete {
                    rounds.append([ChatPayloadMessage(role: .user, content: pending.content),
                                   ChatPayloadMessage(role: .assistant, content: message.content)])
                }
                user = nil
            }
        }
        var remaining = 131_072 - current.utf8.count
        var chosen: [[ChatPayloadMessage]] = []
        for round in rounds.suffix(64).reversed() {
            let size = round.reduce(0) { $0 + $1.content.utf8.count }
            guard size <= remaining else { break }
            chosen.append(round)
            remaining -= size
        }
        return chosen.reversed().flatMap { $0 } + [ChatPayloadMessage(role: .user, content: current)]
    }

    private func updateCurrentDocument() {
        guard let id = currentConversationID, let index = document.conversations.firstIndex(where: { $0.id == id }) else { return }
        document.conversations[index].messages = messages
        document.conversations[index].updatedAt = Date()
        // A model changed while streaming applies to the next request only.
        document.conversations[index].model = selectedModel
        refreshConversations()
    }

    private func rememberSelectedModel() {
        guard !storageBlocked, !isGenerating, currentConversationID != nil else { return }
        updateCurrentDocument()
        persist()
    }

    private func setModel(_ value: String) {
        updatingModel = true
        selectedModel = value
        updatingModel = false
    }

    private func refreshConversations() {
        guard let connection else { conversations = []; return }
        conversations = document.conversations.filter { $0.slot == connection.slot && $0.identity == connection.identity }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func loadConversation(_ conversation: ChatConversation) {
        currentConversationID = conversation.id
        messages = conversation.messages
        setModel(conversation.model.isEmpty ? availableModels.first ?? "" : conversation.model)
        if let connection { selectedConversations[Self.key(connection)] = conversation.id }
    }

    private func persist() {
        guard !storageBlocked else { return }
        hasUnsavedHistory = true
        if writeDocument(document) { hasUnsavedHistory = false }
    }

    private func writeDocument(_ candidate: ChatHistoryDocument) -> Bool {
        guard !storageBlocked else { return false }
        do {
            try store.save(candidate)
            storageMessage = "聊天记录仅保存在本机，不随设备备份同步。"
            return true
        } catch {
            storageMessage = "聊天记录保存失败；本次内容仍保留在内存，请勿退出应用。"
            return false
        }
    }

    private static func key(_ connection: ChatConnection) -> String { "\(connection.slot):\(connection.identity)" }
}
