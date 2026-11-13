import AppKit
import Observation

@MainActor
@Observable
final class LiveSession {
    enum Phase { case idle, active, paused, ending }

    private(set) var phase = Phase.idle
    private(set) var record: MeetingSession?
    private(set) var assistant: AssistantProfile?
    private(set) var options = SessionOptions()
    private(set) var settings = Preferences()
    private(set) var partial = [AudioSource: String]()
    private(set) var levels = [AudioSource: Float]()
    private(set) var audioErrors = [AudioSource: String]()
    private(set) var starting = Set<AudioSource>()
    private(set) var enabled = Set<AudioSource>()
    private(set) var activeSources = Set<AudioSource>()
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
    private(set) var pendingSave: MeetingSession?
    private(set) var resourceCondition = ResourceCondition.normal
    private(set) var captureImage: CaptureImage?
    var captureError: String?
    var composer = ""
    var length = AnswerLength.short
    var automatic = true
    var onSaved: ((MeetingSession) -> Void)?
    var onStateChanged: (() -> Void)?
    var onEmergency: (() -> Void)?

    @ObservationIgnored private let vault: Vault
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let streamer: any AnswerStreaming
    @ObservationIgnored private var index: KnowledgeIndex?
    @ObservationIgnored private var indexTask: Task<KnowledgeIndex, Never>?
    @ObservationIgnored private var answerWork: Task<Void, Never>?
    @ObservationIgnored private var answerID: UUID?
    @ObservationIgnored private var audio = [AudioSource: AudioPipeline]()
    @ObservationIgnored private var startingTasks = [AudioSource: Task<Void, Never>]()
    @ObservationIgnored private var stoppingTasks = [AudioSource: Task<Void, Never>]()
    @ObservationIgnored private var audioIDs = [AudioSource: UUID]()
    @ObservationIgnored private var lastAutomatic: (String, Date)?
    @ObservationIgnored private var questionDate: Date?
    @ObservationIgnored private var lastTask = AnswerTask.suggestion
    @ObservationIgnored private var lastImage: CaptureImage?
    @ObservationIgnored private var audioPart = [AudioSource: Int]()
    @ObservationIgnored private var checkpoint: Task<Void, Never>?
    @ObservationIgnored private let capture = WindowCapture()

    init(vault: Vault, credentials: any CredentialStore, streamer: any AnswerStreaming = HTTPAnswerStream()) {
        self.vault = vault
        self.credentials = credentials
        self.streamer = streamer
    }

    var isOpen: Bool { phase != .idle }
    var canAnswer: Bool { isOpen && phase != .ending && currentProvider.provider != .disabled }
    var responses: [Suggestion] { record?.suggestions ?? [] }
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
        if phase == .paused { return "Paused" }
        if phase == .ending { return "Ending" }
        if audioLive { return savingAudio ? "Recording audio" : "Listening" }
        if !starting.isEmpty { return "Connecting audio" }
        return "Audio off"
    }

    func start(assistant: AssistantProfile, settings: Preferences, options: SessionOptions) {
        guard phase == .idle, pendingSave == nil else { return }
        self.assistant = assistant
        self.settings = settings
        self.options = options
        currentProvider = settings.answerSelection(for: assistant)
        let title = options.title.trimmingCharacters(in: .whitespacesAndNewlines)
        record = MeetingSession(title: title.isEmpty ? "\(assistant.name) \(options.practice ? "practice" : "session")" : title,
                                assistantID: assistant.id, assistantName: assistant.name)
        phase = .active
        partial.removeAll()
        audioErrors.removeAll()
        levels.removeAll()
        audioPart.removeAll()
        enabled = Set([(AudioSource.microphone, options.microphone), (.meeting, options.meetingAudio)].compactMap { $0.1 ? $0.0 : nil })
        automatic = assistant.liveSuggestions && !options.practice
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
        lastAutomatic = nil
        lastImage = nil
        captureImage = nil
        questionDate = nil
        lastTask = .suggestion
        index = nil
        indexTask = Task.detached(priority: .userInitiated) { KnowledgeIndex(assistant: assistant) }
        for source in enabled { startSource(source) }
        scheduleCheckpoint()
        onStateChanged?()
        if options.practice && canAnswer { nextPracticeQuestion() }
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
        cancelAnswer()
        indexTask?.cancel()
        indexTask = nil
        index = nil
        capture.cancel()
        discardImage()
        lastImage = nil
        for source in enabled { stopSource(source, retainPartial: true) }
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
            phase = .idle
            onStateChanged?()
        }
    }

    func retrySave() {
        guard let finished = pendingSave else { return }
        do {
            try vault.save(finished)
            pendingSave = nil
            onSaved?(finished)
        } catch {
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
        capture.cancel()
        discardImage()
        lastImage = nil
        onEmergency?()
    }

    func askComposer() {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        if captureImage != nil {
            sendCapture(question: text)
            return
        }
        guard !text.isEmpty else { answerLatest(); return }
        composer = ""
        if options.practice, !practiceQuestion.isEmpty {
            submitPracticeAnswer(text)
        } else {
            generate(text, task: .suggestion)
        }
    }

    func addNote(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let started = record?.startedAt, phase != .ending else { return }
        append(TranscriptLine(time: Date().timeIntervalSince(started), source: .manual, text: String(clean.prefix(4_000))))
    }

    func answerLatest(task: AnswerTask = .suggestion) {
        guard canAnswer else { return }
        let recent = record?.transcript.suffix(16).reversed() ?? [].reversed()
        if let partial = partial[.meeting], !partial.isEmpty {
            let text = QuestionDetection.question(in: partial, source: .meeting, locale: settings.speechLocale) ?? partial
            lastAutomatic = (QuestionDetection.normalized(text), Date())
            generate(text, task: task)
        } else if let entry = recent.first(where: {
            QuestionDetection.question(in: $0.text, source: $0.source, locale: settings.speechLocale) != nil
        }) ?? recent.first(where: { $0.source == .meeting }) {
            let text = QuestionDetection.question(in: entry.text, source: .meeting, locale: settings.speechLocale) ?? entry.text
            generate(text, task: task)
        } else if !question.isEmpty {
            if task == .suggestion { regenerate() }
            else { generate(question, task: task) }
        } else {
            answerError = "Type a question or wait for meeting audio."
        }
    }

    func answerWith(_ task: AnswerTask) {
        let typed = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { answerLatest(task: task) }
        else {
            composer = ""
            generate(typed, task: task)
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
        record?.suggestions[index].pinned = !isPinned
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
        lastImage = nil
        questionDate = nil
    }

    func answer(_ line: TranscriptLine) { generate(line.text, task: .suggestion) }

    func regenerate() {
        guard !question.isEmpty else { return }
        generate(question, task: lastTask, ended: questionDate, image: lastImage)
    }

    func technicalAnswer() {
        guard !question.isEmpty else { return }
        generate(question, task: lastImage == nil ? .technical : .capture, image: lastImage)
    }

    func nextPracticeQuestion() {
        generate("Ask the next interview question for this role. Previous question: \(practiceQuestion.prefix(500))",
                 task: .practiceQuestion)
    }

    func reviewSpokenPracticeAnswer() {
        let lines = record?.transcript ?? []
        let current = lines.lastIndex(where: { $0.source == .practice }).map { lines.suffix(from: $0 + 1) } ?? lines[...]
        let spoken = current.filter { $0.source == .microphone }.map(\.text).joined(separator: " ")
        if spoken.isEmpty { answerError = "Speak an answer or type it below." }
        else { submitPracticeAnswer(spoken, typed: false) }
    }

    private func submitPracticeAnswer(_ text: String, typed: Bool = true) {
        if typed { addNote(text) }
        generate("Interview question: \(practiceQuestion.prefix(600))\nCandidate’s answer: \(text.prefix(1_350))",
                 task: .practiceFeedback)
    }

    func useBackup() {
        guard let backup else { return }
        currentProvider = .init(provider: backup, model: settings.model(for: backup))
        regenerate()
    }

    func pickWindow() {
        guard canAnswer, options.allowCloud else { captureError = ProviderError.cloudApprovalRequired.localizedDescription; return }
        captureError = nil
        let sessionID = record?.id
        capture.chooseWindow { [weak self] result in
            guard let self, record?.id == sessionID, phase != .ending else { return }
            switch result {
            case .success(let image): if let image { captureImage = image }
            case .failure(let error): captureError = error.localizedDescription
            }
        }
    }

    func attachImage(_ url: URL) {
        guard canAnswer, options.allowCloud else { captureError = ProviderError.cloudApprovalRequired.localizedDescription; return }
        let sessionID = record?.id
        captureError = nil
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) { try CaptureImage.read(url) }.value
                if record?.id == sessionID && phase != .ending { captureImage = image }
            } catch {
                if record?.id == sessionID { captureError = error.localizedDescription }
            }
        }
    }

    func discardImage() { captureImage = nil }

    func sendCapture(question: String) {
        guard let captureImage else { return }
        guard options.allowCloud else { captureError = ProviderError.cloudApprovalRequired.localizedDescription; return }
        self.captureImage = nil
        composer = ""
        generate(question.isEmpty ? "Help me understand and solve the coding problem in this image." : question,
                 task: .capture, image: captureImage)
    }

    func cancelAnswer() {
        answerID = nil
        answerWork?.cancel()
        answerWork = nil
        generating = false
    }

    private func generate(_ text: String, task: AnswerTask, ended: Date? = nil, image: CaptureImage? = nil) {
        guard phase == .active || phase == .paused, let assistant else { return }
        cancelAnswer()
        question = String(text.prefix(2_000))
        responseIndex = nil
        questionDate = ended
        lastTask = task
        lastImage = image
        answer = ""
        answerError = nil
        guard options.allowCloud else { answerError = ProviderError.cloudApprovalRequired.localizedDescription; return }
        let connection: ProviderConnection
        do { connection = try ProviderConnection(selection: currentProvider, credentials: credentials) }
        catch { answerError = error.localizedDescription; return }

        let id = UUID()
        answerID = id
        generating = true
        timing = AnswerTiming(questionEnded: ended, requestStarted: Date())
        usage = TokenUsage()
        let text = question
        let preset = resourceCondition.reducesWork ? ResourcePreset.low : settings.resourcePreset
        let history = record?.transcript.suffix(preset.recentTurns).map { $0 } ?? []
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
                let prompt = AnswerPrompts.make(task: task, question: text, assistant: assistant, index: available,
                                                recent: history, length: length, preset: preset, image: image)
                self?.record?.sentTextToCloud = true
                self?.scheduleCheckpoint()
                try await streamer.stream(prompt, connection: connection) { [weak self] event in
                    await self?.receiveAnswer(event, id: id)
                }
                guard let self, answerID == id else { return }
                timing?.completed = Date()
                if task == .practiceQuestion {
                    practiceQuestion = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let started = record?.startedAt {
                        append(.init(time: Date().timeIntervalSince(started), source: .practice, text: practiceQuestion))
                    }
                }
                record?.suggestions.append(.init(question: text, answer: answer, provider: connection.selection.provider))
                responseIndex = (record?.suggestions.count ?? 1) - 1
                scheduleCheckpoint()
                generating = false
                answerWork = nil
            } catch {
                guard let self, answerID == id else { return }
                answerError = error.localizedDescription
                generating = false
                answerWork = nil
            }
        }
    }

    private func receiveAnswer(_ event: AnswerEvent, id: UUID) {
        guard answerID == id else { return }
        switch event {
        case .text(let token):
            if timing?.firstToken == nil, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                timing?.firstToken = Date()
            }
            if answer.count < 25_000 { answer += token.prefix(25_000 - answer.count) }
        case .usage(let tokens): usage.merge(tokens)
        case .finished: break
        }
    }

    private func startSource(_ source: AudioSource) {
        guard phase == .active, !starting.contains(source), !activeSources.contains(source), let record else { return }
        let apiKey: String?
        if settings.speechProvider == .openAI {
            guard options.allowCloud else {
                audioErrors[source] = ProviderError.cloudApprovalRequired.localizedDescription
                return
            }
            guard let key = try? credentials.read(.openAI), !key.isEmpty else {
                audioErrors[source] = ProviderError.credentialUnavailable.localizedDescription
                return
            }
            apiKey = key
        } else {
            apiKey = nil
        }
        let id = UUID()
        audioIDs[source] = id
        let input = AudioPipeline(source: source) { [weak self] event in
            Task { @MainActor in self?.receiveAudio(event, id: id) }
        }
        audio[source] = input
        audioErrors[source] = nil
        starting.insert(source)
        let priorStop = stoppingTasks[source]
        let settings = settings
        let url = savingAudio ? newRecordingURL(source: source, session: record.id) : nil
        startingTasks[source] = Task { [weak self] in
            await priorStop?.value
            do {
                try Task.checkCancellation()
                try await input.start(microphoneID: settings.microphoneID, speechProvider: settings.speechProvider,
                                      locale: settings.speechLocale, apiKey: apiKey, recordingURL: url)
                guard let self, audioIDs[source] == id, phase == .active else { await input.stop(); return }
                starting.remove(source)
                activeSources.insert(source)
                startingTasks[source] = nil
            } catch {
                guard let self, audioIDs[source] == id else { return }
                audioErrors[source] = error.localizedDescription
                stopSource(source, retainPartial: true)
            }
        }
    }

    private func stopSource(_ source: AudioSource, retainPartial: Bool) {
        audioIDs[source] = nil
        startingTasks.removeValue(forKey: source)?.cancel()
        starting.remove(source)
        activeSources.remove(source)
        levels[source] = 0
        if let text = partial.removeValue(forKey: source), retainPartial, !text.isEmpty, let started = record?.startedAt {
            append(.init(time: Date().timeIntervalSince(started), source: source, text: text, provisional: true))
        }
        if let input = audio.removeValue(forKey: source) {
            let prior = stoppingTasks[source]
            stoppingTasks[source] = Task {
                await prior?.value
                await input.stop()
            }
        }
    }

    private func receiveAudio(_ event: AudioEvent, id: UUID) {
        switch event {
        case .level(let source, let level):
            if audioIDs[source] == id { levels[source] = level }
        case .partial(let source, let text):
            if audioIDs[source] == id { partial[source] = String(text.prefix(6_000)) }
        case .failure(let source, let message, let recoverable):
            guard audioIDs[source] == id else { return }
            audioErrors[source] = message
            if recoverable { stopSource(source, retainPartial: true) }
        case .cloudAudio(let source):
            guard audioIDs[source] == id else { return }
            record?.sentAudioToCloud = true
            scheduleCheckpoint()
        case .final(let source, let text, let began, let ended):
            guard audioIDs[source] == id, let started = record?.startedAt else { return }
            partial[source] = nil
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            transcriptionDelay = max(0, Date().timeIntervalSince(ended))
            append(.init(time: max(0, began.timeIntervalSince(started)), source: source, text: String(clean.prefix(6_000))))
            guard automatic, !resourceCondition.reducesWork, options.allowCloud, canAnswer, phase == .active,
                  let detected = QuestionDetection.question(in: clean, source: source, locale: settings.speechLocale) else { return }
            let key = QuestionDetection.normalized(detected)
            if let (last, when) = lastAutomatic, last == key, Date().timeIntervalSince(when) < 25 { return }
            lastAutomatic = (key, Date())
            generate(detected, task: .suggestion, ended: ended)
        }
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
            audioErrors[source] = AudioFailure.audioStorage.localizedDescription
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
