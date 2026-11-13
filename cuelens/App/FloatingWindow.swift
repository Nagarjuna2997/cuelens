import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
@Observable
final class FloatingWindow: NSObject, NSWindowDelegate {
    enum Mode { case bar, session, test }

    private weak var model: AppModel?
    private var panel: CuePanel?
    private(set) var mode = Mode.bar
    private(set) var visible = false
    private var expandedSize: NSSize?
    private(set) var shortcutError: String?
    @ObservationIgnored private var hotkeys: Hotkeys?

    init(model: AppModel) {
        self.model = model
        super.init()
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
                    guard model.live.isOpen else { return }
                    if model.live.composer.isEmpty { model.live.answerLatest() }
                    else { model.live.askComposer() }
                case .emergency: model.live.emergencyStop(); hide()
                }
            }
        }
        shortcutError = hotkeys?.register(preferences: preferences, live: model.live.isOpen)
    }

    func toggle() {
        if visible { hide() }
        else { show() }
    }

    func show() {
        display(model?.live.isOpen == true ? .session : .bar)
    }

    func showTest() { display(.test) }

    func hide() {
        if mode == .session { expandedSize = panel?.frame.size }
        panel?.orderOut(nil)
        visible = false
    }

    func applyPreferences() {
        register()
        if let model {
            panel?.alphaValue = model.workspace.overlay?.opacity ?? 1
            expandedSize = nil
        }
    }

    private func sessionChanged() {
        register()
        guard visible, mode != .test else { return }
        if model?.live.isOpen == true {
            if mode == .bar, model?.live.phase == .active { display(.session) }
        } else {
            display(.bar)
        }
    }

    private func display(_ mode: Mode) {
        guard let model else { return }
        let window = panel ?? createPanel()
        let firstDisplay = panel == nil
        if self.mode == .session, let panel, visible { expandedSize = panel.frame.size }
        self.mode = mode
        let settings = model.workspace.overlay ?? OverlayPreferences()
        let target: NSSize
        let minimum: NSSize
        switch mode {
        case .bar: target = NSSize(width: 408, height: 54); minimum = target
        case .session:
            target = expandedSize ?? (settings.compact ? NSSize(width: 690, height: 440) : NSSize(width: 850, height: 570))
            minimum = NSSize(width: 550, height: 330)
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
        window.setFrame(frame, display: true)
        window.alphaValue = settings.opacity
        window.orderFrontRegardless()
        panel = window
        visible = true
    }

    private func createPanel() -> CuePanel {
        let window = CuePanel(contentRect: .zero,
                              styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("cuelens.floating")
        window.title = "CueLens Floating Panel"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let model {
            let content = FloatingContent(model: model, controller: self).ignoresSafeArea().tint(CueStyle.accent)
            window.contentView = NSHostingView(rootView: content)
        }
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

    fileprivate func compact() { display(.bar) }
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
                             onMain: { model.openSessionSetup() }, onCompact: { controller.compact() }, onHide: { controller.hide() })
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                if model.live.phase == .paused {
                    Button("Resume", systemImage: "play.fill") { model.live.resume(); controller.show() }.labelStyle(.iconOnly)
                } else {
                    Button("Pause", systemImage: "pause.fill") { model.live.pause() }.labelStyle(.iconOnly)
                        .disabled(model.live.phase != .active)
                }
                Button("Expand Session", systemImage: "rectangle.expand.vertical") { controller.show() }.labelStyle(.iconOnly)
            } else {
                Button("Set Up Session", systemImage: "play.circle.fill") { model.openSessionSetup() }.labelStyle(.iconOnly)
            }
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
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.quaternary).allowsHitTesting(false) }
        .padding(3)
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
private final class Hotkeys {
    enum Command: UInt32 { case toggle = 1, answer, emergency }
    private var references = [EventHotKeyRef]()
    private var handler: EventHandlerRef?
    private let action: (Command) -> Void
    private let signature: OSType = 0x4375654c

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
            Task { @MainActor in hotkeys.action(command) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(preferences: OverlayPreferences, live: Bool) -> String? {
        for key in references { UnregisterEventHotKey(key) }
        references.removeAll()
        var failed = [String]()
        let modifiers = UInt32(cmdKey | optionKey)
        if !register(.toggle, code: Self.key(preferences.shortcut), modifiers: modifiers) { failed.append("floating panel") }
        if let stop = preferences.emergencyShortcut,
           !register(.emergency, code: Self.key(stop), modifiers: modifiers) { failed.append("emergency stop") }
        if live && !register(.answer, code: UInt32(kVK_Return), modifiers: UInt32(cmdKey)) { failed.append("answer") }
        return failed.isEmpty ? nil : "Another app may be using the \(failed.joined(separator: ", ")) shortcut."
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
        for key in references { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
