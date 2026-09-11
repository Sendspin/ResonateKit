import Foundation
@testable import SendspinKit
import Testing

@MainActor
struct AdvertisingTests {
    @Test("startAdvertising waits for listener readiness")
    func waitsForReadiness() async throws {
        let mock = MockClientAdvertiser()
        let client = try makeClient { _, _, _ in mock }
        let starting = Task { @MainActor in try await client.startAdvertising() }

        #expect(await waitUntil { await mock.startWaiting })
        #expect(client.listenerState == .starting)
        #expect(!starting.isCancelled)

        await mock.signalReady()
        try await starting.value
        #expect(client.listenerState == .running)
        await client.close()
    }

    @Test("startup failure does not leave a listener installed")
    func startupFailure() async throws {
        let mock = MockClientAdvertiser()
        await mock.failStart(TestAdvertisingError.startup)
        let client = try makeClient { _, _, _ in mock }

        await #expect(throws: TestAdvertisingError.startup) {
            try await client.startAdvertising()
        }
        #expect(client.listenerState == .failed(TestAdvertisingError.startup.localizedDescription))
        #expect(client.advertiser == nil)
        #expect(await mock.stopCalled)
    }

    @Test("cancelling startup stops the candidate advertiser")
    func cancellation() async throws {
        let mock = MockClientAdvertiser()
        let client = try makeClient { _, _, _ in mock }
        let starting = Task { @MainActor in try await client.startAdvertising() }
        #expect(await waitUntil { await mock.startCalled })

        starting.cancel()
        _ = await starting.result
        #expect(await waitUntil { await mock.stopCalled })
        #expect(client.advertiser == nil)
    }

    @Test("duplicate startup callers share one readiness operation")
    func duplicateStartWaiters() async throws {
        let mock = MockClientAdvertiser()
        await mock.configure(port: 9_321, path: "/custom")
        let client = try makeClient { _, _, _ in mock }
        let first = Task { @MainActor in try await client.startAdvertising(port: 9_321, path: "/custom") }
        #expect(await waitUntil { await mock.startCalled })
        let second = Task { @MainActor in try await client.startAdvertising(port: 9_321, path: "/custom") }
        #expect(await waitUntil { await mock.startCount == 1 })
        #expect(await mock.startCount == 1)
        await mock.signalReady()
        try await first.value
        try await second.value
        #expect(await mock.receivedPort == 9_321)
        #expect(await mock.receivedPath == "/custom")
        await client.close()
    }

    @Test("a running listener rejects a changed endpoint")
    func endpointMismatch() async throws {
        let mock = MockClientAdvertiser()
        let client = try makeClient { _, _, _ in mock }
        let start = Task { @MainActor in try await client.startAdvertising(port: 9_321, path: "/custom") }
        #expect(await waitUntil { await mock.startWaiting })
        await mock.signalReady()
        try await start.value

        await #expect(throws: SendspinClientError.modeConflict) {
            try await client.startAdvertising(port: 9_322, path: "/custom")
        }
        #expect(await mock.startCount == 1)
        await client.close()
    }

    @Test("startup failure can be retried with a fresh advertiser")
    func startupFailureCanRetry() async throws {
        let first = MockClientAdvertiser()
        let second = MockClientAdvertiser()
        await first.failStart(TestAdvertisingError.startup)
        let client = try makeClient { _, _, _ in first }

        await #expect(throws: TestAdvertisingError.startup) {
            try await client.startAdvertising()
        }
        client.advertisingFactory = { _, _, _ in second }
        let retry = Task { @MainActor in try await client.startAdvertising() }
        #expect(await waitUntil { await second.startWaiting })
        await second.signalReady()
        try await retry.value
        #expect(client.listenerState == .running)
        await client.close()
    }

    @Test("a finished connection stream leaves running state")
    func connectionStreamFinishes() async throws {
        let mock = MockClientAdvertiser()
        let client = try makeClient { _, _, _ in mock }
        let start = Task { @MainActor in try await client.startAdvertising() }
        #expect(await waitUntil { await mock.startWaiting })
        await mock.signalReady()
        try await start.value
        await mock.finishConnections()
        #expect(await waitUntil { await MainActor.run { client.listenerState != .running } })
        #expect(client.listenerState == .failed("The advertising listener stopped unexpectedly"))
        await client.close()
    }

    @Test("stop advertising uses a fresh advertiser on restart")
    func stopAndRestart() async throws {
        let first = MockClientAdvertiser()
        let second = MockClientAdvertiser()
        let client = try makeClient { _, _, _ in first }

        let firstStart = Task { @MainActor in try await client.startAdvertising() }
        #expect(await waitUntil { await first.startCalled })
        await first.signalReady()
        try await firstStart.value
        await client.stopAdvertising()
        #expect(client.listenerState == .stopped)
        #expect(await first.stopCalled)

        client.advertisingFactory = { _, _, _ in second }
        let secondStart = Task { @MainActor in try await client.startAdvertising() }
        #expect(await waitUntil { await second.startCalled })
        await second.signalReady()
        try await secondStart.value
        #expect(await second.startCount == 1)
        await client.close()
    }

    @Test("outgoing connect conflicts with an active listener")
    func outgoingModeConflict() async throws {
        let mock = MockClientAdvertiser()
        let client = try makeClient { _, _, _ in mock }
        let starting = Task { @MainActor in try await client.startAdvertising() }
        #expect(await waitUntil { await mock.startCalled })

        await #expect(throws: SendspinClientError.modeConflict) {
            try await client.connect(to: #require(URL(string: "ws://127.0.0.1/sendspin")))
        }
        starting.cancel()
        _ = await starting.result
        await client.close()
    }

    @Test("pending admission is bounded and overflow is disconnected")
    func pendingAdmissionIsBounded() async throws {
        let mock = MockClientAdvertiser()
        let client = try makeClient { _, _, _ in mock }
        let starting = Task { @MainActor in try await client.startAdvertising() }
        #expect(await waitUntil { await mock.startCalled })
        await mock.signalReady()
        try await starting.value

        // Fill every admission slot before yielding the overflow candidate. Waiting for
        // each handshake's first write proves the child is parked, rather than relying on
        // task scheduling to make a burst arrive in the expected order.
        let pending = (0 ..< clientAdvertiserPendingLimit).map { _ in MockTransport() }
        for transport in pending {
            await mock.yield(transport)
            #expect(await waitUntil { await transport.hasSentFrames })
        }
        let overflow = MockTransport()
        await mock.yield(overflow)

        #expect(await waitUntil { await overflow.disconnectCalled })
        #expect(await overflow.disconnectCallCount == 1)
        for transport in pending {
            #expect(await !transport.disconnectCalled)
        }
        await client.stopAdvertising()
    }

    @Test("unexpected listener completion preserves an admitted session")
    func connectionStreamCompletionPreservesAdmittedSession() async throws {
        let mock = MockClientAdvertiser()
        let client = try makeClient { _, _, _ in mock }
        let starting = Task { @MainActor in try await client.startAdvertising() }
        #expect(await waitUntil { await mock.startCalled })
        await mock.signalReady()
        try await starting.value

        let transport = MockTransport()
        let server = MockNoiseServer(transport: transport, psk: .sentinel)
        await mock.yield(transport)
        #expect(await waitUntil { await transport.hasSentFrames })
        try await server.establishSession(activities: [], activeRoles: [])
        #expect(await waitUntil { await MainActor.run { client.connectionState == .connected } })
        #expect(client.connection != nil)

        await mock.finishConnections()
        #expect(await waitUntil { await MainActor.run { client.listenerState != .running } })
        #expect(client.listenerState == .failed("The advertising listener stopped unexpectedly"))
        #expect(client.connection != nil)
        #expect(client.connectionState == .connected)
        #expect(await !transport.disconnectCalled)
        await client.close()
    }

    @Test("close tears down an active listener")
    func closeStopsAdvertising() async throws {
        let mock = MockClientAdvertiser()
        let client = try makeClient { _, _, _ in mock }
        let starting = Task { @MainActor in try await client.startAdvertising() }
        #expect(await waitUntil { await mock.startCalled })
        await mock.signalReady()
        try await starting.value

        await client.close()
        #expect(await mock.stopCalled)
        #expect(client.listenerState == .stopped)
    }

    private func makeClient(
        factory: @escaping @Sendable (String, UInt16, String) -> any ClientAdvertising
    ) throws -> SendspinClient {
        let client = try SendspinClient(identity: .generate(), name: "Advertising Test", roles: [.metadataV1])
        client.advertisingFactory = factory
        return client
    }
}

private enum TestAdvertisingError: Error, Equatable, LocalizedError, Sendable {
    case startup

    var errorDescription: String? {
        "advertiser startup failed"
    }
}

private actor MockClientAdvertiser: ClientAdvertising {
    nonisolated let connections: AsyncStream<any SendspinTransport>
    private let continuation: AsyncStream<any SendspinTransport>.Continuation
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var configuredError: Error?
    private var configuredPort: UInt16?
    private var configuredPath: String?
    private(set) var receivedPort: UInt16?
    private(set) var receivedPath: String?
    private(set) var startCalled = false
    private(set) var startCount = 0
    private(set) var startWaiting = false
    private(set) var stopCalled = false

    init() {
        (connections, continuation) = AsyncStream.makeStream()
    }

    func matches(port: UInt16, path: String) -> Bool {
        configuredPort == port && configuredPath == path
    }

    func start() async throws {
        startCalled = true
        startCount += 1
        startWaiting = true
        if let configuredError {
            throw configuredError
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancelStart() }
        }
    }

    func stop() async {
        stopCalled = true
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
        continuation.finish()
    }

    func configure(port: UInt16, path: String) {
        configuredPort = port
        configuredPath = path
        receivedPort = port
        receivedPath = path
    }

    func finishConnections() {
        continuation.finish()
    }

    func yield(_ transport: any SendspinTransport) {
        continuation.yield(transport)
    }

    func failStart(_ error: Error) {
        configuredError = error
    }

    func signalReady() {
        startContinuation?.resume()
        startContinuation = nil
    }

    private func cancelStart() {
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
    }
}
