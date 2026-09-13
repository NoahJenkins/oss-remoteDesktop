import AppKit
import Foundation
import Observation
import TailviewCore
import TailviewRDP
import TailviewVNC

struct OpenSession {
    var id: UUID
    var peerID: String
    var displayName: String
    var desktopProtocol: DesktopProtocol
    var port: UInt16
    var controller: SessionController
}

@MainActor
@Observable
final class AppState {
    var listModel: ListModel = .notRunning
    var credentialPrompt: PeerRow?
    private(set) var sessions: [UUID: OpenSession] = [:]

    private let client: TailscaleClient
    private let credentialStore: any CredentialStore
    private let profileStore: ProfileStore
    private var pollTask: Task<Void, Never>?
    private var didStart = false
    private var lastStatus: TailscaleStatus?

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
                lastStatus = status
                listModel = ListModel.from(status: status, profiles: profileStore.allProfiles)
            }
        }
    }

    func connect(_ row: PeerRow) -> UUID? {
        guard let desktopProtocol = row.desktopProtocol else { return nil }
        if let credentials = try? credentialStore.load(peerID: row.id, desktopProtocol: desktopProtocol) {
            return presentSession(row: row, credentials: credentials)
        }
        credentialPrompt = row
        return nil
    }

    func submitCredentials(_ credentials: SessionCredentials, saveInKeychain: Bool) -> UUID? {
        guard let row = credentialPrompt, let desktopProtocol = row.desktopProtocol else { return nil }
        if saveInKeychain {
            try? credentialStore.save(peerID: row.id, desktopProtocol: desktopProtocol, credentials: credentials)
        }
        credentialPrompt = nil
        return presentSession(row: row, credentials: credentials)
    }

    func session(for id: UUID) -> OpenSession? {
        sessions[id]
    }

    func endSession(_ id: UUID) {
        sessions.removeValue(forKey: id)
    }

    func rememberFailover(peerID: String, override: ProtocolOverride) {
        try? profileStore.setOverride(peerID: peerID, override: override)
        if let lastStatus {
            listModel = ListModel.from(status: lastStatus, profiles: profileStore.allProfiles)
        }
    }

    func saveSessionCredentials(peerID: String, desktopProtocol: DesktopProtocol, credentials: SessionCredentials) {
        try? credentialStore.save(peerID: peerID, desktopProtocol: desktopProtocol, credentials: credentials)
    }

    private func presentSession(row: PeerRow, credentials: SessionCredentials) -> UUID? {
        guard let host = row.host, let port = row.port, let desktopProtocol = row.desktopProtocol else { return nil }
        let id = UUID()
        try? profileStore.markLastUsed(peerID: row.id)
        sessions[id] = OpenSession(
            id: id,
            peerID: row.id,
            displayName: row.displayName,
            desktopProtocol: desktopProtocol,
            port: port,
            controller: SessionController(
                endpoint: Endpoint(host: host, port: port),
                desktopProtocol: desktopProtocol,
                credentials: credentials,
                factory: CompositeSessionFactory(
                    vnc: VNCSessionFactory.makeSession,
                    rdp: RDPSessionFactory.makeSession
                )
            )
        )
        return id
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
