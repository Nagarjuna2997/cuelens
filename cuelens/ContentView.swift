import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var editing: AssistantProfile?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    ForEach(NavigationSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon).tag(section)
                    }
                } header: {
                    Label("CueLens", systemImage: "waveform.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.vertical, 10)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 172, ideal: 196)
        } detail: {
            switch model.selection ?? .home {
            case .home:
                OverviewView(model: model) { editing = AssistantProfile() }
            case .assistants:
                AssistantsView(model: model) { editing = $0 }
            case .session:
                if model.live.isOpen {
                    SessionWorkspace(live: model.live, floating: false, overlay: model.workspace.overlay ?? OverlayPreferences())
                } else {
                    SessionSetupView(model: model)
                }
            case .history:
                HistoryView(model: model)
            case .providers:
                ProvidersView(model: model)
            case .privacy:
                PrivacyView(model: model)
            }
        }
        .tint(CueStyle.accent)
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
    static let accent = Color(red: 0.08, green: 0.46, blue: 0.56)
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 31, weight: .semibold))
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
                    .fill(.quaternary.opacity(0.32))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct OverviewView: View {
    let model: AppModel
    let create: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Overview", subtitle: "Prepare an assistant and start a session when your meeting begins.")
                CueCard {
                    Label(model.activeAssistants.isEmpty ? "Create your first assistant" : "Start a session",
                          systemImage: "waveform.circle.fill")
                        .font(.title2.weight(.semibold))
                    Text(model.activeAssistants.isEmpty
                         ? "Add your role, background, and instructions so CueLens can ground suggestions in your experience."
                         : "Choose an assistant, confirm the audio sources and providers, and review what will be saved.")
                        .foregroundStyle(.secondary)
                    Button(model.activeAssistants.isEmpty ? "New Assistant" : "Session Setup") {
                        if model.activeAssistants.isEmpty { create() }
                        else { model.selection = .session }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("overviewPrimaryAction")
                }
                if !model.preferences.setupComplete {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("First-time setup").font(.headline).accessibilityAddTraits(.isHeader)
                        setupRow("Choose processing", detail: "Choose on-device transcription or OpenAI Realtime, and connect OpenAI, Claude, or Gemini for answers.",
                                 icon: "slider.horizontal.3", action: "Providers", section: .providers)
                        setupRow("Test audio and review permissions", detail: "Open session setup to choose audio sources and review data and retention.",
                                 icon: "mic", action: "Session Setup", section: .session)
                        Button("Finish Setup") {
                            var settings = model.preferences
                            settings.setupComplete = true
                            model.savePreferences(settings)
                        }
                    }
                }
                HStack {
                    Button("Show Floating Bar", systemImage: "macwindow.on.rectangle") { model.overlay.toggle() }
                    Button("Screen Share Test", systemImage: "rectangle.dashed") { model.selection = .privacy }
                }
                if !model.history.isEmpty {
                    Button("View Session History") { model.selection = .history }
                }
            }
            .frame(maxWidth: 780)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func setupRow(_ title: String, detail: String, icon: String, action: String, section: NavigationSection) -> some View {
        CueCard {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: icon)
                    .foregroundStyle(CueStyle.accent)
                    .font(.title3)
                    .frame(width: 27)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action) { model.selection = section }
            }
        }
    }
}

struct AssistantsView: View {
    let model: AppModel
    let edit: (AssistantProfile) -> Void
    @State private var deleting: AssistantProfile?
    @State private var showArchived = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    PageHeader(title: "Assistants", subtitle: "Give each assistant the context it needs for a specific role or meeting.")
                    Button("New Assistant", systemImage: "plus") { edit(AssistantProfile()) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("newAssistant")
                }
                if model.assistants.contains(where: \.archived) {
                    Toggle("Show archived", isOn: $showArchived).toggleStyle(.switch)
                }
                if visible.isEmpty {
                    ContentUnavailableView("No assistants yet", systemImage: "person.crop.rectangle", description:
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
                            }
                            Spacer()
                            if assistant.archived { Text("Archived").foregroundStyle(.secondary) }
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
        (showArchived ? model.assistants : model.activeAssistants).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct HistoryView: View {
    let model: AppModel

    var body: some View {
        ContentUnavailableView("No saved sessions", systemImage: "clock.arrow.circlepath",
                               description: Text("Completed sessions will appear here once live sessions are available."))
    }
}
