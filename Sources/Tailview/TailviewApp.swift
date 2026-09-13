import SwiftUI
import TailviewCore

@main
struct TailviewApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            PeerListView()
                .environment(appState)
        }
        WindowGroup(id: "session") {
            Group {
                if let controller = appState.sessionController, let row = appState.sessionRow {
                    SessionView(controller: controller, displayName: row.displayName)
                }
            }
            .frame(minWidth: 480, minHeight: 320)
            .environment(appState)
        }
    }
}
