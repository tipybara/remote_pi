import Foundation
import XCTest

@testable import RemotePi

/// Spec 08 §8.5 — assistant output is Markdown (GFM + code blocks), and the
/// same renderer drives the streaming bubble, so it must tolerate syntax that
/// is still being typed.
final class MarkdownParserTests: XCTestCase {

    func testParagraphsSplitOnBlankLines() {
        let blocks = MarkdownParser.blocks("one\nstill one\n\ntwo")
        XCTAssertEqual(blocks, [.paragraph("one\nstill one"), .paragraph("two")])
    }

    func testHeadings() {
        XCTAssertEqual(
            MarkdownParser.blocks("## Plan\n\nbody"),
            [.heading(level: 2, text: "Plan"), .paragraph("body")]
        )
    }

    /// ATX headings need a space after the hashes; `#nofilter` is prose.
    func testHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(MarkdownParser.blocks("#nofilter"), [.paragraph("#nofilter")])
        XCTAssertEqual(
            MarkdownParser.blocks("####### seven"),
            [.paragraph("####### seven")]
        )
    }

    func testBulletAndOrderedLists() {
        XCTAssertEqual(
            MarkdownParser.blocks("- one\n* two\n+ three"),
            [
                .listItem(marker: "•", text: "one"),
                .listItem(marker: "•", text: "two"),
                .listItem(marker: "•", text: "three"),
            ]
        )
        XCTAssertEqual(
            MarkdownParser.blocks("1. first\n2) second"),
            [
                .listItem(marker: "1.", text: "first"),
                .listItem(marker: "2.", text: "second"),
            ]
        )
    }

    func testQuotesAndRules() {
        XCTAssertEqual(MarkdownParser.blocks("> careful"), [.quote("careful")])
        XCTAssertEqual(MarkdownParser.blocks("---"), [.rule])
        XCTAssertEqual(MarkdownParser.blocks("***"), [.rule])
        // Two dashes is not a rule.
        XCTAssertEqual(MarkdownParser.blocks("--"), [.paragraph("--")])
    }

    func testFencedCodeKeepsItsLanguageAndInteriorWhitespace() {
        let blocks = MarkdownParser.blocks("""
        before
        ```swift
        let x = 1

            indented
        ```
        after
        """)
        XCTAssertEqual(
            blocks,
            [
                .paragraph("before"),
                .code(language: "swift", code: "let x = 1\n\n    indented", closed: true),
                .paragraph("after"),
            ]
        )
    }

    /// The streaming case: the closing fence has not arrived yet. The block
    /// must still render as code — this is the frame the bubble spends most of
    /// its life in.
    func testUnterminatedFenceIsStillACodeBlock() {
        let blocks = MarkdownParser.blocks("```sh\nswift build")
        XCTAssertEqual(blocks, [.code(language: "sh", code: "swift build", closed: false)])
    }

    func testTildeFencesWork() {
        XCTAssertEqual(
            MarkdownParser.blocks("~~~\nplain\n~~~"),
            [.code(language: "", code: "plain", closed: true)]
        )
    }

    /// Markdown inside a fence is code, not markup: a `# comment` line in a
    /// shell block must not become a heading.
    func testMarkdownInsideAFenceIsNotParsed() {
        let blocks = MarkdownParser.blocks("```\n# not a heading\n- not a list\n```")
        XCTAssertEqual(
            blocks,
            [.code(language: "", code: "# not a heading\n- not a list", closed: true)]
        )
    }

    func testEmptySourceProducesNoBlocks() {
        XCTAssertTrue(MarkdownParser.blocks("").isEmpty)
        XCTAssertTrue(MarkdownParser.blocks("   \n\n  ").isEmpty)
    }

    /// The streaming row's identity must not change as its text grows — that
    /// is `TranscriptItem.id`'s job — but block ids do change, and that is
    /// fine: they are `ForEach` keys inside one row.
    func testBlockIdsAreStableForIdenticalContent() {
        let first = MarkdownParser.blocks("# Title\n\nbody")
        let second = MarkdownParser.blocks("# Title\n\nbody")
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    // MARK: Inline

    func testInlineCodeIsMarkedForHighlighting() {
        let attributed = MarkdownParser.inline("run `swift build` now")
        let codeRuns = attributed.runs.filter {
            $0.inlinePresentationIntent?.contains(.code) == true
        }
        XCTAssertEqual(codeRuns.count, 1)
        XCTAssertEqual(String(attributed[codeRuns[0].range].characters), "swift build")
    }

    func testInlineBoldIsParsedAndMarkersAreConsumed() {
        let attributed = MarkdownParser.inline("a **bold** word")
        XCTAssertEqual(String(attributed.characters), "a bold word")
    }

    /// Half-typed syntax arrives on nearly every streaming frame. The parser
    /// must return text, never blank the bubble.
    func testPartialSyntaxStillRendersItsCharacters() {
        for partial in ["a **bo", "see [link](", "`open"] {
            let rendered = String(MarkdownParser.inline(partial).characters)
            XCTAssertFalse(rendered.isEmpty, partial)
            XCTAssertTrue(rendered.contains("o") || rendered.contains("link"), partial)
        }
    }
}
