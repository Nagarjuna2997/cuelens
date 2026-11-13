import XCTest
@testable import cuelens

final class LiveSessionLifecycleTests: XCTestCase {
    @MainActor
    func testCancelThenEndRetainsOnePartialAnswerAndIgnoresLateText() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let live = LiveSession(vault: Vault(directory: root), credentials: credentials,
                               streamer: LifecycleFixtureStream(delayed: true))
        live.start(assistant: .init(name: "Lifecycle", provider: .openAI), settings: .init(),
                   options: .init(microphone: false, save: true))
        live.composer = "Explain a queue"
        live.askComposer()
        try await eventually { live.answer == "A bounded queue" }
        live.cancelAnswer()
        XCTAssertFalse(live.generating)
        XCTAssertEqual(live.responses.count, 1)
        XCTAssertTrue(live.responses[0].answer.contains("interrupted"))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(live.answer, "A bounded queue")
        live.end()
        try await eventually { live.phase == .idle }
        let saved = try XCTUnwrap(Vault(directory: root).sessions().first)
        XCTAssertEqual(saved.suggestions.count, 1)
        XCTAssertFalse(saved.suggestions[0].answer.contains("late token"))
    }

    @MainActor
    func testMissingCredentialLeavesPreviousResponseAndUnsentQuestionIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let live = LiveSession(vault: Vault(directory: root), credentials: credentials,
                               streamer: LifecycleFixtureStream())
        live.start(assistant: .init(name: "Lifecycle", provider: .openAI), settings: .init(backupProvider: .claude),
                   options: .init(microphone: false, save: false))
        live.composer = "First request"
        live.askComposer()
        try await eventually { !live.generating && !live.answer.isEmpty }
        let priorAnswer = live.answer
        live.useBackup()
        XCTAssertEqual(live.currentProvider.provider, .openAI)
        XCTAssertEqual(live.answer, priorAnswer)
        XCTAssertEqual(live.question, "First request")
        XCTAssertEqual(live.answerError, ProviderError.credentialUnavailable.localizedDescription)
        try credentials.delete(.openAI)
        live.composer = "Unsent second request"
        live.askComposer()
        XCTAssertEqual(live.composer, "Unsent second request")
        XCTAssertEqual(live.answer, priorAnswer)
        XCTAssertEqual(live.question, "First request")
        XCTAssertEqual(live.responses.count, 1)
        live.end()
        try await eventually { live.phase == .idle }
    }

    @MainActor
    func testFailedEndSaveRetainsRecordUntilRetryAndBlocksNewSession() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedDirectory = root.appending(path: "blocked")
        try Data("fixture obstacle".utf8).write(to: blockedDirectory)
        let vault = Vault(directory: blockedDirectory)
        let live = LiveSession(vault: vault, credentials: TestCredentials())
        var endCount = 0
        var saveCount = 0
        live.onEnded = { endCount += 1 }
        live.onSaved = { _ in saveCount += 1 }
        live.start(assistant: .init(name: "Preserved"), settings: .init(), options: .init(microphone: false, save: true))
        let originalID = try XCTUnwrap(live.record?.id)
        live.addNote("Keep this transcript through a failed save.")
        live.pause()
        live.resume()
        live.end()
        live.end()
        try await eventually { live.phase == .idle }
        XCTAssertEqual(live.pendingSave?.id, originalID)
        XCTAssertEqual(live.pendingSave?.transcript.count, 1)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(saveCount, 0)
        live.start(assistant: .init(name: "Blocked new session"), settings: .init(), options: .init(microphone: false))
        XCTAssertEqual(live.phase, .idle)
        XCTAssertEqual(live.pendingSave?.id, originalID)
        try FileManager.default.removeItem(at: blockedDirectory)
        live.retrySave()
        XCTAssertNil(live.pendingSave)
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(try vault.sessions().first?.id, originalID)
        live.start(assistant: .init(name: "Next session"), settings: .init(), options: .init(microphone: false, save: false))
        XCTAssertEqual(live.phase, .active)
        XCTAssertNotEqual(live.record?.id, originalID)
        live.end()
        try await eventually { live.phase == .idle }
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Session lifecycle did not reach the expected state.")
        throw CancellationError()
    }
}

private struct LifecycleFixtureStream: AnswerStreaming {
    var delayed = false

    func stream(_ prompt: ProviderPrompt, connection: ProviderConnection,
                emit: @escaping @Sendable (AnswerEvent) async -> Void) async throws {
        await emit(.text("A bounded queue"))
        if delayed {
            // Deliberately ignore cancellation to exercise LiveSession's request identity check.
            try? await Task.sleep(for: .milliseconds(80))
            await emit(.text(" late token"))
        }
        await emit(.finished)
    }
}
