import Foundation
import Testing
import VisualizerClientCore
@testable import SendspinKit

struct VisualizerPresentationSchedulerTests {
    private static let configuration = VisualizerStreamConfiguration(
        types: [.loudness, .spectrum],
        rateMax: 30,
        spectrum: SpectrumConfiguration(nDispBins: 2, scale: .log, fMin: 60, fMax: 16_000)
    )

    @Test
    func ingestDoesNotLetFutureFrameStarveAnotherType() {
        var scheduler = VisualizerPresentationScheduler(capacityBytes: 128)
        let now = PresentationInstant(rawMicroseconds: 1_000)
        let futureLoudness = frame(.loudness, byte: 1, at: 2_000)
        let dueSpectrum = frame(.spectrum, byte: 2, at: 1_000)

        let acceptedFuture = scheduler.ingest(futureLoudness)
        let acceptedDue = scheduler.ingest(dueSpectrum)
        #expect(acceptedFuture)
        #expect(acceptedDue)
        let batch = scheduler.tick(at: now)

        #expect(batch.frames.map(\.type) == [.spectrum])
        #expect(batch.frames.first?.data == Data([2]))
        #expect(scheduler.retainedByteCount == 2 * (futureLoudness.data.count + VisualizerPresentationScheduler.visualizerHeaderByteCount))
    }

    @Test
    func tickSelectsLatestDueValuePerTypeAndOrdersEqualTimestampsByArrival() {
        var scheduler = VisualizerPresentationScheduler(capacityBytes: 256)
        let timestamp = PresentationInstant(rawMicroseconds: 1_000)
        let firstLoudness = frame(.loudness, byte: 1, at: timestamp.rawMicroseconds)
        let latestLoudness = frame(.loudness, byte: 2, at: timestamp.rawMicroseconds)
        let spectrum = frame(.spectrum, byte: 3, at: timestamp.rawMicroseconds)

        let acceptedFirst = scheduler.ingest(firstLoudness)
        let acceptedLatest = scheduler.ingest(latestLoudness)
        let acceptedSpectrum = scheduler.ingest(spectrum)
        #expect(acceptedFirst)
        #expect(acceptedLatest)
        #expect(acceptedSpectrum)
        let batch = scheduler.tick(at: timestamp)

        #expect(batch.frames.map(\.type) == [.loudness, .spectrum])
        #expect(batch.frames.map(\.data) == [Data([2]), Data([3])])
        #expect(scheduler.retainedByteCount == 2 * VisualizerPresentationScheduler.visualizerHeaderByteCount + 2)
    }

    @Test
    func futureFramesRemainQueuedUntilPresentationClockReachesDeadline() {
        var scheduler = VisualizerPresentationScheduler(capacityBytes: 128)
        let future = frame(.loudness, byte: 1, at: 2_000)
        let accepted = scheduler.ingest(future)
        #expect(accepted)

        #expect(scheduler.tick(at: PresentationInstant(rawMicroseconds: 1_999)).frames.isEmpty)
        #expect(scheduler.retainedByteCount == 10)
        #expect(scheduler.tick(at: PresentationInstant(rawMicroseconds: 2_000)).frames == [future])
    }

    @Test
    func realMailboxFramesReachSchedulerWithoutDeadlineBlocking() async throws {
        let mailbox = VisualizerFrameMailbox(capacityBytes: 128, now: { PresentationInstant(rawMicroseconds: 0) })
        let subscription = try VisualizerFrameSubscription(acquiring: mailbox)
        let first = frame(.loudness, byte: 1, at: 1_000)
        let second = frame(.spectrum, byte: 2, at: 1_000)
        mailbox.offer(first, now: PresentationInstant(rawMicroseconds: 0))
        mailbox.offer(second, now: PresentationInstant(rawMicroseconds: 0))

        var iterator = subscription.makeAsyncIterator()
        var scheduler = VisualizerPresentationScheduler(capacityBytes: 128)
        let firstFromMailbox = try #require(await VisualizerFrameIngestor.consumeNext(from: &iterator))
        let secondFromMailbox = try #require(await VisualizerFrameIngestor.consumeNext(from: &iterator))
        let acceptedFirst = scheduler.ingest(firstFromMailbox)
        let acceptedSecond = scheduler.ingest(secondFromMailbox)
        #expect(acceptedFirst)
        #expect(acceptedSecond)

        let batch = scheduler.tick(at: PresentationInstant(rawMicroseconds: 1_000))
        #expect(batch.frames.map(\.type) == [.loudness, .spectrum])
        subscription.cancel()
    }

    @Test
    func byteBudgetEvictsOldestFramesForFreshness() {
        var scheduler = VisualizerPresentationScheduler(capacityBytes: 19)
        let first = frame(.loudness, byte: 1, at: 1_000)
        let second = frame(.spectrum, byte: 2, at: 1_001)

        let acceptedFirst = scheduler.ingest(first)
        let acceptedSecond = scheduler.ingest(second)
        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(scheduler.retainedByteCount == VisualizerPresentationScheduler.visualizerHeaderByteCount + second.data.count)
        #expect(scheduler.tick(at: PresentationInstant(rawMicroseconds: 1_001)).frames == [second])
    }

    @Test
    func shownFramesConsumeTheSameByteBudgetAsQueuedFrames() {
        var scheduler = VisualizerPresentationScheduler(capacityBytes: 19)
        let shown = frame(.loudness, byte: 1, at: 1_000)
        let queued = frame(.spectrum, byte: 2, at: 2_000)

        let acceptedShown = scheduler.ingest(shown)
        #expect(acceptedShown)
        _ = scheduler.tick(at: PresentationInstant(rawMicroseconds: 1_000))
        let acceptedQueued = scheduler.ingest(queued)

        #expect(!acceptedQueued)
        #expect(scheduler.retainedByteCount == VisualizerPresentationScheduler.visualizerHeaderByteCount + shown.data.count)
    }

    @Test
    func invalidGenerationClearsPreviouslyPresentedValue() {
        let validity = VisualizerFrameValidity()
        let frame = VisualizerFrame(
            type: .loudness,
            data: Data([1]),
            presentationTime: PresentationInstant(rawMicroseconds: 1_000),
            configuration: Self.configuration,
            validity: validity
        )
        var scheduler = VisualizerPresentationScheduler(capacityBytes: 128)
        let accepted = scheduler.ingest(frame)
        #expect(accepted)
        _ = scheduler.tick(at: PresentationInstant(rawMicroseconds: 1_000))

        validity.invalidate()
        let batch = scheduler.tick(at: PresentationInstant(rawMicroseconds: 2_000))

        #expect(batch.frames.isEmpty)
        #expect(batch.clearedTypes == [.loudness])
    }

    @Test
    func displayedValueIsRetainedAcrossTicksUntilReplacementOrReset() {
        var scheduler = VisualizerPresentationScheduler(capacityBytes: 128)
        let first = frame(.loudness, byte: 1, at: 1_000)
        let replacement = frame(.loudness, byte: 2, at: 3_000)

        let acceptedFirst = scheduler.ingest(first)
        #expect(acceptedFirst)
        _ = scheduler.tick(at: PresentationInstant(rawMicroseconds: 1_000))
        let acceptedReplacement = scheduler.ingest(replacement)
        #expect(acceptedReplacement)
        #expect(scheduler.tick(at: PresentationInstant(rawMicroseconds: 2_000)).frames.isEmpty)
        #expect(scheduler.tick(at: PresentationInstant(rawMicroseconds: 3_000)).frames == [replacement])
        scheduler.reset()
        #expect(scheduler.retainedByteCount == 0)
        #expect(scheduler.tick(at: PresentationInstant(rawMicroseconds: 4_000)).frames.isEmpty)
    }

    private func frame(_ type: VisualizerType, byte: UInt8, at timestamp: Int64) -> VisualizerFrame {
        VisualizerFrame(
            type: type,
            data: Data([byte]),
            presentationTime: PresentationInstant(rawMicroseconds: timestamp),
            configuration: Self.configuration
        )
    }
}
