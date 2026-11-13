import SwiftUI
import UniformTypeIdentifiers

struct AssistantEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: AssistantProfile
    let model: AppModel
    @State private var validation: String?
    @State private var attachment: MaterialKind?
    @State private var reviewing: KnowledgeFile?
    @State private var response: CustomResponse?
    @State private var showBackground = false

    private var remaining: Int { max(0, KnowledgeImport.documentLimit - profile.knowledge.count) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: model.assistants.contains(where: { $0.id == profile.id }) ? "Edit Assistant" : "Create Assistant",
                       subtitle: "Every field is optional. Save now or add details later.")
                .padding(22)
            Divider()
            Form {
                Section("Basics") {
                    TextField("Name", text: $profile.name, prompt: Text("Uses the job title or Untitled Assistant"))
                        .accessibilityIdentifier("assistantName")
                    Picker("Meeting type", selection: $profile.kind) {
                        ForEach(MeetingKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Job title", text: $profile.jobTitle)
                    TextField("Company", text: $profile.company)
                    TextField("Purpose", text: $profile.purpose)
                }
                Section("Materials") {
                    HStack {
                        Button("Upload Résumé", systemImage: "doc.badge.plus") { attachment = .resume }
                            .accessibilityIdentifier("uploadResume")
                        Button("Attach Job Description", systemImage: "briefcase") { attachment = .job }
                        Button("Add Material", systemImage: "paperclip") { attachment = .reference }
                    }.disabled(remaining == 0)
                    if profile.knowledge.isEmpty {
                        Text("You can attach a résumé or job description, paste a note, or reuse a saved document.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(profile.knowledge) { file in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.name)
                                Text(file.kind?.rawValue ?? "Reference").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Review Text") { reviewing = file }
                            Button("Remove", role: .destructive) { profile.knowledge.removeAll { $0.id == file.id } }
                        }
                    }
                    DisclosureGroup("Additional background and job details", isExpanded: $showBackground) {
                        EditorField(label: "Experience, skills, and projects", text: $profile.background)
                        EditorField(label: "Job description", text: $profile.jobDescription)
                    }
                }
                Section("Configuration") {
                    Picker("Answer provider", selection: $profile.provider) {
                        Text("Use app setting").tag(Optional<AnswerProvider>.none)
                        ForEach(AnswerProvider.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    TextField("Model override", text: $profile.model)
                    EditorField(label: "Instructions", text: $profile.instructions)
                    TextField("Language", text: $profile.language)
                    TextField("Tone", text: $profile.tone)
                }
                Section("Response types") {
                    Picker("Default format", selection: $profile.format) {
                        ForEach(AnswerFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Length", selection: $profile.length) {
                        ForEach(AnswerLength.allCases) { Text($0.rawValue).tag($0) }
                    }
                    ForEach(profile.customResponses ?? []) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            Button("Edit") { response = item }
                            Button("Remove", role: .destructive) { profile.customResponses?.removeAll { $0.id == item.id } }
                        }
                    }
                    Button("Add Response Type", systemImage: "plus") { response = CustomResponse() }
                        .disabled((profile.customResponses?.count ?? 0) >= 12)
                }
                Section("Session preferences") {
                    Toggle("Save transcripts and suggestions for this assistant", isOn: $profile.retainSession)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let validation { Text(validation).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Assistant") { save(launch: false) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("saveAssistant")
                Button("Save & Launch") { save(launch: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(profile.archived)
            }
            .padding(16)
        }
        .frame(width: 680, height: 690)
        .sheet(item: $attachment) { kind in
            MaterialPicker(kind: kind, library: model.materials, available: remaining) { materials in
                profile.knowledge.append(contentsOf: materials.prefix(remaining))
                attachment = nil
            }
        }
        .sheet(item: $reviewing) { file in
            MaterialReview(file: file) { updated in
                if let index = profile.knowledge.firstIndex(where: { $0.id == updated.id }) {
                    profile.knowledge[index] = updated
                }
                reviewing = nil
            } close: { reviewing = nil }
        }
        .sheet(item: $response) { item in
            ResponseEditor(response: item) { updated in
                var responses = profile.customResponses ?? []
                if let index = responses.firstIndex(where: { $0.id == updated.id }) { responses[index] = updated }
                else { responses.append(updated) }
                profile.customResponses = responses
                response = nil
            } cancel: { response = nil }
        }
    }

    private func save(launch: Bool) {
        if model.saveAssistant(profile) {
            if launch {
                model.selectedAssistantID = profile.id
                model.selection = .session
            }
            dismiss()
        } else {
            validation = model.error
        }
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

private struct MaterialReview: View {
    @State var file: KnowledgeFile
    let save: (KnowledgeFile) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(file.name).font(.headline)
            EditorField(label: "Extracted text", text: $file.text, height: 260)
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button("Keep Text") {
                    file.text = String(file.text.prefix(KnowledgeImport.textLimit))
                    save(file)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 590, height: 430)
    }
}

private struct ResponseEditor: View {
    @State var response: CustomResponse
    let save: (CustomResponse) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(response.name.isEmpty ? "Add Response Type" : "Edit Response Type").font(.title2)
            TextField("Name", text: $response.name, prompt: Text("Tradeoffs"))
                .textFieldStyle(.roundedBorder)
            EditorField(label: "Instructions", text: $response.instructions, height: 120)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save Response Type") {
                    response.name = String(response.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
                    response.instructions = String(response.instructions.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
                    save(response)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(response.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || response.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 490, height: 300)
    }
}
