import AppKit
import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    let model: AppModel
    @State private var query = ""
    @State private var selected: UUID?
    @State private var unreadableCount = 0

    private var visibleSessions: [MeetingSession] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.history }
        return model.history.filter { session in
            session.title.localizedStandardContains(value) || session.assistantName.localizedStandardContains(value)
                || session.summary.localizedStandardContains(value)
                || session.transcript.contains { $0.text.localizedStandardContains(value) }
                || session.suggestions.contains { $0.question.localizedStandardContains(value) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if unreadableCount > 0 {
                Label("\(unreadableCount) saved session file(s) could not be read. The files are preserved for recovery.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
            history
        }
        .task { unreadableCount = (try? model.vault.readHistory().unreadableCount) ?? 0 }
    }

    @ViewBuilder private var history: some View {
        if model.history.isEmpty {
            ContentUnavailableView("No saved sessions", systemImage: "clock.arrow.circlepath",
                                   description: Text("Saved transcripts and summaries appear here when a session ends."))
        } else {
            HSplitView {
                VStack(alignment: .leading, spacing: 9) {
                    Text("History").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    TextField("Search sessions", text: $query).textFieldStyle(.roundedBorder)
                    if visibleSessions.isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    } else {
                        List(selection: $selected) {
                            ForEach(visibleSessions) { session in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title).font(.headline).lineLimit(1)
                                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                .tag(session.id)
                            }
                        }
                        .listStyle(.inset)
                    }
                }
                .padding(12)
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 345)
                if let id = selected, let session = model.history.first(where: { $0.id == id }) {
                    SessionDetails(model: model, original: session).id(id)
                } else {
                    ContentUnavailableView("Select a session", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear { if selected == nil { selected = visibleSessions.first?.id } }
            .onChange(of: model.history.map(\.id)) { if !model.history.contains(where: { $0.id == selected }) { selected = visibleSessions.first?.id } }
            .onChange(of: query) { if !visibleSessions.contains(where: { $0.id == selected }) { selected = visibleSessions.first?.id } }
        }
    }
}

private struct SessionDetails: View {
    let model: AppModel
    let original: MeetingSession
    @State private var query = ""
    @State private var editing: TranscriptLine?
    @State private var confirmingDelete = false
    @State private var confirmingSummary = false
    @State private var provider = AnswerProvider.disabled
    @State private var summaryWork: Task<Void, Never>?
    @State private var summaryID: UUID?
    @State private var summaryDraft = ""
    @State private var status = ""
    @State private var export: ExportDocument?
    @State private var exportName = ""
    @State private var exportType = UTType.plainText
    @State private var exporting = false
    @State private var savedAudio = [URL]()
    @State private var audioLoadError: String?
    @State private var audioPlayer = SavedSessionAudioPlayer()

    private var session: MeetingSession {
        model.history.first(where: { $0.id == original.id }) ?? original
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Spacer()
                    Menu("Actions", systemImage: "ellipsis.circle") {
                        Button("Copy Transcript") { copy(SessionExport.transcript(session)) }
                        Button("Copy Summary") { copy(session.summary) }.disabled(session.summary.isEmpty)
                        Divider()
                        ForEach(SessionExport.Format.allCases) { format in
                            Button("Export \(format.rawValue)…") { prepareExport(format) }
                        }
                        Divider()
                        Button("Delete Session…", role: .destructive) { confirmingDelete = true }
                            .disabled(summaryWork != nil)
                    }.labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
                }
                Text("\(session.assistantName) · \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                if session.endedAt == nil { Label("Recovered checkpoint", systemImage: "clock.arrow.circlepath").font(.caption) }
                TextField("Find in transcript", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("sessionSearch")
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    if query.isEmpty {
                        summary
                        if session.sentAudioToCloud || session.sentTextToCloud {
                            Label("This session used cloud processing.", systemImage: "cloud").font(.caption).foregroundStyle(.secondary)
                        }
                        if let audioLoadError {
                            Label(audioLoadError, systemImage: "waveform.badge.exclamationmark")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !savedAudio.isEmpty {
                            Text("Saved audio").font(.headline)
                            ForEach(savedAudio, id: \.self) { file in
                                HStack {
                                    Button(audioPlayer.playingFile == file ? "Pause" : "Play",
                                           systemImage: audioPlayer.playingFile == file ? "pause.fill" : "play.fill") {
                                        audioPlayer.toggle(file)
                                    }
                                    Text(file.lastPathComponent).font(.callout).lineLimit(1)
                                    Spacer()
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                                }
                            }
                            if let error = audioPlayer.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Text("Transcript").font(.headline)
                    if let notice = session.transcriptionNotice {
                        Label(notice, systemImage: "exclamationmark.bubble")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if filteredLines.isEmpty { Text(query.isEmpty ? "No transcript was saved." : "No matching lines.").foregroundStyle(.secondary) }
                    ForEach(filteredLines) { line in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(line.timestamp) · \(line.source.rawValue)\(line.provisional == true ? " · Unfinalized" : "")")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(line.text).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Correct Text", systemImage: "pencil") { editing = line }.labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .disabled(summaryWork != nil)
                        }
                    }
                    if query.isEmpty && !session.suggestions.isEmpty {
                        Divider()
                        Text("Questions and suggestions").font(.headline)
                        ForEach(session.suggestions) { suggestion in
                            DisclosureGroup {
                                Text(suggestion.answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Text(suggestion.question)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 370, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let assistant = model.assistants.first { $0.id == session.assistantID }
            provider = assistant.map { model.preferences.answerSelection(for: $0).provider } ?? model.preferences.answerProvider
        }
        .task(id: session.audioFiles) {
            do {
                savedAudio = try model.vault.audioFiles(for: session.id)
                audioLoadError = savedAudio.isEmpty && !(session.audioFiles ?? []).isEmpty
                    ? "The saved recording is missing from this session’s Audio folder." : nil
            } catch {
                savedAudio = []
                audioLoadError = "Saved audio could not be opened. Check the session’s Audio folder."
            }
        }
        .onDisappear { cancelSummary(); audioPlayer.stop() }
        .sheet(item: $editing) { line in
            TranscriptEditor(line: line) { updated in
                var record = session
                if let index = record.transcript.firstIndex(where: { $0.id == updated.id }) {
                    record.transcript[index] = updated
                    if model.saveSession(record) { editing = nil }
                }
            } cancel: { editing = nil }
        }
        .alert("Delete this session?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { audioPlayer.stop(); model.deleteSession(session.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved transcript, suggestions, summary, and raw audio for this session will be removed.")
        }
        .confirmationDialog("Send transcript to \(provider.shortName)?", isPresented: $confirmingSummary) {
            Button("Send and Summarize") { generateSummary() }
        } message: {
            Text("CueLens will send a bounded transcript excerpt to the selected provider to generate the summary.")
        }
        .fileExporter(isPresented: $exporting, document: export, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
    }

    private var filteredLines: [TranscriptLine] {
        query.isEmpty ? session.transcript : session.transcript.filter { $0.text.localizedStandardContains(query) }
    }

    private var summary: some View {
        CueCard {
            HStack {
                Text("Summary").font(.headline)
                Spacer()
                if summaryWork == nil {
                    Picker("Summary provider", selection: $provider) {
                        Text("Choose provider").tag(AnswerProvider.disabled)
                        ForEach(AnswerProvider.cloudProviders) { Text($0.shortName).tag($0) }
                    }.labelsHidden().fixedSize()
                    Button(session.summary.isEmpty ? "Summarize" : "Regenerate") { confirmingSummary = true }
                        .disabled(provider == .disabled || session.transcript.isEmpty)
                } else {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { cancelSummary() }
                }
            }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary).font(.callout) }
            let text = summaryDraft.isEmpty ? session.summary : summaryDraft
            if !text.isEmpty {
                Text(text).textSelection(.enabled)
                if let source = session.summaryProvider, summaryDraft.isEmpty {
                    Text("Generated by \(source.shortName)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func generateSummary() {
        guard summaryWork == nil else { return }
        let requestID = UUID()
        summaryID = requestID
        let original = session
        let selectedProvider = provider
        let preferences = model.preferences
        let assistant = model.assistants.first { $0.id == original.assistantID } ?? .init(name: original.assistantName)
        let configured = preferences.answerSelection(for: assistant)
        let selection = configured.provider == selectedProvider ? configured
            : ProviderSelection(provider: selectedProvider, model: preferences.model(for: selectedProvider))
        status = ""
        summaryDraft = ""
        summaryWork = Task {
            defer { if summaryID == requestID { summaryWork = nil; summaryID = nil } }
            do {
                let connection = try ProviderConnection(selection: selection, credentials: model.credentials)
                var flagged = original
                flagged.sentTextToCloud = true
                guard model.saveSession(flagged) else { return }
                let prompt = AnswerPrompts.make(task: .summary, question: "Summarize this session.",
                                                assistant: assistant, index: KnowledgeIndex(assistant: .init()),
                                                recent: original.transcript, length: .detailed, preset: preferences.resourcePreset)
                try await HTTPAnswerStream().stream(prompt, connection: connection) { event in
                    if case .text(let token) = event {
                        await MainActor.run {
                            if summaryID == requestID { summaryDraft += token }
                        }
                    }
                }
                try Task.checkCancellation()
                guard summaryID == requestID,
                      var latest = model.history.first(where: { $0.id == original.id }) else { return }
                latest.summary = summaryDraft
                latest.summaryProvider = selectedProvider
                latest.sentTextToCloud = true
                if model.saveSession(latest) { summaryDraft = "" }
            } catch {
                guard summaryID == requestID else { return }
                summaryDraft = ""
                if !Task.isCancelled { status = error.localizedDescription }
            }
        }
    }

    private func cancelSummary() {
        summaryID = nil
        summaryWork?.cancel()
        summaryWork = nil
        summaryDraft = ""
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func prepareExport(_ format: SessionExport.Format) {
        let text = SessionExport.render(session, format: format)
        exportType = format == .text ? .plainText : ExportDocument.markdown
        exportName = session.title.replacingOccurrences(of: "/", with: "-") + "." + format.fileExtension
        export = ExportDocument(text: text)
        exporting = true
    }
}

@MainActor
@Observable
private final class SavedSessionAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingFile: URL?
    private(set) var error: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var loadedFile: URL?

    func toggle(_ file: URL) {
        error = nil
        if playingFile == file {
            player?.pause()
            playingFile = nil
            return
        }
        do {
            if loadedFile != file {
                stop()
                player = try AVAudioPlayer(contentsOf: file)
                player?.delegate = self
                loadedFile = file
            }
            guard player?.play() == true else { throw CocoaError(.fileReadCorruptFile) }
            playingFile = file
        } catch {
            stop()
            self.error = "This audio clip could not be played. Use Show in Finder to inspect the recording."
        }
    }

    func stop() {
        player?.stop()
        player = nil
        loadedFile = nil
        playingFile = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
            stop()
            if !flag { error = "Audio playback ended before the clip completed." }
        }
    }
}

private struct TranscriptEditor: View {
    @State var line: TranscriptLine
    let save: (TranscriptLine) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(line.timestamp) · \(line.source.rawValue)").font(.headline)
            EditorField(label: "Transcript text", text: $line.text, height: 140)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save Correction") {
                    line.text = String(line.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
                    line.provisional = false
                    save(line)
                }.keyboardShortcut(.defaultAction)
                .disabled(line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 530, height: 280)
    }
}

private struct ExportDocument: FileDocument {
    static let markdown = UTType(filenameExtension: "md") ?? .plainText
    static var readableContentTypes: [UTType] { [.plainText, markdown] }

    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let decoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = decoded
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
