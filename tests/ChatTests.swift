import Foundation
import Combine

@main struct ChatTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("NDJSON tolerates single-byte UTF-8 chunks, CRLF and blank lines", testByteChunks),
            ("NDJSON finishes a terminal record without a trailing newline", testTerminalWithoutNewline),
            ("NDJSON requires done before treating EOF as complete", testMissingDone),
            ("Malformed JSON and remote error bodies fail without reflecting their contents", testInvalidStream),
            ("Same-packet malformed records preserve previously received text", testMalformedPrefix),
            ("An unterminated final delta survives an EOF error", testUnterminatedDelta),
            ("NDJSON rejects an oversized line", testLineLimit),
            ("NDJSON enforces cumulative response bounds", testResponseLimit),
            ("Only strict loopback base URLs can become chat endpoints", testLoopbackURLs),
            ("A ready connection sends the selected model and current conversation only", testConversationRequest),
            ("Stop preserves partial output and rejects late callbacks", testStopLateEvents),
            ("Changing a slot cancels the previous request and hides its conversation", testSlotIsolation),
            ("Changing server identity within a slot isolates history", testIdentityIsolation),
            ("A new connection generation invalidates old results", testGenerationIsolation),
            ("Loss of readiness cancels generation without replay", testConnectionLoss),
            ("Repeated nil connections leave the cleared controller and offline draft alone", testDuplicateClear),
            ("Identical connection snapshots do not republish or cancel an active request", testDuplicateSnapshot),
            ("Invalid connection snapshots clear the visible namespace", testInvalidConnectionSnapshot),
            ("Clearing a connection hides history, cancels and rejects late callbacks", testClearConnection),
            ("A health-probe failure does not interrupt an active chat stream", testProbeJitter),
            ("Model-list changes preserve an in-flight model snapshot", testModelSnapshot),
            ("New conversations do not send other conversation history", testNewConversation),
            ("Deletion affects only the selected conversation", testDeleteConversation),
            ("Renaming is bounded, persistent and isolated to the current server", testRenameConversation),
            ("Local search finds message text without crossing server namespaces", testConversationSearch),
            ("Failed rename keeps the original title and can be retried", testFailedRename),
            ("Failed deletion retains the visible and stored conversation", testFailedDelete),
            ("Unsaved history retries locally without replaying a prompt", testRetrySave),
            ("A model failure marks the partial answer and does not retry", testStreamFailure),
            ("Interrupted rounds are visible but are not silently resent", testInterruptedContext),
            ("Drafts follow their own server namespace", testDraftIsolation),
            ("History reload preserves isolated sessions and chosen model", testHistoryReload),
            ("History write failure retains the visible answer and reports failure", testHistoryWriteFailure),
            ("History read retry recovers a transient failure without writing", testHistoryReadRetry),
            ("Newly created conversation focus survives a cleared connection", testClearFocus),
            ("History read failure never overwrites the unreadable store", testHistoryReadFailure),
            ("File history round-trips Unicode without unrelated files", testFileRoundtrip),
            ("Unknown history schema is rejected without rewriting it", testUnknownFileSchema),
            ("Malformed history and excessive file size fail closed", testMalformedAndOversizedHistory),
            ("History count limits prevent unbounded persistence", testHistoryCountLimit),
            ("HTTP streaming uses POST with a bounded local endpoint and body", testHTTPStreaming),
            ("Invalid endpoints fail before starting an HTTP request", testHTTPInvalidEndpoint),
            ("HTTP errors expose a friendly error without body or prompt", testHTTPError),
            ("HTTP EOF without done produces an interruption", testHTTPEOF),
            ("HTTP malformed same-packet suffix retains the valid prefix", testHTTPMalformedPrefix),
            ("HTTP cancellation stops the underlying request", testHTTPCancel),
            ("A real HTTP redirect never transmits a prompt to the redirect target", testHTTPRedirect)
        ]
        var failed = 0
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failed += 1; print("FAIL: \(name): \(error)") }
        }
        print("Chat regression tests: \(tests.count - failed)/\(tests.count) passed")
        exit(failed == 0 ? 0 : 1)
    }

    static let done = Data("{\"done\":true}\n".utf8)
    static func delta(_ content: String, thinking: String = "") -> Data {
        let message: [String: Any] = ["message": ["role": "assistant", "content": content, "thinking": thinking], "done": false]
        var bytes = try! JSONSerialization.data(withJSONObject: message)
        bytes.append(0x0a)
        return bytes
    }
    static func contents(_ events: [ChatStreamEvent]) -> String {
        events.reduce("") { result, event in
            if case .delta(let text, _) = event { return result + text }
            return result
        }
    }
    static func thoughts(_ events: [ChatStreamEvent]) -> String {
        events.reduce("") { result, event in
            if case .delta(_, let text) = event { return result + text }
            return result
        }
    }
    static func completions(_ events: [ChatStreamEvent]) -> Int {
        events.filter { if case .completed = $0 { return true }; return false }.count
    }
    static func failures(_ events: [ChatStreamEvent]) -> [ChatTransportError] {
        events.compactMap { if case .failed(let error) = $0 { return error }; return nil }
    }
    static func controller() -> (ChatController, ScriptedChatTransport, MemoryChatHistoryStore) {
        let transport = ScriptedChatTransport(), store = MemoryChatHistoryStore()
        let controller = ChatController(transport: transport, store: store)
        controller.updateConnection(syntheticConnection())
        controller.selectedModel = "synthetic-model-a"
        return (controller, transport, store)
    }
    static func send(_ text: String, _ controller: ChatController, _ transport: ScriptedChatTransport) throws {
        let count = transport.records.count
        controller.draft = text
        controller.send()
        try chatCheck(chatWait { transport.records.count == count + 1 }, "send did not start transport")
        try chatCheck(controller.isGenerating, "generation not marked active")
    }
    static func complete(_ transport: ScriptedChatTransport, _ text: String, index: Int = 0) {
        transport.emit(.delta(content: text, thinking: ""), to: index)
        transport.emit(.completed, to: index)
        chatDrain()
    }

    static func testByteChunks() throws {
        var parser = OllamaNDJSONParser()
        let bytes = Data("\r\n".utf8) + delta("你好 👋", thinking: "想法") + Data("\n\r\n".utf8) + done
        var events: [ChatStreamEvent] = []
        for byte in bytes { events += try parser.append(Data([byte])) }
        events += try parser.finish()
        try chatCheck(contents(events) == "你好 👋" && thoughts(events) == "想法", "partial UTF-8 or framing damaged output")
        try chatCheck(completions(events) == 1, "terminal event absent or duplicated")
    }
    static func testTerminalWithoutNewline() throws {
        var parser = OllamaNDJSONParser()
        var events = try parser.append(delta("answer") + Data("{\"done\":true}".utf8))
        events += try parser.finish()
        try chatCheck(contents(events) == "answer" && completions(events) == 1, "last done line was ignored")
    }
    static func testMissingDone() throws {
        var parser = OllamaNDJSONParser()
        _ = try parser.append(delta("partial"))
        try chatExpectThrows("EOF without done reported success") { _ = try parser.finish() }
    }
    static func testInvalidStream() throws {
        for body in ["<html>synthetic-private-value</html>\n", "{\"error\":\"synthetic-private-value\"}\n", "{broken}\n"] {
            var parser = OllamaNDJSONParser()
            do {
                _ = try parser.append(Data(body.utf8)); _ = try parser.finish()
                throw ChatTestFailure(description: "invalid stream accepted")
            } catch let error as ChatTransportError {
                try chatCheck(!error.localizedDescription.contains("synthetic-private-value"), "remote body leaked into error")
            }
        }
    }
    static func testMalformedPrefix() throws {
        var parser = OllamaNDJSONParser(), events: [ChatStreamEvent] = []
        try chatExpectThrows("malformed suffix accepted") {
            try parser.append(delta("valid prefix") + Data("{broken}\n".utf8)) { events.append($0) }
        }
        try chatCheck(contents(events) == "valid prefix" && completions(events) == 0, "valid same-packet prefix was discarded")
    }
    static func testUnterminatedDelta() throws {
        var parser = OllamaNDJSONParser(), events: [ChatStreamEvent] = []
        var data = delta("last partial delta"); data.removeLast()
        try parser.append(data) { events.append($0) }
        try chatExpectThrows("unterminated delta completed without done") { try parser.finish { events.append($0) } }
        try chatCheck(contents(events) == "last partial delta", "unterminated partial delta was discarded")
    }
    static func testLineLimit() throws {
        var parser = OllamaNDJSONParser()
        try chatExpectThrows("oversized stream line accepted") { _ = try parser.append(Data(repeating: 0x61, count: 262_145)) }
    }
    static func testResponseLimit() throws {
        var parser = OllamaNDJSONParser()
        let chunk = delta(String(repeating: "a", count: 32_000))
        try chatExpectThrows("unbounded accumulated stream accepted") {
            for _ in 0..<70 { _ = try parser.append(chunk) }
        }
    }
    static func testLoopbackURLs() throws {
        for base in ["http://127.0.0.1:11434", "http://localhost:11435/", "http://[::1]:11436/"] {
            let url = try OllamaChatTransport.chatURL(for: URL(string: base)!)
            try chatCheck(url.path == "/api/chat" && url.port != nil, "valid loopback base rejected or path incorrect")
        }
        for base in ["https://127.0.0.1:11434", "http://192.0.2.2:11434", "http://relay.example.invalid", "http://127.0.0.1.evil.invalid:11434", "http://user:synthetic@127.0.0.1:11434", "http://127.0.0.1:11434/?token=synthetic", "http://127.0.0.1:11434/#secret", "http://127.0.0.1:11434/other", "http://0.0.0.0:11434"] {
            try chatExpectThrows("unsafe chat base accepted: " + base) { _ = try OllamaChatTransport.chatURL(for: URL(string: base)!) }
        }
    }
    static func testConversationRequest() throws {
        let (c, t, _) = controller(); defer { c.stop() }
        try send("first synthetic prompt", c, t)
        let request = t.records[0].request
        try chatCheck(request.endpoint.host == "127.0.0.1" && request.model == "synthetic-model-a", "wrong model or endpoint")
        try chatCheck(request.messages.count == 1 && request.messages[0].role == .user && request.messages[0].content == "first synthetic prompt", "unexpected initial context")
        complete(t, "first answer")
        try send("second prompt", c, t)
        let next = t.records[1].request
        try chatCheck(next.messages.map(\.content) == ["first synthetic prompt", "first answer", "second prompt"], "conversation context not replayed in order")
    }
    static func testStopLateEvents() throws {
        let (c, t, _) = controller()
        try send("synthetic prompt", c, t)
        t.emit(.delta(content: "partial answer", thinking: "partial thought")); chatDrain()
        c.stop()
        try chatCheck(!c.isGenerating && t.records[0].token.isCancelled, "Stop did not cancel transport")
        try chatCheck(c.messages.last?.content == "partial answer" && c.messages.last?.status == .interrupted, "Stop discarded partial answer")
        t.emit(.delta(content: "late poison", thinking: "")); t.emit(.completed); chatDrain()
        try chatCheck(c.messages.last?.content == "partial answer" && c.messages.last?.status == .interrupted, "late event changed stopped answer")
        try chatCheck(t.records.count == 1, "Stop automatically retried prompt")
    }
    static func testSlotIsolation() throws {
        let (c, t, _) = controller()
        try send("slot one private context", c, t)
        c.updateConnection(syntheticConnection(slot: 1, identity: "synthetic-server-b", endpoint: "http://127.0.0.1:11435", generation: 2))
        try chatCheck(t.records[0].token.isCancelled && c.messages.isEmpty && !c.isGenerating, "slot change retained prior request/history")
        t.emit(.delta(content: "old response", thinking: "")); t.emit(.completed); chatDrain()
        try chatCheck(c.messages.isEmpty, "old response crossed slots")
        c.selectedModel = "synthetic-model-b"
        try send("slot two prompt", c, t)
        try chatCheck(t.records[1].request.messages.map(\.content) == ["slot two prompt"], "other slot context was transmitted")
        c.stop()
    }
    static func testIdentityIsolation() throws {
        let (c, t, _) = controller()
        try send("old server prompt", c, t); complete(t, "old server answer")
        c.updateConnection(syntheticConnection(identity: "synthetic-server-new", generation: 2))
        try chatCheck(c.messages.isEmpty, "new server inherited old context")
        try send("new server prompt", c, t)
        try chatCheck(t.records[1].request.messages.map(\.content) == ["new server prompt"], "server identity isolation absent")
        c.stop()
    }
    static func testGenerationIsolation() throws {
        let (c, t, _) = controller()
        try send("generation one", c, t)
        c.updateConnection(syntheticConnection(generation: 2))
        try chatCheck(t.records[0].token.isCancelled && !c.isGenerating, "new generation did not cancel old")
        let before = c.messages.map(\.content)
        t.emit(.delta(content: "late generation", thinking: "")); t.emit(.completed); chatDrain()
        try chatCheck(c.messages.map(\.content) == before, "old generation mutated history")
    }
    static func testConnectionLoss() throws {
        let (c, t, _) = controller()
        try send("prompt", c, t)
        c.updateConnection(syntheticConnection(isReady: false))
        try chatCheck(!c.isGenerating && t.records[0].token.isCancelled, "disconnect did not cancel")
        c.updateConnection(syntheticConnection(isReady: true, generation: 2)); chatDrain()
        try chatCheck(t.records.count == 1, "reconnect replayed prompt without user intent")
    }
    static func testDuplicateClear() throws {
        let (c, t, _) = controller()
        try send("synthetic clear once", c, t)
        c.clearConnection()
        c.draft = "offline synthetic draft"
        var publications = 0
        let subscription = c.objectWillChange.sink { publications += 1 }
        c.clearConnection()
        try chatCheck(publications == 0 && c.draft == "offline synthetic draft" &&
                      c.connection == nil && !c.isGenerating && t.records[0].token.isCancelled,
                      "repeated nil snapshot republished or discarded offline input")
        subscription.cancel()
    }
    static func testDuplicateSnapshot() throws {
        let (c, t, _) = controller()
        try send("synthetic stable snapshot", c, t)
        var publications = 0
        let subscription = c.$connection.sink { _ in publications += 1 }
        let before = publications
        c.updateConnection(syntheticConnection())
        try chatCheck(publications == before && c.isGenerating && !t.records[0].token.isCancelled,
                      "identical bridge snapshot republished or cancelled the stream")
        subscription.cancel()
        c.stop()
    }
    static func testInvalidConnectionSnapshot() throws {
        let (c, t, _) = controller()
        try send("synthetic invalid snapshot", c, t)
        c.updateConnection(syntheticConnection(slot: 3, identity: ""))
        try chatCheck(c.connection == nil && c.messages.isEmpty && c.conversations.isEmpty &&
                      c.currentConversationID == nil && !c.isGenerating && t.records[0].token.isCancelled,
                      "invalid snapshot retained private visible namespace")
        t.emit(.completed); chatDrain()
        try chatCheck(c.messages.isEmpty, "late invalid snapshot callback restored namespace")
    }
    static func testClearConnection() throws {
        let (c, t, s) = controller()
        try send("synthetic clear prompt", c, t)
        t.emit(.delta(content: "partial before clear", thinking: "")); chatDrain()
        c.clearConnection()
        try chatCheck(c.connection == nil && c.messages.isEmpty && c.conversations.isEmpty &&
                      c.currentConversationID == nil && c.selectedModel.isEmpty && !c.canSend &&
                      !c.isGenerating && t.records[0].token.isCancelled, "clear retained namespace or active stream")
        t.emit(.delta(content: "late after clear", thinking: "")); t.emit(.completed); chatDrain()
        try chatCheck(c.messages.isEmpty, "late callback exposed cleared history")
        c.updateConnection(syntheticConnection())
        try chatCheck(c.messages.last?.content == "partial before clear" && c.messages.last?.status == .interrupted,
                      "clear lost persisted partial answer")
        try chatCheck(s.document?.conversations.first?.messages.last?.status == .interrupted,
                      "clear failed to persist interruption")
    }
    static func testProbeJitter() throws {
        let (c, t, _) = controller()
        try send("continue despite probe jitter", c, t)
        c.updateConnection(ChatConnection(slot: 0, identity: "synthetic-server-a", endpoint: URL(string: "http://127.0.0.1:11434")!, models: ["synthetic-model-a"], isReady: false, generation: 1, canContinue: true))
        try chatCheck(c.isGenerating && !t.records[0].token.isCancelled, "health-only failure interrupted active chat")
        t.emit(.delta(content: "chat remained live", thinking: "")); t.emit(.completed); chatDrain()
        try chatCheck(c.messages.last?.content == "chat remained live" && !c.isGenerating, "healthy stream reply lost")
        c.draft = "next prompt"
        c.send()
        try chatCheck(t.records.count == 1, "a new prompt started while readiness was false")
    }
    static func testModelSnapshot() throws {
        let (c, t, _) = controller()
        try send("model snapshot", c, t)
        c.updateConnection(syntheticConnection(models: ["synthetic-model-b"]))
        try chatCheck(c.isGenerating && !t.records[0].token.isCancelled, "model-list refresh cancelled active generation")
        c.selectedModel = "synthetic-model-b"
        try chatCheck(t.records[0].request.model == "synthetic-model-a", "in-flight model mutated")
        complete(t, "snapshot answer")
        try send("next model prompt", c, t)
        try chatCheck(t.records[1].request.model == "synthetic-model-b", "next request ignored selected model")
        c.stop()
    }
    static func testNewConversation() throws {
        let (c, t, _) = controller()
        try send("history one", c, t); complete(t, "answer one")
        let first = c.currentConversationID
        c.newConversation()
        try chatCheck(c.currentConversationID != first && c.messages.isEmpty, "new conversation not empty")
        try send("history two", c, t)
        try chatCheck(t.records[1].request.messages.map(\.content) == ["history two"], "new conversation sent prior history")
        c.stop()
        if let first { c.selectConversation(first) }
        try chatCheck(c.messages.first?.content == "history one", "prior conversation was lost")
    }
    static func testDeleteConversation() throws {
        let (c, t, _) = controller()
        try send("keep me", c, t); complete(t, "answer")
        let first = c.currentConversationID!
        c.newConversation()
        try send("delete me", c, t); let second = c.currentConversationID!
        complete(t, "other", index: 1)
        c.deleteConversation(second)
        try chatCheck(!c.conversations.contains(where: { $0.id == second }), "deleted conversation retained")
        c.selectConversation(first)
        try chatCheck(c.messages.first?.content == "keep me", "deleting another conversation damaged history")
    }

    static func testRenameConversation() throws {
        let (chat, transport, store) = controller()
        chat.updateConnection(syntheticConnection())
        chat.draft = "first question"; chat.send()
        transport.emit(.delta(content: "answer", thinking: "")); transport.emit(.completed)
        chatDrain()
        let id = chat.currentConversationID!
        try chatCheck(chat.renameConversation(id, title: "  我的笔记  "), "valid rename rejected")
        try chatCheck(store.document?.conversations.first?.title == "我的笔记", "rename not persisted")
        try chatCheck(!chat.renameConversation(id, title: " "), "blank title accepted")
        try chatCheck(!chat.renameConversation(id, title: String(repeating: "字", count: 41)), "oversized title accepted")
        try chatCheck(!chat.renameConversation(id, title: "two\nlines"), "multiline title accepted")
        chat.updateConnection(syntheticConnection(identity: "different-server"))
        try chatCheck(!chat.renameConversation(id, title: "wrong server"), "rename crossed namespace")
        try chatCheck(store.document?.conversations.first?.title == "我的笔记", "hidden title changed")
    }

    static func testConversationSearch() throws {
        let (chat, transport, _) = controller()
        chat.updateConnection(syntheticConnection())
        chat.draft = "Road map"; chat.send()
        transport.emit(.delta(content: "独特答案", thinking: "")); transport.emit(.completed)
        chatDrain()
        try chatCheck(chat.matchingConversations("ROAD").count == 1, "case-insensitive title search failed")
        try chatCheck(chat.matchingConversations("独特").count == 1, "message search failed")
        try chatCheck(chat.matchingConversations("no match").isEmpty, "unmatched search not empty")
        chat.updateConnection(syntheticConnection(identity: "other"))
        try chatCheck(chat.matchingConversations("独特").isEmpty, "search crossed server namespace")
    }

    static func testFailedRename() throws {
        let (c, t, s) = controller()
        try send("original title", c, t); complete(t, "answer")
        let id = c.currentConversationID!, previous = c.conversations.first!.title
        s.saveError = true
        try chatCheck(!c.renameConversation(id, title: "changed"), "rename reported false success")
        try chatCheck(c.conversations.first?.title == previous && s.document?.conversations.first?.title == previous, "failed rename changed title")
        try chatCheck(c.historyActionError.contains("未保存"), "rename failure not actionable")
        s.saveError = false
        try chatCheck(c.renameConversation(id, title: "changed"), "rename retry failed")
        try chatCheck(s.document?.conversations.first?.title == "changed" && c.historyActionError.isEmpty, "successful retry not committed")
    }

    static func testFailedDelete() throws {
        let (c, t, s) = controller()
        try send("retain me", c, t); complete(t, "answer")
        let id = c.currentConversationID!
        s.saveError = true
        try chatCheck(!c.deleteConversation(id), "delete reported false success")
        try chatCheck(c.currentConversationID == id && c.conversations.contains(where: { $0.id == id }), "failed delete hid conversation")
        try chatCheck(s.document?.conversations.contains(where: { $0.id == id }) == true && c.errorMessage.contains("保留"), "failed delete damaged storage or hid error")
        s.saveError = false
        try chatCheck(c.deleteConversation(id) && c.conversations.isEmpty && c.errorMessage.isEmpty, "delete retry failed or stale error remained")
    }

    static func testRetrySave() throws {
        let (c, t, s) = controller()
        s.saveError = true
        try send("unsaved question", c, t); complete(t, "unsaved answer")
        try chatCheck(c.canRetryHistorySave, "save retry not offered")
        s.saveError = false
        c.retryHistorySave()
        try chatCheck(!c.canRetryHistorySave && s.document?.conversations.first?.messages.last?.content == "unsaved answer", "retry did not store in-memory answer")
        try chatCheck(t.records.count == 1, "save retry replayed a model request")
        let writes = s.writes; c.retryHistorySave()
        try chatCheck(s.writes == writes, "clean history needlessly rewritten")
    }
    static func testStreamFailure() throws {
        let (c, t, _) = controller()
        try send("prompt", c, t)
        t.emit(.delta(content: "partial", thinking: "")); t.emit(.failed(.network)); chatDrain()
        try chatCheck(!c.isGenerating && c.messages.last?.content == "partial" && c.messages.last?.status != .complete, "failure discarded or completed partial answer")
        try chatCheck(!c.errorMessage.isEmpty && t.records.count == 1, "failure hidden or prompt retried")
    }
    static func testInterruptedContext() throws {
        let (c, t, _) = controller()
        try send("cancelled user prompt", c, t)
        t.emit(.delta(content: "partial cancelled response", thinking: "")); chatDrain()
        c.stop()
        try send("fresh explicit user prompt", c, t)
        try chatCheck(t.records[1].request.messages.map(\.content) == ["fresh explicit user prompt"], "cancelled round was silently replayed")
        c.stop()
    }
    static func testDraftIsolation() throws {
        let (c, _, _) = controller()
        c.draft = "draft for server a"
        c.updateConnection(syntheticConnection(slot: 1, identity: "synthetic-server-b", generation: 2))
        try chatCheck(c.draft.isEmpty, "new slot inherited draft")
        c.draft = "draft for server b"
        c.updateConnection(syntheticConnection())
        try chatCheck(c.draft == "draft for server a", "original draft lost on slot return")
        c.updateConnection(syntheticConnection(identity: "synthetic-server-c", generation: 3))
        try chatCheck(c.draft.isEmpty, "edited connection inherited another server draft")
    }
    static func testHistoryReload() throws {
        let (c, t, s) = controller()
        try send("saved question", c, t); complete(t, "saved answer")
        c.selectedModel = "synthetic-model-b"
        c.newConversation()
        c.updateConnection(syntheticConnection(slot: 1, identity: "synthetic-server-b", generation: 2))
        try send("second slot", c, t); complete(t, "second answer", index: 1)
        let restored = ChatController(transport: ScriptedChatTransport(), store: s)
        restored.updateConnection(syntheticConnection(slot: 1, identity: "synthetic-server-b", generation: 3))
        try chatCheck(restored.messages.first?.content == "second slot", "restart lost selected slot context")
        restored.updateConnection(syntheticConnection())
        guard let old = restored.conversations.first(where: { $0.messages.first?.content == "saved question" }) else { throw ChatTestFailure(description: "first slot conversation not restored") }
        restored.selectConversation(old.id)
        try chatCheck(restored.messages.last?.content == "saved answer", "restart corrupted answer")
    }
    static func testHistoryWriteFailure() throws {
        let (c, t, s) = controller(); s.saveError = true
        try send("unsaved prompt", c, t); complete(t, "unsaved visible answer")
        try chatCheck(c.messages.last?.content == "unsaved visible answer", "save failure discarded in-memory reply")
        try chatCheck(!c.storageMessage.isEmpty, "save failure not visible")
    }
    static func testHistoryReadRetry() throws {
        let store = MemoryChatHistoryStore()
        store.loadError = true
        let c = ChatController(store: store)
        c.updateConnection(syntheticConnection())
        try chatCheck(c.canRetryHistoryLoad && !c.canSend, "read failure was not blocked")
        c.retryHistoryLoad()
        try chatCheck(store.writes == 0 && c.canRetryHistoryLoad, "failed retry wrote or unblocked")
        store.loadError = false
        c.retryHistoryLoad()
        c.draft = "synthetic retry"
        try chatCheck(!c.canRetryHistoryLoad && c.canSend && store.writes == 0, "read retry failed to recover without writing")
    }
    static func testClearFocus() throws {
        let (c, t, _) = controller()
        try send("first conversation", c, t); complete(t, "first answer")
        let firstID = c.currentConversationID!
        c.selectConversation(firstID)
        c.newConversation()
        try send("second conversation", c, t); complete(t, "second answer", index: 1)
        let secondID = c.currentConversationID
        c.clearConnection()
        c.updateConnection(syntheticConnection())
        try chatCheck(c.currentConversationID == secondID, "cleared connection restored stale conversation focus")
    }
    static func testHistoryReadFailure() throws {
        let store = MemoryChatHistoryStore(); store.loadError = true
        let c = ChatController(transport: ScriptedChatTransport(), store: store)
        c.updateConnection(syntheticConnection()); c.newConversation()
        c.draft = "must not overwrite unreadable data"; c.send(); c.stop()
        try chatCheck(store.writes == 0 && !c.storageMessage.isEmpty, "unreadable history overwritten")
    }
    static func temporaryStore(_ action: (FileChatHistoryStore, URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FrpClient-chat-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        try action(FileChatHistoryStore(url: url), url)
    }
    static func testFileRoundtrip() throws {
        try temporaryStore { store, url in
            let missing = try store.load()
            try chatCheck(missing == nil, "missing history did not load empty")
            var conversation = ChatConversation(slot: 0, identity: "synthetic-server-a")
            conversation.title = "临时测试 🧪"; conversation.model = "synthetic-model-a"
            let document = ChatHistoryDocument(conversations: [conversation])
            try store.save(document)
            let loaded = try store.load()
            try chatCheck(loaded?.conversations.first?.title == "临时测试 🧪", "Unicode history changed")
            let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            try chatCheck(files.map(\.lastPathComponent) == ["history.json"], "unexpected secret/temp history files")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try chatCheck((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history file is not owner-only")
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            try chatCheck((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "history directory is not owner-only")
            let flags = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            try chatCheck(flags.isExcludedFromBackup == true, "history remains included in device backup")
        }
    }
    static func testUnknownFileSchema() throws {
        try temporaryStore { store, url in
            let unknown = Data("{\"schemaVersion\":999,\"conversations\":[]}".utf8)
            try unknown.write(to: url)
            try chatExpectThrows("unknown history schema accepted") { _ = try store.load() }
            let original = try Data(contentsOf: url)
            try chatCheck(original == unknown, "read rewrote unsupported history")
        }
    }
    static func testMalformedAndOversizedHistory() throws {
        try temporaryStore { store, url in
            let invalid = Data("{malformed protected synthetic history".utf8)
            try invalid.write(to: url)
            try chatExpectThrows("malformed history accepted") { _ = try store.load() }
            let original = try Data(contentsOf: url)
            try chatCheck(original == invalid, "malformed history rewritten")
            let large = Data(repeating: 0x61, count: 8 * 1_048_576 + 1)
            try large.write(to: url)
            try chatExpectThrows("oversized history accepted") { _ = try store.load() }
        }
    }
    static func testHistoryCountLimit() throws {
        try temporaryStore { store, _ in
            let conversations = (0..<97).map { ChatConversation(slot: $0 % 3, identity: "synthetic-\($0)") }
            try chatExpectThrows("unbounded conversations persisted") { try store.save(ChatHistoryDocument(conversations: conversations)) }
        }
    }
    static func networkTransport() -> OllamaChatTransport {
        ChatHTTPProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatHTTPProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "synthetic-must-not-forward", "Cookie": "synthetic-cookie"]
        return OllamaChatTransport(configuration: configuration)
    }
    static func request() -> ChatRequest {
        ChatRequest(endpoint: URL(string: "http://127.0.0.1:11434")!, model: "synthetic-model-a", messages: [ChatPayloadMessage(role: .user, content: "synthetic local prompt")])
    }
    static func testHTTPStreaming() throws {
        let transport = networkTransport(); let recorder = ChatEventRecorder()
        let token = transport.start(request: request()) { recorder.append($0) }; defer { token.cancel() }
        try chatCheck(chatWait { ChatHTTPProtocol.count == 1 }, "HTTP request not started")
        let wire = ChatHTTPProtocol.request()
        try chatCheck(wire.httpMethod == "POST" && wire.url?.path == "/api/chat" && wire.url?.host == "127.0.0.1", "wrong HTTP destination")
        try chatCheck(wire.value(forHTTPHeaderField: "Authorization") == nil && wire.value(forHTTPHeaderField: "Cookie") == nil, "session credentials were forwarded")
        let body = try JSONSerialization.jsonObject(with: chatRequestBody(wire)) as? [String: Any]
        let messages = body?["messages"] as? [[String: String]]
        try chatCheck(body?["model"] as? String == "synthetic-model-a" && body?["stream"] as? Bool == true, "wrong stream/model body")
        try chatCheck(messages?.count == 1 && messages?.first?["role"] == "user" && messages?.first?["content"] == "synthetic local prompt", "request body lost or leaked unrelated context")
        ChatHTTPProtocol.respond(chunks: [delta("stream one"), delta(" + 二"), done])
        try chatCheck(chatWait { completions(recorder.events) == 1 || !failures(recorder.events).isEmpty }, "HTTP stream completion absent")
        try chatCheck(contents(recorder.events) == "stream one + 二" && failures(recorder.events).isEmpty, "HTTP streaming content lost")
    }
    static func testHTTPInvalidEndpoint() throws {
        let transport = networkTransport(); let recorder = ChatEventRecorder()
        var unsafe = request(); unsafe.endpoint = URL(string: "http://192.0.2.55:11434")!
        let token = transport.start(request: unsafe) { recorder.append($0) }; defer { token.cancel() }
        try chatCheck(chatWait { !failures(recorder.events).isEmpty }, "unsafe endpoint not rejected")
        try chatCheck(ChatHTTPProtocol.count == 0, "unsafe endpoint opened an HTTP request")
    }
    static func testHTTPError() throws {
        let transport = networkTransport(); let recorder = ChatEventRecorder()
        let token = transport.start(request: request()) { recorder.append($0) }; defer { token.cancel() }
        try chatCheck(chatWait { ChatHTTPProtocol.count == 1 }, "HTTP request absent")
        ChatHTTPProtocol.respond(403, chunks: [Data("synthetic-private-body-should-not-show".utf8)])
        try chatCheck(chatWait { !failures(recorder.events).isEmpty }, "HTTP error ignored")
        let message = failures(recorder.events).first!.localizedDescription
        try chatCheck(!message.contains("synthetic-private-body") && !message.contains("synthetic local prompt"), "HTTP body/prompt leaked")
        try chatCheck(completions(recorder.events) == 0 && contents(recorder.events).isEmpty, "HTTP failure emitted success/content")
    }
    static func testHTTPEOF() throws {
        let transport = networkTransport(); let recorder = ChatEventRecorder()
        let token = transport.start(request: request()) { recorder.append($0) }; defer { token.cancel() }
        try chatCheck(chatWait { ChatHTTPProtocol.count == 1 }, "HTTP request absent")
        ChatHTTPProtocol.respond(chunks: [delta("partial")])
        try chatCheck(chatWait { !failures(recorder.events).isEmpty }, "truncated HTTP stream accepted")
        try chatCheck(contents(recorder.events) == "partial" && completions(recorder.events) == 0, "truncated stream lost partial or completed")
    }
    static func testHTTPMalformedPrefix() throws {
        let transport = networkTransport(); let recorder = ChatEventRecorder()
        let token = transport.start(request: request()) { recorder.append($0) }; defer { token.cancel() }
        try chatCheck(chatWait { ChatHTTPProtocol.count == 1 }, "HTTP request absent")
        ChatHTTPProtocol.respond(chunks: [delta("prefix kept") + Data("{broken}\n".utf8)])
        try chatCheck(chatWait { !failures(recorder.events).isEmpty }, "malformed HTTP suffix ignored")
        try chatCheck(contents(recorder.events) == "prefix kept" && completions(recorder.events) == 0, "same-packet HTTP prefix discarded")
    }
    static func testHTTPCancel() throws {
        let transport = networkTransport(); let recorder = ChatEventRecorder()
        let token = transport.start(request: request()) { recorder.append($0) }
        try chatCheck(chatWait { ChatHTTPProtocol.count == 1 }, "HTTP request absent")
        token.cancel()
        try chatCheck(chatWait { ChatHTTPProtocol.wasStopped() }, "cancel did not stop HTTP request")
        try chatCheck(completions(recorder.events) == 0, "cancelled HTTP completed")
    }
    static func testHTTPRedirect() throws {
        let target = try ChatLoopbackHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: 14\r\nConnection: close\r\n\r\n{\"done\":true}\n")
        defer { target.close() }
        let origin = try ChatLoopbackHTTPServer(response: "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(target.port)/collect\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { origin.close() }
        let transport = OllamaChatTransport(), recorder = ChatEventRecorder()
        let request = ChatRequest(endpoint: URL(string: "http://127.0.0.1:\(origin.port)")!, model: "synthetic-model", messages: [ChatPayloadMessage(role: .user, content: "synthetic-prompt-never-redirect")])
        let token = transport.start(request: request) { recorder.append($0) }; defer { token.cancel() }
        try chatCheck(chatWait(3) { !failures(recorder.events).isEmpty }, "redirect did not resolve as an error")
        chatDrain(0.08)
        try chatCheck(origin.requests == 1 && target.requests == 0, "prompt followed redirect to second endpoint")
        try chatCheck(completions(recorder.events) == 0, "redirect reported successful completion")
    }

}
