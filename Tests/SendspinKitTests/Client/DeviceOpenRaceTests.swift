import Foundation
@testable import SendspinKit
import Testing

@Suite("Device open creation races")
struct DeviceOpenRaceTests {
    @Test("a lost create adopts the durable winner without saving the loser")
    func adoptsWinner() async throws {
        let winnerStorage = SnapshotExportStorage()
        let winner = try await SendspinDevice.open(storage: winnerStorage)
        let winnerSnapshot = try #require(await winnerStorage.snapshot())
        let storage = WinnerDeviceStorage(snapshot: winnerSnapshot)

        let opened = try await SendspinDevice.open(storage: storage)

        #expect(opened.clientId == winner.clientId)
        #expect(opened.makePairingToken() == winner.makePairingToken())
        #expect(await storage.createCount == 1)
        #expect(await storage.saveCount == 0)
    }

    @Test("a lost create with no durable winner fails without installing a loser")
    func missingWinnerFails() async throws {
        let storage = WinnerDeviceStorage(snapshot: nil)

        await #expect(throws: SendspinDeviceError.invalidSnapshot) {
            _ = try await SendspinDevice.open(storage: storage)
        }

        #expect(await storage.createCount == 1)
        #expect(await storage.saveCount == 0)
    }

    @Test("a lost create with an invalid durable winner fails without saving")
    func invalidWinnerFails() async throws {
        let storage = WinnerDeviceStorage(snapshot: Data())

        await #expect(throws: SendspinDeviceError.invalidSnapshot) {
            _ = try await SendspinDevice.open(storage: storage)
        }

        #expect(await storage.createCount == 1)
        #expect(await storage.saveCount == 0)
    }
}

private actor WinnerDeviceStorage: SendspinDeviceStorage {
    private let snapshot: Data?
    private var loadCount = 0
    private(set) var createCount = 0
    private(set) var saveCount = 0

    init(snapshot: Data?) {
        self.snapshot = snapshot
    }

    func load() async throws -> Data? {
        loadCount += 1
        return loadCount == 1 ? nil : snapshot
    }

    func create(_: Data) async throws -> Bool {
        createCount += 1
        return false
    }

    func save(_: Data) async throws {
        saveCount += 1
    }
}

private actor SnapshotExportStorage: SendspinDeviceStorage {
    private var value: Data?

    func load() async throws -> Data? {
        value
    }

    func create(_ data: Data) async throws -> Bool {
        guard value == nil else { return false }
        value = data
        return true
    }

    func save(_ data: Data) async throws {
        value = data
    }

    func snapshot() -> Data? {
        value
    }
}
