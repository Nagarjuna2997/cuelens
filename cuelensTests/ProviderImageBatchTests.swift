import XCTest
@testable import cuelens

final class ProviderImageBatchTests: XCTestCase {
    private var images: [CaptureImage] {
        (1...6).map { CaptureImage(data: Data([0xff, 0xd8, UInt8($0), 0xff, 0xd9])) }
    }

    private var prompt: ProviderPrompt {
        ProviderPrompt(instructions: "Analyze the supplied images together.", input: "Compare Image 1 with Image 6.",
                       outputLimit: 384, images: images)
    }

    func testOpenAIIncludesEveryImageInOrderAsJPEGDataURLs() throws {
        let request = try connection(.openAI).request(prompt)
        let body = try json(request)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, images.count * 2 + 1)
        for (index, image) in images.enumerated() {
            XCTAssertEqual(content[index * 2]["text"] as? String, "Image \(index + 1):")
            let block = content[index * 2 + 1]
            XCTAssertEqual(block["type"] as? String, "input_image")
            XCTAssertEqual(block["image_url"] as? String, "data:image/jpeg;base64," + image.data.base64EncodedString())
            XCTAssertEqual(block["detail"] as? String, "high")
        }
        XCTAssertEqual(content.last?["text"] as? String, prompt.input)
        XCTAssertEqual(body["instructions"] as? String, prompt.instructions)
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testClaudeIncludesEveryImageInOrderAsBase64Sources() throws {
        let body = try json(connection(.claude).request(prompt))
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, images.count * 2 + 1)
        for (index, image) in images.enumerated() {
            XCTAssertEqual(content[index * 2]["text"] as? String, "Image \(index + 1):")
            let block = content[index * 2 + 1]
            XCTAssertEqual(block["type"] as? String, "image")
            let source = try XCTUnwrap(block["source"] as? [String: String])
            XCTAssertEqual(source["type"], "base64")
            XCTAssertEqual(source["media_type"], "image/jpeg")
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(source["data"])), image.data)
        }
        XCTAssertEqual(content.last?["text"] as? String, prompt.input)
        XCTAssertEqual(body["system"] as? String, prompt.instructions)
    }

    func testGeminiIncludesEveryImageInOrderAsInlineData() throws {
        let request = try connection(.gemini).request(prompt)
        XCTAssertTrue(try XCTUnwrap(request.url).path.hasSuffix(":streamGenerateContent"))
        let body = try json(request)
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, images.count * 2 + 1)
        for (index, image) in images.enumerated() {
            XCTAssertEqual(parts[index * 2]["text"] as? String, "Image \(index + 1):")
            let inline = try XCTUnwrap(parts[index * 2 + 1]["inlineData"] as? [String: String])
            XCTAssertEqual(inline["mimeType"], "image/jpeg")
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(inline["data"])), image.data)
        }
        XCTAssertEqual(parts.last?["text"] as? String, prompt.input)
    }

    func testGeminiRejectsOversizedEncodedImageRequestLocally() throws {
        let image = CaptureImage(data: Data(repeating: 0xa5, count: 15_000_000))
        let oversized = ProviderPrompt(instructions: "Read the image.", input: "Describe it.", outputLimit: 384, images: [image])
        XCTAssertThrowsError(try connection(.gemini).request(oversized)) {
            XCTAssertEqual($0 as? ProviderError, .imagePayloadTooLarge)
        }
    }

    func testSingleImageCompatibilityAndEmptyRequestsKeepExistingShapes() throws {
        var single = ProviderPrompt(instructions: "Read.", input: "Describe.", outputLimit: 384, image: images[0])
        XCTAssertEqual(single.images.map(\.data), [images[0].data])
        single.image = images[1]
        XCTAssertEqual(single.images.map(\.data), [images[1].data])
        single.image = nil
        XCTAssertTrue(single.images.isEmpty)
        let openAI = try json(connection(.openAI).request(single))
        XCTAssertEqual(openAI["input"] as? String, single.input)
        let claude = try json(connection(.claude).request(single))
        XCTAssertEqual((claude["messages"] as? [[String: Any]])?.first?["content"] as? String, single.input)
        let gemini = try json(connection(.gemini).request(single))
        let parts = ((gemini["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: String]])
        XCTAssertEqual(parts, [["text": single.input]])
    }

    private func connection(_ provider: AnswerProvider) throws -> ProviderConnection {
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: XCTUnwrap(provider.credential))
        return try ProviderConnection(selection: .init(provider: provider, model: provider.suggestedModel), credentials: credentials)
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}
