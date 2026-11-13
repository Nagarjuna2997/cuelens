import AVFoundation
import SwiftUI

struct SessionSetupView: View {
    @Bindable var model: AppModel
    @State private var options = SessionOptions()
    @State private var check = AudioCheck()
    @State private var inputs = [Microphone]()
    @State private var microphoneID: String?
    @State private var showFloating = true

    private var assistant: AssistantProfile? {
        model.activeAssistants.first { $0.id == model.selectedAssistantID }
    }

    private var answerSelection: ProviderSelection? {
        assistant.map { model.preferences.answerSelection(for: $0) }
    }

    private var cloudHosts: [String] {
        var hosts = Set<String>()
        if let provider = answerSelection?.provider, provider != .disabled {
            hosts.insert(provider.shortName)
            if let backup = model.preferences.backupProvider { hosts.insert(backup.shortName) }
        }
        if model.preferences.speechProvider == .openAI { hosts.insert("OpenAI") }
        return hosts.sorted()
    }

    private var audioSources: [AudioSource] {
        [(AudioSource.microphone, options.microphone), (.meeting, options.meetingAudio)].compactMap { $0.1 ? $0.0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Session Setup", subtitle: "Choose an assistant, check your audio, then start when you’re ready.")
                .padding([.top, .horizontal], 30)
                .padding(.bottom, 12)
            if model.live.pendingSave != nil {
                CueCard {
                    Text("The previous session is still waiting to save.")
                    Button("Retry Saving") { model.live.retrySave() }
                }.padding()
            }
            if model.activeAssistants.isEmpty {
                CueCard {
                    Text("Create an assistant to set up a session.")
                    Button("Open Assistants") { model.selection = .assistants }
                }.padding(30)
            } else {
                settingsForm
                Divider()
                HStack(spacing: 12) {
                    Text(options.practice ? "Practice can use a typed or spoken answer." : "Use CueLens with participant consent and follow your meeting or assessment rules.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(options.practice ? "Start Practice" : "Start Session", systemImage: "play.fill") { start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("startSession")
                        .disabled(assistant == nil || check.testing || model.live.pendingSave != nil)
                }
                .padding(18)
            }
        }
        .onAppear {
            inputs = Microphone.available()
            microphoneID = model.preferences.microphoneID
            if assistant == nil { model.selectedAssistantID = model.activeAssistants.first?.id }
            refreshAssistant()
        }
        .onChange(of: model.selectedAssistantID) { refreshAssistant() }
        .onChange(of: options.save) { if !options.save { options.saveAudio = false } }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in inputs = Microphone.available() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in inputs = Microphone.available() }
        .onDisappear { check.stop() }
    }

    private var settingsForm: some View {
        Form {
            Section("Assistant") {
                Picker("Assistant", selection: $model.selectedAssistantID) {
                    ForEach(model.activeAssistants) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("Session title", text: $options.title, prompt: Text("Use assistant name"))
                Toggle("Mock interview practice", isOn: $options.practice)
            }
            Section("Audio") {
                Toggle("Microphone", isOn: $options.microphone)
                    .accessibilityIdentifier("microphoneToggle")
                if options.microphone {
                    Picker("Microphone input", selection: $microphoneID) {
                        Text("System default").tag(Optional<String>.none)
                        ForEach(inputs) { Text($0.name).tag(Optional($0.id)) }
                        if let microphoneID, !inputs.contains(where: { $0.id == microphoneID }) {
                            Text("Disconnected input").tag(Optional(microphoneID))
                        }
                    }
                }
                Toggle("Meeting audio from this Mac", isOn: $options.meetingAudio)
                    .accessibilityIdentifier("meetingAudioToggle")
                LabeledContent("Speech to text", value: model.preferences.speechProvider.rawValue)
                if options.meetingAudio && options.microphone {
                    Text("Use headphones to reduce meeting audio picked up by your microphone.").foregroundStyle(.secondary)
                }
                HStack {
                    Button(check.testing ? "Stop Audio Check" : "Test Audio Sources") {
                        if check.testing { check.stop() }
                        else { check.run(sources: audioSources, microphoneID: microphoneID) }
                    }
                    .disabled(audioSources.isEmpty && !check.testing)
                    Spacer()
                    SettingsLink(label: "Audio Permissions", pane: "Privacy_ScreenCapture")
                }
                if check.testing || !check.heard.isEmpty || !check.errors.isEmpty || !check.levels.isEmpty {
                    ForEach(audioSources) { source in
                        if let error = check.errors[source] {
                            Text(error).foregroundStyle(.secondary)
                        } else {
                            LabeledContent(source.rawValue) {
                                if check.testing { ProgressView(value: min(1, Double(check.levels[source] ?? 0) * 12)).frame(width: 130) }
                                else { Text(check.heard.contains(source) ? "Signal detected" : "No signal detected") }
                            }
                        }
                    }
                    if check.testing { Text("Speak and play sample meeting audio. The check lasts about eight seconds.").foregroundStyle(.secondary) }
                }
            }
            Section("Answers and privacy") {
                if let selection = answerSelection {
                    LabeledContent("Answer provider", value: selection.provider.rawValue)
                    if selection.provider != .disabled {
                        LabeledContent("Model", value: selection.model)
                    }
                }
                if !cloudHosts.isEmpty {
                    Toggle("Allow cloud processing for this session", isOn: $options.allowCloud)
                    Text("Cloud processing may send audio, transcript excerpts, assistant material, or a selected image to \(cloudHosts.joined(separator: ", ")), depending on your settings and actions.")
                        .foregroundStyle(.secondary)
                }
                Toggle("Save transcript and suggestions on this Mac", isOn: $options.save)
                Toggle("Save raw audio on this Mac", isOn: $options.saveAudio).disabled(!options.save)
                Toggle("Open floating session window", isOn: $showFloating)
            }
        }
        .formStyle(.grouped)
    }

    private func refreshAssistant() {
        options.save = assistant?.retainSession ?? true
        options.saveAudio = options.save && model.preferences.saveRawAudio == true
        options.allowCloud = false
        options.practice = assistant?.kind == .mockInterview
    }

    private func start() {
        guard let assistant else { return }
        var preferences = model.preferences
        preferences.microphoneID = microphoneID
        if preferences != model.preferences { model.savePreferences(preferences) }
        model.overlay.register()
        model.live.start(assistant: assistant, settings: preferences, options: options)
        if showFloating { model.overlay.show() }
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
