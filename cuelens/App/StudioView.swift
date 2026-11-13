import AppKit
import SwiftUI

struct StudioView: View {
    let model: AppModel
    var practice = false
    @State private var cameraVisible = true

    var body: some View {
        VStack(spacing: 0) {
            if model.live.isOpen {
                HStack(spacing: 10) {
                    Label(model.live.assistant?.name ?? "Session", systemImage: "person.crop.rectangle")
                        .font(.headline).lineLimit(1)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    if !model.live.recordingSources.isEmpty {
                        Label("Recording", systemImage: "record.circle").foregroundStyle(.red).font(.caption)
                    }
                    Spacer(minLength: 0)
                    Button(cameraVisible ? "Hide Camera" : "Show Camera", systemImage: "video") { cameraVisible.toggle() }
                        .accessibilityIdentifier("toggleStudioCamera")
                    Menu {
                        Button("Float Camera", systemImage: "rectangle.on.rectangle") {
                            cameraVisible = false
                            model.cameraWindow.show()
                        }
                    } label: {
                        Label("Camera Options", systemImage: "chevron.down").labelStyle(.iconOnly)
                    }.menuStyle(.borderlessButton).fixedSize()
                    Button("Minimize", systemImage: "arrow.down.right.and.arrow.up.left") {
                        model.overlay.show()
                        model.minimizeMainWindow()
                    }
                    .help("Continue in the compact session window")
                    .accessibilityIdentifier("compactSession")
                }.buttonStyle(.borderless).padding(14)
                Divider()
            }
            GeometryReader { geometry in
                let centerMinimum: CGFloat = model.live.isOpen ? 460 : 400
                let cameraMaximum = max(260, min(440, geometry.size.width - centerMinimum - 1))
                HSplitView {
                    if model.live.isOpen {
                        SessionWorkspace(live: model.live, floating: false,
                                         overlay: model.workspace.overlay ?? OverlayPreferences(), model: model)
                            .frame(minWidth: centerMinimum, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        SessionSetupView(model: model, practice: practice)
                            .frame(minWidth: centerMinimum, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if cameraVisible {
                        ScrollView { CameraStudioPanel(model: model, preview: model.camera).padding(14) }
                        .frame(minWidth: 260, idealWidth: min(320, cameraMaximum), maxWidth: cameraMaximum, maxHeight: .infinity)
                    }
                }
                // Reset AppKit's saved pane widths when the setup pane becomes
                // two live panes; retain resizing throughout the live session.
                .id(model.live.isOpen)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            Divider()
            StudioStatusBar(model: model)
        }
        .task {
            while !Task.isCancelled {
                model.resources.sample()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct StudioStatusBar: View {
    let model: AppModel
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                Label(model.live.audioSourceLabel, systemImage: model.live.audioLive ? "waveform" : "mic.slash")
                ProgressView(value: min(1, Double(model.live.levels[.microphone] ?? 0) * 12))
                    .frame(width: 55).accessibilityLabel("Microphone level")
                if !model.live.clippedSources.isEmpty { Text("Audio clipping").foregroundStyle(.orange) }
                Text(model.live.isOpen ? model.live.speechProvider.rawValue : "Transcription ready")
                Label(model.camera.active ? "Camera on" : "Camera off", systemImage: "video")
                Spacer(minLength: 0)
                if model.live.isOpen { Text(model.live.currentProvider.provider.shortName) }
                if model.live.isOpen, let latency = model.live.timing?.firstTokenDelay {
                    Text(String(format: "First text %.2fs", latency))
                }
                if let memory = model.resources.memoryMB { Text(String(format: "%.0f MB", memory)) }
            }
            HStack {
                Text(model.live.audioSourceLabel)
                Spacer()
                Text(model.camera.active ? "Camera on" : "Camera off")
            }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 31)
    }
}

@MainActor
final class StudioCameraWindow {
    private weak var model: AppModel?
    private var window: NSPanel?
    init(model: AppModel) { self.model = model }

    func show() {
        guard let model else { return }
        if let window { window.orderFrontRegardless(); return }
        let panel = NSPanel(contentRect: NSRect(x: 150, y: 150, width: 420, height: 530),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "CueLens Camera Preview"
        panel.identifier = NSUserInterfaceItemIdentifier("cuelens.camera.preview")
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 350)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollView { CameraStudioPanel(model: model, preview: model.camera, allowsDetach: false).padding(10) }
            .preferredColorScheme(.dark).tint(CueStyle.accent))
        panel.center()
        panel.orderFrontRegardless()
        window = panel
    }
    func hide() { window?.orderOut(nil) }
}
