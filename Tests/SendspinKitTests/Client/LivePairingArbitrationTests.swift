import Foundation
@testable import SendspinKit
import Testing

private enum LivePairingAttemptKind: String, CaseIterable, Sendable {
    case pairingPSK
    case dynamicCode
    case staticCode

    var method: String {
        switch self {
        case .pairingPSK: PairMethod.pairingPsk
        case .dynamicCode: PairMethod.dynamicPairingCode
        case .staticCode: PairMethod.staticPairingCode
        }
    }

    var format: String? {
        switch self {
        case .pairingPSK, .staticCode: nil
        case .dynamicCode: PairingCodeFormat.digits.rawValue
        }
    }

    var incumbentPSK: Psk {
        switch self {
        case .pairingPSK: Self.sharedPairingPSK
        case .dynamicCode, .staticCode: .sentinel
        }
    }

    var pairingConfiguration: PairingConfiguration {
        switch self {
        case .pairingPSK:
            PairingConfiguration(pairingPsk: Self.sharedPairingPSK, enabled: true)
        case .dynamicCode:
            PairingConfiguration(pairingPsk: Self.sharedPairingPSK, enabled: false, dynamicPairingCodeEnabled: true)
        case .staticCode:
            PairingConfiguration(
                pairingPsk: Self.sharedPairingPSK,
                enabled: false,
                staticPairingCode: "12345678",
                staticPairingCodeEnabled: true
            )
        }
    }

    private static let sharedPairingPSK = Psk.generate()
}

@MainActor
@Suite("Live pairing arbitration", .timeLimit(.minutes(1)))
struct LivePairingArbitrationTests {
    @Test("an active Pairing PSK attempt shields its connection from a competing pairing")
    func pairingPSKAttemptIsShielded() async throws {
        try await assertCompetingPairingIsRejected(for: .pairingPSK)
    }

    @Test("an active dynamic-code attempt shields its connection from a competing pairing")
    func dynamicAttemptIsShielded() async throws {
        try await assertCompetingPairingIsRejected(for: .dynamicCode)
    }

    @Test("an active pairing attempt rejects incoming playback with concurrent_attempt goodbye")
    func activeAttemptRejectsIncomingPlayback() async throws {
        let client = try makeClient(for: .dynamicCode)
        let incumbentTransport = MockTransport()
        let incumbent = MockNoiseServer(transport: incumbentTransport, psk: .sentinel)
        async let incumbentAccepted: Void = client.acceptConnection(incumbentTransport)
        try await incumbent.beginAdmission()
        try await sendPairingActivation(to: incumbent, kind: .dynamicCode)
        try await incumbentAccepted
        _ = try await waitForLivePairingMessage(incumbent, type: ClientPairInitMessage.typeString)

        let incumbentConnection = client.connection
        let candidateTransport = MockTransport()
        let candidate = MockNoiseServer(transport: candidateTransport, psk: .sentinel)
        async let candidateAccepted: Void = client.acceptConnection(candidateTransport)
        try await candidate.beginAdmission()
        try await candidate.sendActivation(activities: [.playback], activeRoles: [])
        try await candidateAccepted

        let goodbyeData = try await waitForLivePairingMessage(candidate, type: ClientGoodbyeMessage.typeString)
        let goodbye = try JSONDecoder().decode(ClientGoodbyeMessage.self, from: goodbyeData)
        #expect(goodbye.payload.reason == .concurrentAttempt)
        #expect(await waitUntil { await candidate.disconnectCalled })
        #expect(await candidate.clientJSONMessages(ofType: PairAbortMessage.typeString).isEmpty)
        #expect(client.connection === incumbentConnection)
        #expect(client.connectionState == .connected)
        await client.disconnect()
    }

    @Test("an active static-code attempt shields its connection from a competing pairing")
    func staticAttemptIsShielded() async throws {
        try await assertCompetingPairingIsRejected(for: .staticCode)
    }

    private func makeClient(for kind: LivePairingAttemptKind) throws -> SendspinClient {
        try SendspinClient(
            identity: .generate(),
            name: "Live Pairing Arbitration Client",
            roles: [],
            pairing: kind.pairingConfiguration,
            audioOutputCapabilityProvider: AudioOutputCapabilityService(),
            handshakeTimeout: .seconds(3)
        )
    }

    private func assertCompetingPairingIsRejected(for kind: LivePairingAttemptKind) async throws {
        let client = try makeClient(for: kind)
        let incumbentTransport = MockTransport()
        let incumbent = MockNoiseServer(transport: incumbentTransport, psk: kind.incumbentPSK)
        async let incumbentAccepted: Void = client.acceptConnection(incumbentTransport)
        try await incumbent.beginAdmission(pskCategory: kind == .pairingPSK ? .pairing : .sentinel)
        try await sendPairingActivation(to: incumbent, kind: kind)
        try await incumbentAccepted

        let firstMessageType = kind == .pairingPSK
            ? ClientPairFinalizeMessage.typeString
            : kind == .staticCode
            ? ClientPairPendingMessage.typeString
            : ClientPairInitMessage.typeString
        _ = try await waitForLivePairingMessage(incumbent, type: firstMessageType)
        if kind == .staticCode {
            let attemptID = try #require(await MainActor.run { client.currentPairing?.id })
            try await client.openPairingWindow(for: attemptID)
            _ = try await waitForLivePairingMessage(incumbent, type: ClientPairInitMessage.typeString)
        }

        let incumbentConnection = client.connection
        let candidateTransport = MockTransport()
        let candidate = MockNoiseServer(transport: candidateTransport, psk: kind.incumbentPSK)
        async let candidateAccepted: Void = client.acceptConnection(candidateTransport)
        try await candidate.beginAdmission(pskCategory: kind == .pairingPSK ? .pairing : .sentinel)
        try await sendPairingActivation(to: candidate, kind: kind)
        try await candidateAccepted

        let abortData = try await waitForLivePairingMessage(candidate, type: PairAbortMessage.typeString)
        let abort = try JSONDecoder().decode(PairAbortMessage.self, from: abortData)
        #expect(abort.payload.reason == .concurrentAttempt)
        #expect(await waitUntil { await candidate.disconnectCalled })
        #expect(await candidate.clientJSONMessages(ofType: ClientGoodbyeMessage.typeString).isEmpty)
        #expect(client.connection === incumbentConnection)
        #expect(client.connectionState == .connected)

        await client.disconnect()
    }
}

@MainActor
private func sendPairingActivation(
    to server: MockNoiseServer,
    kind: LivePairingAttemptKind
) async throws {
    let activation = ServerActivateMessage(
        payload: ServerActivatePayload(
            activities: [.pairing],
            activeRoles: [],
            pairing: PairingDirective(method: kind.method, format: kind.format)
        )
    )
    let data = try JSONEncoder().encode(activation)
    guard let text = String(data: data, encoding: .utf8) else {
        throw LivePairingArbitrationTestError.invalidActivation
    }
    try await server.sendJSON(text)
}

private func waitForLivePairingMessage(
    _ server: MockNoiseServer,
    type: String
) async throws -> Data {
    #expect(await waitUntil(timeout: .seconds(3)) {
        await server.clientJSONMessages(ofType: type).count >= 1
    })
    guard let message = await server.clientJSONMessages(ofType: type).last else {
        throw LivePairingArbitrationTestError.missingMessage(type)
    }
    return message
}

private enum LivePairingArbitrationTestError: Error {
    case invalidActivation
    case missingMessage(String)
}
