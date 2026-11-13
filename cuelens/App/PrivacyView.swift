import SwiftUI

struct PrivacyView: View {
    let model: AppModel
    @State private var settings = OverlayPreferences()
    @State private var test = ShareCheck()
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Screen Sharing", subtitle: "Adjust the floating panel and check what a viewer can see.")
                .padding([.top, .horizontal], 30)
                .padding(.bottom, 12)
            Form {
                Section("Floating panel") {
                    Slider(value: $settings.fontSize, in: 12...26, step: 1) {
                        Text("Answer text size")
                    } minimumValueLabel: { Text("12") } maximumValueLabel: { Text("26") }
                    Slider(value: $settings.opacity, in: 0.55...1, step: 0.05) {
                        Text("Opacity")
                    } minimumValueLabel: { Text("55%") } maximumValueLabel: { Text("100%") }
                    Toggle("Use compact session window size", isOn: $settings.compact)
                    Picker("Show or hide (⌘⌥)", selection: $settings.shortcut) {
                        ForEach(Array("abcdefghijklmnopqrstuvwxyz").map(String.init), id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                    Picker("Stop audio and hide (⌘⌥)", selection: $settings.emergencyShortcut) {
                        Text("Off").tag(Optional<String>.none)
                        ForEach(Array("abcdefghijklmnopqrstuvwxyz").map(String.init), id: \.self) { Text($0.uppercased()).tag(Optional($0)) }
                    }
                    HStack {
                        Button("Show Floating Bar") { model.overlay.show() }
                        Spacer()
                        Button("Apply") { saveSettings() }
                    }
                    if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
                    if let error = model.overlay.shortcutError { Text(error).foregroundStyle(.secondary) }
                }
                Section("Check a share") {
                    Label("Treat the panel as visible until you check the viewer’s actual feed.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Show the test card. In your meeting app, share a window or display and inspect the feed from another device or with a participant. An entire display can include the panel. Use the hide shortcut before sharing if unsure.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Show Test Card") { model.overlay.showTest() }
                        Button("Hide Panel") { model.overlay.hide() }
                        Spacer()
                        SettingsLink(label: "Screen & System Audio Settings", pane: "Privacy_ScreenCapture")
                    }
                    LabeledContent("macOS", value: test.macOS)
                    TextField("Meeting or capture app", text: $test.application, prompt: Text("Google Meet in Chrome"))
                    Picker("Share mode", selection: $test.mode) {
                        ForEach(ShareMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("What the viewer saw", selection: $test.visibility) {
                        ForEach(ShareVisibility.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Notes or remaining checks", text: $test.notes, axis: .vertical).lineLimit(1...3)
                    Button("Save Observation") { saveTest() }
                        .disabled(test.application.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let checks = model.workspace.shareChecks, !checks.isEmpty {
                    Section("Saved observations") {
                        ForEach(checks) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.application).font(.headline)
                                Text("\(entry.macOS) · \(entry.mode.rawValue) · \(entry.visibility.rawValue)")
                                    .foregroundStyle(.secondary)
                                if !entry.notes.isEmpty { Text(entry.notes).foregroundStyle(.secondary) }
                            }
                        }
                        Text("Observations apply to the app, macOS version, and capture mode tested. Other combinations are unverified.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { settings = model.workspace.overlay ?? OverlayPreferences() }
    }

    private func saveSettings() {
        guard settings.shortcut != settings.emergencyShortcut else {
            status = "Choose a different letter for each shortcut."
            return
        }
        if model.update({ $0.overlay = settings }) {
            model.overlay.applyPreferences()
            status = "Settings applied."
        }
    }

    private func saveTest() {
        var observation = test
        observation.date = Date()
        observation.application = observation.application.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.update({ workspace in
            var checks = workspace.shareChecks ?? []
            checks.insert(observation, at: 0)
            workspace.shareChecks = checks
        }) { test = ShareCheck() }
    }
}
