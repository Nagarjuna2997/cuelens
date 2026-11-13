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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
            GeometryReader { geometry in
                let transcriptMaximum = max(160, min(320, geometry.size.width - 281))
                HSplitView {
                    if docked && showTranscript {
                        TranscriptColumn(live: live, dragging: floating, showTypes: typesVisible && responsePlacement == .transcript,
                                         hide: { showTranscript = false }, toggleAudio: toggleAudio)
                            .frame(minWidth: 160, idealWidth: min(210, transcriptMaximum), maxWidth: transcriptMaximum, maxHeight: .infinity)
                    }
                    answers
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            Divider()
            SessionComposer(live: live)
        }
        .background {
            if floating {
                Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : overlay.liveBackgroundOpacity)
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
        HStack(spacing: 8) {
            if floating && (!docked || !showTranscript) { PanelDragGrip().frame(width: 18, height: 24) }
            Text(live.options.practice ? "Practice" : "Response")
                .font(.subheadline.weight(.medium))
                .accessibilityAddTraits(.isHeader)
                .lineLimit(1)
            Spacer(minLength: 0)
            if floating, let model {
                icon("Camera Studio", systemImage: "video") { model.cameraWindow.show() }
            }
            Button(live.phase == .paused ? "Resume" : "Pause", systemImage: live.phase == .paused ? "play.fill" : "pause.fill") {
                if live.phase == .paused { live.resume() } else { live.pause() }
            }
            .labelStyle(.iconOnly)
            .help(live.phase == .paused ? "Resume session audio" : "Pause session audio")
            .accessibilityIdentifier("pauseSession")
            Button("End", systemImage: "stop.fill") {
                if let model { model.endSession() } else { live.end() }
            }.disabled(live.phase == .ending).accessibilityIdentifier("endSession")
            if let onCompact {
                Button("Minimize", systemImage: "arrow.down.right.and.arrow.up.left") { onCompact() }
                    .labelStyle(.iconOnly)
                    .help("Minimize to the floating bar")
                    .accessibilityIdentifier("minimizeSession")
            }
            answerOptions
            if let opacityController, let model { PanelQuickSettings(controller: opacityController, model: model) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var answerOptions: some View {
        Menu {
            Button(isTranscriptVisible ? "Hide Transcript" : "Show Transcript", systemImage: "text.bubble") {
                if docked { showTranscript.toggle() }
                else { opacityController?.toggleSeparateTranscript() }
            }
            if !live.options.practice {
                Button(typesVisible ? "Hide Response Types" : "Show Response Types", systemImage: "list.bullet") {
                    if docked { showTypes.toggle() }
                    else { opacityController?.showSeparateResponseTypes.toggle() }
                }
            }
            Button(showPins ? "Hide Pinned Responses" : "Show Pinned Responses", systemImage: "pin") { showPins.toggle() }
            Button("Previous Response", systemImage: "chevron.left") { live.stepResponse(-1) }.disabled(!live.canStepBack)
            Button("Next Response", systemImage: "chevron.right") { live.stepResponse(1) }.disabled(!live.canStepForward)
            Divider()
            Picker("Length", selection: $live.length) {
                ForEach(AnswerLength.allCases) { Text($0.rawValue).tag($0) }
            }
            if !live.options.practice {
                Toggle("Automatic Answers", isOn: $live.automatic).disabled(!live.canAnswer)
            }
            Button("Regenerate") { live.regenerate() }.disabled(live.question.isEmpty)
            if !live.options.practice {
                Button("Technical Explanation") { live.technicalAnswer() }.disabled(live.question.isEmpty)
            }
            if let backup = live.backup { Button("Use \(backup.shortName)") { live.useBackup() } }
            Divider()
            Button("Keyboard Shortcuts…", systemImage: "command") { showKeys = true }
            if floating {
                if let onMain { Button("Main Window", action: onMain) }
                if let onHide { Button("Hide Panel", action: onHide) }
            }
        } label: {
            Label("Session Options", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }.menuStyle(.borderlessButton).fixedSize()
            .help("Response and layout options")
            .accessibilityIdentifier("sessionOptions")
            .popover(isPresented: $showKeys, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Answer or send", value: "⌘C")
                    LabeledContent("Capture display", value: "⌘X")
                    Text("During a live session these replace Copy and Cut. Use the Edit menu or a response’s Copy button to copy text.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Show or hide panel", value: "⌘⌥" + overlay.shortcut.uppercased())
                    if let key = overlay.emergencyShortcut {
                        LabeledContent("Stop audio and hide", value: "⌘⌥" + key.uppercased())
                    }
                }.padding(15).frame(width: 255)
            }
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
                    .disabled(!live.canAnswer)
            } else if live.canAnswer {
                Text("Press ⌘C for the latest question.\nCapture a coding problem with ⌘X.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Connect OpenAI, Claude, or Gemini in Providers to generate answers.")
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
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("streamedAnswer")
                }
                if let error = live.answerError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    if !live.question.isEmpty { Button("Retry Answer") { live.regenerate() } }
                }
                if live.options.practice && !live.generating {
                    if let metrics = live.practiceMetrics { PracticeMetricsView(metrics: metrics) }
                    HStack {
                        Button("Try Again") { live.retryPracticeAnswer() }.disabled(live.practiceQuestion.isEmpty)
                        if live.options.practiceHints {
                            Button("Hint") { live.requestPracticeHint() }.disabled(live.practiceQuestion.isEmpty)
                        }
                        if !live.practiceAttempts.isEmpty, live.practiceAttempts.last?.nextReview == nil {
                            Button("Review Tomorrow") { live.schedulePracticeReview() }
                        }
                    }
                    if let review = live.practiceAttempts.last?.nextReview {
                        Label("Review scheduled \(review.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Next Question") { live.nextPracticeQuestion() }.disabled(!live.canAnswer)
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

    private func toggleAudio(_ source: AudioSource) {
        if let model { model.toggleSessionAudio(source) }
        else { live.toggle(source) }
    }
}

struct SeparateTranscriptPanel: View {
    let model: AppModel
    let controller: FloatingWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        TranscriptColumn(live: model.live, dragging: true,
                         showTypes: controller.showSeparateResponseTypes && model.workspace.overlay?.responsePlacement != .answers,
                         hide: { controller.toggleSeparateTranscript() }, toggleAudio: model.toggleSessionAudio)
            .background(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : (model.workspace.overlay ?? OverlayPreferences()).liveBackgroundOpacity))
            .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}

private struct TranscriptColumn: View {
    let live: LiveSession
    let dragging: Bool
    let showTypes: Bool
    let hide: () -> Void
    let toggleAudio: (AudioSource) -> Void

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
                    Button(live.enabled.contains(.microphone) ? "Disable Microphone" : "Enable Microphone") { toggleAudio(.microphone) }
                    Button(live.enabled.contains(.meeting) ? "Disable Meeting Audio" : "Enable Meeting Audio") { toggleAudio(.meeting) }
                    if live.activeSources.contains(.microphone) {
                        Button("Microphone Effects…") { Microphone.showSystemModes() }
                    }
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
            Text(live.speechProvider.rawValue).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6)
            ForEach([AudioSource.microphone, .meeting]) { source in
                if live.starting.contains(source) || live.activeSources.contains(source) || live.audioErrors[source] != nil {
                    HStack(spacing: 7) {
                        Text(source.rawValue).font(.caption).lineLimit(1)
                        if live.starting.contains(source) { ProgressView().controlSize(.mini) }
                        if live.activeSources.contains(source) {
                            ProgressView(value: min(1, Double(live.levels[source] ?? 0) * 12))
                                .accessibilityLabel("\(source.rawValue) audio level")
                        }
                        if live.speechQueuedSources.contains(source) {
                            Text("Queued").font(.caption2).foregroundStyle(.secondary)
                                .help("Speech is buffered while another audio source is transcribed.")
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
            Menu {
                ForEach(AnswerFormat.allCases) { format in
                    Button(format.rawValue) { live.answerWith(.responseType(format)) }
                }
                if let custom = live.assistant?.customResponses, !custom.isEmpty {
                    Divider()
                    ForEach(custom) { response in
                        Button(response.name) { live.answerWith(.custom(response)) }
                    }
                }
            } label: {
                Text(live.assistant?.format.rawValue ?? "Choose a format").lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .disabled(!live.canAnswer)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

}

enum AnswerMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(marker: String, depth: Int, text: String)
    case quote(String)
    case code(language: String, text: String)
    case divider
}

enum AnswerMarkdown {
    static func blocks(in content: String) -> [AnswerMarkdownBlock] {
        var result = [AnswerMarkdownBlock]()
        var paragraph = [String]()
        var code = [String]()
        var fence: (character: Character, count: Int, language: String)?
        var continuesList = false

        func flushParagraph() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                let closing = trimmed.prefix { $0 == active.character }
                if closing.count >= active.count && trimmed.dropFirst(closing.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(.code(language: active.language, text: code.joined(separator: "\n")))
                    code.removeAll(keepingCapacity: true)
                    fence = nil
                } else {
                    code.append(line)
                }
                continue
            }
            if let character = trimmed.first, character == "`" || character == "~" {
                let opening = trimmed.prefix { $0 == character }
                if opening.count >= 3 {
                    flushParagraph()
                    fence = (character, opening.count, trimmed.dropFirst(opening.count).trimmingCharacters(in: .whitespaces))
                    continuesList = false
                    continue
                }
            }
            if trimmed.isEmpty {
                flushParagraph()
                continuesList = false
                continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), let next = trimmed.dropFirst(hashes).first, next.isWhitespace {
                flushParagraph()
                var title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                let trailingHashes = title.reversed().prefix { $0 == "#" }.count
                if trailingHashes > 0, let prior = title.dropLast(trailingHashes).last, prior.isWhitespace {
                    title = title.dropLast(trailingHashes).trimmingCharacters(in: .whitespaces)
                }
                result.append(.heading(level: hashes, text: title))
                continuesList = false
                continue
            }
            let compact = trimmed.filter { !$0.isWhitespace }
            if compact.count >= 3, let first = compact.first, "-*_".contains(first), compact.allSatisfy({ $0 == first }) {
                flushParagraph()
                result.append(.divider)
                continuesList = false
                continue
            }
            if trimmed.first == ">" {
                flushParagraph()
                result.append(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
                continuesList = false
                continue
            }
            let indentation = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let item = listItem(trimmed) {
                flushParagraph()
                result.append(.listItem(marker: item.marker, depth: min(4, indentation / 2), text: item.text))
                continuesList = true
                continue
            }
            if continuesList, case let .listItem(marker, depth, text) = result.last, indentation > depth * 2 {
                result[result.count - 1] = .listItem(marker: marker, depth: depth, text: text + " " + trimmed)
            } else {
                paragraph.append(trimmed)
                continuesList = false
            }
        }
        flushParagraph()
        // Keep an incomplete streaming fence in its code block, including its
        // indentation and any Markdown-like source comments.
        if let fence { result.append(.code(language: fence.language, text: code.joined(separator: "\n"))) }
        return result
    }

    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first?.isWhitespace == true {
            return ("•", line.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let suffix = line.dropFirst(digits.count)
        guard let delimiter = suffix.first, delimiter == "." || delimiter == ")", suffix.dropFirst().first?.isWhitespace == true else { return nil }
        return (String(digits) + ".", suffix.dropFirst().trimmingCharacters(in: .whitespaces))
    }
}

private struct AnswerText: View {
    let text: String
    let size: Double
    @State private var copied = false

    var body: some View {
        let blocks = AnswerMarkdown.blocks(in: text)
        let detailsIndex = blocks.firstIndex { block in
            if case let .heading(level, title) = block { return level == 3 && title == "Details" }
            return false
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy Response", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(text, forType: .string)
                }.buttonStyle(.borderless).font(.caption).accessibilityIdentifier("copyResponse")
            }
            markdown(Array(blocks.prefix(detailsIndex ?? blocks.count)))
            if let detailsIndex {
                DisclosureGroup("Details") { markdown(Array(blocks.dropFirst(detailsIndex + 1))) }
            }
        }
        .onChange(of: text) { copied = false }
    }

    private func markdown(_ blocks: [AnswerMarkdownBlock]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .code(language, text):
                    AnswerCodeBlock(code: text, language: language, size: size)
                case let .heading(level, text):
                    inline(text)
                        .font(.system(size: size + (level == 1 ? 6 : level == 2 ? 3 : 1), weight: .semibold))
                        .padding(.top, 5)
                        .accessibilityAddTraits(.isHeader)
                case let .paragraph(text):
                    prose(text)
                case let .listItem(marker, depth, text):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(marker).font(.system(size: size).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: marker == "•" ? 12 : 20, alignment: .trailing)
                        prose(text)
                    }.padding(.leading, CGFloat(depth) * 14)
                case let .quote(text):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.4)).frame(width: 3)
                        prose(text).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                case .divider:
                    Divider().padding(.vertical, 3)
                }
            }
        }
    }

    private func inline(_ content: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: content, options: options)) ?? AttributedString(content))
    }

    private func prose(_ content: String) -> some View {
        inline(content)
            .font(.system(size: size))
            .textSelection(.enabled)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnswerCodeBlock: View {
    let code: String
    let language: String
    let size: Double
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(code, forType: .string)
                }.buttonStyle(.borderless).font(.caption)
            }.padding(10)
            Divider()
            ScrollView(.horizontal) {
                Text(code).font(.system(size: max(12, size - 2), design: .monospaced))
                    .textSelection(.enabled).lineSpacing(3)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary) }
        .onChange(of: code) { copied = false }
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
        return "Answer"
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
            if live.capturing { ProgressView("Capturing display…").controlSize(.small) }
            if let error = live.captureError { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Menu {
                        Button("Capture Full Display · ⌘X") { live.captureScreen() }
                        Button("Capture a Window") { live.pickWindow() }
                        Button("Choose an Image…") { importing = true }
                    } label: {
                        Label("Capture", systemImage: "camera").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Capture the display under the pointer (⌘X), a window, or an image")
                    .accessibilityIdentifier("captureMenu")
                    .disabled(!live.canCapture || live.capturing)
                    TextField(live.options.practice ? "Type your practice answer" : "Type to ask CueLens…", text: $live.composer, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .accessibilityIdentifier("questionComposer")
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary).allowsHitTesting(false) }
                Button { live.askComposer() } label: {
                    ViewThatFits(in: .horizontal) {
                        Text(sendLabel).fixedSize()
                        Image(systemName: "arrow.up")
                    }.frame(maxWidth: 120)
                }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityLabel(sendLabel)
                    .accessibilityIdentifier("sendQuestion")
                    .disabled(!live.canAnswer)
                    .help("Send or answer the latest question (⌘C)")
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
