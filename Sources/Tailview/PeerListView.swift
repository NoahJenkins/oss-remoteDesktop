import SwiftUI
import TailviewCore

struct PeerListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch appState.listModel {
            case .notRunning:
                unavailableState(message: "Tailscale is not running.")
            case .notLoggedIn:
                unavailableState(message: "Tailscale is not logged in.")
            case .ready(let rows):
                peerTable(rows)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .onAppear { appState.start() }
        .sheet(item: Bindable(appState).credentialPrompt) { row in
            CredentialSheet(displayName: row.displayName, desktopProtocol: row.desktopProtocol) { credentials, saveInKeychain in
                if let id = appState.submitCredentials(credentials, saveInKeychain: saveInKeychain) {
                    openWindow(id: "session", value: id)
                }
            } onCancel: {
                appState.cancelCredentials()
            }
        }
    }

    private func unavailableState(message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
            Button("Open Tailscale") {
                appState.openTailscale()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func peerTable(_ rows: [PeerRow]) -> some View {
        Table(rows) {
            TableColumn("Name", value: \.displayName)
            TableColumn("OS", value: \.os)
            TableColumn("Status") { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(row.online ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(row.online ? "Online" : "Offline")
                }
            }
            TableColumn("Protocol") { row in
                Text(protocolLabel(row.desktopProtocol))
            }
            TableColumn("") { row in
                HStack {
                    Button("Connect") {
                        if let id = appState.connect(row) {
                            openWindow(id: "session", value: id)
                        }
                    }
                    .disabled(!row.connectEnabled)
                    if let reason = row.disabledReason {
                        Text(reason)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func protocolLabel(_ desktopProtocol: DesktopProtocol?) -> String {
        switch desktopProtocol {
        case .screenSharing:
            return "Screen Sharing"
        case .vnc:
            return "VNC"
        case .rdp:
            return "RDP"
        case nil:
            return ""
        }
    }
}
