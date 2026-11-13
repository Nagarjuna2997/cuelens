import AVFoundation
import Foundation

enum AudioEvent: Sendable {
    case level(AudioSource, Float)
    case clipping(AudioSource, Bool)
    case transcription(AudioSource, Bool)
    case recording(AudioSource, Bool)
    case partial(AudioSource, String)
    case final(AudioSource, String, Date, Date)
    case failure(AudioSource, String, recoverable: Bool)
    case cloudAudio(AudioSource)
}

struct VoiceActivity {
    enum Transition { case idle, start, speech, end }
    private var voiceDuration = 0.0
    private var silenceDuration = 0.0
    private var totalDuration = 0.0
    private(set) var speaking = false

    mutating func consume(rms: Float, duration: TimeInterval) -> Transition {
        let voiced = rms >= (speaking ? 0.007 : 0.012)
        if !speaking {
            voiceDuration = voiced ? voiceDuration + duration : 0
            guard voiceDuration >= 0.045 else { return .idle }
            speaking = true
            totalDuration = voiceDuration
            return .start
        }
        totalDuration += duration
        silenceDuration = voiced ? 0 : silenceDuration + duration
        if silenceDuration >= 0.52 || totalDuration >= 22 {
            self = Self()
            return .end
        }
        return .speech
    }
}

struct SpeechUpdate: Sendable {
    let source: AudioSource
    let text: String
    let began: Date
    let ended: Date
    let finalized: Bool
}

protocol SpeechSink: AnyObject {
    func receive(_ pcm: AVAudioPCMBuffer, level: Float, at: Date)
    func stop()
}

final class AudioPipeline: @unchecked Sendable {
    typealias Emit = @Sendable (AudioEvent) -> Void

    private let queue = DispatchQueue(label: "org.cuelens.audio", qos: .userInitiated)
    private let source: AudioSource
    private let emit: Emit
    private var input: (any AudioInput)?
    private var speech: (any SpeechSink)?
    private var converter = AudioNormalizer()
    private var recorder: AVAudioFile?
    private var recordingURL: URL?
    private var recordingStarted = false
    private var lastMeter: TimeInterval = 0
    private var clippingUntil: TimeInterval = 0
    private var accepting = false
    private var retired = false

    init(source: AudioSource, emit: @escaping Emit) {
        self.source = source
        self.emit = emit
    }

    func start(microphoneID: String?, speechProvider: SpeechProvider?, locale: String, apiKey: String?,
               recordingURL: URL?) async throws {
        if source == .microphone { try await AudioPermissions.microphone() }
        var availableSpeech = speechProvider
        var speechIssue: String?
        if speechProvider == .onDevice {
            do { try await AppleSpeech.requestPermission() }
            catch {
                availableSpeech = nil
                speechIssue = error.localizedDescription
            }
        }
        try Task.checkCancellation()
        let selectedSpeech = availableSpeech
        let permissionIssue = speechIssue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !self.retired else { throw CancellationError() }
                    try self.startOnQueue(microphoneID: microphoneID, speechProvider: selectedSpeech, locale: locale,
                                          apiKey: apiKey, recordingURL: recordingURL)
                    if let permissionIssue { self.reportSpeechFailure(permissionIssue) }
                    continuation.resume()
                } catch {
                    self.stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
        if Task.isCancelled {
            await stop()
            throw CancellationError()
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopOnQueue()
                continuation.resume()
            }
        }
    }

    private func startOnQueue(microphoneID: String?, speechProvider: SpeechProvider?, locale: String, apiKey: String?,
                              recordingURL: URL?) throws {
        self.recordingURL = recordingURL
        let deliver = emit
        let source = source
        do {
            switch speechProvider {
            case .onDevice:
                speech = try AppleSpeech(locale: locale, source: source, queue: queue, onText: { update in
                    if !update.text.isEmpty { deliver(.transcription(source, true)) }
                    deliver(update.finalized ? .final(source, update.text, update.began, update.ended) : .partial(source, update.text))
                }, onError: { [weak self] in self?.reportSpeechFailure($0.localizedDescription) })
            case .openAI:
                guard let apiKey else { throw ProviderError.credentialUnavailable }
                speech = try RealtimeSpeech(key: apiKey, locale: locale, source: source, onText: { update in
                    if !update.text.isEmpty { deliver(.transcription(source, true)) }
                    deliver(update.finalized ? .final(source, update.text, update.began, update.ended) : .partial(source, update.text))
                }, onSend: { deliver(.cloudAudio(source)) }, onError: { [weak self] error in
                    self?.queue.async { [weak self] in
                        guard let self, accepting else { return }
                        speech?.stop()
                        speech = nil
                        reportSpeechFailure(error.localizedDescription)
                    }
                })
            case nil:
                break
            }
        } catch {
            reportSpeechFailure(error.localizedDescription)
        }
        let feed: (AVAudioPCMBuffer) -> Void = { [weak self] pcm in self?.receive(pcm) }
        let failure: (AudioFailure) -> Void = { error in
            deliver(.failure(source, error.localizedDescription, recoverable: true))
        }
        switch source {
        case .microphone: input = MicrophoneInput(deviceID: microphoneID, queue: queue, feed: feed, failure: failure)
        case .meeting: input = MeetingAudioInput(queue: queue, feed: feed, failure: failure)
        case .manual, .practice: return
        }
        accepting = true
        try input?.start()
        emit(.transcription(source, speech != nil))
    }

    private func receive(_ pcm: AVAudioPCMBuffer) {
        guard accepting else { return }
        let buffer: AVAudioPCMBuffer
        do {
            guard let converted = try converter.convert(pcm) else { return }
            buffer = converted
        } catch {
            accepting = false
            emit(.failure(source, AudioFailure.invalidFormat.localizedDescription, recoverable: true))
            return
        }
        let now = Date()
        let level = Self.level(buffer)
        let clock = ProcessInfo.processInfo.systemUptime
        if max(Self.peak(pcm), Self.peak(buffer)) >= 0.98 { clippingUntil = clock + 1.5 }
        if clock - lastMeter >= 0.10 {
            lastMeter = clock
            emit(.level(source, level))
            emit(.clipping(source, clock < clippingUntil))
        }
        if let recordingURL {
            do {
                if recorder == nil {
                    recorder = try AVAudioFile(forWriting: recordingURL, settings: buffer.format.settings,
                                               commonFormat: .pcmFormatFloat32, interleaved: false)
                }
                try recorder?.write(from: buffer)
                if !recordingStarted {
                    recordingStarted = true
                    emit(.recording(source, true))
                }
            } catch {
                self.recordingURL = nil
                recorder = nil
                recordingStarted = false
                emit(.recording(source, false))
                emit(.failure(source, AudioFailure.audioStorage.localizedDescription, recoverable: false))
            }
        }
        speech?.receive(buffer, level: level, at: now)
    }

    private func reportSpeechFailure(_ message: String) {
        emit(.transcription(source, false))
        let continuation = recordingURL == nil ? "Audio input remains on." : "Audio recording continues."
        emit(.failure(source, "\(message) \(continuation)", recoverable: false))
    }

    private func stopOnQueue() {
        retired = true
        accepting = false
        input?.stop()
        input = nil
        speech?.stop()
        speech = nil
        recorder = nil
        recordingURL = nil
        recordingStarted = false
        emit(.recording(source, false))
        emit(.transcription(source, false))
    }

    static func level(_ pcm: AVAudioPCMBuffer) -> Float {
        guard let samples = pcm.floatChannelData?[0], pcm.frameLength > 0 else { return 0 }
        var squares: Float = 0
        for i in 0..<Int(pcm.frameLength) { squares += samples[i] * samples[i] }
        return sqrt(squares / Float(pcm.frameLength))
    }

    static func peak(_ pcm: AVAudioPCMBuffer) -> Float {
        guard pcm.frameLength > 0 else { return 0 }
        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            guard let data = buffer.mData else { continue }
            switch pcm.format.commonFormat {
            case .pcmFormatFloat32:
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) { peak = max(peak, abs(samples[i])) }
            case .pcmFormatInt16:
                let samples = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size) { peak = max(peak, abs(Float(samples[i])) / 32_768) }
            case .pcmFormatInt32:
                let samples = data.assumingMemoryBound(to: Int32.self)
                for i in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size) { peak = max(peak, abs(Float(samples[i])) / 2_147_483_648) }
            default:
                break
            }
        }
        return peak
    }
}

struct AudioNormalizer {
    private let target = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    mutating func convert(_ pcm: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard pcm.frameLength > 0 else { return nil }
        guard pcm.format.sampleRate.isFinite, pcm.format.sampleRate > 0, pcm.format.channelCount > 0 else {
            throw AudioFailure.invalidFormat
        }
        // AudioUnit buffers expire after the I/O callback. Copy via the converter even for a matching format.
        if source != pcm.format {
            source = pcm.format
            converter = AVAudioConverter(from: pcm.format, to: target)
            converter?.downmix = true
        }
        let capacity = AVAudioFrameCount(ceil(Double(pcm.frameLength) * target.sampleRate / pcm.format.sampleRate)) + 32
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioFailure.invalidFormat
        }
        var pending = true
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard pending else { state.pointee = .noDataNow; return nil }
            pending = false
            state.pointee = .haveData
            return pcm
        }
        guard status != .error, error == nil else { throw AudioFailure.invalidFormat }
        // A live resampler may need more input before it produces a frame.
        guard output.frameLength > 0 else { return nil }
        return output
    }
}
