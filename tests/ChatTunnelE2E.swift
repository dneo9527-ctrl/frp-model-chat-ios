import Foundation

/// Executed by the loopback-only Go frps/publisher/visitor harness. No user
/// server, configuration, Keychain or chat history is involved.
@main struct ChatTunnelE2E {
    static func wait(_ predicate: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(8)
        repeat {
            if predicate() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        } while Date() < until
        return predicate()
    }
    static func main() {
        guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]) else { exit(1) }
        let transport = OllamaChatTransport()
        var answer = "", complete = false, failed = false
        let request = ChatRequest(endpoint: url, model: "e2e-stub:tiny",
                                  messages: [ChatPayloadMessage(role: .user, content: "chat-fixture-private-prompt")])
        let stream = transport.start(request: request) { event in
            DispatchQueue.main.async {
                switch event {
                case .delta(let content, _): answer += content
                case .completed: complete = true
                case .failed: failed = true
                }
            }
        }
        guard wait({ complete || failed }), complete, !failed, answer == "本机 STCP 流式测试通过。" else {
            stream.cancel(); fputs("FAIL: Swift NDJSON transport through STCP\n", stderr); exit(1)
        }
        print("PASS: native Swift NDJSON client received incremental Unicode output through the real STCP tunnel")
        var receivedPartial = false, cancelled = false
        var cancelRequest = request
        cancelRequest.messages = [ChatPayloadMessage(role: .user, content: "chat-cancel-fixture")]
        let second = transport.start(request: cancelRequest) { event in
            DispatchQueue.main.async {
                if case .delta = event { receivedPartial = true }
                if case .failed(.cancelled) = event { cancelled = true }
            }
        }
        guard wait({ receivedPartial }) else { second.cancel(); exit(1) }
        second.cancel()
        guard wait({ cancelled }) else { exit(1) }
        print("PASS: native Swift client cancelled a live STCP streaming request")
    }
}
