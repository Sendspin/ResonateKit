import Foundation
@testable import SendspinKit
import Testing

struct PairingDescriptorEncodingTests {
    @Test("pairing_psk is advertised as an object with operator location")
    func pairingPSKDescriptorUsesSpecShape() throws {
        let encoder = SendspinEncoding.makeEncoder()
        let data = try encoder.encode([
            "pairing_psk": PairMethodDescriptor(locations: ["operator"])
        ])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let descriptor = try #require(object["pairing_psk"] as? [String: Any])
        #expect(descriptor["locations"] as? [String] == ["operator"])
        #expect(descriptor["out_channels"] == nil)
        #expect(descriptor["formats"] == nil)
        #expect(descriptor["digit_audio"] == nil)
    }
}
