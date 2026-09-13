import SwiftUI
import TailviewCore

struct CredentialSheet: View {
    var row: PeerRow
    var onConnect: (SessionCredentials, Bool) -> Void
    var onCancel: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var saveInKeychain = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to \(row.displayName)")
                .font(.headline)
            if row.desktopProtocol != .vnc {
                TextField("Username", text: $username)
                    .textContentType(.username)
            }
            SecureField("Password", text: $password)
                .textContentType(.password)
            Toggle("Save in Keychain", isOn: $saveInKeychain)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    onConnect(SessionCredentials(username: username, password: password), saveInKeychain)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}
