import AppKit
import SwiftUI
import TailviewCore

struct SessionView: View {
    let sessionID: UUID
    let controller: SessionController
    let peerID: String
    let displayName: String
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var sessionEvent: SessionEvent = .connecting
    @State private var frame: FramebufferFrame?
    @State private var desktopProtocol: DesktopProtocol
    @State private var sessionPort: UInt16
    @State private var showFailover = false
    @State private var showRDPUnavailable = false
    @State private var showCredentials = false
    @State private var failoverTo: DesktopProtocol = .rdp
    @State private var failoverToPort: UInt16 = 3389
    @State private var pendingOverride = false
    @State private var clipboardLoop = ClipboardLoop()

    init(
        sessionID: UUID,
        controller: SessionController,
        peerID: String,
        displayName: String,
        desktopProtocol: DesktopProtocol,
        port: UInt16
    ) {
        self.sessionID = sessionID
        self.controller = controller
        self.peerID = peerID
        self.displayName = displayName
        _desktopProtocol = State(initialValue: desktopProtocol)
        _sessionPort = State(initialValue: port)
    }

    var body: some View {
        VStack(spacing: 0) {
            if sessionEvent == .dropped {
                HStack {
                    Text("Disconnected")
                    Button("Reconnect") {
                        Task { await controller.reconnect() }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color.yellow.opacity(0.35))
            }
            ZStack {
                SessionFramebufferView(
                    frame: frame,
                    onPointer: { event in
                        Task { await controller.sendPointer(event) }
                    },
                    onKey: { event in
                        Task { await controller.sendKey(event) }
                    }
                )
                if sessionEvent == .connecting && frame == nil {
                    ProgressView("Connecting to \(displayName)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 320)
        .onAppear {
            NSApp.keyWindow?.title = displayName
        }
        .task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in controller.events {
                        await handle(event)
                    }
                }
                group.addTask {
                    for await next in controller.frames {
                        await MainActor.run { frame = next }
                    }
                }
                group.addTask {
                    for await text in controller.remoteClipboard {
                        await MainActor.run { applyRemoteClipboard(text) }
                    }
                }
                await controller.start()
                await group.waitForAll()
            }
        }
        .task(id: desktopProtocol) {
            guard desktopProtocol == .rdp else { return }
            await pollLocalPasteboard()
        }
        .onDisappear {
            Task {
                await controller.disconnect()
                await MainActor.run { appState.endSession(sessionID) }
            }
        }
        .confirmationDialog(failoverPrompt, isPresented: $showFailover) {
            Button("Try \(protocolName(failoverTo))") {
                desktopProtocol = failoverTo
                sessionPort = failoverToPort
                pendingOverride = true
                Task { await controller.acceptFailover() }
            }
            Button("Cancel", role: .cancel) {
                Task { await controller.declineFailover() }
            }
        }
        .alert("RDP is unavailable.", isPresented: $showRDPUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("VNC still works from the list.")
        }
        .sheet(isPresented: $showCredentials) {
            CredentialSheet(displayName: displayName, desktopProtocol: desktopProtocol) { credentials, saveInKeychain in
                showCredentials = false
                if saveInKeychain {
                    appState.saveSessionCredentials(
                        peerID: peerID,
                        desktopProtocol: desktopProtocol,
                        credentials: credentials
                    )
                }
                Task { await controller.retryWithCredentials(credentials) }
            } onCancel: {
                showCredentials = false
            }
        }
    }

    private var failoverPrompt: String {
        "Nothing is listening on port \(sessionPort). Try \(protocolName(failoverTo)) on port \(failoverToPort)?"
    }

    private func protocolName(_ desktopProtocol: DesktopProtocol) -> String {
        switch desktopProtocol {
        case .rdp:
            return "RDP"
        case .vnc, .screenSharing:
            return "VNC"
        }
    }

    @MainActor
    private func applyRemoteClipboard(_ text: String) {
        guard desktopProtocol == .rdp else { return }
        if let incoming = clipboardLoop.remoteArrived(text) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(incoming, forType: .string)
        }
    }

    private func pollLocalPasteboard() async {
        var changeCount = await MainActor.run { NSPasteboard.general.changeCount }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(300))
            let outgoing = await MainActor.run { () -> String? in
                guard desktopProtocol == .rdp else { return nil }
                let pasteboard = NSPasteboard.general
                guard pasteboard.changeCount != changeCount else { return nil }
                changeCount = pasteboard.changeCount
                return clipboardLoop.localPasteboardChanged(pasteboard.string(forType: .string))
            }
            if let outgoing {
                await controller.sendClipboard(outgoing)
            }
        }
    }

    @MainActor
    private func handle(_ event: SessionEvent) {
        sessionEvent = event
        switch event {
        case .offerFailover(_, let to, let port):
            failoverTo = to
            failoverToPort = port
            showFailover = true
        case .failed(.authenticationFailed):
            showCredentials = true
        case .failed(.rdpUnavailable):
            showRDPUnavailable = true
        case .connected:
            if pendingOverride {
                pendingOverride = false
                appState.rememberFailover(
                    peerID: peerID,
                    override: ProtocolOverride(desktopProtocol: desktopProtocol, port: sessionPort)
                )
            }
        case .disconnected:
            dismiss()
        default:
            break
        }
    }
}

struct SessionFramebufferView: NSViewRepresentable {
    var frame: FramebufferFrame?
    var onPointer: (PointerEvent) -> Void
    var onKey: (KeyEvent) -> Void

    func makeNSView(context: Context) -> FramebufferNSView {
        let view = FramebufferNSView()
        view.onPointer = onPointer
        view.onKey = onKey
        view.apply(frame)
        return view
    }

    func updateNSView(_ nsView: FramebufferNSView, context: Context) {
        nsView.onPointer = onPointer
        nsView.onKey = onKey
        nsView.apply(frame)
    }
}

final class FramebufferNSView: NSView {
    var onPointer: ((PointerEvent) -> Void)?
    var onKey: ((KeyEvent) -> Void)?

    private var image: CGImage?
    private var remoteWidth = 0
    private var remoteHeight = 0
    private var left = false
    private var right = false
    private var middle = false
    private var trackingArea: NSTrackingArea?
    private var keyMonitor: Any?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func apply(_ frame: FramebufferFrame?) {
        guard let frame, let next = Self.cgImage(from: frame) else { return }
        image = next
        remoteWidth = frame.width
        remoteHeight = frame.height
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installKeyMonitor()
            window?.makeFirstResponder(self)
            window?.acceptsMouseMovedEvents = true
        } else {
            removeKeyMonitor()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let image else { return }
        let dest = fittedRect()
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        nsImage.draw(in: dest, from: .zero, operation: .copy, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        left = true
        emitPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        left = false
        emitPointer(event)
    }

    override func mouseDragged(with event: NSEvent) {
        emitPointer(event)
    }

    override func mouseMoved(with event: NSEvent) {
        emitPointer(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        right = true
        emitPointer(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        right = false
        emitPointer(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        emitPointer(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            middle = true
        }
        emitPointer(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            middle = false
        }
        emitPointer(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        emitPointer(event)
    }

    override func keyDown(with event: NSEvent) {
        emitKey(event, down: true)
    }

    override func keyUp(with event: NSEvent) {
        emitKey(event, down: false)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        emitKey(event, down: true)
        emitKey(event, down: false)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let down: Bool
        switch event.keyCode {
        case 56, 60:
            down = flags.contains(.shift)
        case 59, 62:
            down = flags.contains(.control)
        case 58, 61:
            down = flags.contains(.option)
        case 55, 54:
            down = flags.contains(.command)
        default:
            return
        }
        onKey?(KeyEvent(down: down, macKeyCode: event.keyCode, characters: ""))
    }

    private func emitKey(_ event: NSEvent, down: Bool) {
        onKey?(KeyEvent(down: down, macKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? ""))
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            guard self.window?.isKeyWindow == true, self.window?.firstResponder === self else { return event }
            self.emitKey(event, down: event.type == .keyDown)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func emitPointer(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let remote = remotePoint(from: local) else { return }
        onPointer?(PointerEvent(x: remote.x, y: remote.y, left: left, right: right, middle: middle))
    }

    private func fittedRect() -> NSRect {
        guard remoteWidth > 0, remoteHeight > 0 else { return .zero }
        let remote = NSSize(width: remoteWidth, height: remoteHeight)
        let scale = min(bounds.width / remote.width, bounds.height / remote.height)
        let drawn = NSSize(width: remote.width * scale, height: remote.height * scale)
        return NSRect(
            x: (bounds.width - drawn.width) / 2,
            y: (bounds.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        )
    }

    private func remotePoint(from local: NSPoint) -> (x: Int, y: Int)? {
        let dest = fittedRect()
        guard dest.width > 0, dest.height > 0, dest.contains(local) else { return nil }
        let x = Int(((local.x - dest.minX) / dest.width) * CGFloat(remoteWidth))
        let y = Int(((local.y - dest.minY) / dest.height) * CGFloat(remoteHeight))
        return (min(max(x, 0), remoteWidth - 1), min(max(y, 0), remoteHeight - 1))
    }

    private static func cgImage(from frame: FramebufferFrame) -> CGImage? {
        let bytesPerRow = frame.width * 4
        guard frame.width > 0, frame.height > 0, frame.rgba.count >= bytesPerRow * frame.height else { return nil }
        guard let provider = CGDataProvider(data: frame.rgba as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
