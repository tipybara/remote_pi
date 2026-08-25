import Foundation
import RemotePiStore
import XCTest

@testable import RemotePi

/// Spec 08 §8.6 — the status table and the argument formatting rules.
final class ToolCardPresentationTests: XCTestCase {

    private func payload(
        tool: String,
        args: Any? = nil,
        status: ToolStatus = .pending,
        error: String? = nil
    ) -> ToolPayload {
        let data = args.map { try! JSONSerialization.data(withJSONObject: $0, options: []) }
        return ToolPayload(
            toolCallID: "call_1",
            tool: tool,
            argsJSON: data,
            status: status,
            error: error
        )
    }

    // MARK: The status table

    func testStatusTable() {
        let expected: [(ToolStatus, ToolCardPresentation.Tone, String, String, Bool)] = [
            (.pending, .accent, "RUNNING", "⏳ Running…", false),
            (.allowed, .accent, "RUNNING", "⏳ Running…", false),
            (.completed, .success, "DONE", "✓ Done", false),
            (.failed, .error, "FAILED", "✗ Failed", false),
            (.denied, .muted, "DENIED", "✗ Denied", true),
            (.expired, .muted, "EXPIRED", "✗ Expired", true),
        ]
        for (status, tone, label, outcome, dimmed) in expected {
            let card = ToolCardPresentation.make(payload(tool: "bash", status: status))
            XCTAssertEqual(card.tone, tone, "\(status)")
            XCTAssertEqual(card.statusLabel, label, "\(status)")
            XCTAssertEqual(card.outcome, outcome, "\(status)")
            XCTAssertEqual(card.dimmed, dimmed, "\(status)")
        }
    }

    /// `failed` and `denied` show the Pi's message when it sent one; only
    /// `expired` is always the literal.
    func testOutcomePrefersTheReportedError() {
        XCTAssertEqual(
            ToolCardPresentation.outcome(status: .failed, error: "exit 2"),
            "✗ exit 2"
        )
        XCTAssertEqual(
            ToolCardPresentation.outcome(status: .denied, error: "user said no"),
            "✗ user said no"
        )
        XCTAssertEqual(
            ToolCardPresentation.outcome(status: .expired, error: "ignored"),
            "✗ Expired"
        )
    }

    func testTitleIsTheUppercasedToolName() {
        XCTAssertEqual(ToolCardPresentation.make(payload(tool: "bash")).title, "BASH")
    }

    // MARK: Argument formatting

    func testBashRendersItsCommand() {
        let card = ToolCardPresentation.make(
            payload(tool: "bash", args: ["command": "swift build", "timeout": 30])
        )
        XCTAssertEqual(card.command, "swift build")
        XCTAssertTrue(card.diff.isEmpty)
    }

    func testEditAndWriteRenderToolPlusPath() {
        XCTAssertEqual(
            ToolCardPresentation.make(
                payload(tool: "Write", args: ["file_path": "/tmp/a.swift"])
            ).command,
            "write /tmp/a.swift"
        )
        // `path` is the accepted alias.
        XCTAssertEqual(
            ToolCardPresentation.make(
                payload(tool: "edit", args: ["path": "/tmp/b.swift"])
            ).command,
            "edit /tmp/b.swift"
        )
    }

    /// Deliberate deviation: the Dart walks Dart's insertion-ordered map;
    /// `JSONSerialization` hands back an unordered dictionary, so without a
    /// sort the same tool call renders its arguments in a different order on
    /// every redraw.
    func testUnknownToolRendersSortedKeyValuePairs() {
        let card = ToolCardPresentation.make(
            payload(tool: "grep", args: ["pattern": "TODO", "glob": "*.swift", "count": 3])
        )
        XCTAssertEqual(card.command, "count=3 glob=*.swift pattern=TODO")
    }

    func testMissingOrUndecodableArgsRenderEmptyRatherThanCrashing() {
        XCTAssertEqual(ToolCardPresentation.make(payload(tool: "bash")).command, "")
        let broken = ToolPayload(
            toolCallID: "c",
            tool: "bash",
            argsJSON: Data([0x7B, 0x7B]),  // "{{"
            status: .pending
        )
        XCTAssertEqual(ToolCardPresentation.make(broken).command, "")
    }

    // MARK: Diff rendering

    func testEditWithHunksRendersASignedPaddedDiff() {
        let args: [String: Any] = [
            "file_path": "/tmp/a.swift",
            "hunks": [
                ["lines": [
                    ["kind": "context", "oldLine": 9, "text": "let a = 1"],
                    ["kind": "remove", "oldLine": 10, "text": "let b = 2"],
                    ["kind": "add", "newLine": 10, "text": "let b = 3"],
                ]],
                ["lines": [
                    ["kind": "context", "oldLine": 120, "text": "return a"],
                ]],
            ],
        ]
        let card = ToolCardPresentation.make(payload(tool: "edit", args: args))

        XCTAssertEqual(card.command, "edit /tmp/a.swift")
        XCTAssertEqual(
            card.diff.map(\.text),
            [
                "    9 let a = 1",
                "-  10 let b = 2",
                "+  10 let b = 3",
                "      ...",
                "  120 return a",
            ]
        )
        XCTAssertEqual(
            card.diff.map(\.kind),
            [.context, .remove, .add, .context, .context]
        )
        // Ids are positional because two identical context lines are otherwise
        // indistinguishable.
        XCTAssertEqual(card.diff.map(\.id), [0, 1, 2, 3, 4])
    }

    func testEllipsisLinesSeparateHunksInsideOneHunkToo() {
        let args: [String: Any] = [
            "file_path": "/tmp/a.swift",
            "hunks": [["lines": [
                ["kind": "add", "newLine": 1, "text": "x"],
                ["kind": "ellipsis"],
                ["kind": "add", "newLine": 9, "text": "y"],
            ]]],
        ]
        let card = ToolCardPresentation.make(payload(tool: "edit", args: args))
        XCTAssertEqual(card.diff.map(\.text), ["+   1 x", "      ...", "+   9 y"])
    }

    /// `hunks` present but unusable must fall back to the plain `edit <path>`
    /// line rather than rendering an empty code block.
    func testEditWithEmptyHunksFallsBackToThePathLine() {
        let card = ToolCardPresentation.make(
            payload(tool: "edit", args: ["file_path": "/tmp/a.swift", "hunks": []])
        )
        XCTAssertEqual(card.command, "edit /tmp/a.swift")
        XCTAssertTrue(card.diff.isEmpty)
    }

    func testLineWithoutANumberPadsWithSpaces() {
        let args: [String: Any] = [
            "file_path": "/x",
            "hunks": [["lines": [["kind": "context", "text": "no number"]]]],
        ]
        let card = ToolCardPresentation.make(payload(tool: "edit", args: args))
        XCTAssertEqual(card.diff.map(\.text), ["      no number"])
    }
}
