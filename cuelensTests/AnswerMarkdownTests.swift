import XCTest
@testable import cuelens

final class AnswerMarkdownTests: XCTestCase {
    func testHeadingsParagraphsAndListMarkers() {
        XCTAssertEqual(AnswerMarkdown.blocks(in: """
        ### Example
        The first line
        continues here.

        - Return **indices**.
        - Preserve the input.

        ### Time complexity ###
        1. Build the lookup.
        2) Scan once.
        """), [
            .heading(level: 3, text: "Example"),
            .paragraph("The first line continues here."),
            .listItem(marker: "•", depth: 0, text: "Return **indices**."),
            .listItem(marker: "•", depth: 0, text: "Preserve the input."),
            .heading(level: 3, text: "Time complexity"),
            .listItem(marker: "1.", depth: 0, text: "Build the lookup."),
            .listItem(marker: "2.", depth: 0, text: "Scan once.")
        ])
    }

    func testStreamingCodePreservesIndentationAndHeadingLikeComments() {
        let partial = "### Solution\n```swift\nfunc solve() {\n    // ### Details\n    return [0, 1]"
        XCTAssertEqual(AnswerMarkdown.blocks(in: partial), [
            .heading(level: 3, text: "Solution"),
            .code(language: "swift", text: "func solve() {\n    // ### Details\n    return [0, 1]")
        ])
        XCTAssertEqual(AnswerMarkdown.blocks(in: partial + "\n}\n```\n### Example").last,
                       .heading(level: 3, text: "Example"))
    }

    func testFenceMustMatchOpeningDelimiterAndLength() {
        XCTAssertEqual(AnswerMarkdown.blocks(in: "````text\n```\n### Details\n~~~~\n````\nAfter"), [
            .code(language: "text", text: "```\n### Details\n~~~~"), .paragraph("After")
        ])
        XCTAssertEqual(AnswerMarkdown.blocks(in: "~~~python\n# Comment\n~~~"), [
            .code(language: "python", text: "# Comment")
        ])
    }

    func testListContinuationsAndNestingKeepSeparateItems() {
        XCTAssertEqual(AnswerMarkdown.blocks(in: "- First line\n  continued.\n  - Child item\n- Final item"), [
            .listItem(marker: "•", depth: 0, text: "First line continued."),
            .listItem(marker: "•", depth: 1, text: "Child item"),
            .listItem(marker: "•", depth: 0, text: "Final item")
        ])
    }

    func testOrdinaryPunctuationIsNotDiscarded() {
        XCTAssertEqual(AnswerMarkdown.blocks(in: "#hashtag\n3.14 is pi.\n\n> Quote\n\n---\n\n**Bold**"), [
            .paragraph("#hashtag 3.14 is pi."), .quote("Quote"), .divider, .paragraph("**Bold**")
        ])
    }

    func testWindowsLineEndingsAndEmptyStreamingFence() {
        XCTAssertEqual(AnswerMarkdown.blocks(in: "## Example\r\n\r\n```swift"), [
            .heading(level: 2, text: "Example"), .code(language: "swift", text: "")
        ])
    }
}
