import SwiftUI
import UniformTypeIdentifiers

struct AssistantEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: AssistantProfile
    let model: AppModel
    @State private var validation: String?
    @State private var importKind = MaterialKind.reference
    @State private var choosingFile = false
    @State private var importing = false
    @State private var reviewing: KnowledgeFile?

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
                Section("Materials") {
                    Menu {
                        ForEach(MaterialKind.allCases) { kind in
                            Button("Attach \(kind.rawValue)") {
                                importKind = kind
                                choosingFile = true
                            }
                        }
                    } label: {
                        Label("Add Material", systemImage: "paperclip")
                    }
                    .disabled(importing || profile.knowledge.count >= KnowledgeImport.documentLimit)
                    ForEach(profile.knowledge) { file in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.name)
                                Text(file.kind?.rawValue ?? "Reference").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Review Text") { reviewing = file }
                            Button("Remove", role: .destructive) { profile.knowledge.removeAll { $0.id == file.id } }
                        }
                    }
                    if importing { ProgressView("Extracting text…").controlSize(.small) }
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
                .disabled(importing || profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("saveAssistant")
            }
            .padding(16)
        }
        .frame(width: 640, height: 630)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [
            .pdf, .plainText,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "md") ?? .plainText
        ]) { result in
            switch result {
            case .success(let url): importFile(url, kind: importKind)
            case .failure(let error): validation = error.localizedDescription
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
    }

    private func importFile(_ url: URL, kind: MaterialKind) {
        importing = true
        validation = nil
        Task {
            defer { importing = false }
            do {
                let file = try await Task.detached(priority: .userInitiated) { try KnowledgeImport.read(url, kind: kind) }.value
                profile.knowledge.append(file)
                reviewing = file
            } catch { validation = error.localizedDescription }
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
