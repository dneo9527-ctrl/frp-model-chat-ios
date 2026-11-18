import Foundation

@main struct UpdateTests {
    static func main() throws {
        let data = Data(#"{"bundleIdentifier":"com.doc.frpmodelchat","version":"1.10.0","build":8,"notes":"更新说明","releasePage":"https://example.invalid/releases/1.10.0#ios"}"#.utf8)
        let release = try AppRelease.parse(data)
        try chatCheck(release.isNewer(than: "1.9.9", build: 99), "numeric version order incorrect")
        try chatCheck(!release.isNewer(than: "2.0.0", build: 1), "older release treated as upgrade")
        try chatCheck(release.isNewer(than: "1.10.0", build: 7), "same-version newer build ignored")
        try chatCheck(!release.isNewer(than: "1.10.0", build: 8), "same build treated as upgrade")
        for url in ["http://example.invalid/feed", "https://user:pass@example.invalid/feed", "file:///feed", "https:///", "https://example.invalid/#secret"] {
            try chatCheck(AppRelease.httpsURL(url) == nil, "unsafe feed URL accepted")
        }
        for version in ["1", "1.2", "1.2.3.4", "1.2.beta", "-1.2.3", "99999999999999999999.0.0"] {
            try chatCheck(AppRelease.components(version) == nil, "invalid version accepted")
        }
        try chatExpectThrows("oversized manifest accepted") { _ = try AppRelease.parse(Data(repeating: 32, count: 65_537)) }
        let badLink = Data(#"{"bundleIdentifier":"com.doc.frpmodelchat","version":"1.4.1","build":8,"notes":"","releasePage":"http://example.invalid/ipa"}"#.utf8)
        try chatExpectThrows("insecure release page accepted") { _ = try AppRelease.parse(badLink) }
        let wrongApp = Data(String(data: data, encoding: .utf8)!.replacingOccurrences(of: "com.doc.frpmodelchat", with: "com.example.other-app").utf8)
        try chatExpectThrows("release for another app accepted") { _ = try AppRelease.parse(wrongApp) }
        print("PASS: numeric versions, same-version builds, invalid URL/version and payload bounds")

        ChatHTTPProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatHTTPProtocol.self]
        let controller = AppUpdateController(version: "1.4.0", build: 7, configuration: configuration)
        controller.check(source: "")
        try chatCheck(!controller.isChecking && ChatHTTPProtocol.count == 0 && controller.message.contains("尚未配置"), "empty source started network or falsely claimed latest")
        controller.check(source: "http://example.invalid/feed")
        try chatCheck(!controller.isChecking && ChatHTTPProtocol.count == 0, "invalid source started network")
        controller.check(source: "https://example.invalid/feed")
        try chatCheck(chatWait { ChatHTTPProtocol.count == 1 }, "update request absent")
        controller.check(source: "https://example.invalid/feed")
        try chatCheck(ChatHTTPProtocol.count == 1, "duplicate update check started request")
        ChatHTTPProtocol.respond(chunks: [data])
        try chatCheck(chatWait { !controller.isChecking }, "update check did not finish")
        try chatCheck(controller.release == release && controller.lastChecked != nil, "valid newer release not exposed")
        controller.sourceChanged()
        try chatCheck(controller.release == nil && controller.lastChecked == nil, "old source result remained visible")
        print("PASS: empty/invalid sources, duplicate check, HTTPS fixture response and source invalidation")

        controller.check(source: "https://example.invalid/feed2")
        try chatCheck(chatWait { ChatHTTPProtocol.count == 2 }, "second request absent")
        ChatHTTPProtocol.respond(chunks: [Data(repeating: 65, count: 65_537)], index: 1, finish: false)
        try chatCheck(chatWait { !controller.isChecking }, "oversized response did not stop")
        try chatCheck(controller.release == nil && controller.message.contains("过大"), "oversized response exposed release")
        controller.check(source: "https://example.invalid/feed3")
        try chatCheck(chatWait { ChatHTTPProtocol.count == 3 }, "third request absent")
        controller.sourceChanged()
        ChatHTTPProtocol.respond(chunks: [data], index: 2)
        chatDrain()
        try chatCheck(controller.release == nil && !controller.isChecking, "stale source callback changed current state")
        print("PASS: streamed response cap and stale-source callback rejection")
    }
}
