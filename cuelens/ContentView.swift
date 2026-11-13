import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var editing: AssistantProfile?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().frame(width: 32, height: 32)
                    Text("CueLens").font(.system(size: 20, weight: .semibold, design: .rounded))
                }.padding(.horizontal, 17).padding(.top, 26).padding(.bottom, 28)
                List(selection: $model.selection) {
                    Section("Workspace") {
                        ForEach([NavigationSection.home, .practice, .history]) { section in
                            Label(section.rawValue, systemImage: section.icon).tag(section).padding(.vertical, 4)
                        }
                    }
                    Section("Setup") {
                        ForEach([NavigationSection.assistants, .camera, .providers, .privacy]) { section in
                            Label(section.rawValue, systemImage: section.icon).tag(section).padding(.vertical, 4)
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                VStack(alignment: .leading, spacing: 7) {
                    if model.live.isOpen {
                        Label(model.live.audioSourceLabel, systemImage: "waveform").foregroundStyle(CueStyle.accent)
                    } else { Label("Ready when you are", systemImage: "circle") }
                    Button("Floating Bar", systemImage: "macwindow") { model.overlay.showBar() }
                        .buttonStyle(.borderless)
                }.font(.caption).foregroundStyle(.secondary).padding(18)
            }
            .background(CueStyle.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 172, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if model.camera.publishing {
                    HStack {
                        Label("CueLens Camera is sending video", systemImage: "video.fill")
                        Spacer()
                        Button("Stop Camera") { model.camera.stop() }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.45))
                }
                switch model.selection ?? .home {
                case .home:
                    StudioView(model: model)
                case .assistants:
                    AssistantsView(model: model) { editing = $0 }
                case .session:
                    StudioView(model: model)
                case .practice:
                    PracticeView(model: model)
                case .history:
                    HistoryView(model: model)
                case .providers:
                    ProvidersView(model: model)
                case .privacy:
                    PrivacyView(model: model)
                case .camera:
                    CameraView(model: model, preview: model.camera)
                }
            }
        }
        .background(CueStyle.canvas)
        .tint(CueStyle.accent)
        .preferredColorScheme(.dark)
        .sheet(item: $editing) { profile in
            AssistantEditor(profile: profile, model: model)
        }
        .alert("CueLens", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

enum CueStyle {
    static let accent = Color(red: 0.38, green: 0.82, blue: 0.74)
    static let canvas = Color(red: 0.075, green: 0.086, blue: 0.10)
    static let surface = Color(red: 0.105, green: 0.12, blue: 0.135)
    static let sidebar = Color(red: 0.065, green: 0.075, blue: 0.087)
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CueCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(CueStyle.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct AssistantsView: View {
    let model: AppModel
    let edit: (AssistantProfile) -> Void
    @State private var deleting: AssistantProfile?
    @State private var showArchived = false
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    PageHeader(title: "Assistants", subtitle: "Give each assistant the context it needs for a specific role or meeting.")
                    Button("New Assistant", systemImage: "plus") { edit(AssistantProfile()) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("newAssistant")
                }
                if !model.assistants.isEmpty {
                    TextField("Search assistants", text: $query).textFieldStyle(.roundedBorder)
                }
                if model.assistants.contains(where: \.archived) {
                    Toggle("Show archived", isOn: $showArchived).toggleStyle(.switch)
                }
                if visible.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No assistants yet" : "No matching assistants", systemImage: "person.crop.rectangle", description:
                                            Text("Create an assistant to add your own background and preferences."))
                }
                ForEach(visible) { assistant in
                    CueCard {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(assistant.name).font(.title3.weight(.semibold))
                                let role = [assistant.jobTitle, assistant.company].filter { !$0.isEmpty }.joined(separator: " · ")
                                Text(role.isEmpty ? assistant.kind.rawValue : role)
                                    .foregroundStyle(.secondary)
                                if let resume = assistant.knowledge.first(where: { $0.kind == .resume }) {
                                    Label(resume.name, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                } else if assistant.kind == .interview || assistant.kind == .mockInterview {
                                    Text("Add a résumé in Edit").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if assistant.archived { Text("Archived").foregroundStyle(.secondary) }
                            if !assistant.archived {
                                Button("Launch") {
                                    model.selectedAssistantID = assistant.id
                                    model.selection = .session
                                }
                            }
                            Button("Edit") { edit(assistant) }
                            Menu {
                                Button("Duplicate") { edit(assistant.duplicate()) }
                                Button(assistant.archived ? "Restore" : "Archive") {
                                    var changed = assistant
                                    changed.archived.toggle()
                                    model.saveAssistant(changed)
                                }
                                Divider()
                                Button("Delete", role: .destructive) { deleting = assistant }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 32)
                            .accessibilityLabel("Actions for \(assistant.name)")
                        }
                    }
                }
            }
            .frame(maxWidth: 780)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .alert("Delete assistant?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { assistant in
            Button("Delete", role: .destructive) { model.deleteAssistant(assistant.id) }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { assistant in
            Text("This removes \(assistant.name) and its imported documents from this Mac.")
        }
    }

    private var visible: [AssistantProfile] {
        (showArchived ? model.assistants : model.activeAssistants).filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.jobTitle.localizedStandardContains(query)
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
