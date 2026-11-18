import Foundation
import Darwin

struct ChatTestFailure: Error, CustomStringConvertible {
    let description: String
}

func chatCheck(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw ChatTestFailure(description: message) }
}

func chatExpectThrows(_ message: String, _ action: () throws -> Void) throws {
    do { try action() }
    catch is ChatTestFailure { throw ChatTestFailure(description: message + ": assertion failed inside action") }
    catch { return }
    throw ChatTestFailure(description: message)
}

@discardableResult func chatWait(_ timeout: TimeInterval = 1.5, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.004))
    } while Date() < deadline
    return predicate()
}

func chatDrain(_ duration: TimeInterval = 0.04) { _ = chatWait(duration) { false } }

/// Deliberately permits events after cancellation to test the controller's ticket barrier.
final class ScriptedChatTransport: ChatTransport {
    final class RequestToken: ChatCancellable {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
    }
    struct Record {
        let request: ChatRequest
        let callback: (ChatStreamEvent) -> Void
        let token: RequestToken
    }
    private(set) var records: [Record] = []
    func start(request: ChatRequest, onEvent: @escaping (ChatStreamEvent) -> Void) -> ChatCancellable {
        let token = RequestToken()
        records.append(Record(request: request, callback: onEvent, token: token))
        return token
    }
    func emit(_ event: ChatStreamEvent, to index: Int = 0) { records[index].callback(event) }
}

final class MemoryChatHistoryStore: ChatHistoryStore {
    var document: ChatHistoryDocument?
    var loadError = false
    var saveError = false
    private(set) var writes = 0
    init(_ document: ChatHistoryDocument? = nil) { self.document = document }
    func load() throws -> ChatHistoryDocument? {
        if loadError { throw ChatTestFailure(description: "synthetic read failure") }
        return document
    }
    func save(_ document: ChatHistoryDocument) throws {
        if saveError { throw ChatTestFailure(description: "synthetic write failure") }
        writes += 1; self.document = document
    }
}

func syntheticConnection(slot: Int = 0, identity: String = "synthetic-server-a", endpoint: String = "http://127.0.0.1:11434", models: [String] = ["synthetic-model-a", "synthetic-model-b"], isReady: Bool = true, generation: UInt64 = 1) -> ChatConnection {
    ChatConnection(slot: slot, identity: identity, endpoint: URL(string: endpoint)!, models: models, isReady: isReady, generation: generation)
}

/// Provides controllable HTTP and byte chunks without opening sockets or reaching a server.
final class ChatHTTPProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [ChatHTTPProtocol] = []
    private var closed = false
    private var responseSent = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.lock(); Self.requests.append(self); Self.lock.unlock() }
    override func stopLoading() { Self.lock.lock(); closed = true; Self.lock.unlock() }

    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    static func reset() { lock.lock(); requests = []; lock.unlock() }
    static func request(_ index: Int = 0) -> URLRequest { lock.lock(); defer { lock.unlock() }; return requests[index].request }
    static func wasStopped(_ index: Int = 0) -> Bool { lock.lock(); defer { lock.unlock() }; return requests[index].closed }

    static func respond(_ status: Int = 200, chunks: [Data] = [], index: Int = 0, finish: Bool = true) {
        lock.lock(); let item = requests[index]; let stopped = item.closed; let sent = item.responseSent; item.responseSent = true; lock.unlock()
        guard !stopped, let url = item.request.url else { return }
        if !sent {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!
            item.client?.urlProtocol(item, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        for chunk in chunks { item.client?.urlProtocol(item, didLoad: chunk) }
        if finish { item.client?.urlProtocolDidFinishLoading(item) }
    }

    static func redirect(to location: URL, index: Int = 0) {
        lock.lock(); let item = requests[index]; lock.unlock()
        guard let url = item.request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location.absoluteString])!
        item.client?.urlProtocol(item, wasRedirectedTo: URLRequest(url: location), redirectResponse: response)
    }

    static func fail(_ error: Error, index: Int = 0) {
        lock.lock(); let item = requests[index]; lock.unlock()
        item.client?.urlProtocol(item, didFailWithError: error)
    }
}

final class ChatEventRecorder {
    private let lock = NSLock()
    private var values: [ChatStreamEvent] = []
    func append(_ event: ChatStreamEvent) { lock.lock(); values.append(event); lock.unlock() }
    var events: [ChatStreamEvent] { lock.lock(); defer { lock.unlock() }; return values }
}

/// A disposable loopback-only HTTP server proves Foundation redirects do not send
/// a prompt to a second endpoint. Both endpoints exist only for this test.
final class ChatLoopbackHTTPServer {
    private let lock = NSLock()
    private var descriptor: Int32
    private var count = 0
    let port: Int

    init(response: String) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChatTestFailure(description: "test socket unavailable") }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 2) == 0 else {
            Darwin.close(fd); throw ChatTestFailure(description: "test listener unavailable")
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0 else { Darwin.close(fd); throw ChatTestFailure(description: "test port unavailable") }
        port = Int(UInt16(bigEndian: address.sin_port)); descriptor = fd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let peer = Darwin.accept(fd, nil, nil)
            guard peer >= 0 else { return }
            defer { Darwin.close(peer) }
            if let self { self.lock.lock(); self.count += 1; self.lock.unlock() }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) { setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
            var scratch = [UInt8](repeating: 0, count: 4096)
            _ = scratch.withUnsafeMutableBytes { Darwin.recv(peer, $0.baseAddress!, $0.count, 0) }
            let bytes = Data(response.utf8)
            _ = bytes.withUnsafeBytes { Darwin.send(peer, $0.baseAddress!, $0.count, 0) }
        }
    }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    func close() {
        lock.lock(); let fd = descriptor; descriptor = -1; lock.unlock()
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
    }
    deinit { close() }
}

func chatRequestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { return data }
        data.append(contentsOf: buffer.prefix(count))
    }
}
