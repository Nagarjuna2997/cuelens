import SwiftUI
import UniformTypeIdentifiers

struct MaterialPicker: View {
    private enum Source: String, CaseIterable, Identifiable {
        case upload = "Upload"
        case library = "My Documents"
        case paste = "Type or Paste"

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    let kind: MaterialKind
    let library: [KnowledgeFile]
    let available: Int
    let attach: ([KnowledgeFile]) -> Void

    @State private var source = Source.upload
    @State private var chooseFiles = false
    @State private var importing = false
    @State private var files = [KnowledgeFile]()
    @State private var errors = [String]()
    @State private var target = false
    @State private var selected: UUID?
    @State private var search = ""
    @State private var title = ""
    @State private var note = ""

    private var documents: [KnowledgeFile] {
        search.isEmpty ? library : library.filter { $0.name.localizedStandardContains(search) }
    }

    private var canAttach: Bool {
        guard !importing, available > 0 else { return false }
        switch source {
        case .upload: return !files.isEmpty
        case .library: return library.contains { $0.id == selected }
        case .paste: return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(kind == .reference ? "Add Material" : "Attach \(kind.rawValue)")
                .font(.title2.weight(.semibold))
            Picker("Material source", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).disabled(importing)
            switch source {
            case .upload:
                upload
            case .library:
                libraryPicker
            case .paste:
                TextField("Title", text: $title, prompt: Text(kind.rawValue)).textFieldStyle(.roundedBorder)
                EditorField(label: "Text", text: $note, height: 180)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Attach to Assistant") { complete() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAttach)
            }
        }
        .padding(21)
        .frame(width: 545, height: 405)
        .fileImporter(isPresented: $chooseFiles, allowedContentTypes: [
            .pdf, .plainText, UTType(filenameExtension: "docx") ?? .data, UTType(filenameExtension: "md") ?? .plainText
        ], allowsMultipleSelection: kind == .reference) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): errors = [error.localizedDescription]
            }
        }
    }

    private var upload: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.up.doc").font(.title2).accessibilityHidden(true)
                Button("Choose Files…") { chooseFiles = true }.disabled(importing)
                    .accessibilityIdentifier("chooseMaterialFiles")
                Text("or drag them here · PDF, DOCX, TXT, or Markdown · 12 MB each")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(target ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9).strokeBorder(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .allowsHitTesting(false)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !importing else { return false }
                importFiles(urls)
                return !urls.isEmpty
            } isTargeted: { target = $0 }
            if importing { ProgressView("Reading files…").controlSize(.small) }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(files) { file in
                        Label(file.name, systemImage: "checkmark.circle")
                    }
                    ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !files.isEmpty { Text("Review the extracted text in the assistant after attaching.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var libraryPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("Search documents", text: $search).textFieldStyle(.roundedBorder)
            if documents.isEmpty {
                Text(library.isEmpty ? "Material from saved assistants appears here." : "No matching documents.")
                    .foregroundStyle(.secondary)
            } else {
                List(documents, selection: $selected) { item in
                    Label(item.name, systemImage: "doc.text").tag(item.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !importing else { return }
        let selectedURLs = Array(urls.prefix(kind == .reference ? available : 1))
        guard !selectedURLs.isEmpty else { return }
        importing = true
        files = []
        errors = []
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var materials = [KnowledgeFile]()
                var failures = [String]()
                for url in selectedURLs {
                    do { materials.append(try KnowledgeImport.read(url, kind: kind)) }
                    catch { failures.append(url.lastPathComponent + " · " + error.localizedDescription) }
                }
                return (materials, failures)
            }.value
            files = result.0
            errors = result.1
            if urls.count > selectedURLs.count { errors.append("Only \(selectedURLs.count) files fit this attachment.") }
            importing = false
        }
    }

    private func complete() {
        guard canAttach else { return }
        switch source {
        case .upload:
            attach(files)
        case .library:
            guard var file = library.first(where: { $0.id == selected }) else { return }
            file.id = UUID()
            file.kind = kind
            attach([file])
        case .paste:
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
            attach([KnowledgeFile(name: name.isEmpty ? kind.rawValue : String(name.prefix(150)),
                                  text: String(text.prefix(KnowledgeImport.textLimit)), kind: kind)])
        }
    }
}
