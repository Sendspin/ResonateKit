import Foundation

struct ConnectionActivationProposal: Sendable {
    let token: UUID
    let activities: Set<Activity>
    let activeRoles: Set<VersionedRole>
}

enum ConnectionActivationVerdict: Sendable {
    case admit
    case reject(GoodbyeReason)
}

/// A continuation-backed admission boundary for activations that can change a
/// parked pairing connection into a competing playback connection.
final class ConnectionActivationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let requestContinuation: AsyncStream<ConnectionActivationProposal>.Continuation
    let requests: AsyncStream<ConnectionActivationProposal>
    private var pending: [UUID: CheckedContinuation<ConnectionActivationVerdict, Never>] = [:]

    init() {
        (requests, requestContinuation) = AsyncStream.makeStream()
    }

    func request(
        activities: Set<Activity>,
        activeRoles: Set<VersionedRole>
    ) async -> ConnectionActivationVerdict {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            pending[token] = continuation
            lock.unlock()
            requestContinuation.yield(ConnectionActivationProposal(
                token: token,
                activities: activities,
                activeRoles: activeRoles
            ))
        }
    }

    func resolve(_ token: UUID, verdict: ConnectionActivationVerdict) {
        lock.lock()
        let continuation = pending.removeValue(forKey: token)
        lock.unlock()
        continuation?.resume(returning: verdict)
    }

    func cancel() {
        lock.lock()
        let continuations = pending.values
        pending.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: .reject(.concurrentAttempt))
        }
        requestContinuation.finish()
    }
}
