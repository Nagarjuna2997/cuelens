import XCTest
@testable import cuelens

final class PracticeReliabilityTests: XCTestCase {
    func testOlderPracticeAttemptsRemainReadableWithoutFeedbackState() throws {
        let attempt = PracticeAttempt(question: "Explain retries", response: "Bound the attempts.",
                                      feedback: "Clear example.", metrics: .analyze(text: "Bound the attempts."))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
        object.removeValue(forKey: "feedbackState")
        object.removeValue(forKey: "feedbackError")
        let restored = try JSONDecoder().decode(PracticeAttempt.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.effectiveFeedbackState, .completed)
        XCTAssertEqual(restored.response, attempt.response)
    }

    @MainActor
    func testFeedbackFailureRetainsAttemptAndRetryUpdatesItWithoutDuplication() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let stream = PracticeReliabilityStream(firstFeedbackFails: true)
        let vault = Vault(directory: root)
        let live = LiveSession(vault: vault, credentials: credentials, streamer: stream)
        let assistant = AssistantProfile(name: "Backend", jobTitle: "Backend engineer", provider: .openAI)
        live.start(assistant: assistant, settings: .init(), options: .init(microphone: false, save: true,
                   practice: true, practiceStyle: .technical, practiceHints: false, reviewTopic: "Retries"))
        try await eventually { !live.practiceQuestion.isEmpty && !live.generating }
        let question = live.practiceQuestion
        let initialCount = await stream.requestCount
        live.requestPracticeHint()
        XCTAssertFalse(live.generating)
        let hintCount = await stream.requestCount
        XCTAssertEqual(hintCount, initialCount)

        live.composer = "I bounded the retry queue and used exponential backoff."
        live.askComposer()
        let accepted = try XCTUnwrap(live.practiceAttempts.first)
        XCTAssertEqual(accepted.effectiveFeedbackState, .pending)
        XCTAssertEqual(try vault.sessions().first?.practiceAttempts?.first?.id, accepted.id)
        try await eventually { !live.generating }
        XCTAssertEqual(live.practiceAttempts.count, 1)
        XCTAssertEqual(live.practiceAttempts.first?.effectiveFeedbackState, .failed)
        XCTAssertEqual(live.practiceAttempts.first?.feedback, "Clarity: Clear approach.")
        XCTAssertNotNil(live.practiceAttempts.first?.feedbackError)
        XCTAssertEqual(try vault.sessions().first?.practiceAttempts?.first?.effectiveFeedbackState, .failed)

        live.regenerate()
        try await eventually { !live.generating }
        XCTAssertEqual(live.practiceAttempts.count, 1)
        XCTAssertEqual(live.practiceAttempts.first?.id, accepted.id)
        XCTAssertEqual(live.practiceAttempts.first?.effectiveFeedbackState, .completed)
        XCTAssertNil(live.practiceAttempts.first?.feedbackError)
        XCTAssertEqual(live.practiceAttempts.first?.reviewTopic, "Retry policies")
        live.schedulePracticeReview()
        let tomorrow = try XCTUnwrap(live.practiceAttempts.first?.nextReview)
        XCTAssertTrue(Calendar.current.isDateInTomorrow(tomorrow))

        live.nextPracticeQuestion()
        try await eventually { !live.generating }
        let questionPrompt = await stream.lastQuestionPrompt
        let followup = try XCTUnwrap(questionPrompt)
        XCTAssertTrue(followup.contains("exponential backoff"))
        XCTAssertTrue(followup.contains("Retry policies"))
        XCTAssertTrue(followup.contains("Backend engineer"))
        live.retryPracticeAnswer()
        XCTAssertEqual(live.practiceQuestion, question)
        XCTAssertEqual(live.answer, "")
        XCTAssertEqual(live.practiceAttempts.count, 1)
        live.end()
        try await eventually { live.phase == .idle }
        let saved = try XCTUnwrap(vault.sessions().first)
        XCTAssertEqual(saved.assistantID, assistant.id)
        let savedReview = try XCTUnwrap(saved.practiceAttempts?.first?.nextReview)
        XCTAssertTrue(Calendar.current.isDate(savedReview, inSameDayAs: tomorrow))
    }

    @MainActor
    func testCancelledPartialFeedbackSurvivesAndIgnoresLateTokens() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let vault = Vault(directory: root)
        let live = LiveSession(vault: vault, credentials: credentials,
                               streamer: PracticeReliabilityStream(delayedFeedback: true))
        live.start(assistant: .init(name: "Practice", provider: .openAI), settings: .init(),
                   options: .init(microphone: false, save: true, practice: true))
        try await eventually { !live.practiceQuestion.isEmpty && !live.generating }
        live.composer = "My complete answer remains available."
        live.askComposer()
        try await eventually { live.practiceAttempts.first?.effectiveFeedbackState == .partial }
        live.cancelAnswer()
        let retained = try XCTUnwrap(vault.sessions().first?.practiceAttempts?.first)
        XCTAssertEqual(retained.response, "My complete answer remains available.")
        XCTAssertEqual(retained.effectiveFeedbackState, .interrupted)
        XCTAssertEqual(retained.feedback, "Clarity: Clear approach.")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(live.practiceAttempts.first?.feedback, retained.feedback)
        XCTAssertEqual(live.practiceAttempts.count, 1)
        live.end()
        try await eventually { live.phase == .idle }
        XCTAssertEqual(try vault.sessions().first?.practiceAttempts?.first?.effectiveFeedbackState, .interrupted)
    }

    @MainActor
    private func eventually(_ check: () -> Bool) async throws {
        for _ in 0..<120 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Practice state did not settle.")
        throw CancellationError()
    }
}

private actor PracticeReliabilityStream: AnswerStreaming {
    let firstFeedbackFails: Bool
    let delayedFeedback: Bool
    private var feedbackCount = 0
    private(set) var requestCount = 0
    private(set) var lastQuestionPrompt: String?

    init(firstFeedbackFails: Bool = false, delayedFeedback: Bool = false) {
        self.firstFeedbackFails = firstFeedbackFails
        self.delayedFeedback = delayedFeedback
    }

    func stream(_ prompt: ProviderPrompt, connection: ProviderConnection,
                emit: @escaping @Sendable (AnswerEvent) async -> Void) async throws {
        requestCount += 1
        if prompt.instructions.contains("mock interviewer") {
            lastQuestionPrompt = prompt.input
            await emit(.text("How did you handle retries?"))
        } else {
            feedbackCount += 1
            await emit(.text("Clarity: Clear approach."))
            if delayedFeedback {
                // Intentionally ignore cancellation to exercise the session's stale-event guard.
                try? await Task.sleep(for: .milliseconds(80))
                await emit(.text(" late token"))
            }
            if firstFeedbackFails && feedbackCount == 1 { throw ProviderError.http(429) }
            await emit(.text("\nPractice topic: Retry policies"))
        }
        await emit(.finished)
    }
}
