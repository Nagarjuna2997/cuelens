import XCTest
@testable import cuelens

final class HistoryTests: XCTestCase {
    func testSessionPersistenceExportAndAudioDeletion() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let vault = Vault(directory: scratch)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let line = TranscriptLine(time: 64.7, source: .meeting, text: "Follow up about the build.", provisional: true)
        var session = MeetingSession(title: "Build Review", assistantID: UUID(), assistantName: "Engineer", startedAt: start,
                                     endedAt: start.addingTimeInterval(74), transcript: [line],
                                     suggestions: [.init(question: "When?", answer: "Next week.", provider: .claude)],
                                     summary: "Review the build next week.", summaryProvider: .claude,
                                     sentTextToCloud: true, audioFiles: ["meeting-1.caf"])
        try FileManager.default.createDirectory(at: vault.audioDirectory(session.id), withIntermediateDirectories: true)
        try Data([0]).write(to: vault.audioDirectory(session.id).appending(path: "meeting-1.caf"))
        try vault.save(session)
        XCTAssertEqual(try vault.sessions(), [session])
        XCTAssertEqual(line.timestamp, "00:01:04")
        XCTAssertEqual(TranscriptLine(time: .infinity, source: .manual, text: "").timestamp, "00:00:00")
        XCTAssertTrue(SessionExport.render(session, format: .text).contains("[00:01:04] Meeting audio (unfinalized): Follow up"))
        XCTAssertTrue(SessionExport.render(session, format: .markdown).contains("## Summary\n\nReview the build next week."))
        XCTAssertTrue(SessionExport.render(session, format: .markdown).contains("### When? · Claude"))
        session.transcript[0].text = "Corrected transcript."
        try vault.save(session)
        XCTAssertEqual(try vault.sessions().first?.transcript.first?.text, "Corrected transcript.")
        try vault.deleteSession(session.id)
        XCTAssertTrue(try vault.sessions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.audioDirectory(session.id).path))
        try vault.deleteSession(session.id)
    }

    func testStreamingParserDeliversMultilineAndUTF8BeforeEOF() throws {
        var reader = ServerSentEvents()
        let stream = ": keepalive\r\nevent: result\r\ndata: first α\r\ndata: second\r\n\r\ndata: another\n\n"
        let frames = try stream.utf8.compactMap { try reader.consume(byte: $0) }
        XCTAssertEqual(frames, ["first α\nsecond", "another"])
    }

    func testImageIsEncodedForEachProviderAndKeysStayInHeaders() throws {
        let keys = TestCredentials()
        let image = CaptureImage(data: Data([0x01, 0x02, 0x03]))
        for provider in AnswerProvider.cloudProviders {
            let credential = try XCTUnwrap(provider.credential)
            try keys.write("fixture-only", for: credential)
            let connection = try ProviderConnection(selection: .init(provider: provider, model: provider.suggestedModel),
                                                    credentials: keys)
            let prompt = ProviderPrompt(instructions: "Read the image.", input: "Solve the problem.", outputLimit: 100, image: image)
            let request = try connection.request(prompt)
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(body.contains("AQID"))
            XCTAssertFalse(body.contains("fixture-only"))
            XCTAssertFalse(try XCTUnwrap(request.url).absoluteString.contains("fixture-only"))
        }
    }
}
