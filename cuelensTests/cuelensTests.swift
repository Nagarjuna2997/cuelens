import XCTest
@testable import cuelens

final class CueLensTests: XCTestCase {
    @MainActor
    func testAssistantLifecycleAndPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(directory: directory)
        let model = AppModel(vault: vault, credentials: TestCredentials())
        XCTAssertFalse(model.saveAssistant(AssistantProfile(name: "  ")))
        var profile = AssistantProfile(name: "  Platform Engineer  ", background: "Built an iOS app.")
        XCTAssertTrue(model.saveAssistant(profile))
        XCTAssertEqual(model.assistants.first?.name, "Platform Engineer")
        profile.archived = true
        XCTAssertTrue(model.saveAssistant(profile))
        XCTAssertTrue(model.activeAssistants.isEmpty)
        let duplicate = try XCTUnwrap(model.assistants.first).duplicate()
        XCTAssertNotEqual(duplicate.id, profile.id)
        XCTAssertTrue(model.saveAssistant(duplicate))
        model.deleteAssistant(profile.id)
        XCTAssertEqual(try vault.load().assistants, [duplicate])
    }

    func testProviderSelectionAndCredentialBoundary() throws {
        var preferences = Preferences()
        preferences.setModel("default", for: .openAI)
        let profile = AssistantProfile(name: "Interview", provider: .openAI, model: "override")
        let selection = preferences.answerSelection(for: profile)
        XCTAssertEqual(selection, ProviderSelection(provider: .openAI, model: "override"))
        let store = TestCredentials()
        XCTAssertThrowsError(try ProviderConnection(selection: selection, credentials: store)) {
            XCTAssertEqual($0 as? ProviderError, .credentialUnavailable)
        }
        try store.write("fixture-only", for: .openAI)
        let connection = try ProviderConnection(selection: selection, credentials: store)
        XCTAssertEqual(try connection.request(.connectionTest).url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(try connection.request(.connectionTest).value(forHTTPHeaderField: "Authorization"), "Bearer fixture-only")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self).contains("fixture-only"))
    }

    func testProviderModelValidation() throws {
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .gemini)
        XCTAssertThrowsError(try ProviderConnection(selection: .init(provider: .gemini, model: "../other"),
                                                   credentials: credentials)) {
            XCTAssertEqual($0 as? ProviderError, .modelRequired)
        }
        let connection = try ProviderConnection(selection: .init(provider: .gemini, model: "gemini-test"),
                                                credentials: credentials)
        XCTAssertEqual(try connection.request(.connectionTest).url?.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(try connection.request(.connectionTest).value(forHTTPHeaderField: "x-goog-api-key"), "fixture-only")
    }

    func testProviderStreamEvents() throws {
        var sse = ServerSentEvents()
        XCTAssertNil(try sse.consume("event: response.output_text.delta"))
        XCTAssertNil(try sse.consume(#"data: {"type":"response.output_text.delta","delta":"I built"}"#))
        let data = try XCTUnwrap(sse.consume(""))
        XCTAssertEqual(try AnswerEvent.decode(data, provider: .openAI), [.text("I built")])
        let claude = #"{"type":"content_block_delta","delta":{"type":"text_delta","text":" a pipeline."}}"#
        XCTAssertEqual(try AnswerEvent.decode(claude, provider: .claude), [.text(" a pipeline.")])
        let gemini = #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"internal"},{"text":"Ready"}]},"finishReason":"STOP"}]}"#
        XCTAssertEqual(try AnswerEvent.decode(gemini, provider: .gemini), [.text("Ready"), .finished])
        XCTAssertThrowsError(try AnswerEvent.decode(#"{"error":{"type":"rate_limit_error"}}"#, provider: .claude)) {
            XCTAssertEqual($0 as? ProviderError, .http(429))
        }
    }
}

final class TestCredentials: CredentialStore {
    private var values = [Credential: String]()

    func read(_ credential: Credential) throws -> String? { values[credential] }
    func write(_ value: String, for credential: Credential) throws { values[credential] = value }
    func delete(_ credential: Credential) throws { values.removeValue(forKey: credential) }
}
