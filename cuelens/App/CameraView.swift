import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct CameraStudioPanel: View {
    let model: AppModel
    @Bindable var preview: CameraPreview
    var showsSettingsButton = true
    var allowsDetach = true
    @State private var compare = false
    @State private var showGuides = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Me", systemImage: "person.crop.rectangle").font(.headline)
                Spacer()
                Circle().fill(preview.active ? CueStyle.accent : Color.secondary.opacity(0.5))
                    .frame(width: 5, height: 5)
                    .accessibilityLabel(preview.active ? "Camera on" : "Camera off")
                if allowsDetach {
                    Button("Float Video Preview", systemImage: "rectangle.on.rectangle") { model.cameraWindow.show() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Move and resize the video preview")
                }
                if showsSettingsButton {
                    Button("Camera Settings", systemImage: "slider.horizontal.3") {
                        model.openSessionSetup()
                        model.selection = .camera
                    }.labelStyle(.iconOnly).buttonStyle(.borderless).help("Camera settings")
                }
            }
            if let frame = preview.frame {
                if compare {
                    cameraImage(frame.original, label: "Original", guides: false)
                }
                cameraImage(frame.processed, label: compare ? "Processed" : nil, guides: showGuides)
                HStack(spacing: 8) {
                    Text(String(format: "%.0f fps", frame.fps)).monospacedDigit()
                    Text(String(format: "%.0f ms", frame.processingMilliseconds)).monospacedDigit()
                    Spacer(minLength: 0)
                    Text("\(frame.droppedFrames) dropped").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                if let cue = frame.postureCue {
                    Label(cue, systemImage: "person.crop.rectangle.badge.plus")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                }
                Text(frame.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(CueStyle.canvas)
                    RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.04))
                    VStack(spacing: 12) {
                        Image(systemName: "viewfinder").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(CueStyle.accent.opacity(0.7))
                        if preview.starting { ProgressView("Starting camera…") }
                        else {
                            Text("Make room for you.").font(.system(size: 20, weight: .medium, design: .rounded))
                            Text("A clear frame. A natural presence.\nCamera processing stays on your Mac.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Start Camera") { preview.start(deviceID: preview.deviceID) }
                                .buttonStyle(.borderedProminent)
                        }
                    }.padding(20)
                }
                .frame(height: 240)
            }
            if let error = preview.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                SettingsLink(label: "Camera Permissions", pane: "Privacy_Camera")
            }
            Picker("Framing position", selection: $preview.framing.position) {
                ForEach(FramingPosition.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).controlSize(.small)
                .accessibilityLabel("Framing position")
                .disabled(!preview.framing.enabled || preview.effects.bypass)
            ViewThatFits(in: .horizontal) {
                controls
                VStack(alignment: .leading, spacing: 8) { primaryControls; previewControls }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(CueStyle.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        HStack(spacing: 8) { primaryControls; Spacer(minLength: 6); previewControls }
    }

    private var primaryControls: some View {
        HStack(spacing: 8) {
            if preview.active || preview.starting {
                Button("Stop", systemImage: "stop.fill") { preview.stop() }
                    .accessibilityIdentifier("cameraPreviewToggle")
            }
            Button("Recenter", systemImage: "viewfinder") { preview.recenter() }
                .disabled(!preview.active || !preview.framing.enabled || preview.effects.bypass)
            Toggle(isOn: $preview.framing.locked) { Label("Lock Framing", systemImage: preview.framing.locked ? "lock.fill" : "lock.open") }
                .toggleStyle(.button).labelStyle(.iconOnly).help("Lock framing")
                .disabled(!preview.active || !preview.framing.enabled || preview.effects.bypass)
        }.controlSize(.small)
    }

    private var previewControls: some View {
        HStack(spacing: 7) {
            Toggle(isOn: $compare) { Label("Before and After", systemImage: "rectangle.split.2x1") }
                .toggleStyle(.button).labelStyle(.iconOnly).help("Compare original and processed video")
                .disabled(preview.frame == nil)
            Toggle(isOn: $showGuides) { Label("Preview Guides", systemImage: "square.grid.3x3") }
                .toggleStyle(.button).labelStyle(.iconOnly).help("Guides appear only in your preview")
                .disabled(preview.frame == nil)
            Toggle(isOn: $preview.effects.bypass) { Text("Bypass") }.toggleStyle(.button).help("Use original camera video instantly")
        }.controlSize(.small)
    }

    private func cameraImage(_ image: CGImage, label: String?, guides: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
            Image(decorative: image, scale: 1)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxHeight: 360)
                .overlay {
                    if guides {
                        GeometryReader { geometry in
                            Path { path in
                                for fraction in [1.0 / 3, 2.0 / 3] {
                                    let x = geometry.size.width * fraction
                                    let y = geometry.size.height * fraction
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                                    path.move(to: CGPoint(x: 0, y: y))
                                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                                }
                            }.stroke(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                        }.allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel((label ?? "Processed") + " camera preview")
        }
    }
}

struct CameraView: View {
    let model: AppModel
    @Bindable var preview: CameraPreview
    @State private var cameras = [CameraDevice]()
    @State private var cameraID: String?
    @State private var installing = false
    @State private var importingBackground = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Camera Studio", subtitle: "Frame yourself, tune the picture, and preview your outgoing video.")
                CueCard {
                    Picker("Camera", selection: $cameraID) {
                        Text("System default").tag(Optional<String>.none)
                        ForEach(cameras) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(preview.active || preview.starting)
                    Picker("Resolution and frame rate", selection: $preview.format) {
                        Text("Camera default").tag(Optional<CameraFormatChoice>.none)
                        ForEach(preview.formatChoices(for: cameraID)) { Text($0.label).tag(Optional($0)) }
                    }.disabled(preview.active || preview.starting)
                    Text("Stop the camera to change its source or format.").font(.caption).foregroundStyle(.secondary)
                }
                CameraStudioPanel(model: model, preview: preview, showsSettingsButton: false)
                CueCard {
                    Toggle("Automatic framing", isOn: $preview.framing.enabled).font(.headline)
                    slider("Zoom", value: $preview.framing.zoom, range: 1...2.5, display: String(format: "%.2f×", preview.framing.zoom))
                    slider("Headroom", value: $preview.framing.headroom, range: 0.04...0.3, display: percent(preview.framing.headroom))
                    slider("Tracking sensitivity", value: $preview.framing.sensitivity, range: 0...1, display: percent(preview.framing.sensitivity))
                    slider("Dead zone", value: $preview.framing.deadZone, range: 0.01...0.12, display: percent(preview.framing.deadZone))
                }
                CueCard {
                    Text("Picture").font(.headline)
                    Picker("Background", selection: $preview.effects.background) {
                        Text("Original").tag(CameraBackground.original)
                        Text("Blur").tag(CameraBackground.blur)
                        if preview.backgroundName != nil { Text("Image").tag(CameraBackground.replacement) }
                    }.pickerStyle(.segmented)
                    HStack {
                        Button("Choose Background Image…") { importingBackground = true }
                        if let name = preview.backgroundName { Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    if preview.backgroundName != nil {
                        Text("Choose the background image again after relaunch.").font(.caption).foregroundStyle(.secondary)
                    }
                    if preview.effects.background != .original {
                        Picker("Mask quality", selection: $preview.effects.segmentation) {
                            ForEach(SegmentationQuality.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if preview.effects.background == .blur {
                            slider("Blur strength", value: $preview.effects.blurRadius, range: 3...24, display: "\(Int(preview.effects.blurRadius))")
                        }
                    }
                    Toggle("Exposure adjustment", isOn: $preview.effects.exposureEnabled)
                    if preview.effects.exposureEnabled { slider("Exposure", value: $preview.effects.exposure, range: -1...1, display: String(format: "%+.2f EV", preview.effects.exposure)) }
                    Toggle("Color adjustment", isOn: $preview.effects.colorEnabled)
                    if preview.effects.colorEnabled { slider("Saturation", value: $preview.effects.saturation, range: 0...1.5, display: percent(preview.effects.saturation)) }
                    Toggle("Lift shadows gently", isOn: $preview.effects.lighting)
                    Toggle("Light denoising", isOn: $preview.effects.denoise)
                    Text("Background effects and denoising pause when processing cannot keep up.").font(.caption).foregroundStyle(.secondary)
                }
                CueCard {
                    Toggle("Posture coaching", isOn: $preview.posture.enabled).font(.headline)
                    if preview.posture.enabled {
                        Text("Place the lens at eye level and sit naturally with your shoulders in view.").foregroundStyle(.secondary)
                        HStack {
                            Button(preview.deskCalibration == nil ? "Calibrate Desk Position" : "Recalibrate Desk Position") { preview.calibrateDesk() }
                                .disabled(!preview.active || preview.calibrating)
                            if preview.deskCalibration != nil { Button("Reset") { preview.resetCalibration() } }
                        }
                        if preview.calibrating { ProgressView(value: preview.calibrationProgress) }
                        if !preview.calibrationMessage.isEmpty { Text(preview.calibrationMessage).font(.callout).foregroundStyle(.secondary) }
                        if preview.active, preview.frame?.tracking.shouldersVisible != true {
                            Text("Shoulders are not clearly visible. Shoulder cues are paused.").font(.caption).foregroundStyle(.secondary)
                        }
                        slider("Cue sensitivity", value: $preview.posture.sensitivity, range: 0...1, display: percent(preview.posture.sensitivity))
                        DisclosureGroup("Choose cues") {
                            ForEach(PostureCue.allCases) { cue in
                                Toggle(cue.rawValue, isOn: Binding(get: { preview.posture.enabledCues.contains(cue) }, set: { enabled in
                                    if enabled { preview.posture.enabledCues.insert(cue) }
                                    else { preview.posture.enabledCues.remove(cue) }
                                }))
                            }
                        }
                        Text("Cues require a sustained change and have an 18-second cooldown. These are framing observations, not medical assessments.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                CueCard {
                    HStack { Text("Built-in eye contact correction").font(.headline); Spacer(); Text("Unavailable").foregroundStyle(.secondary) }
                    Text("CueLens does not yet redirect your eyes. Automatic framing only adjusts the crop. If you select an external camera, its app controls any eye correction; CueLens cannot verify that it is enabled.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                virtualCameraSection
            }
            .frame(maxWidth: 820).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            cameras = CameraDevice.available()
            cameraID = preview.deviceID
            if preview.format == nil { preview.format = preview.preferredFormat(for: cameraID) }
            preview.preset = model.preferences.resourcePreset
            model.virtualCamera.refresh()
        }
        .onChange(of: cameraID) { preview.selectDevice(cameraID) }
        .confirmationDialog("Enable the CueLens camera extension?", isPresented: $installing) {
            Button("Request Activation") { model.virtualCamera.request(install: true) }
        } message: {
            Text("macOS will ask an administrator to approve the camera extension.")
        }
        .fileImporter(isPresented: $importingBackground, allowedContentTypes: [.png, .jpeg, .heic]) { result in
            if case .success(let url) = result { preview.setBackground(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in cameras = CameraDevice.available() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in cameras = CameraDevice.available() }
    }

    private var virtualCameraSection: some View {
        CueCard {
            HStack {
                Text("CueLens Camera output").font(.headline)
                Spacer()
                Text(preview.publishing ? "Sending processed video" : "Off").foregroundStyle(.secondary)
            }
            if model.virtualCamera.bundled {
                HStack {
                    if model.virtualCamera.available {
                        Button(preview.publishing ? "Stop Sending Video" : "Send Video to CueLens Camera") { preview.setPublishing(!preview.publishing) }
                            .disabled(!preview.active)
                    } else {
                        Button("Enable Camera Extension…") { installing = true }.disabled(model.virtualCamera.requesting)
                    }
                    Spacer()
                    Button("Refresh") { model.virtualCamera.refresh() }
                }
                if !model.virtualCamera.status.isEmpty { Text(model.virtualCamera.status).font(.callout).foregroundStyle(.secondary) }
                if let error = preview.virtualError { Text(error).font(.callout).foregroundStyle(.secondary) }
                Text("Choose CueLens Camera in your meeting app after activation. Only processed video is sent. Preview guides and coaching stay in CueLens.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Virtual camera unavailable in this build. The camera extension needs Apple signing and macOS activation before meeting apps can receive processed video.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 145, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(label)
            Text(display).font(.caption.monospacedDigit()).frame(width: 65, alignment: .trailing)
        }
    }

    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
}
