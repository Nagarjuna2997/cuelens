import AVFoundation
import XCTest
@testable import cuelens

final class HistoryTests: XCTestCase {
    func testRecordedPCMIsDiscoverableAndReadableThroughDirectoryAlias() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let realRoot = scratch.appendingPathComponent("workspace", isDirectory: true)
        let alias = scratch.appendingPathComponent("workspace-link", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realRoot)
        let vault = Vault(directory: alias)
        let id = UUID()
        let folder = vault.audioDirectory(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clip = folder.appending(path: "meeting-1.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { samples[i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 24_000) }
        do {
            let recording = try AVAudioFile(forWriting: clip, settings: format.settings,
                                            commonFormat: .pcmFormatFloat32, interleaved: false)
            try recording.write(from: buffer)
        }
        let discovered = try XCTUnwrap(vault.audioFiles(for: id).first)
        XCTAssertEqual(discovered.lastPathComponent, "meeting-1.caf")
        let recording = try AVAudioFile(forReading: discovered)
        XCTAssertEqual(recording.length, 2_400)
        XCTAssertEqual(recording.processingFormat.sampleRate, 24_000)
        XCTAssertEqual(recording.processingFormat.channelCount, 1)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: recording.processingFormat, frameCapacity: 2_400))
        try recording.read(into: output)
        XCTAssertGreaterThan(AudioPipeline.level(output), 0.1)
        let player = try AVAudioPlayer(contentsOf: discovered)
        XCTAssertEqual(player.duration, 0.1, accuracy: 0.001)
        // Resolving a trusted workspace alias is allowed; redirecting its Audio subtree is not.
        let other = scratch.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let redirectedID = UUID()
        try FileManager.default.createSymbolicLink(at: vault.audioDirectory(redirectedID), withDestinationURL: other)
        XCTAssertThrowsError(try vault.audioFiles(for: redirectedID))
    }

    func testDamagedRecordDoesNotHideValidHistory() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let vault = Vault(directory: scratch)
        let session = MeetingSession(title: "Valid", assistantID: UUID(), assistantName: "Role")
        try vault.save(session)
        let corrupt = scratch.appending(path: "Sessions/\(UUID().uuidString).json")
        try Data("{broken".utf8).write(to: corrupt)
        let mismatched = scratch.appending(path: "Sessions/\(UUID().uuidString).json")
        try JSONEncoder().encode(session).write(to: mismatched)
        let result = try vault.readHistory()
        XCTAssertEqual(result.sessions, [session])
        XCTAssertEqual(result.unreadableCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
        let stored = scratch.appending(path: "Sessions/\(session.id.uuidString).json")
        let permissions = try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testAudioDiscoveryRejectsSymlinksAndIgnoresMetadataPaths() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let vault = Vault(directory: scratch)
        let id = UUID()
        let folder = vault.audioDirectory(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clip = folder.appending(path: "meeting-1.caf")
        try Data([1, 2]).write(to: clip)
        let external = scratch.appending(path: "outside.caf")
        try Data([3]).write(to: external)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "external.caf"), withDestinationURL: external)
        try Data([0]).write(to: folder.appending(path: "notes.txt"))
        XCTAssertEqual(try vault.audioFiles(for: id), [clip])
        let otherID = UUID()
        try FileManager.default.createSymbolicLink(at: vault.audioDirectory(otherID), withDestinationURL: folder)
        XCTAssertThrowsError(try vault.audioFiles(for: otherID))
    }

    func testOlderSessionDecodesAndPracticeDataExports() throws {
        var session = MeetingSession(title: "Practice", assistantID: UUID(), assistantName: "Engineer")
        let oldData = try JSONEncoder().encode(session)
        let oldRecord = try JSONDecoder().decode(MeetingSession.self, from: oldData)
        XCTAssertNil(oldRecord.practiceAttempts)
        XCTAssertNil(oldRecord.practiceStyle)
        session.practiceStyle = .technical
        session.practiceAttempts = [PracticeAttempt(question: "Explain retries", response: "Use a bounded retry budget.",
                                                    feedback: "Relevant and concise.",
                                                    metrics: .analyze(text: "Use a bounded retry budget."),
                                                    reviewTopic: "Retry budgets", nextReview: Date())]
        let result = SessionExport.render(session, format: .markdown)
        XCTAssertTrue(result.contains("## Practice review"))
        XCTAssertTrue(result.contains("Interview: Technical"))
        XCTAssertTrue(result.contains("Answer: Use a bounded retry budget."))
        XCTAssertTrue(result.contains("Review topic: Retry budgets"))
        XCTAssertTrue(result.contains("Words: 5"))
    }

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
