import AppKit
import Foundation
import Observation
import TailviewCore

@MainActor
@Observable
final class AppState {
    var listModel: ListModel = .notRunning
    var credentialPrompt: PeerRow?
    var sessionRow: PeerRow?
    private(set) var sessionCredentials: SessionCredentials?

    private let client: TailscaleClient
    private let credentialStore: any CredentialStore
    private let profileStore: ProfileStore
    private var pollTask: Task<Void, Never>?
    private var didStart = false

    init(
        client: TailscaleClient = TailscaleClient(transport: UnixLocalAPITransport()),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        profileDirectory: URL? = nil
    ) {
        self.client = client
        self.credentialStore = credentialStore
        let directory = profileDirectory ?? Self.applicationSupportDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let store = try? ProfileStore(directory: directory) {
            profileStore = store
        } else {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("Tailview-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            profileStore = try! ProfileStore(directory: fallback)
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        pollTask = Task {
            for await status in client.snapshots() {
                listModel = ListModel.from(status: status, profiles: profileStore.allProfiles)
            }
        }
    }

    func connect(_ row: PeerRow) -> Bool {
        guard let desktopProtocol = row.desktopProtocol else { return false }
        if let credentials = try? credentialStore.load(peerID: row.id, desktopProtocol: desktopProtocol) {
            sessionCredentials = credentials
            sessionRow = row
            return true
        }
        credentialPrompt = row
        return false
    }

    func submitCredentials(_ credentials: SessionCredentials, saveInKeychain: Bool) {
        guard let row = credentialPrompt, let desktopProtocol = row.desktopProtocol else { return }
        if saveInKeychain {
            try? credentialStore.save(peerID: row.id, desktopProtocol: desktopProtocol, credentials: credentials)
        }
        sessionCredentials = credentials
        sessionRow = row
        credentialPrompt = nil
    }

    func cancelCredentials() {
        credentialPrompt = nil
    }

    func openTailscale() {
        let workspace = NSWorkspace.shared
        if let url = URL(string: "tailscale://"), workspace.open(url) {
            return
        }
        if let url = URL(string: "https://tailscale.com/download") {
            _ = workspace.open(url)
        }
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tailview", isDirectory: true)
    }
}
