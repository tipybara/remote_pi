import XCTest

/// Home, end to end against a real relay and a real `fake-pi` (see
/// ``Env`` for the preconditions).
///
/// Each test is independent and relaunches the app, because the pairing lives
/// in the app container and survives; only `test00_pair` needs the pairing
/// payload, which it reads from the simulator pasteboard.
final class HomeE2ETests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Pairing

    /// The paste-QR path (spec 08 §6.5).
    ///
    /// The Simulator has no camera, so this is not a fallback — it is the only
    /// way pairing is ever exercised on a development machine, and the screen
    /// knows it: with no camera the flow lands on `cameraBlockedBody`, where
    /// "Paste code instead" is the *primary* button.
    ///
    /// The payload arrives on the **simulator pasteboard**, put there by the
    /// host with `xcrun simctl pbcopy booted`. Two reasons, both practical:
    ///
    /// * `TEST_RUNNER_*` environment does not reach the runner in this
    ///   project — it is baked into the generated `.xctestrun`, and neither
    ///   `xcodebuild test` nor `test-without-building` injected it here, so an
    ///   env-driven payload silently skipped the whole test;
    /// * it is what a user actually does. The sheet's `PasteButton` is the
    ///   one-tap path the design intends, and this is the only test that
    ///   exercises it.
    func test00_pairViaPastedCode() throws {
        let app = launchApp()

        // Home's first-pair empty state, or Settings if a pairing already
        // exists. Only the empty state carries "Scan QR" at the root.
        let scan = app.buttons["Scan QR"]
        guard scan.waitForExistence(timeout: 20) else {
            throw XCTSkip("already paired — no first-pair empty state on Home")
        }
        scan.tap()

        let paste = app.buttons["Paste code instead"]
        require(paste, "the paste entry on the camera-blocked pairing screen")
        paste.tap()

        let field = app.control("Pairing code")
        require(field, "the paste sheet's pairing-code field")

        // The sheet's own paste affordance. `PasteButton` carries its own
        // authorisation, so no "Allow Paste?" system alert appears.
        let pasteButton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] 'paste'"))
            .firstMatch
        require(pasteButton, "the sheet's PasteButton")
        pasteButton.tap()

        waitUntil("the pairing field to hold a remotepi:// payload", timeout: 15) {
            ((field.value as? String) ?? "").hasPrefix("remotepi://pair")
        }
        capture("pair-paste-sheet")

        let pair = app.buttons["Pair"]
        require(pair, "the Pair button")
        pair.tap()

        // `pair_ok` → the nickname sheet (§6.6). Accept whatever it pre-fills.
        let nicknameDone = app.buttons["Save"].firstMatch
        if nicknameDone.waitForExistence(timeout: 30) {
            capture("pair-nickname-sheet")
            nicknameDone.tap()
        }

        waitUntil("Home shows at least one session after pairing", timeout: 60) {
            !app.sessionTiles.isEmpty
        }
        capture("home-after-pairing")
    }

    // MARK: - Hierarchy

    /// Device → Workspace → Session, with more than one workspace visible.
    func test01_homeHierarchy() {
        let app = launchApp()
        waitUntil("sessions to arrive from the relay", timeout: 60) {
            app.sessionTiles.count >= 2
        }
        capture("home-hierarchy")

        // Workspace headers carry the folder basename and a count; they are
        // static text, not buttons, so they never collide with the tiles.
        XCTAssertGreaterThanOrEqual(
            app.sessionTiles.count, 2,
            "expected several sessions from fake-pi"
        )
    }

    // MARK: - Grouping

    /// All three grouping modes (spec 08 §7.4).
    ///
    /// The grouping control is a `Menu` wrapping a `Picker`, so each mode is a
    /// menu item and the menu has to be reopened between selections.
    func test02_groupingModes() {
        let app = launchApp()
        waitUntil("sessions to arrive", timeout: 60) { app.sessionTiles.count >= 2 }

        // `HomeGrouping.label`, verbatim (spec 08 §7.4). The default
        // (`Device / folder`) goes last on purpose: the grouping is persisted,
        // so a test that walks away from the default leaves every later run —
        // and every later screenshot — in a state nobody chose.
        for (mode, shot) in [
            ("No grouping", "grouping-none"),
            ("Device only", "grouping-device-only"),
            ("Device / folder", "grouping-device-folder"),
        ] {
            let menu = app.buttons["Group sessions by"]
            require(menu, "the grouping menu button")
            menu.tap()

            let option = app.buttons[mode].firstMatch
            if option.waitForExistence(timeout: 5) {
                option.tap()
            } else {
                // Some SwiftUI Picker-in-Menu renderings expose rows as cells.
                let cell = app.cells[mode].firstMatch
                require(cell, "the '\(mode)' grouping option")
                cell.tap()
            }

            waitUntil("the list to settle after choosing \(mode)", timeout: 15) {
                !app.sessionTiles.isEmpty
            }
            capture(shot)

            // The grouping is a layout knob: it must never drop a session.
            XCTAssertGreaterThanOrEqual(
                app.sessionTiles.count, 2,
                "grouping '\(mode)' lost sessions"
            )
        }
    }

    // MARK: - Filter tabs

    /// The online / offline / all tabs (spec 08 §7.3).
    ///
    /// Asserts the arithmetic as well as the render: `all == online + offline`
    /// is the invariant that catches a filter applied to the wrong collection.
    func test03_filterTabs() {
        let app = launchApp()
        waitUntil("sessions to arrive", timeout: 60) { app.sessionTiles.count >= 2 }

        for (tab, shot) in [
            ("All", "filter-all"),
            ("Online", "filter-online"),
            ("Offline", "filter-offline"),
        ] {
            let button = app.filterTab(tab)
            require(button, "the \(tab) filter tab")
            button.tap()
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 1.5)
            capture(shot)

            let count = app.filterTabCount(tab)
            XCTAssertNotNil(count, "\(tab) tab lost its count")
            if let count {
                XCTAssertEqual(
                    app.sessionTiles.count, count,
                    "\(tab) tab says \(count) but rendered \(app.sessionTiles.count) tiles"
                )
            }
        }

        let all = app.filterTabCount("All") ?? -1
        let online = app.filterTabCount("Online") ?? -1
        let offline = app.filterTabCount("Offline") ?? -1
        XCTAssertEqual(
            all, online + offline,
            "All (\(all)) must equal Online (\(online)) + Offline (\(offline))"
        )
    }

    // MARK: - Rename (plan 61's acceptance criterion)

    /// Renaming a **live** session must change the label in place: the tile
    /// keeps its slot and no second tile appears.
    ///
    /// This is the whole point of plan 61. A client that keys a tile by its
    /// display name (or re-registers the room on a rename) produces either a
    /// jump or a duplicate here, and both are the bug the Flutter client just
    /// spent a plan fixing.
    func test04_renameKeepsTileInPlace() {
        let app = launchApp()
        waitUntil("sessions to arrive", timeout: 60) { app.sessionTiles.count >= 2 }

        // Rename from the All tab so the assertion is not confounded by a
        // presence flip moving the row between tabs.
        let allTab = app.filterTab("All")
        if allTab.exists { allTab.tap() }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 1)

        let before = app.sessionNames
        XCTAssertGreaterThanOrEqual(before.count, 2, "need at least two sessions")

        // Pick the second tile: renaming the first cannot detect a move to the
        // top, which is the most likely failure.
        let index = 1
        let original = before[index]
        let renamed = "renamed-\(Int(Date().timeIntervalSince1970) % 100000)"

        let tile = app.sessionTiles[index]
        tile.press(forDuration: 0.8)

        let renameRow = app.buttons["Rename session"].firstMatch
        require(renameRow, "the long-press menu's Rename row")
        capture("rename-menu")
        renameRow.tap()

        let alertField = app.alerts.textFields.firstMatch
        require(alertField, "the rename alert's text field")
        alertField.tap()
        // The alert pre-fills with the current name (`renameText =
        // row.currentName`), so this has to replace rather than append.
        let prefilled = (alertField.value as? String) ?? ""
        XCTAssertEqual(
            prefilled, original,
            "the rename alert should pre-fill with the session's current name"
        )
        alertField.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: prefilled.count)
        )
        alertField.typeText(renamed)
        capture("rename-alert")
        app.alerts.buttons["Save"].tap()

        waitUntil("the tile label to become '\(renamed)'", timeout: 45) {
            app.sessionNames.contains(renamed)
        }
        capture("rename-after")

        let after = app.sessionNames

        // 1. No duplicate: the count did not grow.
        XCTAssertEqual(
            after.count, before.count,
            "a rename changed the session count — \(before) -> \(after)"
        )
        // 2. No move: the new name sits exactly where the old one sat.
        XCTAssertEqual(
            after.firstIndex(of: renamed), index,
            "the renamed tile moved — \(before) -> \(after)"
        )
        // 3. The old label is gone entirely (not left behind as a ghost row).
        XCTAssertFalse(
            after.contains(original),
            "the pre-rename label '\(original)' survived — \(after)"
        )
        // 4. Every other tile kept its slot.
        for (position, name) in before.enumerated() where position != index {
            XCTAssertEqual(
                after[position], name,
                "tile at \(position) moved during someone else's rename"
            )
        }
    }

    // MARK: - Chat

    /// Send a message and see the Pi's echo come back.
    ///
    /// fake-pi echoes the `user_message` first (the app renders the user
    /// bubble from the Pi's echo, not from its own optimistic copy) and then
    /// streams `agent_chunk`s followed by `agent_done`.
    func test05_chatSendAndEcho() {
        let app = launchApp()
        waitUntil("sessions to arrive", timeout: 60) { !app.sessionTiles.isEmpty }

        let online = app.filterTab("Online")
        if online.exists { online.tap() }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 1)

        let tiles = app.sessionTiles
        XCTAssertFalse(tiles.isEmpty, "no online session to open")
        let target = Env.chatSession.isEmpty
            ? tiles[0]
            : tiles.first { $0.label.contains(Env.chatSession) } ?? tiles[0]
        target.tap()

        let field = app.control("input-bar-field")
        require(field, "the composer field", timeout: 30)
        capture("chat-open")

        // Unique per run: the transcript is persisted, so a fixed string would
        // match a bubble from a previous run and prove nothing.
        let message = "hello from the native iOS client \(Int(Date().timeIntervalSince1970) % 100000)"
        field.tap()
        field.typeText(message)
        capture("chat-typed")

        let send = app.control("input-bar-action")
        require(send, "the composer's send button")
        XCTAssertTrue(
            send.elementType == .button || send.value(forKey: "traits") != nil,
            "the send control should be exposed as a button to assistive tech"
        )
        send.tap()

        // fake-pi echoes the text back inside its reply ("You said: …"), so
        // waiting for the unique marker inside a `[fake-pi]` bubble proves the
        // round trip rather than just that the local bubble rendered.
        waitUntil("the Pi's reply quoting this message", timeout: 60) {
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "You said: \(message)")
            ).firstMatch.exists
        }
        capture("chat-sent-and-echoed")

        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", message)
            ).firstMatch.exists,
            "the user's own message never rendered"
        )
    }

    // MARK: - Offline

    /// A room the Pi stopped listening on must flip to Offline promptly.
    ///
    /// The host is expected to kill `fake-pi` while this is waiting; the relay
    /// emits `room_ended` and answers any App→Pi frame for that room with a
    /// `transport_error`. This test only asserts the *client* reacts.
    func test06_offlineFlipWhenPiDies() {
        let app = launchApp()
        waitUntil("sessions to arrive", timeout: 60) { !app.sessionTiles.isEmpty }

        let allTab = app.filterTab("All")
        if allTab.exists { allTab.tap() }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 1)

        let onlineBefore = app.filterTabCount("Online") ?? 0
        XCTAssertGreaterThan(onlineBefore, 0, "nothing was online to begin with")
        capture("offline-before")

        // The host kills fake-pi during this window.
        waitUntil("every room to be reported offline", timeout: 120, poll: 1) {
            (app.filterTabCount("Online") ?? -1) == 0
        }
        capture("offline-after")

        XCTAssertEqual(app.filterTabCount("Online"), 0)
        XCTAssertEqual(
            app.filterTabCount("Offline"), app.filterTabCount("All"),
            "every session should have flipped to Offline"
        )
    }
}
