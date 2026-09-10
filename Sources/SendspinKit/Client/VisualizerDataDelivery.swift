import Foundation

/// A bounded async sequence for visualizer frames.
/// The mailbox has one pending consumer and a configured wire-byte budget.
/// Oldest retained frames are discarded when a new frame does not fit.
///
/// A stream has a single-consumer contract: only one iterator may consume it at
/// a time. A second live iterator returns `nil` rather than replacing the
/// current consumer. If the owning iterator is abandoned or cancelled, a later
/// iterator may take ownership.
public struct VisualizerDataStream: AsyncSequence, Sendable {
    public typealias Element = VisualizerData

    private let mailbox: VisualizerDataMailbox

    init(mailbox: VisualizerDataMailbox) {
        self.mailbox = mailbox
    }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        private let mailbox: VisualizerDataMailbox
        private let token: VisualizerIteratorToken

        fileprivate init(mailbox: VisualizerDataMailbox) {
            self.mailbox = mailbox
            token = VisualizerIteratorToken(mailbox: mailbox)
        }

        public mutating func next() async -> VisualizerData? {
            await mailbox.next(owner: token)
        }
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(mailbox: mailbox)
    }
}

/// Identity for the one iterator allowed to consume a mailbox.
private final class VisualizerIteratorLease: @unchecked Sendable {}

private final class VisualizerIteratorToken: @unchecked Sendable {
    weak var mailbox: VisualizerDataMailbox?
    let lease = VisualizerIteratorLease()

    init(mailbox: VisualizerDataMailbox) {
        self.mailbox = mailbox
    }

    deinit {
        mailbox?.cancel(lease: lease)
    }
}

/// Lock-based delivery storage keeps the message loop non-blocking and avoids
/// an unbounded task or `AsyncStream` buffer when the host does not consume.
final class VisualizerDataMailbox: @unchecked Sendable {
    private enum ReadResult {
        case value(VisualizerData)
        case end
        case retry
    }

    private final class QueueNode {
        let value: VisualizerData
        var next: QueueNode?

        init(_ value: VisualizerData) {
            self.value = value
        }
    }

    private final class Waiter {
        let lease: VisualizerIteratorLease
        let continuation: CheckedContinuation<ReadResult, Never>

        init(owner: VisualizerIteratorToken, continuation: CheckedContinuation<ReadResult, Never>) {
            lease = owner.lease
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private let capacityBytes: Int
    private let now: @Sendable () -> Int64
    private var queueHead: QueueNode?
    private var queueTail: QueueNode?
    private var queuedBytes = 0
    private var ownerLease: VisualizerIteratorLease?
    private var waiter: Waiter?
    private var finished = false

    var retainedByteCount: Int {
        lock.withLock { queuedBytes }
    }

    init(
        capacityBytes: Int,
        now: @escaping @Sendable () -> Int64 = { MonotonicClock.absoluteMicroseconds() }
    ) {
        precondition(capacityBytes > 0)
        self.capacityBytes = capacityBytes
        self.now = now
    }

    func offer(_ value: VisualizerData, now arrivalNow: Int64? = nil) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }

        let currentNow = arrivalNow ?? now()
        discardExpiredLocked(now: currentNow)
        guard value.localDisplayTime > currentNow else {
            lock.unlock()
            return
        }

        let bytes = value.frameByteCount
        guard bytes <= capacityBytes else {
            lock.unlock()
            return
        }

        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.continuation.resume(returning: .value(value))
            return
        }

        while bytes > capacityBytes - queuedBytes {
            guard dequeueHeadLocked() != nil else { break }
        }
        appendLocked(value)
        lock.unlock()
    }

    fileprivate func next(owner iterator: VisualizerIteratorToken) async -> VisualizerData? {
        while true {
            guard !Task.isCancelled else {
                cancel(lease: iterator.lease)
                return nil
            }

            enum Immediate {
                case value(VisualizerData)
                case empty
                case finished
                case notOwner
            }

            let immediate: Immediate = lock.withLock {
                if let ownerLease, ownerLease !== iterator.lease {
                    return .notOwner
                }
                if self.ownerLease == nil {
                    self.ownerLease = iterator.lease
                }
                discardExpiredLocked(now: now())
                if let value = dequeueHeadLocked() {
                    return .value(value)
                }
                if finished {
                    return .finished
                }
                return .empty
            }

            switch immediate {
            case let .value(value):
                // A frame can be invalidated or expire after it was dequeued.
                // Never deliver it merely because it was fresh at dequeue time.
                if value.isRenderable(at: now()) {
                    return value
                }
                continue
            case .finished, .notOwner:
                return nil
            case .empty:
                break
            }

            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<ReadResult, Never>) in
                    park(owner: iterator, continuation: continuation)
                }
            } onCancel: {
                cancel(lease: iterator.lease)
            }
            switch result {
            case let .value(value):
                // Cancellation owns the handoff decision. A frame already
                // resumed to a canceled read is dropped; requeueing it would
                // transfer ownership across iterator lifetimes and can strand
                // a new waiter's continuation.
                guard !Task.isCancelled else {
                    cancel(lease: iterator.lease)
                    return nil
                }
                if value.isRenderable(at: now()) {
                    return value
                }
            // The directly delivered frame expired or was invalidated
            // while this task was waking. Wait for a fresh frame.
            // Loop to wait for the next frame rather than returning stale data.
            case .retry:
                continue
            case .end:
                return nil
            }
        }
    }

    func clear() {
        lock.withLock {
            clearQueueLocked()
        }
    }

    func finish() {
        let pending: CheckedContinuation<ReadResult, Never>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            clearQueueLocked()
            let pending = waiter?.continuation
            waiter = nil
            ownerLease = nil
            return pending
        }
        pending?.resume(returning: .end)
    }

    private func park(
        owner iterator: VisualizerIteratorToken,
        continuation: CheckedContinuation<ReadResult, Never>
    ) {
        let result: ReadResult? = lock.withLock {
            guard !finished, ownerLease == nil || ownerLease === iterator.lease else { return .end }
            ownerLease = iterator.lease
            discardExpiredLocked(now: now())
            // A frame can arrive between the immediate check and installing the
            // continuation. Recheck under the same lock so it cannot be hidden
            // behind a newly parked waiter.
            guard queueHead == nil, waiter == nil else {
                return .retry
            }
            guard !Task.isCancelled else {
                // Cancellation may run before this closure gets the lock. Do
                // not leave a dead iterator owning the mailbox.
                ownerLease = nil
                return .end
            }
            waiter = Waiter(owner: iterator, continuation: continuation)
            return nil
        }
        if let result {
            continuation.resume(returning: result)
        }
    }

    fileprivate func cancel(lease: VisualizerIteratorLease) {
        let pending: CheckedContinuation<ReadResult, Never>? = lock.withLock {
            guard ownerLease === lease else { return nil }
            let pending = waiter?.lease === lease ? waiter?.continuation : nil
            if waiter?.lease === lease {
                waiter = nil
            }
            // Do not requeue a value that raced with cancellation. The value
            // was handed to this read and is intentionally dropped.
            ownerLease = nil
            return pending
        }
        pending?.resume(returning: .end)
    }

    private func appendLocked(_ value: VisualizerData) {
        let node = QueueNode(value)
        if let queueTail {
            queueTail.next = node
        } else {
            queueHead = node
        }
        queueTail = node
        queuedBytes += value.frameByteCount
    }

    @discardableResult
    private func dequeueHeadLocked() -> VisualizerData? {
        guard let node = queueHead else { return nil }
        queueHead = node.next
        node.next = nil
        if queueHead == nil {
            queueTail = nil
        }
        queuedBytes -= node.value.frameByteCount
        return node.value
    }

    private func clearQueueLocked() {
        queueHead = nil
        queueTail = nil
        queuedBytes = 0
    }

    private func discardExpiredLocked(now: Int64) {
        // Server visualizer timestamps are non-decreasing, so expired frames form
        // a prefix. Each dequeued node releases its Data immediately.
        while let value = queueHead?.value, value.localDisplayTime <= now {
            _ = dequeueHeadLocked()
        }
    }
}

extension VisualizerData {
    /// The capacity accounting size required by the visualizer wire contract.
    var frameByteCount: Int {
        let (bytes, overflow) = BinaryMessage.headerSize.addingReportingOverflow(data.count)
        return overflow ? .max : bytes
    }
}
