import XCTest
@testable import cuelens

final class ConversationContextTests: XCTestCase {
    func testDraftContextKeepsNewestThreeWithinPresetBudgetAndPreservesGrounding() throws {
        let assistant = AssistantProfile(name: "Engineer")
        let drafts = (0..<8).map { number in
            Suggestion(question: "Question \(number) " + String(repeating: "q", count: 2_000),
                       answer: "Answer \(number) " + String(repeating: "a", count: 8_000), provider: .openAI)
        }
        for preset in [ResourcePreset.low, .balanced, .performance] {
            let prompt = AnswerPrompts.make(task: .suggestion, question: "Expand that example.", assistant: assistant,
                                           index: KnowledgeIndex(assistant: assistant), recent: [], length: .short,
                                           preset: preset, recentSuggestions: drafts)
            let start = try XCTUnwrap(prompt.input.range(of: "RECENT AI-GENERATED DRAFTS"))
            let end = try XCTUnwrap(prompt.input.range(of: "\nREQUEST\n"))
            let context = String(prompt.input[start.lowerBound..<end.lowerBound])
            XCTAssertLessThanOrEqual(context.count, preset.contextCharacters / 5)
            XCTAssertFalse(context.contains("Question 4"))
            for number in 5...7 {
                XCTAssertTrue(context.contains("Question \(number)"))
                XCTAssertTrue(context.contains("Answer \(number)"))
            }
            XCTAssertTrue(prompt.instructions.contains("not evidence of the user's experience"))
            XCTAssertTrue(prompt.instructions.contains("Never invent employers"))
        }
    }

    func testPracticeAndSummariesExcludeDrafts() {
        let assistant = AssistantProfile(name: "Engineer")
        let draft = Suggestion(question: "Prior question", answer: "AI-only detail", provider: .openAI)
        for task in [AnswerTask.practiceQuestion, .practiceFeedback, .practiceHint, .summary] {
            let prompt = AnswerPrompts.make(task: task, question: "Current request", assistant: assistant,
                                           index: KnowledgeIndex(assistant: assistant), recent: [], length: .short,
                                           preset: .balanced, recentSuggestions: [draft])
            XCTAssertFalse(prompt.input.contains("AI-only detail"))
            XCTAssertFalse(prompt.input.contains("RECENT AI-GENERATED DRAFTS"))
        }
    }

    @MainActor
    func testTypedFollowupSeesPriorDraftWithoutAddingItToTranscriptOrAnotherSession() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let stream = ConversationContextStream()
        let live = LiveSession(vault: Vault(directory: root), credentials: credentials, streamer: stream)
        live.start(assistant: .init(name: "Backend", provider: .openAI), settings: .init(),
                   options: .init(microphone: false, save: false))
        live.composer = "Explain bounded retries."
        live.askComposer()
        try await eventually { !live.generating && !live.answer.isEmpty }
        XCTAssertTrue(live.record?.transcript.isEmpty == true)
        live.composer = "Give a concrete example of that."
        live.askComposer()
        try await eventually { !live.generating }
        let followup = await stream.lastInput
        XCTAssertTrue(followup.contains("Prior request: Explain bounded retries."))
        XCTAssertTrue(followup.contains("AI draft excerpt: Limit retries to three attempts."))
        XCTAssertTrue(followup.contains("REQUEST\nGive a concrete example of that."))
        live.end()
        try await eventually { live.phase == .idle }

        live.start(assistant: .init(name: "Design", provider: .openAI), settings: .init(),
                   options: .init(microphone: false, save: false))
        live.composer = "Explain visual hierarchy."
        live.askComposer()
        try await eventually { !live.generating }
        let newRoleInput = await stream.lastInput
        XCTAssertFalse(newRoleInput.contains("bounded retries"))
        XCTAssertFalse(newRoleInput.contains("Limit retries"))
        live.end()
        try await eventually { live.phase == .idle }
    }

    @MainActor
    private func eventually(_ check: () -> Bool) async throws {
        for _ in 0..<120 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Conversation did not settle.")
        throw CancellationError()
    }
}

private actor ConversationContextStream: AnswerStreaming {
    private(set) var lastInput = ""

    func stream(_ prompt: ProviderPrompt, connection: ProviderConnection,
                emit: @escaping @Sendable (AnswerEvent) async -> Void) async throws {
        lastInput = prompt.input
        await emit(.text("Limit retries to three attempts."))
        await emit(.finished)
    }
}
