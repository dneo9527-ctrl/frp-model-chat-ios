import XCTest

/// Run only on a fresh disposable simulator with the loopback fixture from
/// go/e2e (CHAT_UI_FIXTURE_DIR). No real account or device data is used.
final class ChatUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.doc.frpmodelchat")
    func testLiveActivityLifecycle() throws {
        continueAfterFailure = false
        app.launchArguments = ["--ui-activity-only"]
        app.launch()
        let start = app.buttons["验收：已连接"]
        XCTAssertTrue(start.waitForExistence(timeout: 60), app.debugDescription); start.tap()
        XCTAssertTrue(app.staticTexts["ActivityKit 卡片存在"].waitForExistence(timeout: 15), app.debugDescription)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func openNotificationCenter() {
            XCUIDevice.shared.press(.home)
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.0))
            top.press(forDuration: 0.01, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        func card(_ text: String) -> XCUIElement {
            springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        openNotificationCenter()
        snapshot("15-00-notification-center-attempt")
        let reveal = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        reveal.press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        XCTAssertTrue(card("FRPC").waitForExistence(timeout: 120), springboard.debugDescription)
        app.activate(); start.tap()
        openNotificationCenter()
        XCTAssertTrue(card("FRPC 已连接").waitForExistence(timeout: 60), springboard.debugDescription)
        snapshot("15-01-connected-lock-screen")
        app.activate(); app.buttons["验收：重连"].tap()
        openNotificationCenter()
        XCTAssertTrue(card("FRPC 正在重连").waitForExistence(timeout: 60), springboard.debugDescription)
        snapshot("15-02-reconnecting-lock-screen")
        app.activate(); app.buttons["验收：过期"].tap()
        openNotificationCenter()
        XCTAssertTrue(card("FRPC 状态待确认").waitForExistence(timeout: 60), springboard.debugDescription)
        snapshot("15-03-stale-lock-screen")
        app.activate(); app.buttons["验收：停止"].tap()
        XCTAssertTrue(app.staticTexts["ActivityKit 无卡片"].waitForExistence(timeout: 15))
        openNotificationCenter()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card("FRPC"))
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 15), .completed, springboard.debugDescription)
        snapshot("15-04-stopped-lock-screen")
    }
    func testSyntheticChatRefinements() throws {
        continueAfterFailure = false
        app.launchArguments = ["--ui-fixture-only"]
        app.launch()
        let copy = app.buttons["复制代码"]
        XCTAssertTrue(copy.waitForExistence(timeout: 20))
        copy.tap()
        let composer = app.textViews["聊天消息输入框"]
        // Verify the copied bytes by pasting in the same app. XCTest's idle
        // wait can outlast the brief visual confirmation label.
        composer.tap(); composer.press(forDuration: 1)
        let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["粘贴", "Paste"])).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
        XCTAssertEqual(composer.value as? String, "print(\"hello\")")
        snapshot("08-01-code-copy-pasted")
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "print(\"hello\")".count) + "Draft stays")
        let hide = app.buttons["收起聊天键盘"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5)); hide.tap()
        XCTAssertEqual(composer.value as? String, "Draft stays")
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: hide)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        app.buttons["查看本配置的会话"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "界面验收会话")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.swipeLeft()
        let rename = app.buttons["重命名"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5)); rename.tap()
        let name = app.textFields["会话名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        name.press(forDuration: 1)
        let selectAll = app.menuItems.matching(NSPredicate(format: "label IN %@", ["全选", "Select All"])).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); selectAll.tap()
        let pasteName = app.menuItems.matching(NSPredicate(format: "label IN %@", ["粘贴", "Paste"])).firstMatch
        XCTAssertTrue(pasteName.waitForExistence(timeout: 5)); pasteName.tap()
        let renamed = "print(\"hello\")"
        XCTAssertEqual(name.value as? String, renamed)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["名称未保存，请确认设备已解锁和可用空间后重试。"].waitForExistence(timeout: 5))
        XCTAssertTrue(name.exists); XCTAssertEqual(name.value as? String, renamed)
        snapshot("08-02-rename-failure-retained")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", renamed)).firstMatch.waitForExistence(timeout: 5))
        snapshot("08-03-rename-retry-succeeded")
    }

    func testSyntheticEmptyModelMenuAndLargeText() throws {
        continueAfterFailure = false
        app.launchArguments = ["--ui-fixture-only", "--ui-empty-models", "--ui-large-type"]
        app.launch()
        let model = app.buttons["选择聊天模型"]
        XCTAssertTrue(model.waitForExistence(timeout: 20)); XCTAssertTrue(model.isHittable)
        XCTAssertEqual(model.value as? String, "暂无可用模型")
        XCTAssertTrue(app.buttons["打开连接设置"].isHittable)
        XCTAssertLessThan(model.frame.maxY, app.textViews["聊天消息输入框"].frame.minY)
        snapshot("08-04-large-type-header")
        model.tap()
        XCTAssertTrue(app.buttons["刷新模型列表"].waitForExistence(timeout: 5))
        snapshot("08-05-empty-model-refresh-menu")
    }

    func testSyntheticLongModelAndLargeText() throws {
        continueAfterFailure = false
        app.launchArguments = ["--ui-fixture-only", "--ui-large-type"]
        app.launch()
        let model = app.buttons["选择聊天模型"]
        XCTAssertTrue(model.waitForExistence(timeout: 20)); XCTAssertTrue(model.isHittable)
        XCTAssertTrue((model.value as? String)?.contains("qwen3-extremely-long") == true)
        XCTAssertTrue(app.buttons["打开连接设置"].isHittable)
        snapshot("08-06-long-model-large-type")
    }
    func testUpgradeSettingsAndAppearance() throws {
        continueAfterFailure = false
        app.launchArguments = ["--ui-fixture-only", "-updateSource", ""]
        app.launch()
        XCTAssertTrue(app.buttons["打开连接设置"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["发送消息"].isEnabled)
        app.tabBars.buttons["设置"].tap()
        app.segmentedControls.buttons["深色"].tap()
        XCTAssertTrue(app.staticTexts["界面配色：深色"].waitForExistence(timeout: 10))
        app.tabBars.buttons["聊天"].tap()
        snapshot("14-01-dark-chat")
        app.tabBars.buttons["设置"].tap()
        let check = app.buttons["检查更新"]
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        check.tap()
        XCTAssertTrue(app.staticTexts["尚未配置更新源。请从本应用的发布渠道获取新版。"].waitForExistence(timeout: 5))
        snapshot("14-02-dark-settings")
        app.segmentedControls.buttons["浅色"].tap()
        XCTAssertTrue(app.staticTexts["界面配色：浅色"].waitForExistence(timeout: 10))
        snapshot("14-03-light-settings")
        app.tabBars.buttons["连接"].tap()
        XCTAssertTrue(app.staticTexts["连接你的模型"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["STCP · VPS 中转"].exists)
        snapshot("14-04-light-connection")
        app.tabBars.buttons["聊天"].tap()
        snapshot("14-05-light-chat")
    }
    func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func reveal(_ element: XCUIElement, upwards: Bool = true) {
        func scroll(upwards: Bool) {
            let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let start = upwards ? lower : upper
            start.press(forDuration: 0.01, thenDragTo: upwards ? upper : lower)
        }
        for _ in 0..<12 {
            if element.exists {
                let frame = element.frame
                let viewport = app.frame
                // A label can be hittable while its trailing switch lies under
                // the floating tab bar. Bring the whole control into the middle.
                if element.isHittable && frame.minY >= viewport.minY + 100 &&
                    frame.maxY <= viewport.maxY - 160 { return }
                scroll(upwards: frame.midY >= viewport.midY)
            } else { scroll(upwards: upwards) }
        }
    }
    func fill(_ field: XCUIElement, with value: String, initiallyEmpty: Bool = false, verifyPlainText: Bool = true) {
        reveal(field)
        XCTAssertTrue(field.isHittable)
        field.tap()
        let old = field.value as? String ?? ""
        let clearCount = initiallyEmpty ? 0 : old.count
        let done = app.buttons["完成输入"]
        if !done.waitForExistence(timeout: 5) {
            // A simulator transition can miss the first focus tap. Retry once.
            XCTContext.runActivity(named: "First focus tap missed; retrying once") { _ in }
            field.tap()
        }
        // Secure input can be focused with an inputView and this accessory
        // while iOS exposes no XCUIElementTypeKeyboard. Actual typing and the
        // final value/STCP authentication assertions verify input instead.
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        // One keyboard event sequence avoids losing the responder between
        // clearing a native field and entering its replacement.
        if verifyPlainText {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: clearCount) + value)
        } else {
            // Deliver secure keystrokes one at a time and verify the masked
            // count. Authentication later still checks the exact synthetic value.
            XCTAssertTrue(initiallyEmpty)
            for (index, character) in value.enumerated() {
                app.typeText(String(character))
                XCTAssertEqual((field.value as? String)?.count, index + 1)
            }
        }
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: done)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 30), .completed)
        if verifyPlainText { XCTAssertEqual(field.value as? String, value) }
    }
    func testBlankDefaultsAndSTCPChat() throws {
        continueAfterFailure = false
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let serverPort = try XCTUnwrap(fixture["serverPort"] as? Int)
        let visitorPort = try XCTUnwrap(fixture["visitorPort"] as? Int)
        app.launch()
        XCTAssertTrue(app.buttons["打开连接设置"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["发送消息"].isEnabled)
        snapshot("01-blank-chat")
        app.tabBars.buttons["连接"].tap()
        let server = app.textFields["服务器地址"]
        reveal(server)
        XCTAssertTrue(server.isEnabled, "Use an ad-hoc signed simulator app so its isolated test Keychain is accessible.")
        XCTAssertEqual(server.value as? String, "例如 frp.example.com")
        snapshot("02-blank-connection")
        fill(server, with: "127.0.0.1", initiallyEmpty: true)
        fill(app.textFields["服务器端口"], with: String(serverPort))
        // Exercise the default concealed credential path. Successful STCP
        // authentication below verifies both values without revealing them.
        fill(app.secureTextFields["认证 Token"], with: "e2e-token-only", initiallyEmpty: true, verifyPlainText: false)
        fill(app.secureTextFields["访问密钥"], with: "e2e-secret-only", initiallyEmpty: true, verifyPlainText: false)
        let advanced = app.buttons["高级连接选项"]
        reveal(advanced)
        advanced.tap()
        fill(app.textFields["目标代理名称"], with: "e2e-model")
        fill(app.textFields["本机端口"], with: String(visitorPort))
        let connect = app.buttons["保存并连接"]
        reveal(connect, upwards: false)
        connect.tap()
        XCTAssertTrue(app.staticTexts["模型接口可用"].waitForExistence(timeout: 30))
        snapshot("03-stcp-connected")
        app.tabBars.buttons["聊天"].tap()
        let composer = app.textViews["聊天消息输入框"]
        composer.tap()
        composer.typeText("chat-fixture-private-prompt")
        app.buttons["发送消息"].tap()
        XCTAssertTrue(app.staticTexts["本机 STCP 流式测试通过。"].waitForExistence(timeout: 20))
        XCTAssertTrue(NSPredicate(format: "exists == false").evaluate(with: app.buttons["停止生成"]) ||
                      XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["停止生成"])], timeout: 10) == .completed)
        snapshot("04-stream-completed")
        app.buttons["新建会话"].tap()
        composer.tap()
        composer.typeText("chat-cancel-fixture")
        app.buttons["发送消息"].tap()
        XCTAssertTrue(app.staticTexts["partial"].waitForExistence(timeout: 15))
        app.buttons["停止生成"].tap()
        XCTAssertTrue(app.staticTexts["已停止生成，部分回复已保留。"].waitForExistence(timeout: 5))
        snapshot("05-stream-stopped")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["partial"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["停止生成"].exists)
        app.buttons["查看本配置的会话"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "chat-fixture-private-prompt")).firstMatch.waitForExistence(timeout: 10))
        snapshot("06-history-restored")
    }
}
