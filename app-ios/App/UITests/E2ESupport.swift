import XCTest

/// Shared plumbing for the end-to-end suite.
///
/// ## Why these tests exist as XCUITests and not as host-driven taps
///
/// The obvious way to drive a simulator from a script is host-side HID
/// injection (`axe`, `idb`, XcodeBuildMCP's `tap`). That needs a simulator
/// booted **with `Simulator.app` attached** — the HID/indigo port only exists
/// when there is a UI session. A simulator booted headless by `simctl boot`
/// accepts the calls, reports success, and drops every event on the floor:
/// even the hardware Home button does nothing. On a machine with a stripped
/// Xcode (no `Contents/Developer/Applications/Simulator.app`) there is no way
/// to get that session at all.
///
/// XCUITest does not go through host HID. The runner lives inside the
/// simulator and posts events through the automation session, so it works on a
/// headless device. That makes this suite the *only* way to prove a control
/// on this app is actually wired to its action.
///
/// ## Preconditions
///
/// These are not hermetic unit tests. They need, on the host:
///
/// 1. `relay` listening (default `ws://localhost:3888`);
/// 2. `node scripts/fake-pi.mjs --relay <same>` with several `--session`s.
///
/// The relay URL comes from the environment (see ``Env``) so nothing is
/// hardcoded to one developer's machine. The pairing payload does **not**:
/// `TEST_RUNNER_*` never reached the runner in this project, so `test00`
/// reads it from the simulator pasteboard instead (`xcrun simctl pbcopy`).
enum Env {
    /// The relay the app is pointed at. Must match fake-pi's `--relay`.
    static var relay: String { value("RP_RELAY") ?? "ws://localhost:3888" }

    /// Substring of the session the chat tests should open.
    static var chatSession: String { value("RP_CHAT_SESSION") ?? "" }

    private static func value(_ key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else {
            return nil
        }
        return raw
    }
}

extension XCTestCase {
    /// Launch the app under test, pointed at the local relay.
    ///
    /// `--relay` is the app's own debug flag (`AppModel.launchRelayURL`) and
    /// the only way to reach a relay on this Mac: `AppModel` deliberately
    /// drops a *stored* loopback URL so a stale dev setting cannot follow a
    /// user into a release build.
    func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--relay", Env.relay] + extraArguments
        app.launch()
        return app
    }

    /// Screenshot the whole screen and attach it under `name`.
    ///
    /// Attachments, not a file write: the runner is sandboxed inside the
    /// simulator and cannot write to a host path. `scripts/e2e.sh`
    /// pulls these back out of the `.xcresult`.
    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Wait for `element` to exist, failing the test with a useful message.
    @discardableResult
    func require(
        _ element: XCUIElement,
        _ what: String,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "timed out waiting for \(what)",
            file: file,
            line: line
        )
        return element
    }

    /// Poll `condition` until it holds. `waitForExistence` only covers
    /// "does this element exist"; most of what these tests assert is a
    /// *relationship* between elements (order, count, a label that changed).
    @discardableResult
    func waitUntil(
        _ what: String,
        timeout: TimeInterval = 30,
        poll: TimeInterval = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: poll)
        }
        XCTFail("timed out waiting until \(what)", file: file, line: line)
        return false
    }
}

extension XCUIApplication {
    /// Every session tile currently on Home, in render order.
    ///
    /// A tile is a `button` whose accessibility label the tile view builds by
    /// combining its children (`title, model, presence`). The chrome buttons
    /// (tabs, `+`, gear, grouping) are excluded by label.
    var sessionTiles: [XCUIElement] {
        let chrome: Set<String> = ["New session", "Settings", "Group sessions by"]
        return buttons.allElementsBoundByIndex.filter { element in
            guard element.exists else { return false }
            let label = element.label
            if chrome.contains(label) { return false }
            // Filter tabs read "All, 5" / "Online, 3" / "Offline, 0".
            if label.hasPrefix("All, ") || label.hasPrefix("Online, ")
                || label.hasPrefix("Offline, ") {
                return false
            }
            // A tile always carries its presence word as the last component.
            return label.hasSuffix(", online") || label.hasSuffix(", offline")
                || label.hasSuffix(", working") || label.hasSuffix(", reconnecting")
        }
    }

    /// Tile labels in render order — the value the ordering assertions compare.
    var sessionTileLabels: [String] { sessionTiles.map(\.label) }

    /// The session-name half of each tile label.
    var sessionNames: [String] {
        sessionTileLabels.map { label in
            String(label.split(separator: ",").first ?? "")
        }
    }

    /// A filter tab by name, matched on the "Name, count" label shape so the
    /// count does not have to be known.
    func filterTab(_ name: String) -> XCUIElement {
        buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(name), ")
        ).firstMatch
    }

    /// An element by accessibility identifier, whatever type it is exposed as.
    ///
    /// Deliberately not `app.buttons[id]`: several controls here are shapes
    /// with gestures rather than `Button`s, and a type-scoped query turns
    /// "this control has the wrong accessibility type" into "no such element",
    /// which reads like a missing feature instead of the a11y bug it is.
    func control(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The count rendered on a filter tab, or `nil` when the tabs are hidden.
    func filterTabCount(_ name: String) -> Int? {
        let tab = filterTab(name)
        guard tab.exists else { return nil }
        return Int(tab.label.split(separator: " ").last.map(String.init) ?? "")
    }
}
