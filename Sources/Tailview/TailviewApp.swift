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
            SessionWindowHost(sessionID: sessionID)
                .frame(minWidth: 480, minHeight: 320)
                .environment(appState)
        }
    }
}

private struct SessionWindowHost: View {
    let sessionID: UUID?
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
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
        .task(id: sessionID) {
            guard let sessionID else { return }
            if appState.session(for: sessionID) == nil {
                dismissWindow(id: "session", value: sessionID)
            }
        }
    }
}
