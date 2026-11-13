import AppKit
import SwiftUI

@main
struct CueLensApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(CueLensAppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("CueLens", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear {
                    delegate.model = model
                    model.overlay.register()
                    let open = openWindow
                    model.openMainWindow = { open(id: "main") }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                    model.live.emergencyStop()
                    model.overlay.hide()
                }
        }
        .defaultSize(width: 1380, height: 820)
        .commands {
            CommandMenu("Session") {
                Button("Show or Hide Floating Panel") { model.overlay.toggle() }
                Button("Answer · ⌘C") { model.live.askComposer() }
                    .disabled(!model.live.canAnswer)
                Button("Capture Screen · ⌘X") { model.live.captureScreen() }.disabled(!model.live.canCapture)
                Button("End Session") { model.endSession() }.disabled(!model.live.isOpen)
                Divider()
                Button("Stop Audio and Hide Panel") { model.live.emergencyStop(); model.overlay.hide() }
            }
        }
    }
}

@MainActor
final class CueLensAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { [weak self] in
            let ready = await model.prepareForTermination()
            if !ready { model.overlay.showBar() }
            sender.reply(toApplicationShouldTerminate: ready)
            self?.terminationTask = nil
        }
        return .terminateLater
    }
}
