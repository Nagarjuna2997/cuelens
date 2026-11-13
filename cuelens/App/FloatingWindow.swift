import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
@Observable
final class FloatingWindow: NSObject, NSWindowDelegate {
    enum Mode { case bar, session, test }

    private weak var model: AppModel?
    private var panel: CuePanel?
    @ObservationIgnored private var transcriptPanel: CuePanel?
    private(set) var mode = Mode.bar
    private(set) var visible = false
    private var expandedSize: NSSize?
    private(set) var shortcutError: String?
    private(set) var opacity = OverlayPreferences().opacity
    var showSeparateTranscript = true
    var showSeparateResponseTypes = true
    @ObservationIgnored private var opacitySave: Task<Void, Never>?
    @ObservationIgnored private var hotkeys: Hotkeys?

    init(model: AppModel) {
        self.model = model
        super.init()
        opacity = OverlayPreferences.clampedOpacity(model.workspace.overlay?.opacity ?? OverlayPreferences().opacity)
        model.live.onStateChanged = { [weak self] in self?.sessionChanged() }
    }

    func register() {
        guard let model else { return }
        let preferences = model.workspace.overlay ?? OverlayPreferences()
        if hotkeys == nil {
            hotkeys = Hotkeys { [weak self] command in
                guard let self else { return }
                switch command {
                case .toggle: toggle()
                case .answer:
                    guard model.live.isOpen, model.live.phase != .ending else { return }
                    model.live.askComposer()
                    show()
                case .capture:
                    guard model.live.isOpen, model.live.phase != .ending else { return }
                    model.live.captureScreen()
                    show()
                case .emergency: model.live.emergencyStop(); hide()
                }
            }
        }
        shortcutError = hotkeys?.register(preferences: preferences, live: model.live.isOpen)
    }

    var showsBarOpacity: Bool { mode == .bar && model?.live.isOpen == false }

    private var effectiveOpacity: Double { showsBarOpacity ? opacity : 1 }

    func toggle() {
        if visible { hide() }
        else { show() }
    }

    func show() {
        display(model?.live.isOpen == true ? .session : .bar)
    }

    func showTest() { display(.test) }

    func showBar() { display(.bar) }

    func hide() {
        saveOpacity()
        if mode == .session { expandedSize = panel?.frame.size }
        panel?.orderOut(nil)
        transcriptPanel?.orderOut(nil)
        visible = false
    }

    func setOpacity(_ value: Double) {
        let newValue = OverlayPreferences.clampedOpacity(value)
        guard newValue != opacity else { return }
        opacity = newValue
        panel?.alphaValue = effectiveOpacity
        opacitySave?.cancel()
        opacitySave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { self?.saveOpacity() }
        }
    }

    func saveOpacity() {
        opacitySave?.cancel()
        opacitySave = nil
        guard let model else { return }
        var settings = model.workspace.overlay ?? OverlayPreferences()
        guard settings.opacity != opacity else { return }
        settings.opacity = opacity
        _ = model.update { $0.overlay = settings }
    }

    func applyPreferences() {
        register()
        expandedSize = nil
        refreshAppearance()
    }

    func updateQuickSettings(_ edit: (inout OverlayPreferences) -> Void) {
        guard let model else { return }
        var preferences = model.workspace.overlay ?? OverlayPreferences()
        preferences.opacity = opacity
        edit(&preferences)
        if model.update({ $0.overlay = preferences }) { refreshAppearance() }
    }

    func toggleSeparateTranscript() {
        showSeparateTranscript.toggle()
        refreshAppearance()
    }

    private func refreshAppearance() {
        let theme = model?.workspace.overlay?.theme ?? .dark
        let appearance: NSAppearance?
        switch theme {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        panel?.appearance = appearance
        transcriptPanel?.appearance = appearance
        refreshSeparateTranscript(appearance: appearance)
    }

    private func refreshSeparateTranscript(appearance: NSAppearance?) {
        guard visible, mode == .session, showSeparateTranscript, let model,
              model.workspace.overlay?.transcriptLayout == .floating else {
            transcriptPanel?.orderOut(nil)
            return
        }
        if let transcriptPanel {
            transcriptPanel.orderFrontRegardless()
            return
        }
        let source = panel?.frame ?? .zero
        let bounds = panel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? source
        let size = NSSize(width: 250, height: 330)
        let left = source.minX - size.width - 9
        let x = left >= bounds.minX ? left : min(max(bounds.minX, source.maxX + 9), bounds.maxX - size.width)
        let y = max(bounds.minY, min(source.maxY - size.height, bounds.maxY - size.height))
        let transcript = createPanel(title: "CueLens Transcript", identifier: "cuelens.transcript")
        transcript.appearance = appearance
        transcript.minSize = NSSize(width: 200, height: 220)
        transcript.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true, animate: false)
        transcript.contentView = NSHostingView(rootView: SeparateTranscriptPanel(model: model, controller: self)
            .ignoresSafeArea().tint(CueStyle.accent))
        transcriptPanel = transcript
        transcript.orderFrontRegardless()
    }

    private func sessionChanged() {
        if model?.live.isOpen == false {
            showSeparateResponseTypes = true
            showSeparateTranscript = true
        }
        register()
        guard visible, mode != .test else { return }
        panel?.alphaValue = effectiveOpacity
        if model?.live.isOpen != true { display(.bar) }
    }

    private func display(_ mode: Mode) {
        guard let model else { return }
        let window = panel ?? makeMainPanel()
        let firstDisplay = panel == nil
        if self.mode == .session, let panel, visible { expandedSize = panel.frame.size }
        self.mode = mode
        let settings = model.workspace.overlay ?? OverlayPreferences()
        let target: NSSize
        let minimum: NSSize
        switch mode {
        case .bar: target = NSSize(width: 440, height: 52); minimum = target
        case .session:
            target = expandedSize ?? (settings.compact ? NSSize(width: 740, height: 440) : NSSize(width: 900, height: 500))
            minimum = NSSize(width: 630, height: 350)
        case .test: target = NSSize(width: 360, height: 115); minimum = target
        }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let old = window.frame
        let size = NSSize(width: min(target.width, bounds.width), height: min(target.height, bounds.height))
        window.minSize = minimum
        window.maxSize = mode == .session ? NSSize(width: bounds.width, height: bounds.height) : target
        let x = firstDisplay ? bounds.midX - size.width / 2 : old.midX - size.width / 2
        let top = firstDisplay ? bounds.maxY - 14 : old.maxY
        let frame = NSRect(x: max(bounds.minX, min(bounds.maxX - size.width, x)),
                           y: max(bounds.minY, min(bounds.maxY - size.height, top - size.height)),
                           width: size.width, height: size.height)
        window.alphaValue = effectiveOpacity
        window.setFrame(frame, display: true, animate: false)
        window.orderFrontRegardless()
        panel = window
        visible = true
        refreshAppearance()
    }

    private func makeMainPanel() -> CuePanel {
        let window = createPanel(title: "CueLens Floating Panel", identifier: "cuelens.floating")
        if let model {
            let content = FloatingContent(model: model, controller: self).ignoresSafeArea().tint(CueStyle.accent)
            window.contentView = NSHostingView(rootView: content)
        }
        return window
    }

    private func createPanel(title: String, identifier: String) -> CuePanel {
        let window = CuePanel(contentRect: .zero,
                              styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === transcriptPanel { toggleSeparateTranscript() }
        else { hide() }
        return false
    }

    fileprivate func compact() { showBar() }
}

private final class CuePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct FloatingContent: View {
    let model: AppModel
    let controller: FloatingWindow

    var body: some View {
        switch controller.mode {
        case .bar:
            bar
        case .session:
            SessionWorkspace(live: model.live, floating: true, overlay: model.workspace.overlay ?? OverlayPreferences(),
                             onMain: { model.openSessionSetup() }, onCompact: { controller.compact() }, onHide: { controller.hide() },
                             opacityController: controller, model: model)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary).allowsHitTesting(false) }
        case .test:
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    PanelDragGrip().frame(width: 19, height: 20)
                    Label("CueLens sharing test", systemImage: "eye")
                        .font(.headline)
                    Spacer()
                    Button("Hide", systemImage: "xmark") { controller.hide() }.labelStyle(.iconOnly)
                }
                Text("Look for this card in the viewer’s actual shared feed.")
                    .font(.callout)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var bar: some View {
        HStack(spacing: 11) {
            PanelDragGrip().frame(width: 18, height: 27)
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(CueStyle.accent)
                .accessibilityHidden(true)
            Text("CueLens").font(.headline)
            Divider().frame(height: 18)
            if let message = model.live.completionMessage, !model.live.isOpen {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Menu {
                ForEach(model.activeAssistants) { assistant in
                    Button(assistant.name) { model.selectedAssistantID = assistant.id }
                }
                if model.activeAssistants.isEmpty {
                    Button("Open Assistants") {
                        model.openSessionSetup()
                        model.selection = .assistants
                    }
                }
            } label: {
                Text(model.activeAssistants.first { $0.id == model.selectedAssistantID }?.name ?? model.activeAssistants.first?.name ?? "Choose assistant")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            Spacer(minLength: 0)
            if model.live.isOpen {
                Button("End Session", systemImage: "stop.circle.fill") { model.endSession() }.labelStyle(.iconOnly)
                    .help("End the session")
                    .disabled(model.live.phase == .ending)
                if model.live.phase == .paused {
                    Button("Resume", systemImage: "play.fill") { model.live.resume(); controller.show() }.labelStyle(.iconOnly)
                } else {
                    Button("Pause", systemImage: "pause.fill") { model.live.pause() }.labelStyle(.iconOnly)
                        .disabled(model.live.phase != .active)
                }
                Button("Restore", systemImage: "arrow.up.left.and.arrow.down.right") { controller.show() }
                    .help("Restore the live session window")
                    .accessibilityIdentifier("restoreSession")
            } else {
                Button("Set Up Session", systemImage: "play.circle.fill") { model.openSessionSetup() }.labelStyle(.iconOnly)
            }
            PanelQuickSettings(controller: controller, model: model)
            Menu {
                Button("CueLens Window") { model.openSessionSetup() }
                Button("Floating Panel Settings") {
                    model.openSessionSetup()
                    model.selection = .privacy
                }
                Button("Hide Bar") { controller.hide() }
            } label: {
                Label("Bar settings", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if model.live.isOpen {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
            } else {
                Capsule().fill(.regularMaterial)
            }
        }
        .overlay { Capsule().strokeBorder(.quaternary).allowsHitTesting(false) }
        .padding(3)
    }
}

struct PanelQuickSettings: View {
    let controller: FloatingWindow
    let model: AppModel
    @State private var showing = false

    private var settings: OverlayPreferences { model.workspace.overlay ?? OverlayPreferences() }

    var body: some View {
        Button("Quick Settings", systemImage: "slider.horizontal.3") { showing.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Adjust the floating panel")
            .accessibilityIdentifier("panelQuickSettings")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 11) {
                    if controller.showsBarOpacity {
                        HStack {
                            Text("Idle bar opacity").font(.headline)
                            Spacer()
                            Text(controller.opacity.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                        }
                        Slider(value: Binding(get: { controller.opacity }, set: { controller.setOpacity($0) }),
                               in: OverlayPreferences.opacityRange, step: 0.01) {
                            Text("Idle bar opacity")
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("panelOpacitySlider")
                    }
                    if model.live.isOpen {
                        LabeledContent("Background", value: settings.liveBackgroundOpacity.formatted(.percent.precision(.fractionLength(0))))
                        Slider(value: Binding(get: { settings.liveBackgroundOpacity }, set: { opacity in
                            controller.updateQuickSettings { $0.backgroundOpacity = opacity }
                        }), in: OverlayPreferences.opacityRange)
                            .accessibilityLabel("Panel background opacity")
                    }
                    Picker("Appearance", selection: Binding(
                        get: { settings.theme ?? .dark }, set: { theme in controller.updateQuickSettings { $0.theme = theme } }
                    )) {
                        ForEach(PanelTheme.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Transcript", selection: Binding(
                        get: { settings.transcriptLayout ?? .docked },
                        set: { layout in controller.updateQuickSettings { $0.transcriptLayout = layout } }
                    )) {
                        ForEach(TranscriptLayout.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Stepper(value: Binding(
                        get: { settings.fontSize }, set: { size in controller.updateQuickSettings { $0.fontSize = size } }
                    ), in: 12...26, step: 1) {
                        Text("Answer text size  \(Int(settings.fontSize)) pt")
                    }
                    Picker("Response types", selection: Binding(
                        get: { settings.responsePlacement ?? .transcript },
                        set: { placement in controller.updateQuickSettings { $0.responsePlacement = placement } }
                    )) {
                        ForEach(ResponsePlacement.allCases) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        if controller.showsBarOpacity {
                            Button("Reset Opacity") { controller.setOpacity(OverlayPreferences().opacity) }
                                .disabled(controller.opacity == OverlayPreferences().opacity)
                        }
                        Spacer()
                        Button("Done") { controller.saveOpacity(); showing = false }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(15)
                .frame(width: 285)
                .onDisappear { controller.saveOpacity() }
            }
    }
}

struct PanelDragGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let grip = DragView()
        grip.setAccessibilityElement(true)
        grip.setAccessibilityLabel("Move floating panel")
        return grip
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSColor.secondaryLabelColor.setFill()
            for x in [bounds.midX - 3, bounds.midX + 3] {
                for y in [bounds.midY - 5, bounds.midY, bounds.midY + 5] {
                    NSBezierPath(ovalIn: NSRect(x: x - 1.15, y: y - 1.15, width: 2.3, height: 2.3)).fill()
                }
            }
        }
    }
}

@MainActor
final class Hotkeys {
    enum Command: UInt32 { case toggle = 1, answer, emergency, capture }
    private struct Configuration: Equatable {
        let toggle: String
        let emergency: String?
        let live: Bool
    }
    private var references = [EventHotKeyRef]()
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private let action: (Command) -> Void
    private let signature: OSType = 0x4375654c
    private var configuration: Configuration?
    private var registrationError: String?
    private var lastCommand: Command?
    private var lastDispatch = -Double.infinity

    init(action: @escaping (Command) -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, let command = Command(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            guard id.signature == hotkeys.signature else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in hotkeys.dispatch(command) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(preferences: OverlayPreferences, live: Bool) -> String? {
        let next = Configuration(toggle: preferences.shortcut, emergency: preferences.emergencyShortcut, live: live)
        // Pause/resume and presentation changes must not repeatedly release the
        // user's global shortcuts when their bindings have not changed.
        if configuration == next, registrationError == nil { return nil }
        configuration = next
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        for key in references { UnregisterEventHotKey(key) }
        references.removeAll()
        var failed = [String]()
        let modifiers = UInt32(cmdKey | optionKey)
        if !register(.toggle, code: Self.key(preferences.shortcut), modifiers: modifiers) { failed.append("floating panel") }
        if let stop = preferences.emergencyShortcut,
           !register(.emergency, code: Self.key(stop), modifiers: modifiers) { failed.append("emergency stop") }
        if live {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let command = Self.sessionCommand(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return event }
                // Consume repeats too, so holding the shortcut cannot reach an
                // editor's Cut/Copy action while a session shortcut is active.
                if !event.isARepeat { self?.dispatch(command) }
                return nil
            }
            if !register(.answer, code: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey)) { failed.append("⌘C") }
            if !register(.capture, code: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey)) { failed.append("⌘X") }
        }
        registrationError = failed.isEmpty ? nil : "Another app may be using the \(failed.joined(separator: ", ")) shortcut."
        return registrationError
    }

    static func sessionCommand(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Command? {
        // Caps Lock and device-specific flags do not alter the requested chord.
        guard modifiers.intersection([.command, .control, .option, .shift]) == .command else { return nil }
        switch keyCode {
        case UInt16(kVK_ANSI_C): return .answer
        case UInt16(kVK_ANSI_X): return .capture
        default: return nil
        }
    }

    private func dispatch(_ command: Command) {
        if command == .answer || command == .capture {
            guard configuration?.live == true else { return }
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Carbon normally consumes the event before AppKit. Keep the foreground
        // fallback from making a second request if both routes deliver one press.
        guard command != lastCommand || now - lastDispatch > 0.12 else { return }
        lastCommand = command
        lastDispatch = now
        action(command)
    }

    private func register(_ command: Command, code: UInt32?, modifiers: UInt32) -> Bool {
        guard let code, handler != nil else { return false }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: signature, id: command.rawValue),
                                         GetApplicationEventTarget(), 0, &reference)
        if let reference, status == noErr { references.append(reference); return true }
        return false
    }

    static func key(_ character: String) -> UInt32? {
        let keys: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z
        ]
        return keys[character.lowercased()].map(UInt32.init)
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        for key in references { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
