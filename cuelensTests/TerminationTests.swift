import XCTest
@testable import cuelens

final class TerminationTests: XCTestCase {
    @MainActor
    func testQuitFinishesAndSavesRecentSessionBeforeAllowingExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(directory: directory)
        let model = AppModel(vault: vault, credentials: TestCredentials())
        model.live.start(assistant: .init(name: "Quit fixture"), settings: .init(),
                         options: .init(microphone: false, save: true))
        model.live.addNote("A note entered immediately before Quit.")
        let id = try XCTUnwrap(model.live.record?.id)

        let ready = await model.prepareForTermination()

        XCTAssertTrue(ready)
        XCTAssertEqual(model.live.phase, .idle)
        XCTAssertNil(model.live.pendingSave)
        let saved = try XCTUnwrap(vault.sessions().first)
        XCTAssertEqual(saved.id, id)
        XCTAssertNotNil(saved.endedAt)
        XCTAssertEqual(saved.transcript.map(\.text), ["A note entered immediately before Quit."])
        XCTAssertEqual(model.history.first?.id, id)
    }

    @MainActor
    func testQuitRefusesToDiscardFailedSaveAndSucceedsAfterStorageRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(directory: directory)
        try vault.save(Workspace())
        let model = AppModel(vault: vault, credentials: TestCredentials())
        let obstacle = directory.appending(path: "Sessions")
        try Data("fixture prevents directory creation".utf8).write(to: obstacle)
        model.live.start(assistant: .init(name: "Save recovery"), settings: .init(),
                         options: .init(microphone: false, save: true))
        model.live.addNote("Keep this note if Quit cannot save.")
        let id = try XCTUnwrap(model.live.record?.id)

        let first = await model.prepareForTermination()

        XCTAssertFalse(first)
        XCTAssertFalse(model.preparingToQuit)
        XCTAssertEqual(model.live.pendingSave?.id, id)
        XCTAssertEqual(model.live.completionMessage, "Save needs attention")
        try FileManager.default.removeItem(at: obstacle)

        let retry = await model.prepareForTermination()

        XCTAssertTrue(retry)
        XCTAssertNil(model.live.pendingSave)
        XCTAssertEqual(try vault.sessions().first?.transcript.first?.text, "Keep this note if Quit cannot save.")
    }

    func testAudioInboxDeliversBufferedFinalAndIncompleteOnceInOrder() {
        let inbox = AudioEventInbox()
        let time = Date()
        inbox.append(.final(.meeting, "The completed turn", time, time))
        inbox.append(.transcriptionIncomplete(.microphone))
        let pending = inbox.takeAll()
        XCTAssertEqual(pending.count, 2)
        if case .final(.meeting, "The completed turn", _, _) = pending[0] {} else { XCTFail("Final transcript was reordered.") }
        if case .transcriptionIncomplete(.microphone) = pending[1] {} else { XCTFail("Incomplete notice was reordered.") }
        XCTAssertTrue(inbox.takeAll().isEmpty, "A later scheduled drain must not redeliver the same events.")
    }
}
