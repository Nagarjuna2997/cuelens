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
    var opacityController: FloatingWindow?
    var model: AppModel?

    @State private var showTranscript = true
    @State private var showTypes = true
    @State private var showPins = false
    @State private var showKeys = false

    private var docked: Bool { !floating || overlay.transcriptLayout != .floating }
    private var responsePlacement: ResponsePlacement { overlay.responsePlacement ?? .transcript }
    private var isTranscriptVisible: Bool { docked ? showTranscript : opacityController?.showSeparateTranscript == true }
    private var typesVisible: Bool { docked ? showTypes : opacityController?.showSeparateResponseTypes == true }

    var body: some View {
        VStack(spacing: 0) {
            if live.resourceCondition.reducesWork {
                Label("Resource pressure · Automatic answers are paused.", systemImage: "gauge.with.needle")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
                Divider()
            }
            HSplitView {
                if docked && showTranscript {
                    TranscriptColumn(live: live, dragging: floating, showTypes: typesVisible && responsePlacement == .transcript,
                                     hide: { showTranscript = false })
                        .frame(minWidth: 180, idealWidth: 225, maxWidth: 380, maxHeight: .infinity)
                        .layoutPriority(0)
                }
                answers
                    .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
            Divider()
            SessionComposer(live: live)
        }
        .background {
            if floating {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }

    private var answers: some View {
        VStack(alignment: .leading, spacing: 0) {
            answerToolbar
            Divider()
            if showPins { pinnedPanel }
            if typesVisible && (!isTranscriptVisible || responsePlacement == .answers) && !live.options.practice {
                ResponseTypeStrip(live: live)
            }
            ViewThatFits(in: .vertical) {
                if live.answer.isEmpty, !live.generating, live.answerError == nil, live.practiceQuestion.isEmpty {
                    emptyAnswer.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    responseBody
                }
            }
            if let timing = live.timing {
                HStack(spacing: 9) {
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
        }
    }

    private var answerToolbar: some View {
        HStack(spacing: 10) {
            if floating && (!docked || !showTranscript) { PanelDragGrip().frame(width: 18, height: 24) }
            Text(live.options.practice ? "Practice" : "AI Response")
                .font(.subheadline.weight(.medium))
                .accessibilityAddTraits(.isHeader)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !live.options.practice {
                icon(typesVisible ? "Hide Response Types" : "Show Response Types", systemImage: "list.bullet") {
                    if docked { showTypes.toggle() }
                    else { opacityController?.showSeparateResponseTypes.toggle() }
                }
            }
            icon(isTranscriptVisible ? "Hide Transcript" : "Show Transcript", systemImage: "text.bubble") {
                if docked { showTranscript.toggle() }
                else { opacityController?.toggleSeparateTranscript() }
            }
            icon(showPins ? "Hide Pinned Responses" : "Show Pinned Responses", systemImage: "pin") { showPins.toggle() }
            Button("Keyboard Shortcuts", systemImage: "command") { showKeys.toggle() }
                .labelStyle(.iconOnly).help("Keyboard shortcuts")
                .popover(isPresented: $showKeys, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Answer or send", value: "⌘↩ or ⌃N")
                        LabeledContent("Show or hide panel", value: "⌘⌥" + overlay.shortcut.uppercased())
                        if let key = overlay.emergencyShortcut {
                            LabeledContent("Stop audio and hide", value: "⌘⌥" + key.uppercased())
                        }
                    }.padding(15).frame(width: 255)
                }
            icon("Previous Response", systemImage: "chevron.left") { live.stepResponse(-1) }.disabled(!live.canStepBack)
            icon("Next Response", systemImage: "chevron.right") { live.stepResponse(1) }.disabled(!live.canStepForward)
            answerOptions
            if let opacityController, let model { PanelOpacityControl(controller: opacityController, model: model) }
            if let onCompact {
                Button("Minimize", systemImage: "arrow.down.right.and.arrow.up.left") { onCompact() }
                    .help("Minimize to the floating bar")
                    .accessibilityIdentifier("minimizeSession")
            } else {
                Button(live.phase == .paused ? "Resume" : "Pause", systemImage: live.phase == .paused ? "play.fill" : "pause.fill") {
                    if live.phase == .paused { live.resume() } else { live.pause() }
                }.labelStyle(.iconOnly)
                Button("End Session", role: .destructive) { live.end() }
                    .disabled(live.phase == .ending).accessibilityIdentifier("endSession")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var answerOptions: some View {
        Menu {
            Picker("Length", selection: $live.length) {
                ForEach(AnswerLength.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Automatic Suggestions", isOn: $live.automatic).disabled(!live.canAnswer || !live.options.allowCloud)
            Button("Regenerate") { live.regenerate() }.disabled(live.question.isEmpty)
            Button("Technical Explanation") { live.technicalAnswer() }.disabled(live.question.isEmpty)
            if let backup = live.backup { Button("Use \(backup.shortName)") { live.useBackup() } }
            if floating {
                Divider()
                Button(live.phase == .paused ? "Resume Audio" : "Pause Audio") {
                    if live.phase == .paused { live.resume() } else { live.pause() }
                }
                if let onMain { Button("Main Window", action: onMain) }
                if let onHide { Button("Hide Panel", action: onHide) }
                Button("End Session", role: .destructive) { live.end() }.disabled(live.phase == .ending)
            }
        } label: {
            Label("Session Options", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }.menuStyle(.borderlessButton).fixedSize()
    }

    private var pinnedPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Pinned Responses", systemImage: "pin").font(.caption.weight(.semibold))
                Spacer()
                if live.responseIndex != nil {
                    Button(live.isPinned ? "Unpin Current" : "Pin Current") { live.togglePin() }
                        .disabled(live.generating).controlSize(.small)
                }
            }
            if live.pinnedResponses.isEmpty {
                Text("Pin a completed response to return to it here.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(live.pinnedResponses) { item in
                            Button { live.showResponse(item.id) } label: {
                                Text(item.question).lineLimit(1)
                            }.buttonStyle(.link)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 65)
            }
            Divider()
        }.padding([.top, .horizontal], 12)
    }

    private var emptyAnswer: some View {
        VStack(spacing: 8) {
            if live.options.practice {
                Text("Start with a practice question.").foregroundStyle(.secondary)
                Button("Next Question") { live.nextPracticeQuestion() }
                    .disabled(!live.canAnswer || !live.options.allowCloud)
            } else if live.canAnswer && live.options.allowCloud {
                Text("Choose What should I say next, or press ⌘↩.")
                    .foregroundStyle(.secondary)
            } else {
                Text(live.canAnswer ? "Cloud answers are off for this session." : "Connect an answer provider in CueLens → Providers.")
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(20)
    }

    private var responseBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                if !live.question.isEmpty && !live.options.practice {
                    HStack(alignment: .firstTextBaseline) {
                        Text(live.question).font(.callout.weight(.semibold)).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if live.responseIndex != nil {
                            icon(live.isPinned ? "Unpin Response" : "Pin Response", systemImage: live.isPinned ? "pin.fill" : "pin") {
                                live.togglePin()
                            }
                        }
                    }
                }
                if !live.practiceQuestion.isEmpty {
                    Text(live.practiceQuestion).font(.headline).textSelection(.enabled)
                }
                if live.generating && live.answer.isEmpty { ProgressView("Waiting for first text…").controlSize(.small) }
                if !live.answer.isEmpty && (!live.options.practice || live.answer != live.practiceQuestion) {
                    AnswerText(text: live.answer, size: floating ? overlay.fontSize : 17)
                        .accessibilityIdentifier("streamedAnswer")
                }
                if let error = live.answerError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    if !live.question.isEmpty { Button("Retry Answer") { live.regenerate() } }
                }
                if live.options.practice && !live.generating {
                    HStack {
                        Button("Next Question") { live.nextPracticeQuestion() }.disabled(!live.canAnswer || !live.options.allowCloud)
                        Button("Review Spoken Answer") { live.reviewSpokenPracticeAnswer() }.disabled(live.practiceQuestion.isEmpty)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
        }
    }

    private func icon(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly).buttonStyle(.borderless).help(title)
    }
}

struct SeparateTranscriptPanel: View {
    let model: AppModel
    let controller: FloatingWindow

    var body: some View {
        TranscriptColumn(live: model.live, dragging: true,
                         showTypes: controller.showSeparateResponseTypes && model.workspace.overlay?.responsePlacement != .answers,
                         hide: { controller.toggleSeparateTranscript() })
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}

private struct TranscriptColumn: View {
    let live: LiveSession
    let dragging: Bool
    let showTypes: Bool
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if dragging { PanelDragGrip().frame(width: 18, height: 24) }
                Label(live.audioSourceLabel, systemImage: live.audioLive ? "waveform" : "circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(live.audioLive ? Color.accentColor : Color.secondary)
                    .accessibilityIdentifier("captureState")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button(live.enabled.contains(.microphone) ? "Disable Microphone" : "Enable Microphone") { live.toggle(.microphone) }
                    Button(live.enabled.contains(.meeting) ? "Disable Meeting Audio" : "Enable Meeting Audio") { live.toggle(.meeting) }
                    Divider()
                    SettingsLink(label: "Microphone Settings", pane: "Privacy_Microphone")
                    SettingsLink(label: "System Audio Settings", pane: "Privacy_ScreenCapture")
                    SettingsLink(label: "Speech Recognition Settings", pane: "Privacy_SpeechRecognition")
                } label: {
                    Label("Audio sources", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button("Hide Transcript", systemImage: "sidebar.left") { hide() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Hide transcript")
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            Divider()
            ForEach([AudioSource.microphone, .meeting]) { source in
                if live.starting.contains(source) || live.activeSources.contains(source) || live.audioErrors[source] != nil {
                    HStack(spacing: 7) {
                        Text(source.rawValue).font(.caption).lineLimit(1)
                        if live.starting.contains(source) { ProgressView().controlSize(.mini) }
                        if live.activeSources.contains(source) {
                            ProgressView(value: min(1, Double(live.levels[source] ?? 0) * 12))
                                .accessibilityLabel("\(source.rawValue) audio level")
                        }
                        Spacer(minLength: 0)
                        if live.audioErrors[source] != nil && live.enabled.contains(source) && live.phase == .active {
                            Button("Retry") { live.retry(source) }.font(.caption)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    if let error = live.audioErrors[source] {
                        Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }
                }
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 11) {
                        let lines = live.record?.transcript.suffix(240) ?? []
                        if lines.isEmpty && live.partial.isEmpty {
                            Text(live.enabled.isEmpty ? "Turn on audio to start the live transcript." : "The live transcript appears here as people speak.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(lines) { line in
                            transcriptRow(line)
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
                    .padding(12)
                }
                .onChange(of: live.record?.transcript.count) { scroll.scrollTo("latest-transcript", anchor: .bottom) }
                .onChange(of: live.partial) { scroll.scrollTo("latest-transcript", anchor: .bottom) }
            }
            if showTypes && !live.options.practice {
                ResponseTypeStrip(live: live)
            }
        }
        .background(.quaternary.opacity(0.28))
    }

    private func transcriptRow(_ line: TranscriptLine) -> some View {
        HStack(alignment: .top, spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(.quaternary).frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(line.timestamp) · \(line.source.rawValue)\(line.provisional == true ? " · Unfinalized" : "")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(line.text).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if live.canAnswer {
                Button("Answer this line", systemImage: "arrow.turn.down.right") { live.answer(line) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Answer this line")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contextMenu { Button("Answer This") { live.answer(line) }.disabled(!live.canAnswer) }
    }

}

private struct ResponseTypeStrip: View {
    let live: LiveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Response Types").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack {
                if let format = live.assistant?.format {
                    Button(format.rawValue) { live.answerWith(.responseType(format)) }
                        .buttonStyle(.bordered)
                }
                Menu("More") {
                    ForEach(AnswerFormat.allCases) { format in
                        Button(format.rawValue) { live.answerWith(.responseType(format)) }
                    }
                    if let custom = live.assistant?.customResponses, !custom.isEmpty {
                        Divider()
                        ForEach(custom) { response in
                            Button(response.name) { live.answerWith(.custom(response)) }
                        }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            .disabled(!live.canAnswer || !live.options.allowCloud)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
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

    private var sendLabel: String {
        if live.captureImage != nil { return "Solve Image" }
        if !live.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return live.options.practice ? "Review Answer" : "Ask CueLens"
        }
        return "What should I say next?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let capture = live.captureImage, let preview = NSImage(data: capture.data) {
                HStack(spacing: 10) {
                    Image(nsImage: preview).resizable().scaledToFit().frame(width: 104, height: 64)
                        .accessibilityLabel("Selected image preview")
                    Text("Review this image before sending it to \(live.currentProvider.provider.shortName).")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Image", systemImage: "xmark.circle") { live.discardImage() }.labelStyle(.iconOnly)
                }
            }
            if let error = live.captureError { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Menu {
                        Button("Capture a Window") { live.pickWindow() }
                        Button("Choose an Image…") { importing = true }
                    } label: {
                        Label("Capture", systemImage: "camera").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Capture a window or attach an image")
                    .accessibilityIdentifier("captureMenu")
                    .disabled(!live.canAnswer || !live.options.allowCloud)
                    TextField(live.options.practice ? "Type your practice answer" : "Type to ask CueLens…", text: $live.composer, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("questionComposer")
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary).allowsHitTesting(false) }
                Button(sendLabel) { live.askComposer() }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityIdentifier("sendQuestion")
                    .disabled(!live.canAnswer || !live.options.allowCloud)
                    .help("Send or answer the latest question (⌘↩ or ⌃N)")
            }
        }
        .padding(11)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .jpeg, .heic, .tiff]) { result in
            switch result {
            case .success(let url): live.attachImage(url)
            case .failure(let error): live.captureError = error.localizedDescription
            }
        }
    }
}
