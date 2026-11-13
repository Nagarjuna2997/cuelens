import AVFoundation
import Speech

final class AppleSpeech: SpeechSink {
    private final class Turn {
        let id = UUID()
        let began: Date
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
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
    }

    private let recognizer: SFSpeechRecognizer
    private let queue: DispatchQueue
    private let onText: (SpeechUpdate) -> Void
    private let onError: (AudioFailure) -> Void
    private let source: AudioSource
    private var vad = VoiceActivity()
    private var preRoll = [AVAudioPCMBuffer]()
    private var active: Turn?
    private var finishing = [UUID: Turn]()
    private var stopped = false

    init(locale: String, source: AudioSource, queue: DispatchQueue, onText: @escaping (SpeechUpdate) -> Void,
         onError: @escaping (AudioFailure) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw AudioFailure.speechUnavailable }
        self.recognizer = recognizer
        self.source = source
        self.queue = queue
        self.onText = onText
        self.onError = onError
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
        guard !stopped else { return }
        let duration = Double(pcm.frameLength) / pcm.format.sampleRate
        switch vad.consume(rms: level, duration: duration) {
        case .idle:
            preRoll.append(pcm)
            if preRoll.count > 12 { preRoll.removeFirst() }
        case .start:
            let turn = Turn(began: at.addingTimeInterval(-0.045))
            active = turn
            let id = turn.id
            turn.task = recognizer.recognitionTask(with: turn.request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                self?.queue.async { [weak self] in self?.result(id, text: text, final: final, failed: error != nil) }
            }
            for buffer in preRoll { turn.request.append(buffer) }
            preRoll.removeAll(keepingCapacity: true)
            turn.request.append(pcm)
        case .speech:
            active?.request.append(pcm)
        case .end:
            guard let turn = active else { return }
            turn.request.append(pcm)
            active = nil
            turn.ended = at.addingTimeInterval(-min(0.52, at.timeIntervalSince(turn.began)))
            finishing[turn.id] = turn
            turn.request.endAudio()
            if let oldest = finishing.values.min(by: { $0.began < $1.began }), finishing.count > 2 {
                finish(oldest, text: oldest.partial)
            }
            let fallback = DispatchWorkItem { [weak self, weak turn] in
                guard let self, let turn else { return }
                finish(turn, text: turn.partial)
            }
            turn.fallback = fallback
            queue.asyncAfter(deadline: .now() + 0.85, execute: fallback)
        }
    }

    func stop() {
        stopped = true
        preRoll.removeAll()
        let turns = Array(finishing.values) + [active].compactMap { $0 }
        active = nil
        finishing.removeAll()
        for turn in turns {
            turn.fallback?.cancel()
            turn.request.endAudio()
            turn.task?.cancel()
        }
    }

    private func result(_ id: UUID, text: String?, final: Bool, failed: Bool) {
        guard !stopped, let turn = active?.id == id ? active : finishing[id] else { return }
        if let text, !text.isEmpty { turn.partial = text }
        if final || failed {
            let hasText = !turn.partial.isEmpty
            finish(turn, text: turn.partial)
            if failed && !hasText && turn.ended == nil { onError(.speechInterrupted) }
        } else if active?.id == id, let text {
            onText(SpeechUpdate(source: source, text: text, began: turn.began, ended: Date(), finalized: false))
        }
    }

    private func finish(_ turn: Turn, text: String) {
        if active?.id == turn.id { active = nil }
        finishing.removeValue(forKey: turn.id)
        turn.fallback?.cancel()
        turn.task?.cancel()
        onText(SpeechUpdate(source: source, text: text, began: turn.began, ended: turn.ended ?? Date(), finalized: true))
    }
}
