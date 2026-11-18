import Foundation
import Combine

/// A stable release feed, independent from frp credentials and chat traffic.
struct AppRelease: Decodable, Equatable {
    let bundleIdentifier: String
    let version: String
    let build: Int
    let notes: String
    let releasePage: URL

    static func httpsURL(_ text: String, allowFragment: Bool = false) -> URL? {
        guard text.utf8.count <= 2048, let url = URL(string: text),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, allowFragment || parts.fragment == nil else { return nil }
        return url
    }

    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }

    static func parse(_ data: Data) throws -> AppRelease {
        guard data.count <= 65_536 else { throw UpdateError.invalidManifest }
        let release = try JSONDecoder().decode(AppRelease.self, from: data)
        guard release.bundleIdentifier == "com.doc.frpmodelchat",
              components(release.version) != nil, (1...999_999_999).contains(release.build),
              release.notes.utf8.count <= 16_384,
              httpsURL(release.releasePage.absoluteString, allowFragment: true) != nil else { throw UpdateError.invalidManifest }
        return release
    }

    func isNewer(than version: String, build installedBuild: Int) -> Bool {
        guard let candidate = Self.components(self.version), let installed = Self.components(version) else { return false }
        if candidate != installed { return installed.lexicographicallyPrecedes(candidate) }
        return build > installedBuild
    }
}

enum UpdateError: Error { case invalidManifest }

final class AppUpdateController: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published private(set) var isChecking = false
    @Published private(set) var message = "仅在你点击时检查更新。"
    @Published private(set) var release: AppRelease?
    @Published private(set) var lastChecked: Date?
    let installedVersion: String
    let installedBuild: Int
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var payload = Data()
    private var source = ""
    private let configuration: URLSessionConfiguration

    init(version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.0",
         build: Int = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "10") ?? 10,
         configuration: URLSessionConfiguration = .ephemeral) {
        installedVersion = version; installedBuild = build
        self.configuration = configuration.copy() as! URLSessionConfiguration
        super.init()
    }

    func sourceChanged() {
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        payload = Data(); isChecking = false; release = nil; lastChecked = nil
        message = "更新源已变更，请重新检查。"
    }

    func check(source text: String) {
        guard !isChecking else { return }
        release = nil
        source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            message = "尚未配置更新源。请从本应用的发布渠道获取新版。"
            return
        }
        guard let url = AppRelease.httpsURL(source) else {
            message = "更新源须为不含账号密码的 HTTPS 清单地址。"; return
        }
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        payload = Data(); isChecking = true; message = "正在检查更新…"
        let task = session.dataTask(with: request)
        self.task = task; task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard self.session === session else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= 65_536 else {
            completionHandler(.cancel); finish("更新源响应无效，请稍后重试。", session: session); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.session === session else { return }
        guard payload.count <= 65_536 - data.count else {
            finish("更新清单过大，已停止读取。", session: session); return
        }
        payload.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.session === session else { return }
        guard error == nil else { finish("检查失败，请确认网络和更新源后重试。", session: session); return }
        do {
            let candidate = try AppRelease.parse(payload)
            lastChecked = Date()
            if candidate.isNewer(than: installedVersion, build: installedBuild) {
                release = candidate
                finish("发现新版本 \(candidate.version)（\(candidate.build)）。", session: session)
            } else { finish("此更新源暂无比当前安装更新的版本。", session: session) }
        } catch { finish("更新清单格式无效，未打开下载链接。", session: session) }
    }

    private func finish(_ message: String, session: URLSession) {
        guard self.session === session else { return }
        self.message = message; isChecking = false; payload = Data()
        task = nil; self.session = nil
        session.invalidateAndCancel()
    }
}
