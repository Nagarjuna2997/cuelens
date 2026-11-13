import SwiftUI

struct AssistantEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: AssistantProfile
    let model: AppModel
    @State private var validation: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: profile.name.isEmpty ? "New Assistant" : "Edit Assistant",
                       subtitle: "Set the role, source material, and response preferences.")
                .padding(22)
            Divider()
            Form {
                Section("Role") {
                    TextField("Name", text: $profile.name)
                        .accessibilityIdentifier("assistantName")
                    TextField("Purpose", text: $profile.purpose)
                    Picker("Meeting type", selection: $profile.kind) {
                        ForEach(MeetingKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Job title", text: $profile.jobTitle)
                    TextField("Company", text: $profile.company)
                    EditorField(label: "Job description", text: $profile.jobDescription)
                }
                Section("Background") {
                    EditorField(label: "Experience, skills, and projects", text: $profile.background)
                    EditorField(label: "Custom instructions", text: $profile.instructions)
                }
                Section("Responses") {
                    Picker("Format", selection: $profile.format) {
                        ForEach(AnswerFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Length", selection: $profile.length) {
                        ForEach(AnswerLength.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Language", text: $profile.language)
                    TextField("Tone", text: $profile.tone)
                    Picker("Answer provider", selection: $profile.provider) {
                        Text("Use app setting").tag(Optional<AnswerProvider>.none)
                        ForEach(AnswerProvider.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    TextField("Model override", text: $profile.model)
                    Toggle("Suggest answers automatically", isOn: $profile.liveSuggestions)
                    Toggle("Save transcripts and suggestions for this assistant", isOn: $profile.retainSession)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let validation { Text(validation).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Assistant") {
                    if model.saveAssistant(profile) { dismiss() }
                    else { validation = model.error }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("saveAssistant")
            }
            .padding(16)
        }
        .frame(width: 640, height: 630)
    }
}

struct EditorField: View {
    let label: String
    @Binding var text: String
    var height: CGFloat = 75

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
            TextEditor(text: $text)
                .font(.body)
                .padding(4)
                .frame(minHeight: height)
                .scrollContentBackground(.hidden)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
                .accessibilityLabel(label)
        }
    }
}
