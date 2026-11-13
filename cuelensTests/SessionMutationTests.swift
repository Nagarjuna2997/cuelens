import XCTest
@testable import cuelens

final class SessionMutationTests: XCTestCase {
    @MainActor
    func testFirstSpeechFailureAddsNoticeWithoutOverlappingRecordAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(directory: directory)
        let live = LiveSession(vault: vault, credentials: TestCredentials())
        live.start(assistant: .init(name: "Speech failure fixture"), settings: .init(),
                   options: .init(microphone: false, save: true))

        // The production transcriptionIncomplete event calls this mutation.
        // Its former optional assignment read record again during modify access,
        // causing a runtime exclusivity abort on the first native speech error.
        live.markTranscriptionIncomplete(.microphone)
        live.markTranscriptionIncomplete(.microphone)
        live.markTranscriptionIncomplete(.meeting)
        XCTAssertEqual(live.record?.transcriptionIncompleteSources, [.microphone, .meeting])
        XCTAssertNotNil(live.record?.transcriptionNotice)
        live.end()
        try await eventually { live.phase == .idle }
        XCTAssertEqual(try vault.sessions().first?.transcriptionIncompleteSources, [.microphone, .meeting])
    }

    @MainActor
    func testResponsePinTogglesWithoutReadingRecordDuringModification() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let live = LiveSession(vault: Vault(directory: directory), credentials: credentials,
                               streamer: PinFixtureStream())
        live.start(assistant: .init(name: "Pin fixture", provider: .openAI), settings: .init(),
                   options: .init(microphone: false, save: false))
        live.composer = "Explain a bounded queue."
        live.askComposer()
        try await eventually { !live.generating && !live.responses.isEmpty }
        live.togglePin()
        XCTAssertTrue(live.isPinned)
        XCTAssertEqual(live.pinnedResponses.count, 1)
        live.togglePin()
        XCTAssertFalse(live.isPinned)
        XCTAssertTrue(live.pinnedResponses.isEmpty)
        live.end()
        try await eventually { live.phase == .idle }
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Session did not settle.")
        throw CancellationError()
    }
}

private actor PinFixtureStream: AnswerStreaming {
    func stream(_ prompt: ProviderPrompt, connection: ProviderConnection,
                emit: @escaping @Sendable (AnswerEvent) async -> Void) async throws {
        await emit(.text("A bounded queue limits pending work."))
        await emit(.finished)
    }
}
