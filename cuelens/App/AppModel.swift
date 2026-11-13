import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    let vault: Vault
    let credentials: any CredentialStore
    let live: LiveSession
    @ObservationIgnored lazy var overlay = FloatingWindow(model: self)
    var selectedAssistantID: UUID?
    private(set) var workspace = Workspace()
    private(set) var history = [MeetingSession]()
    private(set) var workspaceReady = false
    var error: String?
    var selection: NavigationSection? = .home

    init(vault: Vault = .live(), credentials: any CredentialStore = Keychain()) {
        self.vault = vault
        self.credentials = credentials
        live = LiveSession(vault: vault, credentials: credentials)
        do {
            workspace = try vault.load()
            workspaceReady = true
        } catch {
            self.error = "CueLens couldn’t open its workspace. Your files are in \(vault.directory.path)."
        }
        do { history = try vault.sessions() }
        catch { self.error = "CueLens couldn’t read the session history. Check the Sessions folder in \(vault.directory.path)." }
        live.onSaved = { [weak self] session in self?.updateHistory(session) }
    }

    func openSessionSetup() {
        selection = .session
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
            ?? NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey && $0.title == "CueLens" }) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    var openMainWindow: (() -> Void)?
    var preferences: Preferences { workspace.preferences }
    var assistants: [AssistantProfile] { workspace.assistants }
    var activeAssistants: [AssistantProfile] { assistants.filter { !$0.archived } }

    @discardableResult
    func savePreferences(_ value: Preferences) -> Bool {
        update { $0.preferences = value }
    }

    @discardableResult
    func saveAssistant(_ profile: AssistantProfile) -> Bool {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty else {
            error = "Give this assistant a name."
            return false
        }
        return update { workspace in
            if let index = workspace.assistants.firstIndex(where: { $0.id == profile.id }) {
                workspace.assistants[index] = profile
            } else {
                workspace.assistants.append(profile)
            }
        }
    }

    func deleteAssistant(_ id: UUID) {
        update { $0.assistants.removeAll { $0.id == id } }
    }

    @discardableResult
    func saveSession(_ session: MeetingSession) -> Bool {
        do {
            try vault.save(session)
            updateHistory(session)
            return true
        } catch {
            self.error = "CueLens couldn’t save this session. Check available storage and try again."
            return false
        }
    }

    private func updateHistory(_ session: MeetingSession) {
        history.removeAll { $0.id == session.id }
        history.append(session)
        history.sort { $0.startedAt > $1.startedAt }
    }

    func deleteSession(_ id: UUID) {
        do {
            try vault.deleteSession(id)
            history.removeAll { $0.id == id }
        } catch {
            self.error = "CueLens couldn’t delete all files for this session. Try again."
        }
    }

    @discardableResult
    func update(_ change: (inout Workspace) -> Void) -> Bool {
        guard workspaceReady else {
            error = "Open the workspace successfully before making changes."
            return false
        }
        var next = workspace
        change(&next)
        do {
            try vault.save(next)
            workspace = next
            return true
        } catch {
            self.error = "CueLens couldn’t save the workspace. Check available storage and try again."
            return false
        }
    }
}

enum NavigationSection: String, CaseIterable, Identifiable {
    case home = "Overview"
    case assistants = "Assistants"
    case session = "Live Session"
    case history = "History"
    case providers = "Providers"
    case privacy = "Screen Sharing"

    var id: Self { self }

    var icon: String {
        switch self {
        case .home: "rectangle.grid.2x2"
        case .assistants: "person.crop.rectangle"
        case .session: "waveform"
        case .history: "clock.arrow.circlepath"
        case .providers: "slider.horizontal.3"
        case .privacy: "rectangle.dashed"
        }
    }
}
