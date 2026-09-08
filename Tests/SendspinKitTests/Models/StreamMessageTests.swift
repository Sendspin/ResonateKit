import Foundation
@testable import SendspinKit
import Testing

struct StreamMessageTests {
    @Test
    func playbackStatusDerivesFromWirePlaybackStateAndProgress() {
        let group = GroupInfo(groupId: "g1", groupName: "Kitchen", playbackState: .playing)
        let pausedMetadata = TrackMetadata(
            title: nil,
            artist: nil,
            album: nil,
            albumArtist: nil,
            track: nil,
            year: nil,
            artworkURL: nil,
            progress: PlaybackProgress(trackProgressMs: 30_000, trackDurationMs: 120_000, playbackSpeedX1000: 0, timestamp: 1)
        )
        let playingMetadata = TrackMetadata(
            title: nil,
            artist: nil,
            album: nil,
            albumArtist: nil,
            track: nil,
            year: nil,
            artworkURL: nil,
            progress: PlaybackProgress(trackProgressMs: 30_000, trackDurationMs: 120_000, playbackSpeedX1000: 1_000, timestamp: 1)
        )

        #expect(PlaybackStatus(group: group, metadata: nil) == .playing)
        #expect(PlaybackStatus(group: group, metadata: playingMetadata) == .playing)
        #expect(PlaybackStatus(group: group, metadata: pausedMetadata) == .paused)
        #expect(PlaybackStatus(group: nil, metadata: nil, isPlayerStreamActive: true) == .playing)
        #expect(PlaybackStatus(group: nil, metadata: pausedMetadata, isPlayerStreamActive: true) == .playing)
        #expect(PlaybackStatus(
            group: GroupInfo(groupId: "g1", groupName: "Kitchen", playbackState: .stopped),
            metadata: nil,
            isPlayerStreamActive: true
        ) == .stopped)
        #expect(PlaybackStatus(
            group: GroupInfo(groupId: "g1", groupName: "Kitchen", playbackState: .stopped),
            metadata: pausedMetadata,
            isPlayerStreamActive: true
        ) == .stopped)
        #expect(PlaybackStatus(group: GroupInfo(groupId: "g1", groupName: "Kitchen", playbackState: nil), metadata: playingMetadata) == nil)
    }

    @Test
    func decodeStreamStartMessage() throws {
        let json = """
        {
            "type": "stream/start",
            "payload": {
                "player": {
                    "codec": "opus",
                    "sample_rate": 48000,
                    "channels": 2,
                    "bit_depth": 16,
                    "codec_header": "AQIDBA=="
                }
            }
        }
        """

        // Now uses custom CodingKeys, no strategy needed
        let decoder = JSONDecoder()
        let data = try #require(json.data(using: .utf8))
        let message = try decoder.decode(StreamStartMessage.self, from: data)

        #expect(message.type == "stream/start")
        #expect(message.payload.player?.codec == "opus")
        #expect(message.payload.player?.sampleRate == 48_000)
        #expect(message.payload.player?.channels == 2)
        #expect(message.payload.player?.bitDepth == 16)
        #expect(message.payload.player?.codecHeader == "AQIDBA==")
    }

    @Test
    func decodeVisualizerStreamConfigurationUsesConditionalWireKeys() throws {
        let spectrum = SpectrumConfiguration(nDispBins: 32, scale: .log, fMin: 40, fMax: 16_000)
        let message = StreamStartMessage(payload: StreamStartPayload(
            player: nil,
            artwork: nil,
            visualizer: StreamStartVisualizer(
                types: [.beat, .spectrum], rateMax: 60, tracksDownbeats: true, spectrum: spectrum
            )
        ))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        let payload = try #require(object?["payload"] as? [String: Any])
        let visualizer = try #require(payload["visualizer"] as? [String: Any])
        #expect(visualizer["types"] as? [String] == ["beat", "spectrum"])
        #expect(visualizer["rate_max"] as? Int == 60)
        #expect(visualizer["tracks_downbeats"] as? Bool == true)
        #expect(visualizer["spectrum"] != nil)

        let noBeat = StreamStartVisualizer(types: [.loudness], rateMax: 30)
        let noBeatObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(noBeat)) as? [String: Any]
        #expect(noBeatObject?["tracks_downbeats"] == nil)
    }
}
