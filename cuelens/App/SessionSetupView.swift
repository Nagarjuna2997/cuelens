import AVFoundation
import SwiftUI

struct SessionSetupView: View {
    @Bindable var model: AppModel
    var practice = false
    @State private var options = SessionOptions()
    @State private var check = AudioCheck()
    @State private var inputs = [Microphone]()
    @State private var microphoneID: String?
    @State private var showFloating = false
    @State private var editing: AssistantProfile?

    private var assistant: AssistantProfile? {
        model.activeAssistants.first { $0.id == model.selectedAssistantID }
    }
    private var provider: ProviderSelection? {
        assistant.map { model.preferences.answerSelection(for: $0) }
    }
    private var audioSources: [AudioSource] {
        [(AudioSource.microphone, options.microphone), (.meeting, options.meetingAudio)].compactMap { $0.1 ? $0.0 : nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Label(practice ? "PRACTICE STUDIO" : "CONVERSATION STUDIO", systemImage: practice ? "graduationcap" : "waveform")
                            .font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(CueStyle.accent)
                        Spacer()
                        Button("New Assistant", systemImage: "plus") { editing = AssistantProfile() }
                            .buttonStyle(.borderless).font(.caption)
                            .accessibilityIdentifier("newAssistant")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(practice ? "Make your next answer\nbetter than your last." : "Your space to\nthink clearly.")
                            .font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(practice ? "A role, a question, and room to improve." : "Set your context. Check your frame. Join the conversation.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    CueCard {
                        sectionLabel("01", "Your context")
                        Picker("Assistant", selection: $model.selectedAssistantID) {
                            Text("Choose a role").tag(Optional<UUID>.none)
                            ForEach(model.activeAssistants) { Text($0.name).tag(Optional($0.id)) }
                        }.labelsHidden().controlSize(.large).accessibilityLabel("Assistant")
                        if let assistant {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(assistant.jobTitle.isEmpty ? assistant.kind.rawValue : assistant.jobTitle)
                                        .font(.callout.weight(.medium))
                                    Text(assistant.knowledge.isEmpty ? "Add a résumé or start with a blank slate." : "\(assistant.knowledge.count) document\(assistant.knowledge.count == 1 ? "" : "s") ready for this role")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Button("Edit & documents", systemImage: "doc.badge.plus") { editing = assistant }
                                    .font(.caption).buttonStyle(.borderless)
                            }
                            ForEach(Array(assistant.knowledge.prefix(3))) { file in
                                Label(file.name, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } else {
                            Text("A role keeps your documents and practice progress together. Everything is optional.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if options.practice {
                            Divider()
                            Picker("Interview style", selection: $options.practiceStyle) {
                                ForEach(PracticeStyle.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Toggle("Show practice hints", isOn: $options.practiceHints)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("02", "Listen & capture")
                        HStack(alignment: .top, spacing: 10) {
                            audioTile("Microphone", detail: "Your voice", icon: "mic", enabled: $options.microphone, identifier: "microphoneToggle")
                            audioTile("Meeting audio", detail: "Sound from your Mac", icon: "waveform", enabled: $options.meetingAudio, identifier: "meetingAudioToggle")
                        }
                        Toggle("Save an audio recording", isOn: $options.saveAudio)
                            .onChange(of: options.saveAudio) { if options.saveAudio { options.save = true } }
                        Toggle("Enable screen context", isOn: $options.screenContext)
                            .help("⌘X captures a display locally. Answer sends the attached image to your provider.")
                        Text(options.saveAudio ? "Audio and transcript will be saved on this Mac." : "Recording is off. You control what is captured and saved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    CueCard {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkle").font(.title2).foregroundStyle(CueStyle.accent)
                                .frame(width: 36, height: 36).background(CueStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider?.provider.shortName ?? "Connect your AI").font(.headline)
                                Text(provider?.model ?? "OpenAI, Claude, or Gemini").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button("Connect", systemImage: "arrow.up.right") { model.selection = .providers }
                                .buttonStyle(.borderless).font(.callout)
                        }
                        if let provider, provider.provider != .disabled {
                            Text("Answer sends your question, recent transcript, relevant documents, and attached image to \(provider.provider.shortName).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("Session preferences") {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Open in the compact window", isOn: $showFloating)
                            if !practice { Toggle("Mock interview practice", isOn: $options.practice) }
                            if !options.practice { Toggle("Answer meeting questions automatically", isOn: $options.automaticAnswers) }
                            Toggle("Save transcript and answers", isOn: $options.save)
                            TextField("Session title (optional)", text: $options.title).textFieldStyle(.roundedBorder)
                            Divider()
                            Picker("Microphone input", selection: $microphoneID) {
                                Text("System default").tag(Optional<String>.none)
                                ForEach(inputs) { Text($0.name).tag(Optional($0.id)) }
                            }
                            if model.preferences.speechProvider == .openAI {
                                Toggle("Use OpenAI Realtime transcription", isOn: $options.allowCloud)
                                Text(options.allowCloud ? "Enabled audio sources are sent to OpenAI." : "Speech recognition stays on this Mac.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Speech recognition stays on this Mac.").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(check.testing ? "Stop Audio Check" : "Test Audio") {
                                    if check.testing { check.stop() }
                                    else { check.run(sources: audioSources, microphoneID: microphoneID) }
                                }.disabled(audioSources.isEmpty && !check.testing)
                                Spacer()
                                Menu("Permissions") {
                                    SettingsLink(label: "Microphone", pane: "Privacy_Microphone")
                                    SettingsLink(label: "Screen & System Audio", pane: "Privacy_ScreenCapture")
                                    SettingsLink(label: "Speech Recognition", pane: "Privacy_SpeechRecognition")
                                }
                            }
                            ForEach(audioSources.filter { check.attempted.contains($0) }) { source in
                                if let error = check.errors[source] { Text(error).font(.caption).foregroundStyle(.secondary) }
                                else {
                                    LabeledContent(source.rawValue) {
                                        if check.testing { ProgressView(value: min(1, Double(check.levels[source] ?? 0) * 12)).frame(width: 100) }
                                        else { Text(check.heard.contains(source) ? "Signal detected" : "No signal detected") }
                                    }
                                }
                            }
                        }.padding(.top, 14)
                    }.font(.callout)
                }.padding(26)
            }
            Divider().overlay(.white.opacity(0.03))
            HStack(spacing: 12) {
                if model.live.pendingSave != nil {
                    Button("Retry Saving Previous Session") { model.live.retrySave() }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ready when you are").font(.caption.weight(.medium))
                        Text("⌘X Capture   ⌘C Answer").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button(options.practice ? "Start Practice" : "Start Session", systemImage: "arrow.right", action: start)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("startSession")
                    .disabled(check.testing || model.live.pendingSave != nil)
            }.padding(20).background(CueStyle.surface)
        }
        .background(CueStyle.canvas)
        .onAppear {
            inputs = Microphone.available()
            microphoneID = model.preferences.microphoneID
            options.microphone = model.preferences.sessionMicrophone ?? true
            options.meetingAudio = practice ? false : (model.preferences.sessionMeetingAudio ?? true)
            if assistant == nil { model.selectedAssistantID = model.activeAssistants.first?.id }
            refreshAssistant()
        }
        .onChange(of: model.selectedAssistantID) { refreshAssistant() }
        .onChange(of: options.save) { if !options.save { options.saveAudio = false } }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in inputs = Microphone.available() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in inputs = Microphone.available() }
        .onDisappear { check.stop() }
        .sheet(item: $editing) { AssistantEditor(profile: $0, model: model) }
    }

    private func sectionLabel(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(CueStyle.accent)
                .frame(width: 23, height: 23).background(CueStyle.accent.opacity(0.1), in: Circle())
            Text(title).font(.callout.weight(.semibold))
        }
    }

    private func audioTile(_ title: String, detail: String, icon: String, enabled: Binding<Bool>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).font(.title3).foregroundStyle(enabled.wrappedValue ? CueStyle.accent : .secondary)
                Spacer()
                Toggle(title, isOn: enabled).labelsHidden().toggleStyle(.checkbox)
                    .accessibilityLabel(title).accessibilityIdentifier(identifier)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(enabled.wrappedValue ? CueStyle.accent.opacity(0.045) : CueStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(enabled.wrappedValue ? CueStyle.accent.opacity(0.32) : Color.white.opacity(0.07)))
    }

    private func refreshAssistant() {
        options.save = assistant?.retainSession ?? true
        options.saveAudio = false
        options.practice = practice || assistant?.kind == .mockInterview
    }

    private func start() {
        var selected = assistant
        if selected == nil {
            let profile = AssistantProfile(name: options.practice ? "General practice" : "General conversation")
            guard model.saveAssistant(profile) else { return }
            model.selectedAssistantID = profile.id
            selected = profile
        }
        guard let selected else { return }
        var preferences = model.preferences
        preferences.microphoneID = microphoneID
        preferences.sessionMicrophone = options.microphone
        preferences.sessionMeetingAudio = options.meetingAudio
        if preferences != model.preferences { model.savePreferences(preferences) }
        model.live.start(assistant: selected, settings: preferences, options: options)
        model.overlay.register()
        if showFloating {
            model.overlay.show()
            model.minimizeMainWindow()
        } else { model.overlay.hide() }
    }
}

struct SettingsLink: View {
    let label: String
    let pane: String
    var body: some View {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            Link(label, destination: url)
        }
    }
}
