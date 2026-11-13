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
    func testManualAnswerAndStaleAnswerCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let streamer = FixtureAnswerStream()
        let live = LiveSession(vault: Vault(directory: root), credentials: credentials, streamer: streamer)
        let assistant = AssistantProfile(name: "Practice", background: "Built a build cache.", provider: .openAI)
        live.start(assistant: assistant, settings: .init(), options: .init(microphone: false, save: true))
        live.composer = "First question"
        live.askComposer()
        try await waitUntil { live.answer == "Initial" }
        live.composer = "Second question"
        live.askComposer()
        try await waitUntil { live.answer == "Newest answer" && !live.generating }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(live.answer, "Newest answer")
        XCTAssertEqual(live.record?.suggestions.map(\.question), ["First question", "Second question"])
        XCTAssertTrue(live.record?.suggestions.first?.answer.contains("interrupted") == true)
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
    func testLocalCaptureRequiresScreenOptInButNoAPIProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appending(path: "fixture.png")
        let pixel = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJt8AAAAASUVORK5CYII="))
        try pixel.write(to: image)
        let live = LiveSession(vault: Vault(directory: root), credentials: TestCredentials())
        live.start(assistant: .init(name: "Capture"), settings: .init(), options: .init(microphone: false, save: false))
        XCTAssertFalse(live.canCapture)
        live.attachImage(image)
        XCTAssertNotNil(live.captureError)
        live.end()
        try await waitUntil { live.phase == .idle }
        live.start(assistant: .init(name: "Capture"), settings: .init(),
                   options: .init(microphone: false, save: false, screenContext: true))
        XCTAssertTrue(live.canCapture)
        XCTAssertFalse(live.canAnswer)
        live.attachImage(image)
        try await waitUntil { !live.capturing }
        XCTAssertNil(live.captureError)
        XCTAssertNotNil(live.captureImage)
        live.askComposer()
        XCTAssertEqual(live.answerError, ProviderError.providerDisabled.localizedDescription)
        XCTAssertNotNil(live.captureImage)
        live.attachImage(image)
        live.discardImage()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(live.captureImage)
        XCTAssertFalse(live.capturing)
        live.end()
        try await waitUntil { live.phase == .idle }
        XCTAssertEqual(live.completionMessage, "Session ended")
    }

    @MainActor
    func testEndingRetainsStreamingAnswerAndCallsEndedAfterSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let live = LiveSession(vault: Vault(directory: root), credentials: credentials, streamer: FixtureAnswerStream())
        var ended = false
        live.onEnded = {
            XCTAssertEqual(live.phase, .idle)
            ended = true
        }
        live.start(assistant: .init(name: "Saving", provider: .openAI), settings: .init(),
                   options: .init(microphone: false, save: true))
        live.composer = "First question"
        live.askComposer()
        try await waitUntil { live.answer == "Initial" }
        live.end()
        try await waitUntil { ended }
        let saved = try XCTUnwrap(Vault(directory: root).sessions().first)
        XCTAssertEqual(saved.suggestions.count, 1)
        XCTAssertTrue(saved.suggestions[0].answer.hasPrefix("Initial"))
        XCTAssertTrue(saved.suggestions[0].answer.contains("interrupted"))
        XCTAssertEqual(live.completionMessage, "Saved to History")
    }

    @MainActor
    func testCloudSpeechFallsBackLocallyAndPracticeFeedbackPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let live = LiveSession(vault: Vault(directory: root), credentials: credentials, streamer: PracticeAnswerStream())
        live.start(assistant: .init(name: "Practice", provider: .openAI), settings: .init(speechProvider: .openAI),
                   options: .init(microphone: false, save: true, practice: true, practiceStyle: .technical))
        XCTAssertEqual(live.speechProvider, .onDevice)
        XCTAssertFalse(live.automatic)
        try await waitUntil { !live.practiceQuestion.isEmpty && !live.generating }
        live.composer = "I used a bounded retry queue."
        live.askComposer()
        try await waitUntil { live.practiceAttempts.first?.effectiveFeedbackState == .completed && !live.generating }
        XCTAssertEqual(live.practiceAttempts[0].reviewTopic, "Retry policies")
        XCTAssertNil(live.practiceMetrics?.wordsPerMinute)
        live.schedulePracticeReview()
        XCTAssertNotNil(live.practiceAttempts[0].nextReview)
        let priorQuestion = live.practiceQuestion
        live.retryPracticeAnswer()
        XCTAssertEqual(live.practiceQuestion, priorQuestion)
        XCTAssertEqual(live.answer, "")
        XCTAssertEqual(live.practiceAttempts.count, 1)
        live.end()
        try await waitUntil { live.phase == .idle }
        let saved = try XCTUnwrap(Vault(directory: root).sessions().first)
        XCTAssertEqual(saved.practiceStyle, .technical)
        XCTAssertEqual(saved.practiceAttempts?.count, 1)
        XCTAssertNotNil(saved.practiceAttempts?.first?.nextReview)
    }

    func testPracticeDeliveryMetricsUseTimedSpeechOnly() {
        let text = "Um I used retries. I used retries, you know."
        let typed = PracticeMetrics.analyze(text: text)
        XCTAssertEqual(typed.fillerCount, 2)
        XCTAssertTrue(typed.repeatedPhrases.contains("i used retries"))
        XCTAssertNil(typed.wordsPerMinute)
        XCTAssertNil(typed.longPauseCount)
        let start = Date()
        let spoken = PracticeMetrics.analyze(text: text, speech: [
            .init(text: "Um I used retries.", began: start, ended: start.addingTimeInterval(3)),
            .init(text: "I used retries, you know.", began: start.addingTimeInterval(6), ended: start.addingTimeInterval(10))
        ])
        XCTAssertEqual(spoken.longPauseCount, 1)
        XCTAssertEqual(spoken.wordsPerMinute, Double(spoken.wordCount) * 6)
        XCTAssertEqual(spoken.spokenDuration, 10)
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
        if prompt.input.contains("\nREQUEST\nFirst question") {
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

private struct PracticeAnswerStream: AnswerStreaming {
    func stream(_ prompt: ProviderPrompt, connection: ProviderConnection,
                emit: @escaping @Sendable (AnswerEvent) async -> Void) async throws {
        if prompt.instructions.contains("mock interviewer") {
            await emit(.text("How did you handle retries?"))
        } else {
            await emit(.text("Clarity: Your approach is specific.\nPractice topic: Retry policies"))
        }
        await emit(.finished)
    }
}
