import AppKit
import SwiftUI

@main
struct CueLensApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var model = AppModel()

    var body: some Scene {
        Window("CueLens", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 600)
                .onAppear {
                    model.overlay.register()
                    let open = openWindow
                    model.openMainWindow = { open(id: "main") }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                    model.live.emergencyStop()
                    model.overlay.hide()
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandMenu("Session") {
                Button("Show or Hide Floating Panel") { model.overlay.toggle() }
                Button("Answer Latest Question") { model.live.answerLatest() }
                    .disabled(!model.live.canAnswer)
                Divider()
                Button("Stop Audio and Hide Panel") { model.live.emergencyStop(); model.overlay.hide() }
            }
        }
    }
}
