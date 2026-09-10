import Foundation
import SendspinKit

public struct VisualizerPresentationBatch: Sendable {
    public let frames: [VisualizerFrame]
    public let clearedTypes: [VisualizerType]

    public init(frames: [VisualizerFrame], clearedTypes: [VisualizerType]) {
        self.frames = frames
        self.clearedTypes = clearedTypes
    }
}

public struct VisualizerPresentationScheduler: Sendable {
    public static let visualizerHeaderByteCount = 9

    private struct Entry: Sendable {
        let sequence: UInt64
        let frame: VisualizerFrame
        let byteCount: Int
    }

    private let capacityBytes: Int
    private var entries: [Entry] = []
    private var queuedBytes = 0
    private var presentedBytes = 0
    private var nextSequence: UInt64 = 0
    private var presented: [(VisualizerType, VisualizerFrame, Int)] = []

    public init(capacityBytes: Int) {
        precondition(capacityBytes > 0)
        self.capacityBytes = capacityBytes
    }

    public var retainedByteCount: Int {
        queuedBytes + presentedBytes
    }

    public var capacity: Int {
        capacityBytes
    }

    @discardableResult
    public mutating func ingest(_ frame: VisualizerFrame) -> Bool {
        let (byteCount, overflow) = Self.visualizerHeaderByteCount.addingReportingOverflow(frame.data.count)
        guard !overflow, byteCount <= capacityBytes, frame.isValid else { return false }

        while byteCount > availableCapacity, !entries.isEmpty {
            let evicted = entries.removeFirst()
            queuedBytes -= evicted.byteCount
        }
        guard byteCount <= availableCapacity else { return false }

        entries.append(Entry(sequence: nextSequence, frame: frame, byteCount: byteCount))
        nextSequence &+= 1
        queuedBytes += byteCount
        return true
    }

    public mutating func tick(at now: PresentationInstant) -> VisualizerPresentationBatch {
        var selected: [(VisualizerType, Entry)] = []
        var retained: [Entry] = []
        var newRetainedBytes = 0

        for entry in entries {
            guard entry.frame.isValid else { continue }
            guard entry.frame.presentationTime <= now else {
                retained.append(entry)
                newRetainedBytes += entry.byteCount
                continue
            }
            if let index = selected.firstIndex(where: { $0.0 == entry.frame.type }) {
                if isLater(entry, than: selected[index].1) {
                    selected[index].1 = entry
                }
            } else {
                selected.append((entry.frame.type, entry))
            }
        }
        entries = retained
        queuedBytes = newRetainedBytes

        var frames = selected.map { $0.1 }
            .sorted { lhs, rhs in
                if lhs.frame.presentationTime != rhs.frame.presentationTime {
                    return lhs.frame.presentationTime < rhs.frame.presentationTime
                }
                return lhs.sequence < rhs.sequence
            }
            .compactMap { entry -> VisualizerFrame? in
                guard entry.frame.isValid else { return nil }
                setPresented(entry.frame)
                return entry.frame
            }

        var clearedTypes: [VisualizerType] = []
        let invalidPresentedTypes = presented.compactMap { type, frame, _ in
            frame.isValid ? nil : type
        }
        for type in invalidPresentedTypes {
            if let index = presented.firstIndex(where: { $0.0 == type }) {
                presentedBytes -= presented[index].2
                presented.remove(at: index)
            }
            appendCleared(type, to: &clearedTypes)
        }
        for frame in frames where !frame.isValid {
            if let index = presented.firstIndex(where: { $0.0 == frame.type }) {
                presentedBytes -= presented[index].2
                presented.remove(at: index)
            }
            appendCleared(frame.type, to: &clearedTypes)
        }
        frames.removeAll { !$0.isValid }
        return VisualizerPresentationBatch(frames: frames, clearedTypes: clearedTypes)
    }

    public mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        queuedBytes = 0
        presentedBytes = 0
        presented.removeAll(keepingCapacity: true)
    }

    private var availableCapacity: Int {
        capacityBytes - presentedBytes - queuedBytes
    }

    private mutating func setPresented(_ frame: VisualizerFrame) {
        let byteCount = Self.visualizerHeaderByteCount + frame.data.count
        if let index = presented.firstIndex(where: { $0.0 == frame.type }) {
            presentedBytes -= presented[index].2
            presented[index].1 = frame
            presented[index].2 = byteCount
        } else {
            presented.append((frame.type, frame, byteCount))
        }
        presentedBytes += byteCount
    }

    private func appendCleared(_ type: VisualizerType, to clearedTypes: inout [VisualizerType]) {
        guard !clearedTypes.contains(type) else { return }
        clearedTypes.append(type)
    }

    private func isLater(_ lhs: Entry, than rhs: Entry) -> Bool {
        if lhs.frame.presentationTime != rhs.frame.presentationTime {
            return lhs.frame.presentationTime > rhs.frame.presentationTime
        }
        return lhs.sequence > rhs.sequence
    }
}
