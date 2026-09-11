import Foundation

final class AdvertisingAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var active = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < capacity else { return false }
        active += 1
        return true
    }

    func release() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }
}
