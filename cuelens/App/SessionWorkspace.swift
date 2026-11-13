import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionWorkspace: View {
    @Bindable var live: LiveSession
    let floating: Bool
    let overlay: OverlayPreferences
    var onMain: (() -> Void)?
    var onCompact: (() -> Void)?
    var onHide: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if live.resourceCondition.reducesWork {
                Label("Resource pressure · Automatic answers are paused.", systemImage: "gauge.with.needle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            HSplitView {
                transcript
                    .frame(minWidth: floating ? 200 : 235, idealWidth: 280, maxWidth: 520)
                answers
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
        }
        .background(floating ? Color(nsColor: .windowBackgroundColor) : Color.clear)
    }

    private var header: some View {
        HStack(spacing: 9) {
            if floating { PanelDragGrip().frame(width: 21, height: 24) }
            Image(systemName: "waveform.circle.fill").foregroundStyle(CueStyle.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(live.record?.title ?? "Session").font(.headline).lineLimit(1)
                Label(live.audioSourceLabel, systemImage: live.audioLive ? "record.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(live.audioLive ? .red : .secondary)
                    .accessibilityIdentifier("captureState")
            }
            Spacer(minLength: 4)
            if let started = live.record?.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if live.phase == .paused {
                Button("Resume", systemImage: "play.fill") { live.resume() }.labelStyle(.iconOnly).help("Resume audio")
            } else {
                Button("Pause", systemImage: "pause.fill") { live.pause() }.labelStyle(.iconOnly).help("Pause audio")
                    .disabled(live.phase != .active)
            }
            if let onMain {
                Button("Main Window", systemImage: "macwindow") { onMain() }.labelStyle(.iconOnly)
            }
            if let onCompact {
                Button("Compact Bar", systemImage: "rectangle.compress.vertical") { onCompact() }.labelStyle(.iconOnly)
            }
            if let onHide {
                Button("Hide Panel", systemImage: "eye.slash") { onHide() }.labelStyle(.iconOnly)
            }
            Button("End Session", role: .destructive) { live.end() }
                .disabled(live.phase == .ending)
                .accessibilityIdentifier("endSession")
        }
        .buttonStyle(.borderless)
        .padding(floating ? 12 : 18)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Button(live.enabled.contains(.microphone) ? "Disable Microphone" : "Enable Microphone") { live.toggle(.microphone) }
                    Button(live.enabled.contains(.meeting) ? "Disable Meeting Audio" : "Enable Meeting Audio") { live.toggle(.meeting) }
                    Divider()
                    SettingsLink(label: "Microphone Settings", pane: "Privacy_Microphone")
                    SettingsLink(label: "System Audio Settings", pane: "Privacy_ScreenCapture")
                    SettingsLink(label: "Speech Recognition Settings", pane: "Privacy_SpeechRecognition")
                } label: {
                    Label("Audio sources", systemImage: "waveform")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding([.horizontal, .top], 13)
            ForEach([AudioSource.microphone, .meeting]) { source in
                if live.enabled.contains(source) || live.audioErrors[source] != nil {
                    HStack(spacing: 6) {
                        Text(source.rawValue).font(.caption)
                        if live.starting.contains(source) {
                            ProgressView().controlSize(.mini)
                        } else if live.activeSources.contains(source) {
                            ProgressView(value: min(1, Double(live.levels[source] ?? 0) * 12)).frame(maxWidth: 95)
                                .accessibilityLabel("\(source.rawValue) audio level")
                        }
                        Spacer()
                        if live.audioErrors[source] != nil && live.enabled.contains(source) && live.phase == .active {
                            Button("Retry") { live.retry(source) }.font(.caption)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 3)
                    if let error = live.audioErrors[source] {
                        Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 13)
                    }
                }
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        let lines = live.record?.transcript.suffix(240) ?? []
                        if lines.isEmpty && live.partial.isEmpty {
                            Text(live.enabled.isEmpty ? "Turn on audio to see the transcript." : "The transcript will appear as people speak.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(lines) { line in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(line.timestamp) · \(line.source.rawValue)\(line.provisional == true ? " · Unfinalized" : "")")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(line.text).textSelection(.enabled)
                            }
                            .contextMenu {
                                Button("Answer This") { live.answer(line) }.disabled(!live.canAnswer)
                            }
                        }
                        ForEach([AudioSource.microphone, .meeting]) { source in
                            if let text = live.partial[source], !text.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.rawValue + " · Live").font(.caption).foregroundStyle(.secondary)
                                    Text(text).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("latest-transcript")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                }
                .onChange(of: live.record?.transcript.count) { scroll.scrollTo("latest-transcript", anchor: .bottom) }
                .onChange(of: live.partial) { scroll.scrollTo("latest-transcript", anchor: .bottom) }
            }
        }
        .background(.quaternary.opacity(0.25))
    }

    private var answers: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(live.options.practice ? "Practice" : "Answer").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if live.currentProvider.provider != .disabled {
                    Text(live.currentProvider.provider.shortName).font(.caption).foregroundStyle(.secondary)
                }
                if !live.options.practice {
                    Toggle("Auto", isOn: $live.automatic).toggleStyle(.switch).controlSize(.mini)
                        .help("Suggest answers to likely questions in meeting audio")
                        .disabled(!live.canAnswer || !live.options.allowCloud)
                }
                Menu {
                    Picker("Length", selection: $live.length) {
                        ForEach(AnswerLength.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("Regenerate") { live.regenerate() }.disabled(live.question.isEmpty)
                    Button("Technical Explanation") { live.technicalAnswer() }.disabled(live.question.isEmpty)
                    if let backup = live.backup { Button("Use \(backup.shortName)") { live.useBackup() } }
                } label: {
                    Label("Answer options", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(13)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    if !live.question.isEmpty && !live.options.practice {
                        Text(live.question).font(.callout.weight(.semibold)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !live.practiceQuestion.isEmpty {
                        Text(live.practiceQuestion).font(.headline).textSelection(.enabled)
                    }
                    if live.generating && live.answer.isEmpty {
                        ProgressView("Waiting for first text…").controlSize(.small)
                    }
                    if !live.answer.isEmpty {
                        AnswerText(text: live.answer, size: floating ? overlay.fontSize : 17)
                            .accessibilityIdentifier("streamedAnswer")
                    } else if !live.generating && live.answerError == nil {
                        Text(live.canAnswer ? "Ask a question or press ⌘↩ to answer the latest meeting question." : "Choose an answer provider in Providers before starting a session to generate suggestions.")
                            .foregroundStyle(.secondary)
                    }
                    if let error = live.answerError {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                        if !live.question.isEmpty {
                            Button("Retry Answer") { live.regenerate() }
                        }
                    }
                    if live.options.practice && !live.generating {
                        HStack {
                            Button("Next Question") { live.nextPracticeQuestion() }.disabled(!live.canAnswer)
                            Button("Review Spoken Answer") { live.reviewSpokenPracticeAnswer() }.disabled(live.practiceQuestion.isEmpty)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
            }
            if let timing = live.timing {
                HStack(spacing: 8) {
                    if let delay = timing.firstTokenDelay { Text(String(format: "First text %.2fs", delay)) }
                    if let duration = timing.requestDuration { Text(String(format: "Total %.2fs", duration)) }
                    if let delay = live.transcriptionDelay { Text(String(format: "Speech %.2fs", delay)) }
                    if let tokens = live.usage.output { Text("\(tokens) output tokens") }
                    Spacer(minLength: 0)
                    if live.generating { Button("Cancel") { live.cancelAnswer() } }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding([.horizontal, .bottom], 8)
            }
            Divider()
            SessionComposer(live: live)
        }
    }
}

private struct AnswerText: View {
    let text: String
    let size: Double

    var body: some View {
        let parts = text.components(separatedBy: "\n### Details")
        VStack(alignment: .leading, spacing: 10) {
            markdown(parts.first ?? text)
            if parts.count > 1 {
                DisclosureGroup("Details") { markdown(parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
    }

    private func markdown(_ content: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: content, options: options)) ?? AttributedString(content))
            .font(.system(size: size))
            .textSelection(.enabled)
            .lineSpacing(4)
    }
}

private struct SessionComposer: View {
    @Bindable var live: LiveSession
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let capture = live.captureImage, let preview = NSImage(data: capture.data) {
                HStack(spacing: 10) {
                    Image(nsImage: preview).resizable().scaledToFit().frame(width: 104, height: 64)
                        .accessibilityLabel("Selected image preview")
                    Text("Review this image before sending it to \(live.currentProvider.provider.shortName).")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Image", systemImage: "xmark.circle") { live.discardImage() }
                        .labelStyle(.iconOnly)
                }
            }
            if let error = live.captureError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Capture a Window") { live.pickWindow() }
                    Button("Choose an Image…") { importing = true }
                } label: {
                    Label("Capture", systemImage: "viewfinder").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Capture a window or attach an image. Requires cloud approval.")
                .accessibilityIdentifier("captureMenu")
                .disabled(!live.canAnswer || !live.options.allowCloud)
                TextField(live.options.practice ? "Type your practice answer" : "Ask a question", text: $live.composer, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("questionComposer")
                Button(live.captureImage == nil ? "Send" : "Send Image", systemImage: "arrow.up.circle.fill") { live.askComposer() }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("sendQuestion")
                    .disabled(!live.canAnswer)
                    .help("Send or answer the latest question (⌘↩)")
            }
        }
        .padding(10)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .jpeg, .heic, .tiff]) { result in
            switch result {
            case .success(let url): live.attachImage(url)
            case .failure(let error): live.captureError = error.localizedDescription
            }
        }
    }
}
