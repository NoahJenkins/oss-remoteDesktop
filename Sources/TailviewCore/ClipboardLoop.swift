public struct ClipboardLoop {
    public var lastSent: String?
    public var lastApplied: String?

    public init(lastSent: String? = nil, lastApplied: String? = nil) {
        self.lastSent = lastSent
        self.lastApplied = lastApplied
    }

    public mutating func localPasteboardChanged(_ text: String?) -> String? {
        guard let outgoing = ClipboardBridge.outgoingText(text, lastSent: lastSent) else { return nil }
        lastSent = outgoing
        lastApplied = outgoing
        return outgoing
    }

    public mutating func remoteArrived(_ text: String) -> String? {
        guard let incoming = ClipboardBridge.incomingText(text, lastApplied: lastApplied) else { return nil }
        lastApplied = incoming
        lastSent = incoming
        return incoming
    }
}
