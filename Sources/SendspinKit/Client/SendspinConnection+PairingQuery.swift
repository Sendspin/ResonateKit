import Foundation

extension SendspinConnection {
    /// Snapshot the admission facts owned by this connection. The facade must
    /// query these facts from the actor instead of relying on event-drain state,
    /// which can lag behind the ordered message loop while arbitration awaits.
    struct AdmissionSnapshot: Sendable, Equatable {
        let serverId: String
        let activities: Set<Activity>
        let isPairingAttempt: Bool
    }

    func admissionSnapshot() -> AdmissionSnapshot {
        AdmissionSnapshot(
            serverId: currentServerId ?? "",
            activities: activities,
            isPairingAttempt: pairingAttemptActive
                || pendingPairingPsk != nil
                || dynamicPairingAttempt != nil
                || staticPairingAttempt != nil
        )
    }
}
