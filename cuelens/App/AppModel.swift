import AppKit
import Combine
import Observation

@MainActor
@Observable
final class AppModel {
    let vault: Vault
    let credentials: any CredentialStore
    let live: LiveSession
    let camera = CameraPreview()
    let virtualCamera = VirtualCameraControl()
    let resources = Resources()
    @ObservationIgnored lazy var overlay = FloatingWindow(model: self)
    @ObservationIgnored lazy var cameraWindow = StudioCameraWindow(model: self)
    @ObservationIgnored private var cameraSettingsSave: Task<Void, Never>?
    @ObservationIgnored private var terminationSubscription: AnyCancellable?
    @ObservationIgnored private var terminationWaiters = [CheckedContinuation<Void, Never>]()
    private(set) var preparingToQuit = false
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
        if let settings = workspace.camera { camera.applySettings(settings) }
        camera.onSettingsChanged = { [weak self] settings in
            self?.cameraSettingsSave?.cancel()
            self?.cameraSettingsSave = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.update { $0.camera = settings }
            }
        }
        terminationSubscription = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                // AppKit posts this synchronously on the main actor. An asynchronous
                // task would not be guaranteed to run before the process exits.
                MainActor.assumeIsolated { self?.flushCameraSettings() }
            }
        live.onEmergency = { [weak self] in self?.camera.stop() }
        live.onEnded = { [weak self] in
            guard let self else { return }
            camera.stop()
            cameraWindow.hide()
            if !preparingToQuit { overlay.showBar() }
            let waiters = terminationWaiters
            terminationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        resources.onConditionChange = { [weak self] condition in
            self?.camera.lowResources = condition.reducesWork
            self?.live.setResources(condition)
        }
        camera.lowResources = resources.condition.reducesWork
        camera.preset = workspace.preferences.resourcePreset
        live.setResources(resources.condition)
    }

    func flushCameraSettings() {
        cameraSettingsSave?.cancel()
        cameraSettingsSave = nil
        let settings = camera.settingsSnapshot
        guard workspace.camera != settings else { return }
        update { $0.camera = settings }
    }

    /// AppKit keeps the process alive until capture has stopped and the session
    /// save completes. A failed save remains in memory and cancels normal Quit.
    func prepareForTermination() async -> Bool {
        preparingToQuit = true
        flushCameraSettings()
        camera.stop()
        cameraWindow.hide()
        if live.isOpen {
            await withCheckedContinuation { continuation in
                terminationWaiters.append(continuation)
                live.end()
            }
        } else if live.pendingSave != nil {
            live.retrySave()
        }
        guard live.pendingSave == nil else {
            preparingToQuit = false
            return false
        }
        overlay.saveOpacity()
        overlay.hide()
        return true
    }

    func openSessionSetup() {
        selection = .home
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
            ?? NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey && $0.title == "CueLens" }) {
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    func minimizeMainWindow() {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.orderOut(nil)
    }

    func endSession() {
        camera.stop()
        cameraWindow.hide()
        minimizeMainWindow()
        overlay.showBar()
        live.end()
    }

    func toggleSessionAudio(_ source: AudioSource) {
        guard live.isOpen, live.phase != .ending, source == .microphone || source == .meeting else { return }
        live.toggle(source)
        guard !live.options.practice else { return }
        var updated = preferences
        if source == .microphone { updated.sessionMicrophone = live.enabled.contains(source) }
        else { updated.sessionMeetingAudio = live.enabled.contains(source) }
        if updated != preferences { savePreferences(updated) }
    }

    func startCameraForSessionIfEnabled() {
        guard live.phase == .active, live.options.previewCamera, !camera.active, !camera.starting else { return }
        camera.start(deviceID: camera.deviceID)
    }

    func quickSessionOptions(for assistant: AssistantProfile) -> SessionOptions {
        var options = SessionOptions()
        options.microphone = preferences.sessionMicrophone ?? true
        options.meetingAudio = assistant.kind == .mockInterview ? false : (preferences.sessionMeetingAudio ?? true)
        options.screenContext = preferences.sessionScreenContext ?? false
        options.previewCamera = preferences.startCameraWithSession ?? false
        options.save = assistant.retainSession
        options.practice = assistant.kind == .mockInterview
        // Audio recording and cloud transcription need a deliberate session choice.
        options.saveAudio = false
        options.allowCloud = false
        return options
    }

    func startQuickSession() {
        if live.isOpen {
            if live.phase != .ending { overlay.show(focus: true) }
            return
        }
        guard live.pendingSave == nil else { return }
        var assistant = activeAssistants.first { $0.id == selectedAssistantID } ?? activeAssistants.first
        if assistant == nil {
            let profile = AssistantProfile(name: "General conversation")
            guard saveAssistant(profile) else { return }
            assistant = profile
        }
        guard let assistant else { return }
        selectedAssistantID = assistant.id
        live.start(assistant: assistant, settings: preferences, options: quickSessionOptions(for: assistant))
        guard live.isOpen else { return }
        startCameraForSessionIfEnabled()
        overlay.register()
        minimizeMainWindow()
        overlay.show(focus: true)
    }

    func openSection(_ section: NavigationSection) {
        openSessionSetup()
        selection = section
    }

    var openMainWindow: (() -> Void)?
    var preferences: Preferences { workspace.preferences }
    var assistants: [AssistantProfile] { workspace.assistants }
    var activeAssistants: [AssistantProfile] { assistants.filter { !$0.archived } }
    var materials: [KnowledgeFile] {
        var seen = Set<MaterialContents>()
        return assistants.flatMap(\.knowledge).filter { file in
            seen.insert(MaterialContents(name: file.name, text: file.text)).inserted
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct MaterialContents: Hashable {
        let name: String
        let text: String
    }

    @discardableResult
    func savePreferences(_ value: Preferences) -> Bool {
        update { $0.preferences = value }
    }

    @discardableResult
    func saveAssistant(_ profile: AssistantProfile) -> Bool {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return update { workspace in
            if profile.name.isEmpty {
                let jobTitle = profile.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if jobTitle.isEmpty {
                    let taken = Set(workspace.assistants.lazy.filter { $0.id != profile.id }.map(\.name))
                    let base = "Untitled Assistant"
                    var name = base
                    var suffix = 2
                    while taken.contains(name) {
                        name = "\(base) \(suffix)"
                        suffix += 1
                    }
                    profile.name = name
                } else {
                    profile.name = jobTitle
                }
            }
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
            if camera.preset != next.preferences.resourcePreset {
                camera.preset = next.preferences.resourcePreset
            }
            return true
        } catch {
            self.error = "CueLens couldn’t save the workspace. Check available storage and try again."
            return false
        }
    }
}

enum NavigationSection: String, CaseIterable, Identifiable {
    case home = "Studio"
    case practice = "Practice"
    case assistants = "Assistants"
    case session = "Live Session"
    case history = "History"
    case providers = "Providers"
    case privacy = "Screen Sharing"
    case camera = "Camera"

    var id: Self { self }

    var icon: String {
        switch self {
        case .home: "rectangle.grid.2x2"
        case .practice: "graduationcap"
        case .assistants: "person.crop.rectangle"
        case .session: "waveform"
        case .history: "clock.arrow.circlepath"
        case .providers: "slider.horizontal.3"
        case .privacy: "rectangle.dashed"
        case .camera: "video"
        }
    }
}
