import AVFoundation
import Foundation

final class RealtimeSpeech: SpeechSink {
    private enum Command: Sendable {
        case append(Data, Date)
        case commit(Date)
    }

    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let queue: AsyncStream<Command>.Continuation
    private let worker: Task<Void, Never>
    private let state: RealtimeSpeechState
    private var vad = VoiceActivity()
    private var recent = [(Data, Date)]()
    private var sendingTurn = false

    init(key: String, locale: String, source: AudioSource, onText: @escaping @Sendable (SpeechUpdate) -> Void,
         onSend: @escaping @Sendable () -> Void, onError: @escaping @Sendable (AudioFailure) -> Void) throws {
        session = ProviderHTTP.session()
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        socket = session.webSocketTask(with: request)
        let (stream, continuation) = AsyncStream<Command>.makeStream(bufferingPolicy: .bufferingOldest(90))
        queue = continuation
        let state = RealtimeSpeechState(source: source, onText: onText)
        self.state = state
        let socket = socket
        socket.resume()
        worker = Task.detached {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            let data: Data
                            switch message {
                            case .data(let bytes): data = bytes
                            case .string(let text): data = Data(text.utf8)
                            @unknown default: continue
                            }
                            try await state.receive(data)
                        }
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(5))
                            try await state.checkTimeout(at: Date())
                        }
                    }
                    group.addTask {
                        let language = Locale(identifier: locale).language.languageCode?.identifier
                        var transcription: [String: Any] = ["model": "gpt-live-transcribe", "delay": "minimal"]
                        if let language { transcription["languages"] = [language] }
                        try await Self.send(["type": "session.update", "session": [
                            "type": "transcription", "audio": ["input": [
                                "format": ["type": "audio/pcm", "rate": 24_000], "transcription": transcription,
                                "turn_detection": NSNull()
                            ]]
                        ]], socket: socket)
                        var beginning: Date?
                        var reported = false
                        for await command in stream {
                            try Task.checkCancellation()
                            switch command {
                            case .append(let data, let date):
                                if beginning == nil { beginning = date }
                                try await Self.send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()], socket: socket)
                                if !reported { onSend(); reported = true }
                            case .commit(let end):
                                guard let start = beginning else { continue }
                                await state.expect(start: start, end: end)
                                try await Self.send(["type": "input_audio_buffer.commit"], socket: socket)
                                beginning = nil
                            }
                        }
                    }
                    defer { socket.cancel(with: .normalClosure, reason: nil); group.cancelAll() }
                    _ = try await group.next()
                }
            } catch {
                if !Task.isCancelled { onError(.cloudStream) }
            }
        }
        self.onError = onError
    }

    private let onError: @Sendable (AudioFailure) -> Void

    func receive(_ pcm: AVAudioPCMBuffer, level: Float, at: Date) {
        let duration = Double(pcm.frameLength) / pcm.format.sampleRate
        let transition = vad.consume(rms: level, duration: duration)
        let data = Self.pcm16(pcm)
        switch transition {
        case .idle:
            recent.append((data, at))
            recent.removeAll { at.timeIntervalSince($0.1) > 0.16 }
        case .start:
            for (buffer, date) in recent { enqueue(.append(buffer, date)) }
            recent.removeAll(keepingCapacity: true)
            enqueue(.append(data, at))
            sendingTurn = true
        case .speech:
            if sendingTurn { enqueue(.append(data, at)) }
        case .end:
            if sendingTurn {
                enqueue(.append(data, at))
                enqueue(.commit(at.addingTimeInterval(-0.52)))
            }
            sendingTurn = false
        }
    }

    func stop() {
        queue.finish()
        worker.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func enqueue(_ command: Command) {
        if case .dropped = queue.yield(command) {
            stop()
            onError(.tooSlow)
        }
    }

    private static func pcm16(_ pcm: AVAudioPCMBuffer) -> Data {
        guard let source = pcm.floatChannelData?[0] else { return Data() }
        let count = Int(pcm.frameLength)
        var data = Data(count: count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { bytes in
            let target = bytes.bindMemory(to: Int16.self)
            for index in 0..<count {
                let sample = source[index].isFinite ? source[index] : 0
                target[index] = Int16(max(-32_768, min(32_767, sample * 32_768))).littleEndian
            }
        }
        return data
    }

    private static func send(_ event: [String: Any], socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}

private actor RealtimeSpeechState {
    private struct Turn {
        var start: Date
        var end: Date
        var text = ""
    }

    let source: AudioSource
    let onText: @Sendable (SpeechUpdate) -> Void
    private var expected = [Turn]()
    private var turns = [String: Turn]()
    private var partials = [String: String]()

    init(source: AudioSource, onText: @escaping @Sendable (SpeechUpdate) -> Void) {
        self.source = source
        self.onText = onText
    }

    func expect(start: Date, end: Date) {
        if expected.count == 12 { expected.removeFirst() }
        expected.append(Turn(start: start, end: max(start, end)))
    }

    func checkTimeout(at now: Date) throws {
        let pending = expected + Array(turns.values)
        if pending.contains(where: { now.timeIntervalSince($0.end) > 30 }) {
            throw AudioFailure.cloudStream
        }
    }

    func receive(_ data: Data) throws {
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        if type == "error" || type == "conversation.item.input_audio_transcription.failed" { throw AudioFailure.cloudStream }
        guard let id = event["item_id"] as? String else { return }
        switch type {
        case "input_audio_buffer.committed":
            if !expected.isEmpty {
                if turns.count >= 12, let oldest = turns.min(by: { $0.value.start < $1.value.start }) { turns.removeValue(forKey: oldest.key) }
                turns[id] = expected.removeFirst()
            }
        case "conversation.item.input_audio_transcription.delta":
            if let delta = event["delta"] as? String {
                if partials.count >= 12 && partials[id] == nil { partials.removeAll() }
                let text = String(((partials[id] ?? "") + delta).prefix(12_000))
                partials[id] = text
                let turn = turns[id]
                onText(SpeechUpdate(source: source, text: text, began: turn?.start ?? Date(),
                                    ended: turn?.end ?? Date(), finalized: false))
            }
        case "conversation.item.input_audio_transcription.completed":
            let turn = turns.removeValue(forKey: id)
            let partial = partials.removeValue(forKey: id)
            let text = event["transcript"] as? String ?? partial ?? ""
            onText(SpeechUpdate(source: source, text: text, began: turn?.start ?? Date(),
                                ended: turn?.end ?? Date(), finalized: true))
        default: break
        }
    }
}
