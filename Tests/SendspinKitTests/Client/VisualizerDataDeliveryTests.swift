import Foundation
@testable import SendspinKit
import Testing

struct VisualizerDataDeliveryTests {
    @Test("cancellation before parking lets a new iterator reclaim ownership")
    func cancellationBeforeParkDoesNotStealFrame() async {
        let mailbox = VisualizerDataMailbox(capacityBytes: 64)
        let cancelled = Task { () -> VisualizerData? in
            await Task.yield()
            var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
            return await iterator.next()
        }
        cancelled.cancel()
        #expect(await cancelled.value == nil)

        let value = VisualizerData(type: .peak, data: Data([1]), localDisplayTime: .max)
        mailbox.offer(value, now: 0)
        var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
        #expect(await iterator.next() == value)
        mailbox.finish()
    }

    @Test("cancellation while parked lets a new iterator reclaim ownership")
    func cancellationWhileParkedDoesNotStealFrame() async {
        let clock = MailboxTestClock()
        let mailbox = VisualizerDataMailbox(capacityBytes: 64, now: { clock.read() })
        let waiting = Task { () -> VisualizerData? in
            var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
            return await iterator.next()
        }
        #expect(await clock.waitUntilReadCount(2))
        waiting.cancel()
        #expect(await waiting.value == nil)

        let value = VisualizerData(type: .peak, data: Data([2]), localDisplayTime: .max)
        mailbox.offer(value, now: 0)
        var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
        #expect(await iterator.next() == value)
        mailbox.finish()
    }

    @Test("a second live iterator returns nil without replacing the owner")
    func iteratorOwnershipIsStable() async {
        let clock = MailboxTestClock()
        let mailbox = VisualizerDataMailbox(capacityBytes: 64, now: { clock.read() })
        let parked = Task { () -> VisualizerData? in
            var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
            return await iterator.next()
        }
        #expect(await clock.waitUntilReadCount(2))

        var second = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
        #expect(await second.next() == nil)
        let value = VisualizerData(type: .peak, data: Data([3]), localDisplayTime: .max)
        mailbox.offer(value, now: 0)
        #expect(await parked.value == value)
        mailbox.finish()
    }

    @Test("mailbox admission remains safe at Int.max capacity")
    func intMaxCapacityDoesNotOverflow() async {
        let mailbox = VisualizerDataMailbox(capacityBytes: .max)
        let value = VisualizerData(type: .loudness, data: Data([4, 5]), localDisplayTime: .max)
        mailbox.offer(value, now: 0)
        var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
        #expect(await iterator.next() == value)
        mailbox.finish()
    }

    @Test("mailbox rechecks a frame deadline after a waiter resumes")
    func resumedExpiredFrameIsDropped() async {
        let clock = MailboxTestClock(value: 0)
        let mailbox = VisualizerDataMailbox(capacityBytes: 64, now: { clock.read() })
        let pending = Task { () -> VisualizerData? in
            var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
            return await iterator.next()
        }
        #expect(await clock.waitUntilReadCount(2))
        clock.setValue(10)
        mailbox.offer(
            VisualizerData(type: .beat, data: Data([6]), localDisplayTime: 5),
            now: 0
        )
        mailbox.finish()
        #expect(await pending.value == nil)
    }

    @Test("a canceled read that was woken does not transfer its frame to a newer waiter")
    func cancellationAfterWakeDropsFrameWithoutStealing() async {
        let clock = MailboxTestClock()
        let mailbox = VisualizerDataMailbox(capacityBytes: 64, now: { clock.read() })
        let oldRead = Task { () -> VisualizerData? in
            var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
            return await iterator.next()
        }
        #expect(await clock.waitUntilReadCount(2))

        let first = VisualizerData(type: .peak, data: Data([7]), localDisplayTime: .max)
        mailbox.offer(first, now: 0)
        oldRead.cancel()

        let newer = Task { () -> VisualizerData? in
            var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
            return await iterator.next()
        }
        #expect(await clock.waitUntilReadCount(4))
        #expect(await oldRead.value == nil)

        let second = VisualizerData(type: .peak, data: Data([8]), localDisplayTime: .max)
        mailbox.offer(second, now: 0)
        #expect(await newer.value == second)
        mailbox.finish()
    }

    @Test("invalidation after a wake never delivers an invalid frame")
    func invalidationAfterWakeDropsFrame() async {
        let validity = VisualizerFrameValidity()
        let clock = MailboxTestClock(blockedRead: 3)
        let mailbox = VisualizerDataMailbox(capacityBytes: 64, now: { clock.read() })
        let pending = Task { () -> VisualizerData? in
            var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
            return await iterator.next()
        }
        #expect(await clock.waitUntilReadCount(2))

        let value = VisualizerData(
            type: .beat,
            data: Data([9]),
            localDisplayTime: .max,
            validity: validity
        )
        mailbox.offer(value, now: 0)
        #expect(await clock.waitUntilReadCount(3))
        validity.invalidate()
        clock.releaseBlockedRead()
        mailbox.finish()
        #expect(await pending.value == nil)
    }

    @Test("an abandoned iterator token releases ownership")
    func abandonedIteratorReclaimsOwnership() async {
        let mailbox = VisualizerDataMailbox(capacityBytes: 64)
        let first = VisualizerData(type: .peak, data: Data([10]), localDisplayTime: .max)
        mailbox.offer(first, now: 0)

        do {
            var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
            #expect(await iterator.next() == first)
        }
        await Task.yield()

        let second = VisualizerData(type: .peak, data: Data([11]), localDisplayTime: .max)
        mailbox.offer(second, now: 0)
        var replacement = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
        #expect(await replacement.next() == second)
        mailbox.finish()
    }

    @Test("consuming a frame releases its byte storage and linked-queue budget")
    func consumedFrameReleasesLinkedQueueBytes() async {
        let frameBytes = BinaryMessage.headerSize + 1
        let mailbox = VisualizerDataMailbox(capacityBytes: frameBytes * 2)
        let firstReleased = ByteReleaseProbe()
        offerTrackedFrame(firstReleased, to: mailbox, byte: 12)
        let second = VisualizerData(type: .loudness, data: Data([13]), localDisplayTime: .max)
        let third = VisualizerData(type: .loudness, data: Data([14]), localDisplayTime: .max)

        do {
            var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
            #expect(await (iterator.next())?.data == Data([12]))
            mailbox.offer(second, now: 0)
            mailbox.offer(third, now: 0)
            #expect(await iterator.next() == second)
            #expect(await iterator.next() == third)
        }
        #expect(firstReleased.wasReleased)
        mailbox.finish()
    }

    @Test("queued frames retain the configuration that validated them")
    func configurationSnapshotSurvivesUpdate() async {
        let old = VisualizerStreamConfiguration(
            types: [.spectrum],
            rateMax: 30,
            spectrum: SpectrumConfiguration(nDispBins: 2, scale: .lin, fMin: 20, fMax: 20_000)
        )
        let updated = VisualizerStreamConfiguration(types: [.loudness], rateMax: 60)
        let mailbox = VisualizerDataMailbox(capacityBytes: 128)
        let oldFrame = VisualizerData(
            type: .spectrum,
            data: Data([0, 1, 0, 2]),
            localDisplayTime: .max,
            streamConfiguration: old
        )
        let newFrame = VisualizerData(
            type: .loudness,
            data: Data([0, 3]),
            localDisplayTime: .max,
            streamConfiguration: updated
        )
        mailbox.offer(oldFrame, now: 0)
        mailbox.offer(newFrame, now: 0)

        var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
        #expect(await iterator.next()?.streamConfiguration == old)
        #expect(await iterator.next()?.streamConfiguration == updated)
        mailbox.finish()
    }

    @Test("mailbox keeps retained visualizer bytes within the exact wire budget")
    func byteBudgetDropsOldestFrames() async {
        let mailbox = VisualizerDataMailbox(capacityBytes: 22)
        let validity = VisualizerFrameValidity()
        let first = VisualizerData(
            type: .loudness,
            data: Data([1, 2]),
            localDisplayTime: .max,
            validity: validity
        )
        let second = VisualizerData(
            type: .loudness,
            data: Data([3, 4]),
            localDisplayTime: .max,
            validity: validity
        )
        let third = VisualizerData(
            type: .loudness,
            data: Data([5, 6]),
            localDisplayTime: .max,
            validity: validity
        )

        mailbox.offer(first, now: 0)
        mailbox.offer(second, now: 0)
        mailbox.offer(third, now: 0)

        var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
        #expect(await iterator.next() == second)
        #expect(await iterator.next() == third)
        mailbox.finish()
        #expect(await iterator.next() == nil)
    }

    @Test("an oversized visualizer frame never bypasses the byte cap")
    func oversizedFrameIsDropped() async {
        let mailbox = VisualizerDataMailbox(capacityBytes: BinaryMessage.headerSize + 1)
        let value = VisualizerData(
            type: .spectrum,
            data: Data(repeating: 0, count: 2),
            localDisplayTime: .max
        )
        mailbox.offer(value, now: 0)

        var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
        mailbox.finish()
        #expect(await iterator.next() == nil)
    }

    @Test("mailbox drops expired frames when a slow consumer resumes")
    func expiredFramesAreDroppedOnConsumption() async {
        let mailbox = VisualizerDataMailbox(capacityBytes: 64)
        let value = VisualizerData(type: .beat, data: Data([1]), localDisplayTime: 1)
        mailbox.offer(value, now: 0)

        let pending = Task { () -> VisualizerData? in
            var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
            return await iterator.next()
        }
        let observation = await observeTask(
            pending,
            timeout: .milliseconds(50),
            onTimeout: { mailbox.finish() }
        )
        switch observation {
        case .timedOut:
            break
        case let .completed(value):
            Issue.record("dropping an expired frame must keep a live mailbox open; got \(String(describing: value))")
        }
        mailbox.finish()
    }

    @Test("clear releases all retained visualizer frames")
    func clearDropsQueuedFrames() async {
        let mailbox = VisualizerDataMailbox(capacityBytes: 64)
        mailbox.offer(
            VisualizerData(type: .peak, data: Data([1]), localDisplayTime: .max),
            now: 0
        )
        mailbox.clear()

        var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
        mailbox.finish()
        #expect(await iterator.next() == nil)
    }

    @Test("parked clear, end, and teardown preserve the primary mailbox")
    func parkedDeliveryDoesNotClearPrimaryMailbox() {
        let mailbox = VisualizerDataMailbox(capacityBytes: 64)
        let primary = makeConnectionDataDelivery(mailbox: mailbox)
        let parked = makeConnectionDataDelivery(mailbox: mailbox)
        primary.promoteToPrimary()
        let frame = VisualizerData(type: .peak, data: Data([15, 16]), localDisplayTime: .max)
        primary.offerVisualizerIfValid(frame, validity: SessionValidityToken())
        #expect(mailbox.retainedByteCount == frame.frameByteCount)

        for _ in 0 ..< 3 {
            parked.clearVisualizer()
            #expect(mailbox.retainedByteCount == frame.frameByteCount)
        }

        primary.clearVisualizer()
        #expect(mailbox.retainedByteCount == 0)
        mailbox.finish()
    }

    @Test("primary delivery clear releases retained bytes immediately")
    func primaryDeliveryClearsMailboxImmediately() {
        let mailbox = VisualizerDataMailbox(capacityBytes: 64)
        let primary = makeConnectionDataDelivery(mailbox: mailbox)
        primary.promoteToPrimary()
        let frame = VisualizerData(type: .peak, data: Data([17, 18]), localDisplayTime: .max)
        primary.offerVisualizerIfValid(frame, validity: SessionValidityToken())
        #expect(mailbox.retainedByteCount == frame.frameByteCount)

        primary.clearVisualizer()

        #expect(mailbox.retainedByteCount == 0)
        mailbox.finish()
    }

    @Test("mailbox preserves FIFO order among retained frames")
    func retainedFramesRemainFifo() async {
        let mailbox = VisualizerDataMailbox(capacityBytes: 64)
        let values = (0 ..< 4).map { index in
            VisualizerData(type: .loudness, data: Data([UInt8(index)]), localDisplayTime: .max)
        }
        for value in values {
            mailbox.offer(value, now: 0)
        }

        var iterator = VisualizerDataStream(mailbox: mailbox).makeAsyncIterator()
        for value in values {
            #expect(await iterator.next() == value)
        }
        mailbox.finish()
    }
}

private func makeConnectionDataDelivery(mailbox: VisualizerDataMailbox) -> ConnectionDataDelivery {
    let (_, audio) = AsyncStream<AudioChunk>.makeStream()
    let (_, artwork) = AsyncStream<ArtworkData>.makeStream()
    return ConnectionDataDelivery(
        audio: audio,
        artwork: artwork,
        visualizer: mailbox,
        artworkObserver: nil
    )
}

private final class ByteReleaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    var wasReleased: Bool {
        lock.withLock { released }
    }

    func markReleased() {
        lock.withLock { released = true }
    }
}

private func offerTrackedFrame(_ probe: ByteReleaseProbe, to mailbox: VisualizerDataMailbox, byte: UInt8) {
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    pointer.initializeMemory(as: UInt8.self, repeating: byte, count: 1)
    let data = Data(bytesNoCopy: pointer, count: 1, deallocator: .custom { pointer, _ in
        pointer.deallocate()
        probe.markReleased()
    })
    mailbox.offer(VisualizerData(type: .loudness, data: data, localDisplayTime: .max), now: 0)
}

private final class MailboxTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    private var readCount = 0
    private let blockedRead: Int?
    private let release = DispatchSemaphore(value: 0)

    init(value: Int64 = 0, blockedRead: Int? = nil) {
        self.value = value
        self.blockedRead = blockedRead
    }

    func read() -> Int64 {
        let shouldBlock = lock.withLock {
            readCount += 1
            return readCount == blockedRead
        }
        if shouldBlock {
            release.wait()
        }
        return lock.withLock { value }
    }

    func setValue(_ value: Int64) {
        lock.withLock { self.value = value }
    }

    func waitUntilReadCount(_ target: Int) async -> Bool {
        for _ in 0 ..< 10_000 {
            if lock.withLock({ readCount >= target }) {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func releaseBlockedRead() {
        release.signal()
    }
}
