import Foundation
@testable import SendspinKit
import Testing

struct VisualizerFrameDeliveryTests {
    private let configuration = VisualizerStreamConfiguration(types: [.peak, .loudness, .beat, .spectrum], rateMax: 60)

    @Test("a canceled subscription releases mailbox ownership")
    func cancellationReleasesOwnership() async throws {
        let mailbox = VisualizerFrameMailbox(capacityBytes: 64)
        let first = try VisualizerFrameSubscription(acquiring: mailbox)
        first.cancel()
        let second = try VisualizerFrameSubscription(acquiring: mailbox)
        mailbox.offer(frame(type: .peak, byte: 1, at: .max), now: PresentationInstant(rawMicroseconds: 0))
        var iterator = second.makeAsyncIterator()
        #expect(await iterator.next()?.data == Data([1]))
        mailbox.finish()
    }

    @Test("a pending read cancellation releases ownership")
    func pendingCancellationReleasesOwnership() async throws {
        let clock = MailboxTestClock()
        let mailbox = VisualizerFrameMailbox(capacityBytes: 64, now: { clock.now })
        let first = try VisualizerFrameSubscription(acquiring: mailbox)
        let pending = Task { var iterator = first.makeAsyncIterator(); return await iterator.next() }
        #expect(await clock.waitUntilReadCount(1))
        pending.cancel()
        let observation = await observeTask(
            pending,
            timeout: .seconds(1),
            onTimeout: { mailbox.finish() }
        )
        guard case let .completed(value) = observation else {
            Issue.record("cancelled mailbox read did not finish")
            mailbox.finish()
            return
        }
        #expect(value == nil)
        let second = try VisualizerFrameSubscription(acquiring: mailbox)
        mailbox.offer(frame(type: .peak, byte: 2, at: .max), now: PresentationInstant(rawMicroseconds: 0))
        var iterator = second.makeAsyncIterator()
        #expect(await iterator.next()?.data == Data([2]))
        mailbox.finish()
    }

    @Test("an old iterator cannot consume a replacement after cancellation")
    func oldIteratorAfterCancellationDoesNotConsumeReplacement() async throws {
        let mailbox = VisualizerFrameMailbox(capacityBytes: 64)
        let first = try VisualizerFrameSubscription(acquiring: mailbox)
        var oldIterator = first.makeAsyncIterator()
        first.cancel()

        let replacement = try VisualizerFrameSubscription(acquiring: mailbox)
        let replacementFrame = frame(type: .peak, byte: 19, at: .max)
        mailbox.offer(replacementFrame, now: PresentationInstant(rawMicroseconds: 0))

        #expect(await oldIterator.next() == nil)
        var replacementIterator = replacement.makeAsyncIterator()
        #expect(await replacementIterator.next() == replacementFrame)
        mailbox.finish()
    }

    @Test("subscription deinit revokes an old iterator lease")
    func subscriptionDeinitRevokesOldIteratorLease() async throws {
        let mailbox = VisualizerFrameMailbox(capacityBytes: 64)
        var oldIterator: VisualizerFrameSubscription.Iterator?
        do {
            let first = try VisualizerFrameSubscription(acquiring: mailbox)
            oldIterator = first.makeAsyncIterator()
        }

        let replacement = try VisualizerFrameSubscription(acquiring: mailbox)
        let replacementFrame = frame(type: .peak, byte: 24, at: .max)
        mailbox.offer(replacementFrame, now: PresentationInstant(rawMicroseconds: 0))

        var staleIterator = try #require(oldIterator)
        #expect(await staleIterator.next() == nil)
        var replacementIterator = replacement.makeAsyncIterator()
        #expect(await replacementIterator.next() == replacementFrame)
        mailbox.finish()
    }

    @Test("explicit cancellation between the immediate check and park is a barrier")
    func explicitCancellationImmediateCheckToParkBarrier() async throws {
        let reachedParkBarrier = AsyncTestBarrier()
        let releaseParkBarrier = AsyncTestBarrier()
        let mailbox = VisualizerFrameMailbox(
            capacityBytes: 64,
            beforePark: {
                await reachedParkBarrier.signalReached()
                await releaseParkBarrier.waitUntilReleased()
            }
        )
        let first = try VisualizerFrameSubscription(acquiring: mailbox)
        let pending = Task {
            var iterator = first.makeAsyncIterator()
            return await iterator.next()
        }

        defer {
            first.cancel()
            Task { await releaseParkBarrier.release() }
            mailbox.finish()
        }
        try #require(await reachedParkBarrier.waitUntilReached())
        first.cancel()
        await releaseParkBarrier.release()
        let observation = await observeTask(
            pending,
            timeout: .seconds(1),
            onTimeout: {
                mailbox.finish()
                await releaseParkBarrier.release()
            }
        )
        guard case let .completed(value) = observation else {
            Issue.record("cancelled parked read did not finish")
            return
        }
        #expect(value == nil)

        let replacement = try VisualizerFrameSubscription(acquiring: mailbox)
        let replacementFrame = frame(type: .peak, byte: 20, at: .max)
        mailbox.offer(replacementFrame, now: PresentationInstant(rawMicroseconds: 0))
        var replacementIterator = replacement.makeAsyncIterator()
        #expect(await replacementIterator.next() == replacementFrame)
        mailbox.finish()
    }

    @Test("explicit cancellation after handoff drops the old frame")
    func explicitCancellationAfterHandoff() async throws {
        let reachedParkBarrier = AsyncTestBarrier()
        let releaseParkBarrier = AsyncTestBarrier()
        let reachedHandoffBarrier = AsyncTestBarrier()
        let releaseHandoffBarrier = AsyncTestBarrier()
        let mailbox = VisualizerFrameMailbox(
            capacityBytes: 64,
            beforePark: {
                await reachedParkBarrier.signalReached()
                await releaseParkBarrier.waitUntilReleased()
            },
            beforePostHandoffCheck: {
                await reachedHandoffBarrier.signalReached()
                await releaseHandoffBarrier.waitUntilReleased()
            }
        )
        let first = try VisualizerFrameSubscription(acquiring: mailbox)
        let pending = Task {
            var iterator = first.makeAsyncIterator()
            return await iterator.next()
        }
        defer {
            first.cancel()
            Task {
                await releaseParkBarrier.release()
                await releaseHandoffBarrier.release()
            }
            mailbox.finish()
        }
        try #require(await reachedParkBarrier.waitUntilReached())
        await releaseParkBarrier.release()
        mailbox.offer(frame(type: .peak, byte: 21, at: .max), now: PresentationInstant(rawMicroseconds: 0))
        try #require(await reachedHandoffBarrier.waitUntilReached())
        first.cancel()
        await releaseHandoffBarrier.release()
        let observation = await observeTask(
            pending,
            timeout: .seconds(1),
            onTimeout: {
                mailbox.finish()
                await releaseHandoffBarrier.release()
            }
        )
        guard case let .completed(value) = observation else {
            Issue.record("cancelled handed-off read did not finish")
            return
        }
        #expect(value == nil)
        await releaseHandoffBarrier.release()
        mailbox.finish()
    }

    @Test("task cancellation after handoff drops the old frame")
    func taskCancellationAfterHandoff() async throws {
        let reachedParkBarrier = AsyncTestBarrier()
        let releaseParkBarrier = AsyncTestBarrier()
        let reachedHandoffBarrier = AsyncTestBarrier()
        let releaseHandoffBarrier = AsyncTestBarrier()
        let mailbox = VisualizerFrameMailbox(
            capacityBytes: 64,
            beforePark: {
                await reachedParkBarrier.signalReached()
                await releaseParkBarrier.waitUntilReleased()
            },
            beforePostHandoffCheck: {
                await reachedHandoffBarrier.signalReached()
                await releaseHandoffBarrier.waitUntilReleased()
            }
        )
        let subscription = try VisualizerFrameSubscription(acquiring: mailbox)
        let pending = Task {
            var iterator = subscription.makeAsyncIterator()
            return await iterator.next()
        }
        defer {
            pending.cancel()
            Task {
                await releaseParkBarrier.release()
                await releaseHandoffBarrier.release()
            }
            mailbox.finish()
        }
        try #require(await reachedParkBarrier.waitUntilReached())
        await releaseParkBarrier.release()
        mailbox.offer(frame(type: .peak, byte: 25, at: .max), now: PresentationInstant(rawMicroseconds: 0))

        try #require(await reachedHandoffBarrier.waitUntilReached())
        pending.cancel()
        await releaseHandoffBarrier.release()
        let observation = await observeTask(
            pending,
            timeout: .seconds(1),
            onTimeout: {
                mailbox.finish()
                await releaseHandoffBarrier.release()
            }
        )
        guard case let .completed(value) = observation else {
            Issue.record("task-cancelled handed-off read did not finish")
            return
        }
        #expect(value == nil)
        subscription.cancel()

        await releaseHandoffBarrier.release()
        mailbox.finish()
    }

    @Test("copied iterators share one parked read and preserve the original")
    func copiedIteratorsShareOneInFlightRead() async throws {
        let clock = MailboxTestClock()
        let reachedPark = AsyncTestBarrier()
        let releasePark = AsyncTestBarrier()
        let mailbox = VisualizerFrameMailbox(
            capacityBytes: 64,
            now: { clock.now },
            beforePark: {
                await reachedPark.signalReached()
                await releasePark.waitUntilReleased()
            }
        )
        let subscription = try VisualizerFrameSubscription(acquiring: mailbox)
        let first = subscription.makeAsyncIterator()
        var copy = first
        let pending = Task {
            var iterator = first
            return await iterator.next()
        }

        try #require(await reachedPark.waitUntilReached())
        defer {
            pending.cancel()
            Task { await releasePark.release() }
            mailbox.finish()
        }
        let parkedReadCount = clock.readCountSnapshot
        #expect(await copy.next() == nil)
        #expect(clock.readCountSnapshot == parkedReadCount)
        await releasePark.release()

        let value = frame(type: .peak, byte: 23, at: .max)
        mailbox.offer(value, now: PresentationInstant(rawMicroseconds: 0))
        let observation = await observeTask(
            pending,
            timeout: .seconds(1),
            onTimeout: {
                mailbox.finish()
                await releasePark.release()
            }
        )
        guard case let .completed(result) = observation else {
            Issue.record("copied iterator's parked read did not finish")
            return
        }
        #expect(result == value)
    }

    @Test("a second active subscription throws without replacing the owner")
    func secondSubscriptionIsRejected() throws {
        let mailbox = VisualizerFrameMailbox(capacityBytes: 64)
        let first = try VisualizerFrameSubscription(acquiring: mailbox)
        #expect(throws: VisualizerFrameAcquisitionError.consumerAlreadyActive) {
            _ = try VisualizerFrameSubscription(acquiring: mailbox)
        }
        first.cancel()
        mailbox.finish()
    }

    @Test("a subscription ends duplicate iterators without entering mailbox reads")
    func duplicateIteratorEndsImmediately() async throws {
        let mailbox = VisualizerFrameMailbox(capacityBytes: 64)
        let subscription = try VisualizerFrameSubscription(acquiring: mailbox)
        var primary = subscription.makeAsyncIterator()
        var duplicate = subscription.makeAsyncIterator()

        #expect(await duplicate.next() == nil)

        mailbox.offer(frame(type: .peak, byte: 10, at: .max), now: PresentationInstant(rawMicroseconds: 0))
        #expect(await primary.next()?.data == Data([10]))
        mailbox.finish()
    }

    @Test("scheduling eligibility is separate from validity at presentation")
    func dueFrameCanRemainValid() {
        let validity = VisualizerFrameValidity()
        let frame = frame(type: .peak, byte: 3, at: 10, validity: validity)
        #expect(frame.eligibilityForScheduling(at: PresentationInstant(rawMicroseconds: 9)))
        #expect(frame.eligibilityForScheduling(at: PresentationInstant(rawMicroseconds: 10)) == false)
        #expect(frame.isValid)
        validity.invalidate()
        #expect(frame.isValid == false)
        #expect(frame.eligibilityForScheduling(at: PresentationInstant(rawMicroseconds: 9)) == false)
    }

    @Test("invalidated frames are not delivered after a waiter wakes")
    func invalidationAfterWakeDropsFrame() async throws {
        let validity = VisualizerFrameValidity()
        let clock = MailboxTestClock()
        let reachedParkBarrier = AsyncTestBarrier()
        let releaseParkBarrier = AsyncTestBarrier()
        let reachedHandoffBarrier = AsyncTestBarrier()
        let releaseHandoffBarrier = AsyncTestBarrier()
        let mailbox = VisualizerFrameMailbox(
            capacityBytes: 64,
            now: { clock.now },
            beforePark: {
                await reachedParkBarrier.signalReached()
                await releaseParkBarrier.waitUntilReleased()
            },
            beforePostHandoffCheck: {
                await reachedHandoffBarrier.signalReached()
                await releaseHandoffBarrier.waitUntilReleased()
            }
        )
        let subscription = try VisualizerFrameSubscription(acquiring: mailbox)
        let pending = Task { var iterator = subscription.makeAsyncIterator(); return await iterator.next() }
        defer {
            Task {
                await releaseParkBarrier.release()
                await releaseHandoffBarrier.release()
            }
            mailbox.finish()
        }
        try #require(await reachedParkBarrier.waitUntilReached())
        await releaseParkBarrier.release()
        mailbox.offer(frame(type: .beat, byte: 4, at: .max, validity: validity), now: PresentationInstant(rawMicroseconds: 0))
        try #require(await reachedHandoffBarrier.waitUntilReached())
        validity.invalidate()
        await releaseHandoffBarrier.release()
        mailbox.finish()
        let observation = await observeTask(
            pending,
            timeout: .seconds(1),
            onTimeout: {
                mailbox.finish()
                await releaseHandoffBarrier.release()
            }
        )
        guard case let .completed(value) = observation else {
            Issue.record("invalidated handed-off read did not finish")
            return
        }
        #expect(value == nil)
    }

    @Test("mailbox drops expired frames but keeps future frames FIFO")
    func expirationAndFIFO() async throws {
        let clock = MailboxTestClock(value: 0)
        let mailbox = VisualizerFrameMailbox(capacityBytes: 64, now: { clock.now })
        let subscription = try VisualizerFrameSubscription(acquiring: mailbox)
        mailbox.offer(frame(type: .peak, byte: 5, at: 1), now: PresentationInstant(rawMicroseconds: 0))
        mailbox.offer(frame(type: .peak, byte: 6, at: 20), now: PresentationInstant(rawMicroseconds: 0))
        clock.setValue(10)
        var iterator = subscription.makeAsyncIterator()
        #expect(await iterator.next()?.data == Data([6]))
        mailbox.finish()
    }

    @Test("mailbox enforces the exact wire byte budget")
    func byteBudgetDropsOldestFrames() async throws {
        let frameBytes = BinaryMessage.headerSize + Data([UInt8(7)]).count
        let mailbox = VisualizerFrameMailbox(capacityBytes: frameBytes * 2)
        let subscription = try VisualizerFrameSubscription(acquiring: mailbox)
        mailbox.offer(frame(type: .peak, byte: 7, at: .max), now: PresentationInstant(rawMicroseconds: 0))
        mailbox.offer(frame(type: .peak, byte: 8, at: .max), now: PresentationInstant(rawMicroseconds: 0))
        mailbox.offer(frame(type: .peak, byte: 9, at: .max), now: PresentationInstant(rawMicroseconds: 0))
        var iterator = subscription.makeAsyncIterator()
        try #require(mailbox.retainedByteCount == frameBytes * 2)
        #expect(await iterator.next()?.data == Data([8]))
        #expect(await iterator.next()?.data == Data([9]))
        mailbox.finish()
    }

    @Test("mailbox admission remains safe at Int.max capacity")
    func intMaxCapacityDoesNotOverflow() async throws {
        let mailbox = VisualizerFrameMailbox(capacityBytes: .max)
        let subscription = try VisualizerFrameSubscription(acquiring: mailbox)
        let value = frame(type: .loudness, byte: 4, at: .max)
        mailbox.offer(value, now: PresentationInstant(rawMicroseconds: 0))
        var iterator = subscription.makeAsyncIterator()
        #expect(await iterator.next() == value)
        mailbox.finish()
    }

    @Test("an oversized visualizer frame never bypasses the byte cap")
    func oversizedFrameIsDropped() throws {
        let mailbox = VisualizerFrameMailbox(capacityBytes: BinaryMessage.headerSize + 1)
        _ = try VisualizerFrameSubscription(acquiring: mailbox)
        let oversized = VisualizerFrame(
            type: .loudness,
            data: Data([1, 2]),
            presentationTime: PresentationInstant(rawMicroseconds: .max),
            configuration: configuration
        )

        mailbox.offer(oversized, now: PresentationInstant(rawMicroseconds: 0))

        #expect(mailbox.retainedByteCount == 0)
        mailbox.finish()
    }

    @Test("consuming a frame releases its byte storage and linked-queue budget")
    func consumedFrameReleasesLinkedQueueBytes() async throws {
        let frameBytes = BinaryMessage.headerSize + 1
        let mailbox = VisualizerFrameMailbox(capacityBytes: frameBytes * 2)
        let firstReleased = ByteReleaseProbe()
        offerTrackedFrame(firstReleased, to: mailbox, byte: 12)
        let second = frame(type: .loudness, byte: 13, at: .max)
        let third = frame(type: .loudness, byte: 14, at: .max)

        do {
            let subscription = try VisualizerFrameSubscription(acquiring: mailbox)
            var iterator = subscription.makeAsyncIterator()
            #expect(await iterator.next()?.data == Data([12]))
            mailbox.offer(second, now: PresentationInstant(rawMicroseconds: 0))
            mailbox.offer(third, now: PresentationInstant(rawMicroseconds: 0))
            #expect(await iterator.next() == second)
            #expect(await iterator.next() == third)
        }
        #expect(firstReleased.wasReleased)
        mailbox.finish()
    }

    @Test("clear releases all retained visualizer frames immediately")
    func clearDropsQueuedFrames() throws {
        let mailbox = VisualizerFrameMailbox(capacityBytes: 64)
        _ = try VisualizerFrameSubscription(acquiring: mailbox)
        mailbox.offer(frame(type: .peak, byte: 15, at: .max), now: PresentationInstant(rawMicroseconds: 0))
        mailbox.offer(frame(type: .loudness, byte: 16, at: .max), now: PresentationInstant(rawMicroseconds: 0))
        #expect(mailbox.retainedByteCount > 0)

        mailbox.clear()

        #expect(mailbox.retainedByteCount == 0)
        mailbox.finish()
    }

    @Test("parked delivery cannot clear the primary mailbox")
    func parkedDeliveryDoesNotClearPrimaryMailbox() {
        let mailbox = VisualizerFrameMailbox(capacityBytes: 64)
        let primary = makeConnectionDataDelivery(mailbox: mailbox)
        let parked = makeConnectionDataDelivery(mailbox: mailbox)
        primary.promoteToPrimary()
        let value = frame(type: .peak, byte: 17, at: .max)
        primary.offerVisualizerIfValid(value, validity: SessionValidityToken())
        #expect(mailbox.retainedByteCount == value.frameByteCount)

        for _ in 0 ..< 3 {
            parked.clearVisualizer()
            #expect(mailbox.retainedByteCount == value.frameByteCount)
        }

        primary.clearVisualizer()
        #expect(mailbox.retainedByteCount == 0)
        mailbox.finish()
    }

    @Test("primary delivery clear releases retained bytes immediately")
    func primaryDeliveryClearsMailboxImmediately() {
        let mailbox = VisualizerFrameMailbox(capacityBytes: 64)
        let primary = makeConnectionDataDelivery(mailbox: mailbox)
        primary.promoteToPrimary()
        let value = frame(type: .peak, byte: 18, at: .max)
        primary.offerVisualizerIfValid(value, validity: SessionValidityToken())
        #expect(mailbox.retainedByteCount == value.frameByteCount)

        primary.clearVisualizer()

        #expect(mailbox.retainedByteCount == 0)
        mailbox.finish()
    }

    private func frame(
        type: VisualizerType,
        byte: UInt8,
        at microseconds: Int64,
        validity: VisualizerFrameValidity = VisualizerFrameValidity()
    ) -> VisualizerFrame {
        VisualizerFrame(
            type: type,
            data: Data([byte]),
            presentationTime: PresentationInstant(rawMicroseconds: microseconds),
            configuration: configuration,
            validity: validity
        )
    }
}

private func makeConnectionDataDelivery(mailbox: VisualizerFrameMailbox) -> ConnectionDataDelivery {
    let (_, audio) = AsyncStream<AudioChunk>.makeStream()
    let (_, artwork) = AsyncStream<ArtworkData>.makeStream()
    return ConnectionDataDelivery(
        audio: audio,
        artwork: artwork,
        visualizer: mailbox,
        artworkObserver: nil
    )
}

private actor AsyncTestBarrier {
    private var reached = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func signalReached() {
        reached = true
    }

    func waitUntilReached(timeout: Duration = .seconds(2)) async -> Bool {
        await waitUntil(timeout: timeout) { await self.isReached }
    }

    private var isReached: Bool {
        reached
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
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

private func offerTrackedFrame(_ probe: ByteReleaseProbe, to mailbox: VisualizerFrameMailbox, byte: UInt8) {
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    pointer.initializeMemory(as: UInt8.self, repeating: byte, count: 1)
    let data = Data(bytesNoCopy: pointer, count: 1, deallocator: .custom { pointer, _ in
        pointer.deallocate()
        probe.markReleased()
    })
    let value = VisualizerFrame(
        type: .loudness,
        data: data,
        presentationTime: PresentationInstant(rawMicroseconds: .max),
        configuration: VisualizerStreamConfiguration(types: [.loudness], rateMax: 60)
    )
    mailbox.offer(value, now: PresentationInstant(rawMicroseconds: 0))
}

private final class MailboxTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    private var readCount = 0

    init(value: Int64 = 0) {
        self.value = value
    }

    var now: PresentationInstant {
        lock.withLock {
            readCount += 1
            return PresentationInstant(rawMicroseconds: value)
        }
    }

    var readCountSnapshot: Int {
        lock.withLock { readCount }
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
}
