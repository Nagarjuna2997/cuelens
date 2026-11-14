import AppKit
import Observation

struct CaptureAttachment: Identifiable {
    let id = UUID()
    let image: CaptureImage
}

/// Capture callbacks enqueue synchronously. The main actor can drain this inbox
/// after `AudioPipeline.stop` as a delivery barrier, independently of task order.
final class AudioEventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [AudioEvent]()

    func append(_ event: AudioEvent) { lock.withLock { events.append(event) } }
    func takeAll() -> [AudioEvent] {
        lock.withLock {
            let pending = events
            events.removeAll(keepingCapacity: true)
            return pending
        }
    }
}

struct AudioIssueState {
    private var capture = [AudioSource: String]()
    private var speech = [AudioSource: String]()

    var messages: [AudioSource: String] {
        capture.merging(speech) { captureMessage, speechMessage in
            captureMessage + "\n" + speechMessage
        }
    }

    mutating func captureFailed(_ source: AudioSource, message: String) { capture[source] = message }
    mutating func speechFailed(_ source: AudioSource, message: String) { speech[source] = message }
    mutating func speechRecovered(_ source: AudioSource) { speech[source] = nil }
    mutating func clear(_ source: AudioSource) {
        capture[source] = nil
        speech[source] = nil
    }
}

@MainActor
@Observable
final class LiveSession {
    enum Phase { case idle, active, paused, ending }
    static let maximumCaptureImages = 6
    static let maximumCaptureBytes = 12_000_000

    private(set) var phase = Phase.idle
    private(set) var record: MeetingSession?
    private(set) var assistant: AssistantProfile?
    private(set) var options = SessionOptions()
    private(set) var settings = Preferences()
    private(set) var partial = [AudioSource: String]()
    private(set) var levels = [AudioSource: Float]()
    private var audioIssues = AudioIssueState()
    var audioErrors: [AudioSource: String] { audioIssues.messages }
    private(set) var starting = Set<AudioSource>()
    private(set) var enabled = Set<AudioSource>()
    private(set) var activeSources = Set<AudioSource>()
    private(set) var clippedSources = Set<AudioSource>()
    private(set) var transcribingSources = Set<AudioSource>()
    private(set) var speechQueuedSources = Set<AudioSource>()
    private(set) var recordingSources = Set<AudioSource>()
    private(set) var currentProvider = ProviderSelection(provider: .disabled, model: "")
    private(set) var question = ""
    private(set) var answer = ""
    private(set) var responseIndex: Int?
    private(set) var answerError: String?
    private(set) var generating = false
    private(set) var timing: AnswerTiming?
    private(set) var usage = TokenUsage()
    private(set) var transcriptionDelay: TimeInterval?
    private(set) var practiceQuestion = ""
    private(set) var practiceMetrics: PracticeMetrics?
    private(set) var practiceHint = ""
    private(set) var pendingSave: MeetingSession?
    private(set) var resourceCondition = ResourceCondition.normal
    private(set) var captureAttachments = [CaptureAttachment]()
    var captureImages: [CaptureImage] { captureAttachments.map(\.image) }
    var captureImage: CaptureImage? { captureAttachments.first?.image }
    private(set) var capturing = false
    private(set) var completionMessage: String?
    var captureError: String?
    var composer = ""
    var length = AnswerLength.short
    var automatic = true
    var onSaved: ((MeetingSession) -> Void)?
    var onStateChanged: (() -> Void)?
    var onEmergency: (() -> Void)?
    var onEnded: (() -> Void)?

    @ObservationIgnored private let vault: Vault
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let streamer: any AnswerStreaming
    @ObservationIgnored private var index: KnowledgeIndex?
    @ObservationIgnored private var indexTask: Task<KnowledgeIndex, Never>?
    @ObservationIgnored private var answerWork: Task<Void, Never>?
    @ObservationIgnored private var answerID: UUID?
    @ObservationIgnored private var audio = [AudioSource: AudioPipeline]()
    @ObservationIgnored private var audioInboxes = [AudioSource: AudioEventInbox]()
    @ObservationIgnored private var startingTasks = [AudioSource: Task<Void, Never>]()
    @ObservationIgnored private var stoppingTasks = [AudioSource: Task<Void, Never>]()
    @ObservationIgnored private var audioIDs = [AudioSource: UUID]()
    @ObservationIgnored private var lastAutomatic: (String, Date)?
    @ObservationIgnored private var questionDate: Date?
    @ObservationIgnored private var lastTask = AnswerTask.suggestion
    @ObservationIgnored private var lastImages = [CaptureImage]()
    @ObservationIgnored private var audioPart = [AudioSource: Int]()
    @ObservationIgnored private var checkpoint: Task<Void, Never>?
    @ObservationIgnored private let capture = WindowCapture()
    @ObservationIgnored private var captureWork: Task<Void, Never>?
    @ObservationIgnored private var captureID: UUID?
    @ObservationIgnored private var practiceSpeech = [PracticeSpeechSegment]()
    @ObservationIgnored private var feedbackAttemptID: UUID?

    init(vault: Vault, credentials: any CredentialStore, streamer: any AnswerStreaming = HTTPAnswerStream()) {
        self.vault = vault
        self.credentials = credentials
        self.streamer = streamer
    }

    var isOpen: Bool { phase != .idle }
    var canAnswer: Bool { isOpen && phase != .ending && currentProvider.provider != .disabled }
    var canCapture: Bool { (phase == .active || phase == .paused) && options.screenContext }
    var speechProvider: SpeechProvider {
        settings.speechProvider == .openAI && !options.allowCloud ? .onDevice : settings.speechProvider
    }
    var responses: [Suggestion] { record?.suggestions ?? [] }
    var practiceAttempts: [PracticeAttempt] { record?.practiceAttempts ?? [] }
    var pinnedResponses: [Suggestion] { responses.filter { $0.pinned == true } }
    var canStepBack: Bool {
        guard !generating, !responses.isEmpty else { return false }
        return (responseIndex ?? responses.count) > 0
    }
    var canStepForward: Bool {
        guard !generating, let responseIndex else { return false }
        return responseIndex < responses.count - 1
    }
    var isPinned: Bool { responseIndex.flatMap { responses.indices.contains($0) ? responses[$0].pinned : nil } == true }

    var audioLive: Bool { !activeSources.isEmpty }
    var backup: AnswerProvider? { settings.backupProvider == currentProvider.provider ? nil : settings.backupProvider }
    var savingAudio: Bool { options.save && options.saveAudio }
    var audioSourceLabel: String {
        if phase == .idle { return "Ready to start" }
        if phase == .paused { return "Paused" }
        if phase == .ending { return "Ending" }
        if !recordingSources.isEmpty { return "Recording audio" }
        if audioLive { return "Listening" }
        if !starting.isEmpty { return "Connecting audio" }
        if !enabled.isEmpty && !audioErrors.isEmpty { return "Audio needs attention" }
        return enabled.isEmpty ? "Sources disabled" : "Audio stopped"
    }

    func start(assistant: AssistantProfile, settings: Preferences, options: SessionOptions) {
        guard phase == .idle, pendingSave == nil else { return }
        self.assistant = assistant
        self.settings = settings
        self.options = options
        completionMessage = nil
        currentProvider = settings.answerSelection(for: assistant)
        let title = options.title.trimmingCharacters(in: .whitespacesAndNewlines)
        record = MeetingSession(title: title.isEmpty ? "\(assistant.name) \(options.practice ? "practice" : "session")" : title,
                                assistantID: assistant.id, assistantName: assistant.name)
        if options.practice { record?.practiceStyle = options.practiceStyle }
        phase = .active
        partial.removeAll()
        audioIssues = AudioIssueState()
        levels.removeAll()
        clippedSources.removeAll()
        transcribingSources.removeAll()
        speechQueuedSources.removeAll()
        recordingSources.removeAll()
        audioPart.removeAll()
        enabled = Set([(AudioSource.microphone, options.microphone), (.meeting, options.meetingAudio)].compactMap { $0.1 ? $0.0 : nil })
        automatic = options.automaticAnswers && !options.practice
        length = assistant.length
        composer = ""
        question = ""
        answer = ""
        responseIndex = nil
        answerError = nil
        captureError = nil
        timing = nil
        usage = TokenUsage()
        transcriptionDelay = nil
        practiceQuestion = ""
        practiceMetrics = nil
        practiceHint = ""
        practiceSpeech.removeAll()
        feedbackAttemptID = nil
        lastAutomatic = nil
        lastImages.removeAll()
        captureAttachments.removeAll()
        questionDate = nil
        lastTask = .suggestion
        index = nil
        indexTask = Task.detached(priority: .userInitiated) { KnowledgeIndex(assistant: assistant) }
        for source in enabled { startSource(source) }
        scheduleCheckpoint()
        onStateChanged?()
        if options.practice && canAnswer { nextPracticeQuestion(reviewing: options.reviewTopic) }
    }

    func pause() {
        guard phase == .active else { return }
        phase = .paused
        for source in enabled { stopSource(source, retainPartial: true) }
        scheduleCheckpoint()
        onStateChanged?()
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .active
        for source in enabled { startSource(source) }
        onStateChanged?()
    }

    func toggle(_ source: AudioSource) {
        guard isOpen, phase != .ending, source == .microphone || source == .meeting else { return }
        if enabled.contains(source) {
            enabled.remove(source)
            stopSource(source, retainPartial: true)
        } else {
            enabled.insert(source)
            if phase == .active { startSource(source) }
        }
    }

    func retry(_ source: AudioSource) {
        guard enabled.contains(source), phase == .active else { return }
        stopSource(source, retainPartial: true)
        startSource(source)
    }

    func end() {
        guard isOpen, phase != .ending else { return }
        phase = .ending
        preservePartialAnswer(reason: "Response interrupted when the session ended.")
        completionMessage = options.save ? "Saving session…" : "Session ended"
        cancelAnswer()
        indexTask?.cancel()
        indexTask = nil
        index = nil
        discardImage()
        lastImages.removeAll()
        // Stop capture immediately, then give already captured speech a bounded
        // opportunity to finish before saving the session.
        for source in enabled { stopSource(source, retainPartial: true, finalizeSpeech: true) }
        enabled.removeAll()
        checkpoint?.cancel()
        checkpoint = nil
        let stops = Array(stoppingTasks.values)
        Task {
            for task in stops { await task.value }
            if var finished = record, options.save {
                finished.endedAt = Date()
                finished.audioFiles = existingAudioFiles(finished.id)
                pendingSave = finished
                retrySave()
            }
            record = nil
            stoppingTasks.removeAll()
            phase = .idle
            onEnded?()
            onStateChanged?()
        }
    }

    func retrySave() {
        guard let finished = pendingSave else { return }
        do {
            try vault.save(finished)
            pendingSave = nil
            completionMessage = "Saved to History"
            onSaved?(finished)
        } catch {
            completionMessage = "Save needs attention"
            answerError = "CueLens couldn’t finish saving. Free up disk space and retry."
        }
    }

    func setResources(_ condition: ResourceCondition) {
        resourceCondition = condition
        if condition == .critical && generating {
            cancelAnswer()
            answerError = "CueLens paused generation to reduce resource use."
        }
    }

    func emergencyStop() {
        pause()
        cancelAnswer()
        discardImage()
        lastImages.removeAll()
        onEmergency?()
    }

    func askComposer() {
        guard !capturing else { captureError = "Finishing capture. Press Answer when the preview appears."; return }
        guard canAnswer else { answerError = ProviderError.providerDisabled.localizedDescription; return }
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        if captureImage != nil {
            sendCapture(question: text)
            return
        }
        guard !text.isEmpty else { answerLatest(); return }
        if options.practice, !practiceQuestion.isEmpty {
            if submitPracticeAnswer(text) { composer = "" }
        } else {
            if generate(text, task: .suggestion) { composer = "" }
        }
    }

    func addNote(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let started = record?.startedAt, phase != .ending else { return }
        append(TranscriptLine(time: Date().timeIntervalSince(started), source: .manual, text: String(clean.prefix(4_000))))
    }

    func answerLatest(task: AnswerTask = .suggestion) {
        guard canAnswer else { answerError = ProviderError.providerDisabled.localizedDescription; return }
        let recent = record?.transcript.suffix(16).reversed() ?? [].reversed()
        let questionSource: AudioSource = enabled.contains(.meeting) ? .meeting : .microphone
        if let partial = partial[.meeting] ?? partial[questionSource], !partial.isEmpty {
            let text = QuestionDetection.question(in: partial, source: .meeting, locale: settings.speechLocale) ?? partial
            lastAutomatic = (QuestionDetection.normalized(text), Date())
            generate(text, task: task)
        } else if let entry = recent.first(where: {
            QuestionDetection.question(in: $0.text, source: $0.source, locale: settings.speechLocale) != nil
        }) ?? recent.first(where: { $0.source == .meeting || $0.source == questionSource || $0.source == .manual }) {
            let text = QuestionDetection.question(in: entry.text, source: .meeting, locale: settings.speechLocale) ?? entry.text
            generate(text, task: task)
        } else if !question.isEmpty {
            if task == .suggestion { regenerate() }
            else { generate(question, task: task) }
        } else {
            answerError = "Type a question, capture an image, or wait for the live transcript."
        }
    }

    func answerWith(_ task: AnswerTask) {
        let typed = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { answerLatest(task: task) }
        else {
            if generate(typed, task: task) { composer = "" }
        }
    }

    func stepResponse(_ offset: Int) {
        showResponse(at: (responseIndex ?? responses.count) + offset)
    }

    func showResponse(_ id: UUID) {
        guard let index = responses.firstIndex(where: { $0.id == id }) else { return }
        showResponse(at: index)
    }

    func togglePin() {
        guard let index = responseIndex, responses.indices.contains(index), !generating else { return }
        let pinned = !isPinned
        record?.suggestions[index].pinned = pinned
        scheduleCheckpoint()
    }

    private func showResponse(at index: Int) {
        guard !generating, responses.indices.contains(index) else { return }
        let suggestion = responses[index]
        responseIndex = index
        question = suggestion.question
        answer = suggestion.answer
        answerError = nil
        timing = nil
        usage = TokenUsage()
        lastTask = .suggestion
        lastImages.removeAll()
        questionDate = nil
    }

    func answer(_ line: TranscriptLine) { generate(line.text, task: .suggestion) }

    func regenerate() {
        guard !question.isEmpty else { return }
        guard lastTask != .capture || !lastImages.isEmpty else {
            captureError = "The previous images were cleared. Attach images before requesting another image answer."
            return
        }
        generate(question, task: lastTask, ended: questionDate, images: lastImages,
                 retryingPracticeAttempt: lastTask == .practiceFeedback ? feedbackAttemptID : nil)
    }

    func technicalAnswer() {
        guard !question.isEmpty else { return }
        generate(question, task: lastImages.isEmpty ? .technical : .capture, images: lastImages)
    }

    func nextPracticeQuestion(reviewing topic: String? = nil) {
        guard options.practice else { return }
        let previous = practiceAttempts.last
        let review = topic ?? previous?.reviewTopic ?? ""
        generate("""
                 Ask one \(options.practiceStyle.rawValue.lowercased()) interview question for this role.
                 \(practiceAttempts.isEmpty ? "Start a baseline interview." : "Adapt a follow-up to the prior answer and feedback.")
                 Review topic: \(review.prefix(180))
                 Previous question: \(practiceQuestion.prefix(350))
                 Previous answer: \(previous?.response.prefix(500) ?? "")
                 Previous feedback: \(previous?.feedback.prefix(700) ?? "")
                 Feedback status: \(previous?.feedbackStatus ?? "No prior feedback")
                 """,
                 task: .practiceQuestion)
    }

    func requestPracticeHint() {
        guard options.practice, options.practiceHints, !practiceQuestion.isEmpty else { return }
        generate(practiceQuestion, task: .practiceHint)
    }

    func retryPracticeAnswer() {
        guard options.practice, !practiceQuestion.isEmpty, let started = record?.startedAt,
              phase == .active || phase == .paused else { return }
        cancelAnswer()
        answer = ""
        answerError = nil
        composer = ""
        responseIndex = nil
        practiceMetrics = nil
        practiceHint = ""
        practiceSpeech.removeAll()
        feedbackAttemptID = nil
        question = ""
        append(.init(time: Date().timeIntervalSince(started), source: .practice, text: practiceQuestion))
    }

    func schedulePracticeReview() {
        guard let count = record?.practiceAttempts?.count, count > 0 else { return }
        record?.practiceAttempts?[count - 1].nextReview = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        scheduleCheckpoint()
    }

    func reviewSpokenPracticeAnswer() {
        guard options.practice, !practiceQuestion.isEmpty else { return }
        let lines = record?.transcript ?? []
        let current = lines.lastIndex(where: { $0.source == .practice }).map { lines.suffix(from: $0 + 1) } ?? lines[...]
        var spoken = current.filter { $0.source == .microphone }.map(\.text).joined(separator: " ")
        if let partial = partial[.microphone], !partial.isEmpty { spoken += " " + partial }
        if spoken.isEmpty { answerError = "Speak an answer or type it below." }
        else { submitPracticeAnswer(spoken, typed: false) }
    }

    @discardableResult
    private func submitPracticeAnswer(_ text: String, typed: Bool = true) -> Bool {
        let speech = !typed && partial[.microphone] == nil ? practiceSpeech : []
        let metrics = PracticeMetrics.analyze(text: text, speech: speech)
        let attempt = PracticeAttempt(question: practiceQuestion, response: String(text.prefix(8_000)), metrics: metrics)
        let excerpt = text.count > 1_250 ? " (excerpt; the remaining answer is omitted)" : ""
        let accepted = generate("Interview question: \(practiceQuestion.prefix(550))\nCandidate’s answer\(excerpt): \(text.prefix(1_250))",
                                task: .practiceFeedback, practiceAttempt: attempt)
        if accepted { practiceMetrics = metrics }
        if accepted && typed { addNote(text) }
        return accepted
    }

    func useBackup() {
        guard let backup else { return }
        let selection = ProviderSelection(provider: backup, model: settings.model(for: backup))
        do { _ = try ProviderConnection(selection: selection, credentials: credentials) }
        catch { answerError = error.localizedDescription; return }
        cancelAnswer()
        currentProvider = selection
        regenerate()
    }

    func pickWindow() {
        guard requireScreenContext() else { return }
        let id = beginCapture()
        capture.chooseWindow { [weak self] result in
            self?.finishCapture(result.map { image in image.map { [$0] } ?? [] }, id: id)
        }
    }

    func captureScreen() {
        guard requireScreenContext() else { return }
        let id = beginCapture()
        captureWork = Task { [weak self] in
            guard let self else { return }
            do { finishCapture(.success([try await capture.captureDisplay()]), id: id) }
            catch { if !Task.isCancelled { finishCapture(.failure(error), id: id) } }
        }
    }

    func attachImage(_ url: URL) {
        attachImages([url])
    }

    func attachImages(_ urls: [URL]) {
        guard requireScreenContext() else { return }
        guard !urls.isEmpty else { return }
        guard captureAttachments.count + urls.count <= Self.maximumCaptureImages else {
            captureError = "Attach up to \(Self.maximumCaptureImages) images per answer. Remove an image before adding more."
            return
        }
        let id = beginCapture()
        captureWork = Task { [weak self] in
            let reading = Task.detached(priority: .userInitiated) {
                try urls.map { url in
                    try Task.checkCancellation()
                    return try CaptureImage.read(url)
                }
            }
            do {
                let images = try await withTaskCancellationHandler {
                    try await reading.value
                } onCancel: {
                    reading.cancel()
                }
                try Task.checkCancellation()
                self?.finishCapture(.success(images), id: id)
            } catch {
                if !Task.isCancelled { self?.finishCapture(.failure(error), id: id) }
            }
        }
    }

    func setScreenContext(_ enabled: Bool) {
        guard phase == .active || phase == .paused else { return }
        options.screenContext = enabled
        if !enabled {
            discardImage()
            lastImages.removeAll()
            if generating, lastTask == .capture { cancelAnswer() }
        }
    }

    private func requireScreenContext() -> Bool {
        guard phase == .active || phase == .paused else { return false }
        guard options.screenContext else {
            captureError = "Enable screen context in Session Setup before using Capture."
            return false
        }
        return true
    }

    private func beginCapture() -> UUID {
        cancelCapture()
        let id = UUID()
        captureID = id
        capturing = true
        captureError = nil
        return id
    }

    private func finishCapture(_ result: Result<[CaptureImage], Error>, id: UUID) {
        guard captureID == id, canCapture else { return }
        capturing = false
        captureWork = nil
        captureID = nil
        switch result {
        case .success(let images):
            if let error = Self.captureLimitError(for: captureImages + images) {
                captureError = error
            } else {
                captureAttachments.append(contentsOf: images.map(CaptureAttachment.init(image:)))
            }
        case .failure(let error): captureError = error.localizedDescription
        }
    }

    static func captureLimitError(for images: [CaptureImage]) -> String? {
        if images.count > maximumCaptureImages {
            return "Attach up to \(maximumCaptureImages) images per answer. Remove an image before adding more."
        }
        if images.reduce(0, { $0 + $1.data.count }) > maximumCaptureBytes {
            return "These images exceed the 12 MB attachment limit. Remove an image or choose smaller images."
        }
        return nil
    }

    private func cancelCapture() {
        captureID = nil
        captureWork?.cancel()
        captureWork = nil
        capture.cancel()
        capturing = false
    }

    func removeCaptureImage(_ id: UUID) {
        captureAttachments.removeAll { $0.id == id }
        captureError = nil
    }

    func discardImage() {
        cancelCapture()
        captureAttachments.removeAll()
        captureError = nil
    }

    func sendCapture(question: String) {
        guard !capturing else { captureError = "Finishing capture. Press Answer when the previews appear."; return }
        guard !captureAttachments.isEmpty else { return }
        if generate(question.isEmpty ? "Help me understand and solve the coding problem across these images. Read them in attachment order." : question,
                    task: .capture, images: captureImages) {
            captureAttachments.removeAll()
            composer = ""
        }
    }

    func cancelAnswer() {
        if generating, lastTask == .practiceFeedback {
            updatePracticeFeedback(.interrupted, error: "Feedback stopped before completion.", persist: true)
        }
        preservePartialAnswer(reason: "Response interrupted before completion.")
        answerID = nil
        answerWork?.cancel()
        answerWork = nil
        generating = false
    }

    private func preservePartialAnswer(reason: String) {
        guard responseIndex == nil, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record != nil else { return }
        let retained = answer + "\n\n(" + reason + ")"
        record?.suggestions.append(.init(question: question, answer: retained, provider: currentProvider.provider))
        responseIndex = (record?.suggestions.count ?? 1) - 1
        scheduleCheckpoint()
    }

    @discardableResult
    private func generate(_ text: String, task: AnswerTask, ended: Date? = nil, images: [CaptureImage] = [],
                          practiceAttempt: PracticeAttempt? = nil, retryingPracticeAttempt: UUID? = nil) -> Bool {
        guard phase == .active || phase == .paused, let assistant else { return false }
        let connection: ProviderConnection
        do { connection = try ProviderConnection(selection: currentProvider, credentials: credentials) }
        catch { answerError = error.localizedDescription; return false }
        cancelAnswer()
        question = String(text.prefix(2_000))
        responseIndex = nil
        questionDate = ended
        lastTask = task
        lastImages = images
        answer = ""
        answerError = nil
        feedbackAttemptID = practiceAttempt?.id ?? retryingPracticeAttempt
        if let practiceAttempt {
            if record?.practiceAttempts == nil { record?.practiceAttempts = [] }
            record?.practiceAttempts?.append(practiceAttempt)
        }
        if feedbackAttemptID != nil {
            updatePracticeFeedback(.pending, persist: true)
        }

        let id = UUID()
        answerID = id
        generating = true
        timing = AnswerTiming(questionEnded: ended, requestStarted: Date())
        usage = TokenUsage()
        let text = question
        let preset = resourceCondition.reducesWork ? ResourcePreset.low : settings.resourcePreset
        let history = record?.transcript.suffix(preset.recentTurns).map { $0 } ?? []
        let recentSuggestions = record?.suggestions.suffix(3).map { $0 } ?? []
        let length = length
        let index = index
        let indexTask = indexTask
        let streamer = streamer
        answerWork = Task { [weak self] in
            do {
                let available: KnowledgeIndex
                if let index { available = index }
                else if let indexTask { available = await indexTask.value }
                else { return }
                try Task.checkCancellation()
                guard self?.answerID == id else { return }
                self?.index = available
                self?.indexTask = nil
                var prompt = AnswerPrompts.make(task: task, question: text, assistant: assistant, index: available,
                                                recent: history, length: length, preset: preset,
                                                recentSuggestions: recentSuggestions)
                prompt.images = images
                self?.record?.sentTextToCloud = true
                self?.scheduleCheckpoint()
                try await streamer.stream(prompt, connection: connection) { [weak self] event in
                    await self?.receiveAnswer(event, id: id)
                }
                guard let self, answerID == id else { return }
                timing?.completed = Date()
                if task == .practiceQuestion {
                    practiceQuestion = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    practiceHint = ""
                    practiceMetrics = nil
                    practiceSpeech.removeAll()
                    if let started = record?.startedAt {
                        append(.init(time: Date().timeIntervalSince(started), source: .practice, text: practiceQuestion))
                    }
                }
                if task == .practiceHint { practiceHint = answer }
                if task == .practiceFeedback {
                    updatePracticeFeedback(.completed, persist: true)
                }
                record?.suggestions.append(.init(question: text, answer: answer, provider: connection.selection.provider))
                responseIndex = (record?.suggestions.count ?? 1) - 1
                scheduleCheckpoint()
                generating = false
                answerWork = nil
            } catch {
                guard let self, answerID == id else { return }
                answerError = error.localizedDescription
                if task == .practiceFeedback {
                    updatePracticeFeedback(.failed, error: error.localizedDescription, persist: true)
                }
                generating = false
                answerWork = nil
            }
        }
        return true
    }

    private func receiveAnswer(_ event: AnswerEvent, id: UUID) {
        guard answerID == id else { return }
        switch event {
        case .text(let token):
            if timing?.firstToken == nil, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                timing?.firstToken = Date()
            }
            if answer.count < 25_000 { answer += token.prefix(25_000 - answer.count) }
            if lastTask == .practiceFeedback { updatePracticeFeedback(.partial) }
        case .usage(let tokens): usage.merge(tokens)
        case .finished: break
        }
    }

    private func updatePracticeFeedback(_ state: PracticeFeedbackState, error: String? = nil, persist: Bool = false) {
        guard let feedbackAttemptID,
              let position = record?.practiceAttempts?.firstIndex(where: { $0.id == feedbackAttemptID }) else { return }
        record?.practiceAttempts?[position].feedback = answer
        record?.practiceAttempts?[position].feedbackState = state
        record?.practiceAttempts?[position].feedbackError = error
        if state == .completed {
            record?.practiceAttempts?[position].reviewTopic = PracticeAttempt.topic(in: answer)
        }
        if persist, options.save, phase != .ending, var snapshot = record {
            snapshot.audioFiles = existingAudioFiles(snapshot.id)
            do { try vault.save(snapshot) }
            catch { answerError = "CueLens couldn’t save this practice attempt yet. It will retry when the session ends." }
        }
        scheduleCheckpoint()
    }

    private func startSource(_ source: AudioSource) {
        guard phase == .active, !starting.contains(source), !activeSources.contains(source), let record else { return }
        let apiKey: String?
        let speechProvider = speechProvider
        if speechProvider == .openAI {
            let key = try? credentials.read(.openAI)
            apiKey = key?.isEmpty == false ? key : nil
        } else {
            apiKey = nil
        }
        let id = UUID()
        audioIDs[source] = id
        let inbox = AudioEventInbox()
        audioInboxes[source] = inbox
        let input = AudioPipeline(source: source) { [weak self] event in
            inbox.append(event)
            Task { @MainActor in self?.receiveBufferedAudio(inbox, id: id) }
        }
        audio[source] = input
        audioIssues.clear(source)
        starting.insert(source)
        let priorStop = stoppingTasks[source]
        let settings = settings
        let url = savingAudio ? newRecordingURL(source: source, session: record.id) : nil
        startingTasks[source] = Task { [weak self] in
            await priorStop?.value
            do {
                try Task.checkCancellation()
                try await input.start(microphoneID: settings.microphoneID, speechProvider: speechProvider,
                                      locale: settings.speechLocale, apiKey: apiKey, recordingURL: url)
                guard let self, audioIDs[source] == id else { await input.stop(); return }
                guard phase == .active else {
                    // End owns graceful shutdown while its source ID is retained.
                    if phase != .ending { await input.stop() }
                    return
                }
                starting.remove(source)
                activeSources.insert(source)
                startingTasks[source] = nil
            } catch {
                guard let self, audioIDs[source] == id else { return }
                guard phase != .ending else { return }
                audioIssues.captureFailed(source, message: error.localizedDescription)
                stopSource(source, retainPartial: true)
            }
        }
    }

    private func stopSource(_ source: AudioSource, retainPartial: Bool, finalizeSpeech: Bool = false) {
        let id = audioIDs[source]
        let inbox = audioInboxes.removeValue(forKey: source)
        if let inbox, let id { receiveBufferedAudio(inbox, id: id) }
        if !finalizeSpeech { audioIDs[source] = nil }
        let startup = startingTasks.removeValue(forKey: source)
        if !finalizeSpeech { startup?.cancel() }
        starting.remove(source)
        activeSources.remove(source)
        levels[source] = 0
        clippedSources.remove(source)
        if !finalizeSpeech {
            transcribingSources.remove(source)
            speechQueuedSources.remove(source)
        }
        recordingSources.remove(source)
        if !finalizeSpeech { retainStoppedPartial(source, retain: retainPartial) }
        if let input = audio.removeValue(forKey: source) {
            let prior = stoppingTasks[source]
            stoppingTasks[source] = Task {
                await prior?.value
                await input.stop(finalizeSpeech: finalizeSpeech)
                if let inbox, let id { receiveBufferedAudio(inbox, id: id) }
                if finalizeSpeech, audioIDs[source] == id {
                    audioIDs[source] = nil
                    transcribingSources.remove(source)
                    speechQueuedSources.remove(source)
                    levels[source] = 0
                    retainStoppedPartial(source, retain: retainPartial)
                }
            }
        } else if finalizeSpeech {
            audioIDs[source] = nil
            transcribingSources.remove(source)
            speechQueuedSources.remove(source)
            retainStoppedPartial(source, retain: retainPartial)
        }
    }

    private func receiveBufferedAudio(_ inbox: AudioEventInbox, id: UUID) {
        for event in inbox.takeAll() { receiveAudio(event, id: id) }
    }

    private func retainStoppedPartial(_ source: AudioSource, retain: Bool) {
        if let text = partial.removeValue(forKey: source), retain, !text.isEmpty, let started = record?.startedAt {
            append(.init(time: Date().timeIntervalSince(started), source: source, text: text, provisional: true))
        }
    }

    private func receiveAudio(_ event: AudioEvent, id: UUID) {
        switch event {
        case .transcription(let source, let active):
            guard audioIDs[source] == id else { return }
            if active { transcribingSources.insert(source) }
            else { transcribingSources.remove(source) }
        case .speechFailure(let source, let message):
            guard audioIDs[source] == id else { return }
            audioIssues.speechFailed(source, message: message)
        case .speechRecovered(let source):
            guard audioIDs[source] == id else { return }
            audioIssues.speechRecovered(source)
        case .speechQueued(let source, let queued):
            guard audioIDs[source] == id else { return }
            if queued { speechQueuedSources.insert(source) }
            else { speechQueuedSources.remove(source) }
        case .transcriptionIncomplete(let source):
            guard audioIDs[source] == id else { return }
            markTranscriptionIncomplete(source)
        case .recording(let source, let active):
            guard audioIDs[source] == id else { return }
            if active { recordingSources.insert(source) }
            else { recordingSources.remove(source) }
        case .clipping(let source, let clipped):
            guard audioIDs[source] == id else { return }
            if clipped { clippedSources.insert(source) }
            else { clippedSources.remove(source) }
        case .level(let source, let level):
            if audioIDs[source] == id { levels[source] = level }
        case .partial(let source, let text):
            if audioIDs[source] == id { partial[source] = String(text.prefix(6_000)) }
        case .failure(let source, let message, let recoverable):
            guard audioIDs[source] == id else { return }
            audioIssues.captureFailed(source, message: message)
            if recoverable, phase != .ending { stopSource(source, retainPartial: true) }
        case .cloudAudio(let source):
            guard audioIDs[source] == id else { return }
            record?.sentAudioToCloud = true
            scheduleCheckpoint()
        case .final(let source, let text, let began, let ended):
            guard audioIDs[source] == id else { return }
            finalizeTranscript(text, source: source, began: began, ended: ended)
        }
    }

    func markTranscriptionIncomplete(_ source: AudioSource) {
        guard isOpen, source == .microphone || source == .meeting else { return }
        var sources = record?.transcriptionIncompleteSources ?? []
        guard !sources.contains(source) else { return }
        sources.append(source)
        // Read the old value before opening the optional record's modify access.
        // Reading record again on the RHS traps under Swift exclusivity checks.
        record?.transcriptionIncompleteSources = sources
        scheduleCheckpoint()
    }

    func finalizeTranscript(_ text: String, source: AudioSource, began: Date, ended: Date) {
        guard isOpen, let started = record?.startedAt else { return }
        partial[source] = nil
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        transcriptionDelay = max(0, Date().timeIntervalSince(ended))
        if options.practice && source == .microphone {
            practiceSpeech.append(.init(text: clean, began: began, ended: ended))
        }
        append(.init(time: max(0, began.timeIntervalSince(started)), source: source, text: String(clean.prefix(6_000))))
        guard !options.practice, automatic, !generating, !capturing, captureImage == nil,
              composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !resourceCondition.reducesWork, canAnswer, phase == .active,
              let detected = QuestionDetection.question(in: clean, source: source, locale: settings.speechLocale) else { return }
        let key = QuestionDetection.normalized(detected)
        if let (last, when) = lastAutomatic, last == key, Date().timeIntervalSince(when) < 25 { return }
        lastAutomatic = (key, Date())
        generate(detected, task: .suggestion, ended: ended)
    }

    private func append(_ line: TranscriptLine) {
        record?.transcript.append(line)
        if let lines = record?.transcript, lines.count > 1, lines[lines.count - 2].time > line.time {
            record?.transcript.sort { $0.time < $1.time }
        }
        scheduleCheckpoint()
    }

    private func scheduleCheckpoint() {
        guard options.save, phase != .ending, checkpoint == nil else { return }
        checkpoint = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            checkpoint = nil
            if var snapshot = record {
                snapshot.audioFiles = existingAudioFiles(snapshot.id)
                do { try vault.save(snapshot) }
                catch { answerError = "CueLens couldn’t checkpoint this session. It will retry when the session ends." }
            }
        }
    }

    private func newRecordingURL(source: AudioSource, session: UUID) -> URL? {
        let directory = vault.audioDirectory(session)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch {
            audioIssues.captureFailed(source, message: AudioFailure.audioStorage.localizedDescription)
            return nil
        }
        audioPart[source, default: 0] += 1
        let name = source == .microphone ? "microphone" : "meeting"
        return directory.appending(path: "\(name)-\(audioPart[source, default: 1]).caf")
    }

    private func existingAudioFiles(_ id: UUID) -> [String]? {
        guard let paths = try? FileManager.default.contentsOfDirectory(atPath: vault.audioDirectory(id).path),
              !paths.isEmpty else { return nil }
        return paths.sorted()
    }
}
