import AVFoundation
import SwiftUI

struct CameraView: View {
    let model: AppModel
    @Bindable var preview: CameraPreview
    @State private var cameras = [CameraDevice]()
    @State private var cameraID: String?
    @State private var compare = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Camera", subtitle: "Preview your camera and try local eye tracking.")
                CueCard {
                    HStack {
                        Picker("Camera", selection: $cameraID) {
                            Text("System default").tag(Optional<String>.none)
                            ForEach(cameras) { Text($0.name).tag(Optional($0.id)) }
                            if let cameraID, !cameras.contains(where: { $0.id == cameraID }) {
                                Text("Disconnected camera").tag(Optional(cameraID))
                            }
                        }.disabled(preview.active || preview.starting)
                        Spacer()
                        Button(preview.active || preview.starting ? "Stop Preview" : "Start Preview",
                               systemImage: preview.active ? "video.slash" : "video") {
                            if preview.active || preview.starting { preview.stop() }
                            else { preview.start(deviceID: cameraID) }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("cameraPreviewToggle")
                    }
                    if let error = preview.error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
                    if preview.starting { ProgressView("Starting camera…").controlSize(.small) }
                    SettingsLink(label: "Camera Permissions", pane: "Privacy_Camera")
                }
                if let frame = preview.frame {
                    HStack(alignment: .top, spacing: 12) {
                        if compare || !preview.correction {
                            cameraImage(frame.original, label: "Original", eyes: preview.tracking ? frame.eyeCenters : [])
                        }
                        if preview.correction {
                            cameraImage(frame.corrected ?? frame.original,
                                        label: frame.corrected == nil ? "Original fallback" : "Experimental correction", eyes: [])
                        }
                    }
                    HStack {
                        Text(frame.status)
                        Spacer()
                        if frame.fps > 0 { Text(String(format: "%.1f preview fps", frame.fps)).monospacedDigit() }
                    }.font(.callout).foregroundStyle(.secondary)
                }
                CueCard {
                    Toggle("Show eye tracking landmarks", isOn: $preview.tracking)
                    Toggle("Try eye-contact correction", isOn: $preview.correction)
                    if preview.correction {
                        Slider(value: $preview.strength, in: 0...1, step: 0.05) {
                            Text("Correction strength")
                        } minimumValueLabel: { Text("0%") } maximumValueLabel: { Text("100%") }
                        Toggle("Compare with original", isOn: $compare)
                    }
                    Text("Experimental correction gently shifts detected pupils when the face is nearly front-on. Blinks, side angles, uncertain landmarks, and resource pressure use the original feed.")
                        .foregroundStyle(.secondary)
                    Text("Camera processing stays on this Mac. CueLens currently previews the result here. Select your physical camera in the meeting app.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 900)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { cameras = CameraDevice.available(); preview.preset = model.preferences.resourcePreset }
        .onDisappear { preview.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in cameras = CameraDevice.available() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in cameras = CameraDevice.available() }
    }

    private func cameraImage(_ image: CGImage, label: String, eyes: [CGPoint]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.medium))
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay {
                    GeometryReader { size in
                        ForEach(Array(eyes.enumerated()), id: \.offset) { _, eye in
                            Circle().strokeBorder(.mint, lineWidth: 2).frame(width: 9, height: 9)
                                .position(x: eye.x * size.size.width, y: eye.y * size.size.height)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(label + " camera preview")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
