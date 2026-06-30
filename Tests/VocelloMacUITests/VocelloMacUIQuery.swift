import XCTest

/// Expectation-based element queries for macOS Vocello UI tests (no RunLoop polling).
enum VocelloMacUIQuery {
    static func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    static func button(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }

    @discardableResult
    static func waitForExistence(
        _ element: XCUIElement,
        timeout: TimeInterval = 15,
        fail: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let ok = element.waitForExistence(timeout: timeout)
        if !ok, fail {
            XCTFail("expected \(element) to exist within \(timeout)s", file: file, line: line)
        }
        return ok
    }

    @discardableResult
    static func waitForNonExistence(
        _ element: XCUIElement,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [exp], timeout: timeout)
        let ok = result == .completed
        if !ok {
            XCTFail("expected \(element) to disappear within \(timeout)s", file: file, line: line)
        }
        return ok
    }

    @discardableResult
    static func waitForMarkerValue(
        _ app: XCUIApplication,
        identifier: String,
        contains substring: String,
        timeout: TimeInterval = 15,
        fail: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let marker = element(app, identifier)
        guard marker.waitForExistence(timeout: timeout) else {
            if fail { XCTFail("marker \(identifier) missing", file: file, line: line) }
            return false
        }
        let predicate = NSPredicate { _, _ in
            let value = ((marker.value as? String) ?? marker.label)
            return value.contains(substring)
        }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: marker)
        let result = XCTWaiter.wait(for: [exp], timeout: timeout)
        let ok = result == .completed
        if !ok, fail {
            XCTFail("marker \(identifier) did not contain '\(substring)' within \(timeout)s", file: file, line: line)
        }
        return ok
    }

    @discardableResult
    static func clickWhenReady(
        _ element: XCUIElement,
        timeout: TimeInterval = 45,
        fail: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let enabled = NSPredicate(format: "exists == true AND isEnabled == true AND hittable == true")
        let exp = XCTNSPredicateExpectation(predicate: enabled, object: element)
        guard XCTWaiter.wait(for: [exp], timeout: timeout) == .completed else {
            if fail { XCTFail("element not ready to click within \(timeout)s", file: file, line: line) }
            return false
        }
        element.click()
        return true
    }

    @discardableResult
    static func focusAndTypeScript(
        app: XCUIApplication,
        text: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let editor = element(app, "textInput_textEditor")
        guard waitForExistence(editor, timeout: timeout, file: file, line: line) else { return false }
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
        app.typeText(text)
        let badge = element(app, "textInput_charCount")
        let predicate = NSPredicate { _, _ in
            guard badge.exists else { return false }
            let label = ((badge.value as? String) ?? badge.label)
            return !label.isEmpty && !label.hasPrefix("0")
        }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: badge)
        guard XCTWaiter.wait(for: [exp], timeout: 5) == .completed else {
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).doubleClick()
            app.typeText(text)
            guard XCTWaiter.wait(for: [exp], timeout: 5) == .completed else {
                XCTFail("script did not land in composer", file: file, line: line)
                return false
            }
            return true
        }
        return true
    }

    static func clearScriptEditor(app: XCUIApplication) {
        let editor = element(app, "textInput_textEditor")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
    }

    @discardableResult
    static func navigateSidebar(
        app: XCUIApplication,
        item: String,
        timeout: TimeInterval = 15,
        fail: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let sidebarID = item.hasPrefix("sidebar_") ? item : "sidebar_\(item)"
        let screenKey = item.replacingOccurrences(of: "sidebar_", with: "")
        let btn = button(app, sidebarID)
        guard btn.waitForExistence(timeout: timeout) else {
            if fail { XCTFail("sidebar \(sidebarID) missing", file: file, line: line) }
            return false
        }
        guard clickWhenReady(btn, timeout: timeout, fail: fail, file: file, line: line) else { return false }
        return waitForMarkerValue(
            app,
            identifier: "mainWindow_activeScreen",
            contains: screenKey,
            timeout: timeout,
            fail: fail,
            file: file,
            line: line
        )
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        VocelloMacUIQuery.waitForNonExistence(self, timeout: timeout)
    }
}
