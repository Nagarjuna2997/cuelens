import XCTest
@testable import cuelens

final class PracticeIsolationTests: XCTestCase {
    @MainActor
    func testPracticeNeverAutomaticallyAnswersTranscriptEvenIfFlagChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let live = LiveSession(vault: Vault(directory: directory), credentials: credentials, streamer: IsolationAnswerStream())
        live.start(assistant: .init(name: "Practice", provider: .openAI), settings: .init(),
                   options: .init(microphone: false, save: false, practice: true))
        try await waitUntil { !live.generating && !live.practiceQuestion.isEmpty }
        let baselineQuestion = live.practiceQuestion
        let baselineAnswer = live.answer
        let baselineResponses = live.responses.count

        // A stale UI binding or restored preference must not switch practice
        // speech into the conversation auto-answer path.
        live.automatic = true
        let now = Date()
        live.finalizeTranscript("How did you handle retries?", source: .meeting, began: now, ended: now)
        XCTAssertEqual(live.record?.transcript.last?.text, "How did you handle retries?")
        XCTAssertFalse(live.generating)
        XCTAssertEqual(live.practiceQuestion, baselineQuestion)
        XCTAssertEqual(live.answer, baselineAnswer)
        XCTAssertEqual(live.responses.count, baselineResponses)
        live.end()
        try await waitUntil { live.phase == .idle }

        // Exercise the same transcript entry point in conversation mode, so
        // this test also proves the fixture can trigger an automatic answer.
        live.start(assistant: .init(name: "Conversation", provider: .openAI), settings: .init(),
                   options: .init(microphone: false, save: false, automaticAnswers: true))
        live.finalizeTranscript("How did you handle retries?", source: .meeting, began: now, ended: now)
        XCTAssertTrue(live.generating)
        try await waitUntil { !live.generating && live.responses.count == 1 }
        XCTAssertEqual(live.responses.first?.question, "How did you handle retries?")
        live.end()
        try await waitUntil { live.phase == .idle }
    }

    @MainActor
    func testPracticeSourceTogglesDoNotOverwriteConversationDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(directory: directory)
        let model = AppModel(vault: vault, credentials: TestCredentials())
        model.live.onEnded = nil
        var settings = model.preferences
        settings.sessionMicrophone = true
        settings.sessionMeetingAudio = true
        XCTAssertTrue(model.savePreferences(settings))
        model.live.start(assistant: .init(name: "Practice"), settings: settings,
                         options: .init(microphone: false, save: false, practice: true))
        // Paused toggles exercise preference handling without starting capture.
        model.live.pause()
        model.toggleSessionAudio(.microphone)
        model.toggleSessionAudio(.microphone)
        model.toggleSessionAudio(.meeting)
        model.toggleSessionAudio(.meeting)
        XCTAssertFalse(model.live.enabled.contains(.microphone))
        XCTAssertFalse(model.live.enabled.contains(.meeting))
        XCTAssertEqual(model.preferences.sessionMicrophone, true)
        XCTAssertEqual(model.preferences.sessionMeetingAudio, true)
        XCTAssertEqual(try vault.load().preferences.sessionMeetingAudio, true)
        model.live.end()
        try await waitUntil { model.live.phase == .idle }

        model.live.start(assistant: .init(name: "Conversation"), settings: settings,
                         options: .init(microphone: false, save: false))
        model.live.pause()
        model.toggleSessionAudio(.microphone)
        model.toggleSessionAudio(.microphone)
        model.toggleSessionAudio(.meeting)
        model.toggleSessionAudio(.meeting)
        XCTAssertEqual(model.preferences.sessionMicrophone, false)
        XCTAssertEqual(model.preferences.sessionMeetingAudio, false)
        XCTAssertEqual(try vault.load().preferences.sessionMicrophone, false)
        XCTAssertEqual(try vault.load().preferences.sessionMeetingAudio, false)
        model.live.end()
        try await waitUntil { model.live.phase == .idle }
    }

    @MainActor
    func testQuickPracticeUsesMicrophonePreferenceWithoutMeetingAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(vault: Vault(directory: directory), credentials: TestCredentials())
        var settings = model.preferences
        settings.sessionMicrophone = false
        settings.sessionMeetingAudio = true
        XCTAssertTrue(model.savePreferences(settings))
        var assistant = AssistantProfile(name: "Practice")
        assistant.kind = .mockInterview
        let options = model.quickSessionOptions(for: assistant)
        XCTAssertTrue(options.practice)
        XCTAssertFalse(options.microphone)
        XCTAssertFalse(options.meetingAudio)
        XCTAssertEqual(model.preferences.sessionMeetingAudio, true)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the practice isolation fixture.")
        throw CancellationError()
    }
}

private struct IsolationAnswerStream: AnswerStreaming {
    func stream(_ prompt: ProviderPrompt, connection: ProviderConnection,
                emit: @escaping @Sendable (AnswerEvent) async -> Void) async throws {
        await emit(.text(prompt.instructions.contains("mock interviewer") ? "Explain a retry policy." : "Use bounded retries."))
        await emit(.finished)
    }
}
