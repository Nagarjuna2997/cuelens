import SwiftUI

@main
struct CueLensApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("CueLens", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 720)
    }
}
