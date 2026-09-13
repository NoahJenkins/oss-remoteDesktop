import Foundation
import Network

public protocol LocalAPITransport: Sendable {
    func getStatusJSON() async throws -> Data
}

public struct MissingSocketError: Error, Equatable {}

public struct UnixLocalAPITransport: LocalAPITransport {
    public static let defaultSocketPaths: [String] = [
        "/var/run/tailscaled.socket",
        "/var/run/tailscale/tailscaled.socket",
        NSHomeDirectory() + "/Library/Group Containers/group.io.tailscale.ipn.macsys/tailscaled.sock",
    ]

    private let socketPaths: [String]

    public init(socketPaths: [String] = UnixLocalAPITransport.defaultSocketPaths) {
        self.socketPaths = socketPaths
    }

    public func getStatusJSON() async throws -> Data {
        guard let path = socketPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw MissingSocketError()
        }
        return try await Self.fetchStatus(socketPath: path)
    }

    private static func fetchStatus(socketPath: String) async throws -> Data {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        try await start(connection)
        let request = Data("GET /localapi/v0/status HTTP/1.0\r\nHost: local-tailscaled.sock\r\n\r\n".utf8)
        try await send(request, on: connection)
        let response = try await receiveAll(from: connection)
        connection.cancel()
        return httpBody(from: response)
    }

    private static func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = OnceResume(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    box.resume(returning: ())
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    box.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    box.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private static func receiveAll(from connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while true {
            let (chunk, isComplete) = try await receiveChunk(from: connection)
            buffer.append(chunk)
            if isComplete {
                return buffer
            }
        }
    }

    private static func receiveChunk(from connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (content ?? Data(), isComplete))
                }
            }
        }
    }

    private static func httpBody(from response: Data) -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: separator) else {
            return response
        }
        return response.subdata(in: range.upperBound ..< response.endIndex)
    }
}

private final class OnceResume<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
