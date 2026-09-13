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
        WindowGroup(id: "session", for: UUID.self) { $sessionID in
            Group {
                if let sessionID, let session = appState.session(for: sessionID) {
                    SessionView(
                        sessionID: sessionID,
                        controller: session.controller,
                        peerID: session.peerID,
                        displayName: session.displayName,
                        desktopProtocol: session.desktopProtocol,
                        port: session.port
                    )
                }
            }
            .frame(minWidth: 480, minHeight: 320)
            .environment(appState)
        }
    }
}
