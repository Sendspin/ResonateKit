import Foundation

/// The error thrown when an app attempts to acquire a second visualizer consumer.
public enum VisualizerFrameAcquisitionError: Error, Sendable, Equatable {
    case consumerAlreadyActive
}

/// Bounded async sequence with one mailbox consumer.
/// Acquire it with ``SendspinClient/acquireVisualizerFrames()``; ownership lasts until
/// `cancel()` or deallocation, and cancelling a pending `next()` releases the consumer.
/// Copied iterators share one read; a concurrent copy ends without canceling that read.
public final class VisualizerFrameSubscription: AsyncSequence, @unchecked Sendable {
    public typealias Element = VisualizerFrame

    private let mailbox: VisualizerFrameMailbox
    private let token: VisualizerIteratorToken
    private let iteratorLock = NSLock()
    private var iteratorIssued = false

    init(acquiring mailbox: VisualizerFrameMailbox) throws(VisualizerFrameAcquisitionError) {
        self.mailbox = mailbox
        let candidate = VisualizerIteratorToken(mailbox: mailbox)
        guard mailbox.claim(lease: candidate.lease) else {
            throw .consumerAlreadyActive
        }
        token = candidate
    }

    fileprivate init(mailbox: VisualizerFrameMailbox, token: VisualizerIteratorToken) {
        self.mailbox = mailbox
        self.token = token
    }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        private let mailbox: VisualizerFrameMailbox?
        private let token: VisualizerIteratorToken?

        fileprivate init(
            mailbox: VisualizerFrameMailbox?,
            token: VisualizerIteratorToken?
        ) {
            self.mailbox = mailbox
            self.token = token
        }

        public mutating func next() async -> VisualizerFrame? {
            guard let mailbox, let token, token.beginRead() else { return nil }
            defer { token.endRead() }
            return await mailbox.next(owner: token)
        }
    }

    /// Release this subscription's mailbox ownership immediately.
    public func cancel() {
        mailbox.cancel(lease: token.lease)
    }

    deinit {
        cancel()
    }

    /// A subscription has one consumer; repeated iterator requests end immediately.
    public func makeAsyncIterator() -> Iterator {
        let isFirst = iteratorLock.withLock {
            guard !iteratorIssued else { return false }
            iteratorIssued = true
            return true
        }
        guard isFirst else { return Iterator(mailbox: nil, token: nil) }
        return Iterator(mailbox: mailbox, token: token)
    }
}

/// Identity for the one iterator allowed to consume a mailbox.
private final class VisualizerIteratorLease: @unchecked Sendable {
    /// Access is serialized by the mailbox lock and remains true for the lease lifetime.
    var revoked = false
}

private final class VisualizerIteratorToken: @unchecked Sendable {
    weak var mailbox: VisualizerFrameMailbox?
    let lease = VisualizerIteratorLease()
    private let readLock = NSLock()
    private var readInFlight = false

    init(mailbox: VisualizerFrameMailbox) {
        self.mailbox = mailbox
    }

    /// Copied iterator structs share this single-flight boundary. A losing read ends
    /// immediately and must not cancel the read that owns the mailbox waiter.
    func beginRead() -> Bool {
        readLock.withLock {
            guard !readInFlight else { return false }
            readInFlight = true
            return true
        }
    }

    func endRead() {
        readLock.withLock { readInFlight = false }
    }

    deinit {
        mailbox?.cancel(lease: lease)
    }
}

/// Lock-based delivery storage keeps the message loop non-blocking and avoids
/// an unbounded task or `AsyncStream` buffer when the host does not consume.
final class VisualizerFrameMailbox: @unchecked Sendable {
    private enum ReadResult {
        case value(VisualizerFrame)
        case end
        case retry
    }

    private final class QueueNode {
        let value: VisualizerFrame
        var next: QueueNode?

        init(_ value: VisualizerFrame) {
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
    private let now: @Sendable () -> PresentationInstant
    private let beforePark: (@Sendable () -> Void)?
    private let beforePostHandoffCheck: (@Sendable () -> Void)?
    private var queueHead: QueueNode?
    private var queueTail: QueueNode?
    private var queuedBytes = 0
    private var ownerLease: VisualizerIteratorLease?
    private var waiter: Waiter?
    private var finished = false

    var retainedByteCount: Int {
        lock.withLock { queuedBytes }
    }

    var claimable: Bool {
        lock.withLock { !finished && ownerLease == nil }
    }

    fileprivate func claim(lease: VisualizerIteratorLease) -> Bool {
        lock.withLock {
            guard !finished, !lease.revoked, ownerLease == nil else { return false }
            ownerLease = lease
            return true
        }
    }

    private func leaseIsActive(_ lease: VisualizerIteratorLease) -> Bool {
        lock.withLock {
            !finished && !lease.revoked && ownerLease === lease
        }
    }

    init(
        capacityBytes: Int,
        now: @escaping @Sendable () -> PresentationInstant = { .now },
        beforePark: (@Sendable () -> Void)? = nil,
        beforePostHandoffCheck: (@Sendable () -> Void)? = nil
    ) {
        precondition(capacityBytes > 0)
        self.capacityBytes = capacityBytes
        self.now = now
        self.beforePark = beforePark
        self.beforePostHandoffCheck = beforePostHandoffCheck
    }

    func offer(_ value: VisualizerFrame, now arrivalNow: PresentationInstant? = nil) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }

        let currentNow = arrivalNow ?? now()
        discardExpiredLocked(now: currentNow)
        guard value.eligibilityForScheduling(at: currentNow) else {
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

    fileprivate func next(owner iterator: VisualizerIteratorToken) async -> VisualizerFrame? {
        while true {
            guard !Task.isCancelled else {
                cancel(lease: iterator.lease)
                return nil
            }

            enum Immediate {
                case value(VisualizerFrame)
                case empty
                case finished
                case notOwner
            }

            let immediate: Immediate = lock.withLock {
                guard !finished, !iterator.lease.revoked else { return .finished }
                if let ownerLease, ownerLease !== iterator.lease {
                    return .notOwner
                }
                if self.ownerLease == nil {
                    self.ownerLease = iterator.lease
                }
                discardExpiredLocked(now: now())
                if let value = dequeueHeadLocked() {
                    guard !iterator.lease.revoked, self.ownerLease === iterator.lease else {
                        return .finished
                    }
                    return .value(value)
                }
                return .empty
            }

            switch immediate {
            case let .value(value):
                // Recheck both stream generation and deadline after dequeue. A
                // consumer must never receive a frame that became stale while waking.
                if value.isValid, value.eligibilityForScheduling(at: now()), leaseIsActive(iterator.lease) {
                    return value
                }
                continue
            case .finished, .notOwner:
                return nil
            case .empty:
                break
            }

            beforePark?()
            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<ReadResult, Never>) in
                    park(owner: iterator, continuation: continuation)
                }
            } onCancel: {
                cancel(lease: iterator.lease)
            }
            beforePostHandoffCheck?()
            switch result {
            case let .value(value):
                // An explicitly canceled lease drops a frame already handed to its continuation.
                guard !Task.isCancelled, leaseIsActive(iterator.lease) else {
                    return nil
                }
                if value.isValid, value.eligibilityForScheduling(at: now()) {
                    return value
                }
            // The directly delivered frame was invalidated or became stale
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
            guard !finished, !iterator.lease.revoked,
                  ownerLease == nil || ownerLease === iterator.lease else { return .end }
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
            lease.revoked = true
            guard ownerLease === lease else { return nil }
            let pending = waiter?.lease === lease ? waiter?.continuation : nil
            if waiter?.lease === lease {
                waiter = nil
            }
            ownerLease = nil
            return pending
        }
        pending?.resume(returning: .end)
    }

    private func appendLocked(_ value: VisualizerFrame) {
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
    private func dequeueHeadLocked() -> VisualizerFrame? {
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

    private func discardExpiredLocked(now: PresentationInstant) {
        // Server visualizer timestamps are non-decreasing, so expired frames form
        // a prefix. Each dequeued node releases its Data immediately.
        while let value = queueHead?.value, !value.eligibilityForScheduling(at: now) {
            _ = dequeueHeadLocked()
        }
    }
}

extension VisualizerFrame {
    /// The capacity accounting size required by the visualizer wire contract.
    var frameByteCount: Int {
        let (bytes, overflow) = BinaryMessage.headerSize.addingReportingOverflow(data.count)
        return overflow ? .max : bytes
    }
}
