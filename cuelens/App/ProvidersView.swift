import AppKit
import SwiftUI

struct ProvidersView: View {
    let model: AppModel
    @State private var draft = Preferences()
    @State private var key = ""
    @State private var provider = AnswerProvider.openAI
    @State private var hasKey = false
    @State private var status = ""
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Providers", subtitle: "Choose who transcribes audio and generates answers.")
                .padding([.top, .horizontal], 30)
                .padding(.bottom, 12)
            Form {
                Section("API connection") {
                    Picker("Configure", selection: $provider) {
                        ForEach(AnswerProvider.cloudProviders) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(work != nil)
                    if let credential = provider.credential {
                        HStack {
                            SecureField(credential.name, text: $key, prompt: Text(hasKey ? "Saved in Keychain" : "Paste your API key"))
                                .accessibilityIdentifier("providerKey")
                            Button("Paste API Key", systemImage: "clipboard") { pasteKey() }
                                .accessibilityIdentifier("pasteProviderKey")
                        }
                        .disabled(work != nil)
                        TextField("Model ID", text: Binding(
                            get: { draft.model(for: provider) },
                            set: { draft.setModel($0, for: provider) }
                        ))
                        HStack {
                            if let url = provider.keyURL { Link("Get API Key", destination: url) }
                            Spacer()
                            if hasKey {
                                Button("Remove Key", role: .destructive) { remove(credential) }.disabled(work != nil)
                            }
                            Button("Test Connection") { test() }.disabled(work != nil)
                        }
                        Text("Test Connection sends a short sample prompt. Save Settings stores the key in macOS Keychain.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Answers") {
                    Picker("Default provider", selection: $draft.answerProvider) {
                        ForEach(AnswerProvider.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Backup provider", selection: $draft.backupProvider) {
                        Text("Off").tag(Optional<AnswerProvider>.none)
                        ForEach(AnswerProvider.cloudProviders) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    Text("With session approval, your selected provider receives the question, recent transcript, and relevant assistant material. API billing and access are managed by each provider.")
                        .foregroundStyle(.secondary)
                }
                Section("Speech to text") {
                    Picker("Speech provider", selection: $draft.speechProvider) {
                        ForEach(SpeechProvider.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Speech locale", text: $draft.speechLocale, prompt: Text("en-US"))
                    Text(draft.speechProvider == .onDevice
                         ? "Speech is processed on this Mac when Apple supports the selected locale."
                         : "With session approval, OpenAI Realtime receives the selected audio. Configure an OpenAI API key to use it.")
                        .foregroundStyle(.secondary)
                }
                Section("Resources") {
                    Picker("Preset", selection: $draft.resourcePreset) {
                        ForEach(ResourcePreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if work != nil { ProgressView().controlSize(.small) }
                Text(status).foregroundStyle(.secondary).lineLimit(3)
                    .accessibilityIdentifier("providerStatus")
                Spacer()
                Button("Save Settings") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(work != nil)
            }
            .padding(16)
        }
        .onAppear {
            draft = model.preferences
            if draft.answerProvider != .disabled { provider = draft.answerProvider }
            refreshKey()
        }
        .onChange(of: provider) {
            key = ""
            status = ""
            refreshKey()
        }
        .onDisappear {
            work?.cancel()
            work = nil
            key = ""
        }
    }

    private func pasteKey() {
        guard let value = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            status = "Copy your API key first, then click Paste API Key."
            return
        }
        guard !value.contains(where: \.isNewline) else {
            status = "Copy only the API key, then try again."
            return
        }
        key = value
        status = "Key pasted. Test Connection or Save Settings."
    }

    private func refreshKey() {
        hasKey = provider.credential.flatMap { try? model.credentials.read($0) } != nil
    }

    private func remove(_ credential: Credential) {
        do {
            try model.credentials.delete(credential)
            key = ""
            refreshKey()
            status = "Key removed."
        } catch { status = error.localizedDescription }
    }

    private func save() {
        do {
            if let credential = provider.credential {
                let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    guard !value.contains(where: \.isNewline) else { throw ProviderError.credentialUnavailable }
                    try model.credentials.write(value, for: credential)
                    key = ""
                    refreshKey()
                }
            }
            if model.savePreferences(draft) { status = "Settings saved." }
        } catch { status = error.localizedDescription }
    }

    private func test() {
        let selection = ProviderSelection(provider: provider, model: draft.model(for: provider))
        let credentials = PreviewCredentialStore(key: key.trimmingCharacters(in: .whitespacesAndNewlines), fallback: model.credentials)
        status = "Checking \(provider.shortName)…"
        work = Task {
            defer { work = nil }
            do {
                let connection = try ProviderConnection(selection: selection, credentials: credentials)
                try await HTTPAnswerStream().stream(.connectionTest, connection: connection) { _ in }
                try Task.checkCancellation()
                if draft.answerProvider == .disabled { draft.answerProvider = selection.provider }
                status = "\(selection.provider.shortName) streamed a response. Click Save Settings to use this connection."
            } catch {
                if !Task.isCancelled { status = error.localizedDescription }
            }
        }
    }
}

private struct PreviewCredentialStore: CredentialStore {
    let key: String
    let fallback: any CredentialStore

    func read(_ credential: Credential) throws -> String? { key.isEmpty ? try fallback.read(credential) : key }
    func write(_ value: String, for credential: Credential) throws { try fallback.write(value, for: credential) }
    func delete(_ credential: Credential) throws { try fallback.delete(credential) }
}
