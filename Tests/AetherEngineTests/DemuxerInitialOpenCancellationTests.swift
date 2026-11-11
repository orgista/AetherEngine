import Foundation
import Network
import os
import Testing
@testable import AetherEngine

struct DemuxerInitialOpenCancellationTests {
    @Test(.timeLimit(.minutes(1)))
    func cancellationBeforeOpenDoesNotCreateAnOriginRequest() async throws {
        let origin = try await NoBytesOrigin.start()
        defer { origin.stop() }
        let demuxer = Demuxer()
        demuxer.markClosed()
        let url = try origin.url()
        let cancelled = await Task.detached {
            do {
                try demuxer.open(url: url)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        #expect(cancelled)
        #expect(!origin.hasOpenRequests)
        demuxer.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAnInitialOpenClosesTheOriginBeforeItsTimeout() async throws {
        let origin = try await NoBytesOrigin.start()
        defer { origin.stop() }
        let demuxer = Demuxer()
        let url = try origin.url()
        let opening = Task.detached { () -> Bool in
            do {
                try demuxer.open(url: url)
                return true
            } catch {
                return false
            }
        }
        let received = await Task.detached { waitForSignal(origin.request) }.value
        let stopped = ContinuousClock.now
        demuxer.markClosed()
        while origin.hasOpenRequests && stopped.duration(to: .now) < .seconds(1) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let closeLatency = stopped.duration(to: .now)
        let requestsClosedPromptly = !origin.hasOpenRequests
        origin.stop()
        let didOpen = await opening.value
        #expect(received == .success)
        #expect(!didOpen)
        #expect(requestsClosedPromptly, "The initial no-bytes connection must be cancelled")
        #expect(closeLatency < .milliseconds(250), "Origin close took \(closeLatency)")
        demuxer.close()
    }
}

private final class NoBytesOrigin: Sendable {
    private struct State {
        var connections: [UUID: NWConnection] = [:]
        var requests: Set<UUID> = []
        var closed: Set<UUID> = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let listener: NWListener
    private let ready = DispatchSemaphore(value: 0)
    let request = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "engine-test.no-bytes-origin")

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [ready] state in
            switch state {
            case .ready, .failed: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            self.state.withLock { $0.connections[id] = connection }
            connection.start(queue: self.queue)
            self.receive(connection, id: id)
        }
        listener.start(queue: queue)
    }

    static func start() async throws -> NoBytesOrigin {
        let origin = try NoBytesOrigin()
        let status = await Task.detached { waitForSignal(origin.ready) }.value
        try #require(status == .success)
        return origin
    }

    func url() throws -> URL {
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/never.mkv"))
    }

    var hasOpenRequests: Bool {
        state.withLock { !$0.requests.subtracting($0.closed).isEmpty }
    }

    private func receive(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.state.withLock { _ = $0.requests.insert(id) }
                self.request.signal()
            }
            if complete || error != nil {
                self.state.withLock { _ = $0.closed.insert(id) }
                connection.cancel()
            } else {
                self.receive(connection, id: id)
            }
        }
    }

    func stop() {
        listener.cancel()
        let connections = state.withLock { Array($0.connections.values) }
        for connection in connections { connection.cancel() }
    }
}

private func waitForSignal(_ signal: DispatchSemaphore) -> DispatchTimeoutResult {
    signal.wait(timeout: .now() + 2)
}
