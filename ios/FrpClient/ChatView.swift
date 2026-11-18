import SwiftUI
import Combine
import UIKit

/// The tabs share one tunnel owner and one conversation controller.
struct RootTabView: View {
    private enum Tab { case chat, connection, settings }
    @State private var tab: Tab = .chat
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        TabView(selection: $tab) {
            ChatView(openConnection: { tab = .connection })
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chat)
            ContentView()
                .tabItem { Label("连接", systemImage: "network") }
                .tag(Tab.connection)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .preferredColorScheme(AppTheme.scheme(appearance))
        .onOpenURL { url in
            if url.scheme == "frpmodelchat", url.host == "connection" { tab = .connection }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject private var chat: ChatController
    @EnvironmentObject private var tunnel: FrpcController
    var openConnection: () -> Void
    @State private var showConversations = false
    @State private var showDeleteConfirmation = false
    @State private var deletingConversationID: UUID?
    @State private var nearBottom = true
    @State private var conversationSearch = ""
    @State private var renamingConversation: ChatConversation?
    @State private var editorWidth: CGFloat = 0
    @FocusState private var inputFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var editorBaseHeight: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var editorFontSize: CGFloat = 17
    private let tailID = "conversation-tail"

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                connectionHeader
                Divider()
                messageList
                composer
            }
            .background(AppTheme.background)
            .navigationTitle("模型对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if inputFocused {
                        Spacer()
                        Button("收起键盘") { inputFocused = false }
                            .accessibilityLabel("收起聊天键盘")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showConversations = true } label: {
                        Label("会话", systemImage: "list.bullet")
                    }
                    .accessibilityLabel("查看本配置的会话")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        inputFocused = false
                        chat.newConversation()
                    } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("新建会话")
                }
            }
            .sheet(isPresented: $showConversations, onDismiss: {
                conversationSearch = ""
                renamingConversation = nil
                if deletingConversationID != nil { showDeleteConfirmation = true }
            }) { conversationSheet }
            .alert("删除这个会话？", isPresented: $showDeleteConfirmation) {
                Button("取消", role: .cancel) { deletingConversationID = nil }
                Button("删除会话", role: .destructive) {
                    if let id = deletingConversationID { chat.deleteConversation(id) }
                    deletingConversationID = nil
                }
            } message: {
                Text("会从本机移除此会话的记录。此操作无法撤销。")
            }
        }
        .navigationViewStyle(.stack)
    }

    private var connectionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        connectionStatus
                        HStack(spacing: 8) { modelPicker; Spacer(minLength: 0); connectionSettings }
                    }
                } else {
                    connectionStatus
                    Spacer(minLength: 4)
                    modelPicker
                    connectionSettings
                }
            }
            if !chat.availableModels.isEmpty && !chat.availableModels.contains(chat.selectedModel) {
                Text("此会话原模型当前不可用，请重新选择模型后发送。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            if !isReady || chat.availableModels.isEmpty {
                if dynamicTypeSize.isAccessibilitySize {
                    Text(isReady ? "请在模型菜单刷新列表。" : "请打开连接设置。")
                        .font(.footnote).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        Text(connectionHint)
                            .font(.footnote).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("去连接", action: openConnection).font(.footnote.weight(.semibold))
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(AppTheme.surface)
    }

    private var connectionStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(isReady ? Color.green : tunnel.canStop ? Color.orange : Color.secondary)
                .frame(width: 7, height: 7).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(isReady ? "已连接" : tunnel.phase.title)
                    .font(.caption.weight(.semibold)).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text("配置 \(tunnel.selectedSlot + 1) · STCP 中转")
                    .font(.caption2).foregroundColor(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
        }.layoutPriority(1).accessibilityElement(children: .combine)
    }

    private var connectionSettings: some View {
        Button(action: openConnection) {
            Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
        }.accessibilityLabel("打开连接设置")
    }

    private var modelPicker: some View {
        Menu {
            if chat.availableModels.isEmpty { Text("暂无可用模型，可刷新列表或检查连接。") }
            Picker("选择聊天模型", selection: $chat.selectedModel) {
                if !chat.selectedModel.isEmpty && !chat.availableModels.contains(chat.selectedModel) {
                    Text("不可用：\(chat.selectedModel)").tag(chat.selectedModel)
                }
                ForEach(chat.availableModels, id: \.self) { model in Text(model).tag(model) }
            }.disabled(chat.isGenerating)
            Divider()
            Button { tunnel.refreshModels() } label: {
                Label(tunnel.isTesting ? "正在刷新…" : "刷新模型列表", systemImage: "arrow.clockwise")
            }.disabled(tunnel.isTesting || !tunnel.isRunning || tunnel.isBusy)
            Button("连接设置", action: openConnection)
        } label: {
            HStack(spacing: 4) {
                Text(chat.availableModels.isEmpty || chat.selectedModel.isEmpty ? "暂无模型" : chat.selectedModel)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }.font(.subheadline.weight(.medium)).padding(.horizontal, 10).frame(minHeight: 44)
                .background(AppTheme.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel("选择聊天模型")
        .accessibilityValue(chat.availableModels.isEmpty || chat.selectedModel.isEmpty ? "暂无可用模型" : chat.selectedModel)
    }

    private var messageList: some View {
        GeometryReader { viewport in
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty { emptyConversation }
                        ForEach(chat.messages) { message in
                            ChatMessageBubble(message: message)
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1)
                            .id(tailID)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: ChatTailPositionKey.self,
                                                       value: geometry.frame(in: .named("chat-scroll")).maxY)
                            })
                    }
                    .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
                    .frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "chat-scroll")
                .dismissKeyboardWhenScrolling()
                .onPreferenceChange(ChatTailPositionKey.self) { bottom in
                    nearBottom = bottom <= viewport.size.height + 120 && bottom >= 0
                }
                .overlay(alignment: .bottomTrailing) {
                    if !nearBottom && !chat.messages.isEmpty {
                        Button {
                            withAnimation { scroll.scrollTo(tailID, anchor: .bottom) }
                            nearBottom = true
                        } label: {
                            Image(systemName: "arrow.down").font(.headline)
                                .padding(12).background(.regularMaterial).clipShape(Circle())
                                .overlay(Circle().stroke(Color.secondary.opacity(0.2)))
                        }
                        .accessibilityLabel("滚动到最新消息")
                        .padding(16)
                    }
                }
                .onChange(of: chat.currentConversationID) { _ in
                    nearBottom = true
                    DispatchQueue.main.async { scroll.scrollTo(tailID, anchor: .bottom) }
                }
                .onChange(of: chat.messages.count) { _ in
                    if nearBottom {
                        DispatchQueue.main.async { scroll.scrollTo(tailID, anchor: .bottom) }
                    }
                }
                // Update at a bounded cadence, and only while the reader is at
                // the bottom. Reading older messages never forces a jump.
                .onReceive(chat.$messages.throttle(for: .milliseconds(350), scheduler: RunLoop.main, latest: true)) { _ in
                    if nearBottom { scroll.scrollTo(tailID, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyConversation: some View {
        VStack(alignment: .center, spacing: 12) {
            BrandMark(size: 76).padding(.bottom, 8)
            Text(isReady ? "让想法接着走" : "随身连接，自己的模型").font(.title3.weight(.semibold))
            Text("选择电脑上的模型，输入第一条消息。会话按 VPS 配置独立保存。")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            if isReady {
                HStack(spacing: 8) {
                    suggestion("解释一个概念", prompt: "用简单的语言解释一个有趣的科学概念，并举一个生活中的例子。")
                    suggestion("整理思路", prompt: "帮我整理思路。我会告诉你目标和当前遇到的问题，请先帮我梳理关键步骤。")
                }.padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 48)
    }

    private func suggestion(_ title: String, prompt: String) -> some View {
        Button { chat.draft = prompt; inputFocused = true } label: {
            Text(title).font(.caption.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 44)
                .background(AppTheme.surface).clipShape(Capsule())
        }.disabled(chat.isGenerating)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !chat.errorMessage.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundColor(.red)
                    Text(chat.errorMessage).font(.footnote).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { chat.clearError() } label: { Image(systemName: "xmark") }
                        .font(.caption).accessibilityLabel("关闭聊天提示")
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $chat.draft)
                        .clearEditorBackground()
                        .font(.system(size: editorFontSize))
                        .focused($inputFocused)
                        .frame(height: composerHeight)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ChatEditorWidthKey.self, value: geometry.size.width)
                        })
                        .onPreferenceChange(ChatEditorWidthKey.self) { width in
                            if abs(width - editorWidth) > 0.5 { editorWidth = width }
                        }
                        .accessibilityLabel("聊天消息输入框")
                    if chat.draft.isEmpty {
                        Text("输入消息…").foregroundColor(.secondary)
                            .padding(.leading, 5).padding(.top, 8).allowsHitTesting(false)
                    }
                }
                .padding(6)
                .background(AppTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.15)))
                if chat.isGenerating {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.fill").frame(width: 46, height: 46)
                            .foregroundColor(.white).background(Circle().fill(Color.red))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("停止生成")
                } else {
                    Button {
                        inputFocused = false
                        nearBottom = true
                        chat.send()
                    } label: {
                        Image(systemName: "arrow.up").font(.headline).frame(width: 46, height: 46)
                            .foregroundColor(chat.canSend ? AppTheme.onAccent : .secondary)
                            .background(Circle().fill(chat.canSend ? AppTheme.accent : AppTheme.surface))
                    }
                    .buttonStyle(.plain)
                    .disabled(!chat.canSend)
                    .accessibilityLabel("发送消息")
                }
            }
            if chat.canRetryHistoryLoad {
                Button("重试读取聊天记录", action: chat.retryHistoryLoad).font(.footnote)
            }
            if chat.canRetryHistorySave {
                Button("重试保存记录", action: chat.retryHistorySave).font(.footnote)
            }
            if chat.canRetryHistoryLoad || chat.storageMessage.contains("失败") {
                Text(chat.storageMessage).font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var composerHeight: CGFloat {
        let width = max(1, (editorWidth > 0 ? editorWidth : 260) - 10)
        let text = chat.draft.isEmpty ? " " : chat.draft + " "
        let bounds = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: [.font: UIFont.systemFont(ofSize: editorFontSize)], context: nil)
        return min(dynamicTypeSize.isAccessibilitySize ? 180 : 112,
                   max(editorBaseHeight, ceil(bounds.height) + 16))
    }

    private var conversationSheet: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        inputFocused = false
                        chat.newConversation()
                        showConversations = false
                    } label: { Label("新建会话", systemImage: "square.and.pencil") }
                }
                Section(header: Text("配置 \(tunnel.selectedSlot + 1) 的会话"),
                        footer: Text("只显示当前连接配置对应的记录。更换服务器后，原会话不会自动发送到新服务器。")) {
                    if chat.matchingConversations(conversationSearch).isEmpty {
                        Text(conversationSearch.isEmpty ? "暂无已保存的会话" : "未找到匹配的会话").foregroundColor(.secondary)
                    }
                    ForEach(chat.matchingConversations(conversationSearch)) { conversation in
                        Button {
                            inputFocused = false
                            chat.selectConversation(conversation.id)
                            showConversations = false
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(conversation.title.isEmpty ? "新会话" : conversation.title)
                                        .font(.body).foregroundColor(.primary).lineLimit(2)
                                    HStack {
                                        Text(conversation.model).lineLimit(1)
                                        Text(conversation.updatedAt, style: .date)
                                    }.font(.caption).foregroundColor(.secondary)
                                }
                                Spacer(minLength: 0)
                                if conversation.id == chat.currentConversationID {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deletingConversationID = conversation.id
                                showConversations = false
                            } label: { Label("删除", systemImage: "trash") }
                            Button { renamingConversation = conversation } label: {
                                Label("重命名", systemImage: "pencil")
                            }.tint(AppTheme.secondaryAction)
                        }
                        .contextMenu {
                            Button { renamingConversation = conversation } label: { Label("重命名", systemImage: "pencil") }
                        }
                    }
                }
            }
            .navigationTitle("本机会话")
            .searchable(text: $conversationSearch, prompt: "搜索标题、模型或消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showConversations = false }
                }
            }
            .sheet(item: $renamingConversation) { conversation in
                RenameConversationView(conversation: conversation)
                    .environmentObject(chat)
            }
        }.navigationViewStyle(.stack)
    }

    private var isReady: Bool { chat.connection?.isReady == true }
    private var connectionHint: String {
        if chat.isGenerating { return "正在接收回复。健康检查暂不可用，新的发送将在接口恢复后开放。" }
        if isReady { return "暂未发现可用模型。可在模型菜单刷新列表，或检查电脑上的 Ollama。" }
        if tunnel.canStop { return "等待模型接口就绪后即可发送；断开时保留已收到的回复。" }
        return "先到连接页填写配置并连接，再返回这里选择模型。"
    }
}

private struct ChatTailPositionKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatEditorWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatMessageBubble: View {
    let message: ChatMessage
    @State private var thinkingExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 30) }
            VStack(alignment: .leading, spacing: 9) {
                Text(isUser ? "你" : "模型").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                if !message.thinking.isEmpty {
                    DisclosureGroup(isExpanded: $thinkingExpanded) {
                        Group {
                            if message.status == .streaming {
                                Text(verbatim: message.thinking).textSelection(.enabled)
                            } else { ChatMarkdownText(content: message.thinking) }
                        }
                        .foregroundColor(.secondary).padding(.top, 6)
                    } label: {
                        Text(message.status == .streaming && message.content.isEmpty ? "思考中…" : "思考过程")
                    }.font(.footnote)
                }
                if !message.content.isEmpty {
                    if isUser || message.status == .streaming {
                        Text(verbatim: message.content).textSelection(.enabled)
                    } else { ChatMarkdownText(content: message.content) }
                } else if message.status == .streaming {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("等待模型回复…").font(.footnote).foregroundColor(.secondary)
                    }
                }
                if let note = statusNote {
                    Text(note).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(14)
            .background(isUser ? AppTheme.userBubble : AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contextMenu {
                if !message.content.isEmpty {
                    Button {
                        UIPasteboard.general.string = message.content
                    } label: { Label("复制文字", systemImage: "doc.on.doc") }
                }
            }
            if !isUser { Spacer(minLength: 20) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var isUser: Bool { message.role == .user }
    private var statusNote: String? {
        switch message.status {
        case .complete: return nil
        case .streaming: return "正在生成…"
        case .interrupted: return "生成已中断，已收到的内容已保留。"
        case .failed: return "生成未完成，请检查连接后重新发送。"
        }
    }
}

/// Native inline Markdown plus selectable fenced code; no web view or remote assets.
private struct ChatMarkdownText: View {
    let content: String
    private struct Block: Identifiable {
        let id: Int
        let text: String
        let isCode: Bool
        let language: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                if block.isCode {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(block.language.isEmpty ? "代码" : block.language).font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            CopyCodeButton(text: block.text)
                        }
                        ScrollView(.horizontal) {
                            Text(block.text).font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(10).background(Color.primary.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    prose(block.text)
                }
            }
        }
    }

    private func prose(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#"), let space = line.firstIndex(of: " "),
                   line[..<space].allSatisfy({ $0 == "#" }), line.distance(from: line.startIndex, to: space) <= 6 {
                    Text(markdown(String(line[line.index(after: space)...])))
                        .font(.headline).padding(.top, 5).textSelection(.enabled)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundColor(.secondary)
                        Text(markdown(String(line.dropFirst(2)))).textSelection(.enabled)
                    }
                } else { Text(markdown(line.isEmpty ? " " : line)).textSelection(.enabled) }
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var lines: [String] = []
        var code = false
        var language = ""
        func flush() {
            guard !lines.isEmpty else { return }
            result.append(Block(id: result.count, text: lines.joined(separator: "\n"), isCode: code, language: language))
            lines.removeAll(keepingCapacity: true)
        }
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                flush()
                code.toggle()
                language = code ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) : ""
            } else { lines.append(line) }
        }
        flush()
        return result
    }

    private func markdown(_ text: String) -> AttributedString {
        var formatted = (try? AttributedString(markdown: text,
                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        // Display remote-model links as text, without embedding a browser or
        // loading linked images while a response is rendered.
        formatted.link = nil
        return formatted
    }
}

private struct CopyCodeButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? "已复制" : "复制代码", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption).frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundColor(.accentColor)
    }
}

private struct RenameConversationView: View {
    let conversation: ChatConversation
    @EnvironmentObject private var chat: ChatController
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var error = ""
    init(conversation: ChatConversation) {
        self.conversation = conversation
        _title = State(initialValue: conversation.title)
    }
    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("最多 40 个字符，只修改当前配置下的会话名称。")) {
                    TextField("会话名称", text: $title).accessibilityLabel("会话名称")
                    if !error.isEmpty { Text(error).font(.footnote).foregroundColor(.red) }
                }
            }.navigationTitle("重命名会话").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            if chat.renameConversation(conversation.id, title: title) { dismiss() }
                            else { error = chat.historyActionError }
                        }
                    }
                }
        }.navigationViewStyle(.stack)
    }
}
