import Foundation
import Observation

@MainActor
@Observable
final class AudioCheck {
    private(set) var levels = [AudioSource: Float]()
    private(set) var heard = Set<AudioSource>()
    private(set) var errors = [AudioSource: String]()
    private(set) var testing = false
    private(set) var attempted = Set<AudioSource>()
    @ObservationIgnored private var inputs = [AudioPipeline]()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var id: UUID?

    func run(sources: [AudioSource], microphoneID: String?) {
        guard !testing, !sources.isEmpty else { return }
        let id = UUID()
        self.id = id
        testing = true
        attempted = Set(sources)
        levels.removeAll()
        errors.removeAll()
        heard.removeAll()
        work = Task { [weak self] in
            guard let self else { return }
            for source in sources {
                guard self.id == id else { break }
                let input = AudioPipeline(source: source) { [weak self] event in
                    Task { @MainActor in self?.receive(event, id: id) }
                }
                inputs.append(input)
                do {
                    try await input.start(microphoneID: microphoneID, speechProvider: nil, locale: "", apiKey: nil, recordingURL: nil)
                } catch {
                    if self.id == id { errors[source] = error.localizedDescription }
                }
            }
            if self.id == id { try? await Task.sleep(for: .seconds(8)) }
            let stopping = inputs
            inputs.removeAll()
            for input in stopping { await input.stop() }
            testing = false
            self.id = nil
            work = nil
        }
    }

    func stop() {
        id = nil
        work?.cancel()
    }

    private func receive(_ event: AudioEvent, id: UUID) {
        guard self.id == id else { return }
        switch event {
        case .level(let source, let level):
            levels[source] = level
            if level > 0.008 { heard.insert(source) }
        case .failure(let source, let error, _): errors[source] = error
        default: break
        }
    }
}
