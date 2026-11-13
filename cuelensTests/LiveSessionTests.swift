import XCTest
@testable import cuelens

final class LiveSessionTests: XCTestCase {
    func testDOCXExtractsTextAndScopesRetrievalToAssistant() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let word = scratch.appending(path: "word")
        try FileManager.default.createDirectory(at: word, withIntermediateDirectories: true)
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body><w:p><w:r><w:t>Designed a Kafka ingestion pipeline.</w:t></w:r></w:p>
              <w:p><w:r><w:t>Reduced the retry queue by 35%.</w:t></w:r></w:p></w:body>
            </w:document>
            """
        try xml.write(to: word.appending(path: "document.xml"), atomically: true, encoding: .utf8)
        let file = scratch.appending(path: "Resume.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = scratch
        zip.arguments = ["-q", file.path, "word/document.xml"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        let imported = try KnowledgeImport.read(file, kind: .resume)
        XCTAssertTrue(imported.text.contains("Kafka ingestion pipeline"))
        XCTAssertEqual(imported.kind, .resume)
        let assistant = AssistantProfile(name: "Data Engineer", knowledge: [imported])
        let query = "How did you design a Kafka pipeline?"
        XCTAssertTrue(KnowledgeIndex(assistant: assistant).context(for: query, limit: 700).contains("Kafka ingestion"))
        XCTAssertFalse(KnowledgeIndex(assistant: .init(name: "Other")).context(for: query, limit: 700).contains("Kafka"))
        try Data([0x50, 0x4b, 0x03]).write(to: file)
        XCTAssertThrowsError(try KnowledgeImport.read(file, kind: .resume))
    }

    func testQuestionDetectionUsesMeetingSourceAndLastQuestion() {
        XCTAssertEqual(QuestionDetection.question(in: "Let’s move on. How did you handle retries? Great.", source: .meeting, locale: "en-US"),
                       "How did you handle retries?")
        XCTAssertNotNil(QuestionDetection.question(in: "Walk me through your incident response", source: .meeting, locale: "en-US"))
        XCTAssertNil(QuestionDetection.question(in: "Did you see that?", source: .microphone, locale: "en-US"))
        XCTAssertNil(QuestionDetection.question(in: "The deployment went well.", source: .meeting, locale: "en-US"))
    }

    func testVoiceActivityClosesAfterSilence() {
        var detector = VoiceActivity()
        XCTAssertEqual(detector.consume(rms: 0, duration: 0.5), .idle)
        XCTAssertEqual(detector.consume(rms: 0.06, duration: 0.06), .start)
        XCTAssertEqual(detector.consume(rms: 0.04, duration: 0.3), .speech)
        XCTAssertEqual(detector.consume(rms: 0, duration: 0.53), .end)
        XCTAssertFalse(detector.speaking)
    }

    func testPromptSeparatesBackgroundFromRoleAndBoundsContext() {
        let assistant = AssistantProfile(name: "Infra", jobDescription: "Lead 80 people.", background: "I built a build cache.")
        let lines = (0..<40).map { index in
            TranscriptLine(time: Double(index), source: .meeting, text: "Turn \(index) " + String(repeating: "w", count: 400))
        }
        let prompt = AnswerPrompts.make(task: .suggestion, question: "How did you speed up builds?", assistant: assistant,
                                        index: KnowledgeIndex(assistant: assistant), recent: lines, length: .short, preset: .low)
        XCTAssertTrue(prompt.instructions.contains("zero evidence"))
        XCTAssertTrue(prompt.input.contains("JOB DESCRIPTION\nLead 80 people.\nUSER BACKGROUND\nI built a build cache."))
        XCTAssertTrue(prompt.input.contains("Turn 39"))
        XCTAssertFalse(prompt.input.contains("Turn 0"))
        XCTAssertLessThan(prompt.input.count, 4_000)
    }

    @MainActor
    func testCloudApprovalAndStaleAnswerCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let streamer = FixtureAnswerStream()
        let live = LiveSession(vault: Vault(directory: root), credentials: credentials, streamer: streamer)
        let assistant = AssistantProfile(name: "Practice", background: "Built a build cache.", provider: .openAI)
        live.start(assistant: assistant, settings: .init(), options: .init(microphone: false, save: false))
        live.composer = "First question"
        live.askComposer()
        XCTAssertEqual(live.answerError, ProviderError.cloudApprovalRequired.localizedDescription)
        let blocked = await streamer.count
        XCTAssertEqual(blocked, 0)
        live.end()
        try await waitUntil { live.phase == .idle }
        live.start(assistant: assistant, settings: .init(), options: .init(microphone: false, save: true, allowCloud: true))
        live.composer = "First question"
        live.askComposer()
        try await waitUntil { live.answer == "Initial" }
        live.composer = "Second question"
        live.askComposer()
        try await waitUntil { live.answer == "Newest answer" && !live.generating }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(live.answer, "Newest answer")
        XCTAssertEqual(live.record?.suggestions.map(\.question), ["Second question"])
        XCTAssertEqual(live.record?.sentTextToCloud, true)
        XCTAssertNotNil(live.timing?.firstTokenDelay)
        live.addNote("Typed note.")
        live.end()
        try await waitUntil { live.phase == .idle }
        let saved = try XCTUnwrap(Vault(directory: root).sessions().first)
        XCTAssertEqual(saved.transcript.first?.text, "Typed note.")
        XCTAssertNotNil(saved.endedAt)
    }

    @MainActor
    private func waitUntil(_ check: () -> Bool) async throws {
        for _ in 0..<120 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the live session.")
        throw CancellationError()
    }
}

private actor FixtureAnswerStream: AnswerStreaming {
    private(set) var count = 0

    func stream(_ prompt: ProviderPrompt, connection: ProviderConnection,
                emit: @escaping @Sendable (AnswerEvent) async -> Void) async throws {
        count += 1
        if prompt.input.contains("First question") {
            await emit(.text("Initial"))
            try? await Task.sleep(for: .seconds(2))
            await emit(.text(" obsolete"))
        } else {
            await emit(.text("Newest"))
            await emit(.text(" answer"))
        }
        await emit(.finished)
    }
}
