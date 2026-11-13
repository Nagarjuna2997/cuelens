import AVFoundation
import OSLog
import Speech

enum AppleSpeechFailure {
    static func isNoMatch(_ error: NSError) -> Bool {
        error.domain == "kAFAssistantErrorDomain" && error.code == 1110
    }
}

/// Apple speech recognition is serialized across captured sources. Each source keeps
/// its own PCM and timestamps while another source's recognition turn finishes.
final class SpeechTaskQueue {
    static let shared = SpeechTaskQueue()
    private struct Work {
        let id: UUID
        let queue: DispatchQueue
        let start: () -> Void
    }
    private let state = DispatchQueue(label: "org.cuelens.speech-tasks")
    private var pending = [Work]()
    private var running: UUID?
    private var coolingDown = false

    func enqueue(id: UUID, on queue: DispatchQueue, start: @escaping () -> Void) {
        state.async {
            self.pending.append(Work(id: id, queue: queue, start: start))
            self.startNext()
        }
    }

    func finish(_ id: UUID) {
        state.async {
            self.pending.removeAll { $0.id == id }
            guard self.running == id else { return }
            self.running = nil
            self.coolingDown = true
            // Allow a cancelled Speech.framework task to release its local service.
            self.state.asyncAfter(deadline: .now() + 0.15) {
                self.coolingDown = false
                self.startNext()
            }
        }
    }

    private func startNext() {
        guard running == nil, !coolingDown, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        running = next.id
        next.queue.async(execute: next.start)
    }
}

final class AppleSpeech: SpeechSink {
    private final class Turn {
        let id = UUID()
        let began: Date
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var buffers = [AVAudioPCMBuffer]()
        var partial = ""
        var ended: Date?
        var fallback: DispatchWorkItem?

        init(began: Date) {
            self.began = began
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            if #available(macOS 13, *) { request.addsPunctuation = true }
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            if task != nil { request.append(buffer) }
            else { buffers.append(buffer) }
        }
    }

    private static let logger = Logger(subsystem: "org.cuelens.mac", category: "Speech")
    private let recognizer: SFSpeechRecognizer
    private let queue: DispatchQueue
    private let onText: (SpeechUpdate) -> Void
    private let onError: (AudioFailure) -> Void
    private let onQueued: (Bool) -> Void
    private let onIncomplete: () -> Void
    private let source: AudioSource
    private var vad = VoiceActivity()
    private var preRoll = [AVAudioPCMBuffer]()
    private var active: Turn?
    private var finishing = [UUID: Turn]()
    private var stopped = false
    private var retryAfter = Date.distantPast
    private var finalizationCompletion: (() -> Void)?
    private var finalizationTimeout: DispatchWorkItem?

    init(locale: String, source: AudioSource, queue: DispatchQueue, onText: @escaping (SpeechUpdate) -> Void,
         onError: @escaping (AudioFailure) -> Void, onQueued: @escaping (Bool) -> Void = { _ in },
         onIncomplete: @escaping () -> Void = {}) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw AudioFailure.speechUnavailable }
        self.recognizer = recognizer
        self.source = source
        self.queue = queue
        self.onText = onText
        self.onError = onError
        self.onQueued = onQueued
        self.onIncomplete = onIncomplete
    }

    static func requestPermission() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        guard status == .notDetermined else { throw AudioFailure.speechPermission }
        let updated = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard updated == .authorized else { throw AudioFailure.speechPermission }
    }

    func receive(_ pcm: AVAudioPCMBuffer, level: Float, at: Date) {
        guard !stopped, finalizationCompletion == nil else { return }
        guard at >= retryAfter || active != nil else { retainPreRoll(pcm); return }
        let duration = Double(pcm.frameLength) / pcm.format.sampleRate
        switch vad.consume(rms: level, duration: duration) {
        case .idle:
            retainPreRoll(pcm)
        case .start:
            let turn = Turn(began: at.addingTimeInterval(-0.045))
            active = turn
            for buffer in preRoll { turn.append(buffer) }
            preRoll.removeAll(keepingCapacity: true)
            turn.append(pcm)
            let id = turn.id
            SpeechTaskQueue.shared.enqueue(id: id, on: queue) { [weak self, weak turn] in
                guard let self, let turn, !self.stopped,
                      self.active?.id == id || self.finishing[id] != nil else {
                    SpeechTaskQueue.shared.finish(id)
                    return
                }
                self.startRecognition(turn)
            }
            publishQueueStatus()
        case .speech:
            active?.append(pcm)
            if let turn = active, at.timeIntervalSince(turn.began) >= 8 {
                endTurn(turn, at: at)
                vad = VoiceActivity()
            }
        case .end:
            guard let turn = active else { return }
            turn.append(pcm)
            endTurn(turn, at: at.addingTimeInterval(-min(0.52, at.timeIntervalSince(turn.began))))
        }
    }

    func stop() {
        stopped = true
        let completion = finalizationCompletion
        finalizationCompletion = nil
        finalizationTimeout?.cancel()
        finalizationTimeout = nil
        preRoll.removeAll()
        let turns = Array(finishing.values) + [active].compactMap { $0 }
        active = nil
        finishing.removeAll()
        for turn in turns {
            turn.fallback?.cancel()
            turn.request.endAudio()
            turn.task?.cancel()
            SpeechTaskQueue.shared.finish(turn.id)
        }
        onQueued(false)
        completion?()
    }

    /// Stop receiving audio, then allow already captured utterances a bounded drain.
    /// Callbacks remain on the source audio queue so final transcript events precede completion.
    func finalizePending(completion: @escaping () -> Void) {
        guard !stopped else { completion(); return }
        finalizationCompletion = completion
        if let turn = active { endTurn(turn, at: Date()) }
        if finishing.isEmpty { completeFinalizationIfReady(); return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.finalizationCompletion != nil else { return }
            let turns = Array(self.finishing.values)
            if turns.contains(where: { $0.partial.isEmpty }) {
                self.onIncomplete()
                self.onError(.speechDrainTimeout)
            }
            for turn in turns { self.finish(turn, text: turn.partial) }
            self.completeFinalizationIfReady()
        }
        finalizationTimeout = timeout
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func retainPreRoll(_ pcm: AVAudioPCMBuffer) {
        preRoll.append(pcm)
        if preRoll.count > 12 { preRoll.removeFirst() }
    }

    private func startRecognition(_ turn: Turn) {
        let id = turn.id
        turn.task = recognizer.recognitionTask(with: turn.request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failure = error as NSError?
            self?.queue.async { [weak self] in self?.result(id, text: text, final: final, failure: failure) }
        }
        for buffer in turn.buffers { turn.request.append(buffer) }
        turn.buffers.removeAll()
        publishQueueStatus()
        if turn.ended != nil { endRecognition(turn) }
    }

    private func endTurn(_ turn: Turn, at: Date) {
        active = nil
        turn.ended = at
        finishing[turn.id] = turn
        if turn.task != nil { endRecognition(turn) }
        if let oldest = finishing.values.filter({ $0.task == nil }).min(by: { $0.began < $1.began }), finishing.count > 3 {
            finish(oldest, text: oldest.partial)
            onIncomplete()
            onError(.tooSlow)
        }
        publishQueueStatus()
    }

    private func publishQueueStatus() {
        onQueued((active != nil && active?.task == nil) || finishing.values.contains { $0.task == nil })
    }

    private func endRecognition(_ turn: Turn) {
        turn.request.endAudio()
        let fallback = DispatchWorkItem { [weak self, weak turn] in
            guard let self, let turn, self.active?.id == turn.id || self.finishing[turn.id] != nil else { return }
            let missingText = turn.partial.isEmpty
            if missingText {
                self.onIncomplete()
                self.onError(.speechTimeout)
            }
            self.finish(turn, text: turn.partial)
        }
        turn.fallback = fallback
        // Queued/cold recognition needs time to process PCM already accumulated.
        let allowance = turn.partial.isEmpty ? 5.0 : 1.2
        queue.asyncAfter(deadline: .now() + allowance, execute: fallback)
    }

    private func result(_ id: UUID, text: String?, final: Bool, failure: NSError?) {
        guard !stopped, let turn = active?.id == id ? active : finishing[id] else { return }
        if let text, !text.isEmpty { turn.partial = text }
        if final || failure != nil {
            let hasText = !turn.partial.isEmpty
            if let failure, !hasText {
                if AppleSpeechFailure.isNoMatch(failure) {
                    // VAD also admits room noise. Apple reports 1110 when a turn has no
                    // recognizable speech, so keep the source ready for its next turn.
                    retryAfter = Date().addingTimeInterval(0.2)
                    Self.logger.debug("No speech recognized for \(self.source.rawValue, privacy: .public)")
                } else {
                    onIncomplete()
                    retryAfter = Date().addingTimeInterval(1)
                    Self.logger.error("On-device speech failed for \(self.source.rawValue, privacy: .public): \(failure.domain, privacy: .public) (\(failure.code))")
                    onError(.speechService(failure.domain, failure.code))
                }
            }
            finish(turn, text: turn.partial)
        } else if let text, !text.isEmpty {
            onText(SpeechUpdate(source: source, text: text, began: turn.began, ended: turn.ended ?? Date(), finalized: false))
        }
    }

    private func finish(_ turn: Turn, text: String) {
        guard active?.id == turn.id || finishing[turn.id] != nil else { return }
        if active?.id == turn.id {
            active = nil
            vad = VoiceActivity()
        }
        finishing.removeValue(forKey: turn.id)
        turn.fallback?.cancel()
        turn.task?.cancel()
        SpeechTaskQueue.shared.finish(turn.id)
        publishQueueStatus()
        onText(SpeechUpdate(source: source, text: text, began: turn.began, ended: turn.ended ?? Date(), finalized: true))
        completeFinalizationIfReady()
    }

    private func completeFinalizationIfReady() {
        guard active == nil, finishing.isEmpty, let completion = finalizationCompletion else { return }
        finalizationCompletion = nil
        finalizationTimeout?.cancel()
        finalizationTimeout = nil
        stopped = true
        onQueued(false)
        completion()
    }
}
