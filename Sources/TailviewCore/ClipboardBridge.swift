public enum ClipboardBridge {
    public static func outgoingText(_ pasteboard: String?, lastSent: String?) -> String? {
        guard let pasteboard, pasteboard != lastSent else { return nil }
        return pasteboard
    }

    public static func incomingText(_ remote: String, lastApplied: String?) -> String? {
        guard remote != lastApplied else { return nil }
        return remote
    }
}
