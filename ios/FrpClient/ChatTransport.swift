import Foundation
import Darwin

enum ChatRole: String, Codable { case user, assistant }

struct ChatPayloadMessage: Codable, Equatable {
    var role: ChatRole
    var content: String
}

struct ChatRequest {
    var endpoint: URL
    var model: String
    var messages: [ChatPayloadMessage]
}

enum ChatTransportError: Error, LocalizedError, Equatable {
    case invalidEndpoint, invalidRequest, httpStatus(Int), invalidResponse
    case remoteError, interrupted, tooLarge, network, cancelled

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "聊天地址必须是当前隧道的本机回环地址。"
        case .invalidRequest: return "消息或模型设置无效，请缩短消息后重试。"
        case .httpStatus(let code): return "模型接口返回 HTTP \(code)，请检查远端 Ollama。"
        case .invalidResponse: return "模型返回的数据格式无法识别，已保留收到的文字。"
        case .remoteError: return "远端模型未能完成生成，请检查模型和远端服务。"
        case .interrupted: return "响应提前中断，已保留收到的文字。"
        case .tooLarge: return "响应超过本机处理上限，已停止并保留收到的文字。"
        case .network: return "模型连接中断或超时，已保留收到的文字。"
        case .cancelled: return "已停止生成。"
        }
    }
}

enum ChatStreamEvent: Equatable {
    case delta(content: String, thinking: String)
    case completed
    case failed(ChatTransportError)
}

protocol ChatCancellable: AnyObject { func cancel() }
protocol ChatTransport {
    @discardableResult
    func start(request: ChatRequest, onEvent: @escaping (ChatStreamEvent) -> Void) -> ChatCancellable
}

/// Ollama emits newline-delimited JSON. Parse bytes before UTF-8 decoding so a
/// multi-byte character split across network packets is not damaged.
struct OllamaNDJSONParser {
    static let maximumLineBytes = 262_144
    static let maximumResponseBytes = 2_097_152
    private var pending = Data()
    private var received = 0
    private(set) var isDone = false

    private struct Chunk: Decodable {
        struct Message: Decodable {
            var role: String?
            var content: String?
            var thinking: String?
        }
        var message: Message?
        var done: Bool?
        var error: String?
    }

    mutating func append(_ data: Data) throws -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        try append(data, onEvent: { events.append($0) })
        return events
    }

    /// The transport uses this callback form so a valid prefix is delivered
    /// before a later malformed/error line in the same packet is rejected.
    mutating func append(_ data: Data, onEvent: (ChatStreamEvent) -> Void) throws {
        guard received <= Self.maximumResponseBytes - data.count else { throw ChatTransportError.tooLarge }
        received += data.count
        if isDone {
            guard data.allSatisfy({ $0 == 10 || $0 == 13 || $0 == 32 || $0 == 9 }) else {
                throw ChatTransportError.invalidResponse
            }
            return
        }
        pending.append(data)
        var completed = false
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            for event in try parse(line) {
                if event == .completed { completed = true }
                else { onEvent(event) }
            }
        }
        guard pending.count <= Self.maximumLineBytes else { throw ChatTransportError.tooLarge }
        if isDone, pending.contains(where: { $0 != 13 && $0 != 32 && $0 != 9 }) {
            throw ChatTransportError.invalidResponse
        }
        if completed { onEvent(.completed) }
    }

    mutating func finish() throws -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        try finish(onEvent: { events.append($0) })
        return events
    }

    mutating func finish(onEvent: (ChatStreamEvent) -> Void) throws {
        if !pending.isEmpty {
            for event in try parse(pending) { onEvent(event) }
            pending.removeAll()
        }
        guard isDone else { throw ChatTransportError.interrupted }
    }

    private mutating func parse(_ bytes: Data) throws -> [ChatStreamEvent] {
        guard bytes.count <= Self.maximumLineBytes else { throw ChatTransportError.tooLarge }
        if bytes.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { return [] }
        guard !isDone else { throw ChatTransportError.invalidResponse }
        let chunk: Chunk
        do { chunk = try JSONDecoder().decode(Chunk.self, from: bytes) }
        catch { throw ChatTransportError.invalidResponse }
        guard chunk.error == nil else { throw ChatTransportError.remoteError }
        guard chunk.message != nil || chunk.done == true else { throw ChatTransportError.invalidResponse }
        if let role = chunk.message?.role, role != "assistant" { throw ChatTransportError.invalidResponse }
        let content = chunk.message?.content ?? ""
        let thinking = chunk.message?.thinking ?? ""
        var events: [ChatStreamEvent] = []
        if !content.isEmpty || !thinking.isEmpty { events.append(.delta(content: content, thinking: thinking)) }
        if chunk.done == true { isDone = true; events.append(.completed) }
        return events
    }
}

final class OllamaChatTransport: ChatTransport {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.configuration.urlCache = nil
        self.configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration.httpCookieStorage = nil
        self.configuration.httpShouldSetCookies = false
        self.configuration.urlCredentialStorage = nil
        self.configuration.connectionProxyDictionary = [:]
        self.configuration.httpAdditionalHeaders = nil
        self.configuration.timeoutIntervalForRequest = 120
        self.configuration.timeoutIntervalForResource = 600
    }

    static func chatURL(for endpoint: URL) throws -> URL {
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "http", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              let host = parts.host?.lowercased(), let port = parts.port, (1...65535).contains(port) else {
            throw ChatTransportError.invalidEndpoint
        }
        let plain = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if plain == "localhost" { parts.host = "127.0.0.1" }
        else {
            var v4 = in_addr()
            var v6 = in6_addr()
            if inet_pton(AF_INET, plain, &v4) == 1 {
                guard UInt32(bigEndian: v4.s_addr) >> 24 == 127 else { throw ChatTransportError.invalidEndpoint }
            } else if inet_pton(AF_INET6, plain, &v6) == 1 {
                let raw = withUnsafeBytes(of: &v6) { Array($0) }
                guard raw == Array(repeating: UInt8(0), count: 15) + [1] else { throw ChatTransportError.invalidEndpoint }
            } else { throw ChatTransportError.invalidEndpoint }
        }
        parts.path = "/api/chat"
        guard let url = parts.url else { throw ChatTransportError.invalidEndpoint }
        return url
    }

    func start(request: ChatRequest, onEvent: @escaping (ChatStreamEvent) -> Void) -> ChatCancellable {
        do {
            let url = try Self.chatURL(for: request.endpoint)
            guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  request.model.utf8.count <= 1024, !request.messages.isEmpty,
                  request.messages.count <= 129,
                  request.messages.allSatisfy({ $0.content.utf8.count <= 131_072 }) else {
                throw ChatTransportError.invalidRequest
            }
            struct Body: Encodable {
                let model: String
                let messages: [ChatPayloadMessage]
                let stream = true
            }
            let body = try JSONEncoder().encode(Body(model: request.model, messages: request.messages))
            guard body.count <= 262_144 else { throw ChatTransportError.invalidRequest }
            var http = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            http.httpMethod = "POST"
            http.httpBody = body
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("application/x-ndjson, application/json", forHTTPHeaderField: "Accept")
            let stream = OllamaStreamTask(onEvent: onEvent)
            stream.begin(request: http, configuration: configuration)
            return stream
        } catch {
            onEvent(.failed((error as? ChatTransportError) ?? .invalidRequest))
            return EmptyChatCancellable()
        }
    }
}

private final class EmptyChatCancellable: ChatCancellable { func cancel() {} }

private final class OllamaStreamTask: NSObject, URLSessionDataDelegate, ChatCancellable, @unchecked Sendable {
    private let lock = NSLock()
    private var terminal = false
    private var responseAccepted = false
    private var parser = OllamaNDJSONParser()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var onEvent: ((ChatStreamEvent) -> Void)?

    init(onEvent: @escaping (ChatStreamEvent) -> Void) { self.onEvent = onEvent }

    func begin(request: URLRequest, configuration: URLSessionConfiguration) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() { finish(.failed(.cancelled)) }

    private func isTerminal() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return terminal
    }

    private func emit(_ event: ChatStreamEvent) {
        lock.lock()
        let callback = terminal ? nil : onEvent
        lock.unlock()
        callback?(event)
    }

    private func finish(_ event: ChatStreamEvent) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        let callback = onEvent
        onEvent = nil
        let session = self.session
        self.session = nil
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        callback?(event)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !isTerminal() else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failed(.invalidResponse)); return
        }
        guard response.statusCode == 200 else {
            completionHandler(.cancel); finish(.failed(.httpStatus(response.statusCode))); return
        }
        guard response.expectedContentLength <= Int64(OllamaNDJSONParser.maximumResponseBytes) else {
            completionHandler(.cancel); finish(.failed(.tooLarge)); return
        }
        responseAccepted = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isTerminal(), responseAccepted else { return }
        do {
            try parser.append(data, onEvent: { event in
                if event == .completed { finish(event) }
                else { emit(event) }
            })
        } catch { finish(.failed((error as? ChatTransportError) ?? .invalidResponse)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isTerminal() else { return }
        guard error == nil else { finish(.failed(.network)); return }
        guard responseAccepted else { finish(.failed(.invalidResponse)); return }
        do {
            try parser.finish(onEvent: { event in
                if event == .completed { finish(event) }
                else { emit(event) }
            })
            finish(.completed)
        } catch { finish(.failed((error as? ChatTransportError) ?? .invalidResponse)) }
    }
}
