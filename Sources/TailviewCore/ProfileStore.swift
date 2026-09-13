import Foundation

public final class ProfileStore {
    private struct Envelope: Codable {
        var profiles: [PeerProfile]
    }

    private let fileURL: URL
    private var profiles: [String: PeerProfile]

    public init(directory: URL) throws {
        fileURL = directory.appendingPathComponent("profiles.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            profiles = Dictionary(envelope.profiles.map { ($0.peerID, $0) }, uniquingKeysWith: { _, last in last })
        } else {
            profiles = [:]
        }
    }

    public var allProfiles: [String: PeerProfile] {
        profiles
    }

    public func profile(for peerID: String) -> PeerProfile? {
        profiles[peerID]
    }

    public func upsert(_ profile: PeerProfile) throws {
        profiles[profile.peerID] = profile
        try persist()
    }

    public func setOverride(peerID: String, override: ProtocolOverride) throws {
        var profile = profiles[peerID] ?? PeerProfile(peerID: peerID, protocolOverride: nil, lastUsed: nil)
        profile.protocolOverride = override
        try upsert(profile)
    }

    public func markLastUsed(peerID: String, at date: Date = Date()) throws {
        var profile = profiles[peerID] ?? PeerProfile(peerID: peerID, protocolOverride: nil, lastUsed: nil)
        profile.lastUsed = date
        try upsert(profile)
    }

    private func persist() throws {
        let envelope = Envelope(profiles: Array(profiles.values))
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
