import Foundation
@testable import SendspinKit
import Testing

struct VisualizerBinaryPayloadTests {
    private let spectrum = SpectrumConfiguration(nDispBins: 2, scale: .lin, fMin: 20, fMax: 20_000)

    private var configuration: VisualizerStreamConfiguration {
        VisualizerStreamConfiguration(
            types: [.loudness, .beat, .fPeak, .spectrum, .peak],
            rateMax: 30,
            tracksDownbeats: true,
            spectrum: spectrum
        )
    }

    @Test("visualizer payloads accept each negotiated wire shape")
    func validPayloadShapeForEachType() {
        let payloads: [(VisualizerType, Data)] = [
            (.loudness, Data([0x00, 0x01])),
            (.beat, Data([0x01])),
            (.fPeak, Data([0x01, 0x00, 0x02, 0x00])),
            (.spectrum, Data([0x00, 0x01, 0x00, 0x02])),
            (.peak, Data([0xFF]))
        ]

        for (type, payload) in payloads {
            #expect(
                VisualizerBinaryPayloadValidator.isValid(type: type, data: payload, configuration: configuration),
                "Expected the documented payload shape for \(type)"
            )
        }
    }

    @Test("visualizer payloads reject every wrong length")
    func invalidPayloadLengthForEachType() {
        let payloads: [(VisualizerType, Data)] = [
            (.loudness, Data([0x00])),
            (.beat, Data()),
            (.fPeak, Data([0x00, 0x01, 0x00])),
            (.spectrum, Data([0x00, 0x01])),
            (.peak, Data([0xFF, 0x00]))
        ]

        for (type, payload) in payloads {
            #expect(
                !VisualizerBinaryPayloadValidator.isValid(type: type, data: payload, configuration: configuration),
                "Expected malformed length for \(type) to be rejected"
            )
        }
    }

    @Test("f_peak with zero frequency requires zero amplitude")
    func fPeakZeroFrequencyInvariant() {
        #expect(
            VisualizerBinaryPayloadValidator.isValid(
                type: .fPeak,
                data: Data([0x00, 0x00, 0x00, 0x00]),
                configuration: configuration
            )
        )
        #expect(
            !VisualizerBinaryPayloadValidator.isValid(
                type: .fPeak,
                data: Data([0x00, 0x00, 0x00, 0x01]),
                configuration: configuration
            )
        )
    }

    @Test("beat downbeat flag follows negotiation while reserved bits are ignored")
    func beatValueInvariant() {
        #expect(
            VisualizerBinaryPayloadValidator.isValid(
                type: .beat,
                data: Data([0b1111_1111]),
                configuration: configuration
            )
        )

        let withoutDownbeats = VisualizerStreamConfiguration(
            types: [.beat],
            rateMax: 30,
            tracksDownbeats: false,
            spectrum: nil
        )
        #expect(
            VisualizerBinaryPayloadValidator.isValid(
                type: .beat,
                data: Data([0b1111_1110]),
                configuration: withoutDownbeats
            )
        )
        #expect(
            !VisualizerBinaryPayloadValidator.isValid(
                type: .beat,
                data: Data([0b1111_1111]),
                configuration: withoutDownbeats
            )
        )
    }

    @Test("spectrum length multiplication rejects an overflowing negotiated bin count")
    func spectrumLengthOverflowIsRejected() {
        let overflowingConfiguration = VisualizerStreamConfiguration(
            types: [.spectrum],
            rateMax: 30,
            tracksDownbeats: nil,
            spectrum: SpectrumConfiguration(nDispBins: Int.max, scale: .lin, fMin: 20, fMax: 20_000)
        )
        #expect(
            !VisualizerBinaryPayloadValidator.isValid(
                type: .spectrum,
                data: Data(),
                configuration: overflowingConfiguration
            )
        )
    }
}
