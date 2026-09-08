import Foundation

/// Validates payloads against the negotiated stream while ignoring reserved bits.
/// Malformed frames are dropped without closing the session; the visualizer spec
/// does not require disconnecting for payload violations.
enum VisualizerBinaryPayloadValidator {
    static func isValid(
        type: VisualizerType,
        data: Data,
        configuration: VisualizerStreamConfiguration
    ) -> Bool {
        guard configuration.types.contains(type) else { return false }

        switch type {
        case .loudness:
            return data.count == 2

        case .beat:
            guard data.count == 1, let tracksDownbeats = configuration.tracksDownbeats else { return false }
            // Bit 0 is always zero when the negotiated tracker does not report downbeats.
            // Bits 1-7 are reserved and intentionally ignored by the client.
            return tracksDownbeats || data[0] & 0x01 == 0

        case .fPeak:
            guard data.count == 4 else { return false }
            return data.withUnsafeBytes { buffer in
                let frequency = buffer.loadUnaligned(as: UInt16.self).bigEndian
                let amplitude = buffer.loadUnaligned(fromByteOffset: 2, as: UInt16.self).bigEndian
                return frequency != 0 || amplitude == 0
            }

        case .spectrum:
            guard let spectrum = configuration.spectrum,
                  spectrum.nDispBins > 0,
                  spectrum.nDispBins <= Int.max / 2 else { return false }
            return data.count == spectrum.nDispBins * 2

        case .peak:
            return data.count == 1
        }
    }
}
