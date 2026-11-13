import XCTest
@testable import cuelens

final class ProviderReliabilityTests: XCTestCase {
    func testHaikuLiveAnswerReservesOutputForVisibleText() throws {
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .claude)
        let haiku = try ProviderConnection(selection: .init(provider: .claude, model: "claude-haiku-5-5"), credentials: credentials)
        let request = try haiku.request(.connectionTest)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["max_tokens"] as? Int, ProviderPrompt.connectionTest.outputLimit)

        let other = try ProviderConnection(selection: .init(provider: .claude, model: "claude-opus-5-5"), credentials: credentials)
        let otherBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(other.request(.connectionTest).httpBody)) as? [String: Any])
        XCTAssertNil(otherBody["thinking"], "Models with mandatory thinking must not inherit Haiku-specific settings.")
    }

    func testClaudeContextLimitIsNotSuccessfulCompletion() {
        let event = #"{"type":"message_delta","delta":{"stop_reason":"model_context_window_exceeded"},"usage":{"output_tokens":34}}"#
        XCTAssertThrowsError(try AnswerEvent.decode(event, provider: .claude)) {
            XCTAssertEqual($0 as? ProviderError, .incomplete)
        }
    }

    func testEventReaderHandlesCRLFAndMultibyteTextAcrossBytes() throws {
        let text = "event: message\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"café 👋\"}\r\n\r\n"
        var reader = ServerSentEvents()
        var events = [AnswerEvent]()
        for byte in text.utf8 {
            if let payload = try reader.consume(byte: byte) {
                events += try AnswerEvent.decode(payload, provider: .openAI)
            }
        }
        XCTAssertEqual(events, [.text("café 👋")])
    }
}
