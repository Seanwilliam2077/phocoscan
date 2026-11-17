import XCTest

/// Read-only UI acceptance on an existing phone scan. Supply PHOCOSCAN_LOCAL_SCAN_ID and
/// PHOCOSCAN_LOCAL_SCAN_NUMBER in the UI runner environment. Never confirms fresh training.
final class LocalResultUITests: XCTestCase {
    private func displayed(_ app: XCUIApplication, prefix: String) {
        let query = prefix == "local.rendered.ondevice" ? "identifier == %@" : "identifier BEGINSWITH %@"
        let view = app.descendants(matching: .any).matching(NSPredicate(format: query, prefix)).firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 30))
        let predicate = NSPredicate(format: "value == %@", "已显示")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: view)], timeout: 30), .completed)
        XCTAssertTrue(app.buttons["关闭"].exists)
    }

    func testFirstOpenReopenAndRetrainOption() throws {
        guard let id = ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_SCAN_ID"],
              let number = ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_SCAN_NUMBER"] else {
            throw XCTSkip("Requires explicit existing-scan UI acceptance")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.pocketworld.mvp")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["我的"].waitForExistence(timeout: 15)); app.buttons["我的"].tap()
        if !app.textFields["library.searchField"].exists { app.buttons["library.search"].tap() }
        if app.buttons["清空搜索"].exists { app.buttons["清空搜索"].tap() }
        let field = app.textFields["library.searchField"]
        field.tap(); field.typeText(number + "\n")
        let card = app.buttons["scan.card." + id]
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        let open = app.buttons["local.open"]
        for _ in 0..<8 { if open.exists && open.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(open.isHittable)
        // The first presentation used to have no content, including no Close button.
        open.tap(); displayed(app, prefix: "local.rendered.ondevice")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "local-first-open"; attachment.lifetime = .keepAlways; add(attachment)
        if ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_SUBJECT_SWITCH"] == "1" {
            for (asset,button) in [("subject.ply","主体"),("scene.ply","全景"),("subject.ply","")] {
                let element=app.descendants(matching:.any).matching(identifier:"splat.asset."+asset).firstMatch
                XCTAssertTrue(element.waitForExistence(timeout:20))
                XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","已显示"),object:element)],timeout:20),.completed)
                if !button.isEmpty { app.buttons[button].tap() }
            }
            print("LOCAL_UI subject_full_subject=true exact_asset_ids=true")
        }
        app.buttons["关闭"].tap()
        open.tap(); displayed(app, prefix: "local.rendered.ondevice")
        app.buttons["关闭"].tap()
        let options = app.buttons["local.options"]
        XCTAssertTrue(options.exists); options.tap()
        let retrain = app.buttons["local.retrain"]
        XCTAssertTrue(retrain.waitForExistence(timeout: 5)); XCTAssertTrue(retrain.isEnabled)
        retrain.tap()
        XCTAssertTrue(app.alerts["重新进行本机重建？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "保留")).firstMatch.exists)
        app.alerts.buttons["取消"].tap()
        print("LOCAL_UI first_open=true reopen=true retrain_visible=true cancelled_without_training=true")
        // If the user already has an archived result, it must open a distinct model item.
        options.tap()
        if app.buttons["local.previous"].waitForExistence(timeout: 2) {
            app.buttons["local.previous"].tap(); displayed(app, prefix: "local.rendered.ondevice.previous.")
            app.buttons["关闭"].tap()
            print("LOCAL_UI previous_result=true")
        } else {
            // Dismiss the menu through its already verified action and cancel its confirmation.
            app.buttons["local.retrain"].tap(); app.alerts.buttons["取消"].tap()
        }
        open.tap(); displayed(app, prefix: "local.rendered.ondevice")
    }
}
