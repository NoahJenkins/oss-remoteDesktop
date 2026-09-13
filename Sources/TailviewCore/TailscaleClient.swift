import Foundation
import Network

public final class TailscaleClient: Sendable {
    private let transport: LocalAPITransport
    private let pollInterval: Duration

    public init(transport: LocalAPITransport, pollInterval: Duration = .seconds(2)) {
        self.transport = transport
        self.pollInterval = pollInterval
    }

    public func snapshot() async -> TailscaleStatus {
        do {
            let data = try await transport.getStatusJSON()
            return try LocalAPIStatusParser.parse(data)
        } catch is MissingSocketError {
            return .unavailable(.notRunning)
        } catch let error as POSIXError where Self.indicatesMissingSocket(error) {
            return .unavailable(.notRunning)
        } catch let error as NWError where Self.indicatesMissingSocket(error) {
            return .unavailable(.notRunning)
        } catch {
            return .unavailable(.notRunning)
        }
    }

    public func snapshots() -> AsyncStream<TailscaleStatus> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(await self.snapshot())
                    do {
                        try await Task.sleep(for: self.pollInterval)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func indicatesMissingSocket(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("no such file")
            || message.contains("not found")
            || message.contains("socket")
            || message.contains("enoent")
            || message.contains("connection refused")
    }
}
