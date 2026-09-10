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

    struct ProjectionSnapshot: Sendable {
        let serverId: String
        let activities: Set<Activity>
        let trustLevel: TrustLevel
        let activeRoles: Set<VersionedRole>
        let streamFormat: AudioFormatSpec?
        let codecHeader: Data?
        let playerStreamActive: Bool
        let artworkStreamActive: Bool
        let visualizerConfiguration: VisualizerStreamConfiguration?
        let metadata: TrackMetadata?
        let group: GroupInfo?
        let controller: ControllerState?
        let color: ColorState?
        let operationalState: EngineSyncState
        let clockSynced: Bool
        let outputFormatStatus: OutputFormatStatus?
        let volume: Int
        let muted: Bool
        let outputDelayMs: Int

        var serverInfo: ServerInfo {
            ServerInfo(
                serverId: serverId,
                name: serverName,
                trustLevel: trustLevel,
                activeRoles: activeRoles,
                activities: activities
            )
        }

        let serverName: String
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

    func pairingAttemptSnapshot() -> PairingAttemptSnapshot? {
        guard let id = pairingAttemptID, let peer = pairingAttemptPeer else { return nil }
        let phase: PairingAttemptPhase = if dynamicPairingAttempt?.emission != nil || staticPairingAttempt != nil {
            .codeReady
        } else if pendingPairingPsk != nil {
            .authenticating
        } else {
            .pending
        }
        return PairingAttemptSnapshot(id: id, peer: peer, phase: phase, code: dynamicPairingAttempt?.emission)
    }

    func projectionSnapshot() -> ProjectionSnapshot {
        ProjectionSnapshot(
            serverId: currentServerId ?? "",
            activities: activities,
            trustLevel: pskCategory == .longTerm ? .user : .none,
            activeRoles: activeRoles,
            streamFormat: announcedPlayerStream?.format,
            codecHeader: announcedPlayerStream?.codecHeader,
            playerStreamActive: playerStreamActive,
            artworkStreamActive: artworkStreamActive,
            visualizerConfiguration: visualizerStreamConfiguration,
            metadata: currentMetadata,
            group: currentGroup,
            controller: currentControllerState,
            color: currentColorState,
            operationalState: clientOperationalState,
            clockSynced: isClockSynced,
            outputFormatStatus: outputFormatStatus,
            volume: currentVolume,
            muted: currentMuted,
            outputDelayMs: currentOutputDelayMs,
            serverName: serverName
        )
    }
}
