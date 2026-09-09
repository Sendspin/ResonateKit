import Foundation

// MARK: - Stream Messages

/// Stream start message
struct StreamStartMessage: SendspinMessage, Equatable {
    static let typeString = "stream/start"
    let type = Self.typeString
    let payload: StreamStartPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct StreamStartPayload: Codable, Equatable {
    let player: StreamStartPlayer?
    let artwork: StreamStartArtwork?
    let visualizer: StreamStartVisualizer?
}

/// Player stream configuration within stream/start.
///
/// `codec` is `String` rather than `AudioCodec` because this is a server-provided
/// type — the server may support codecs the client doesn't know about yet. The client
/// validates the codec when building `AudioFormatSpec` and surfaces a structured
/// `.unsupportedCodec` error if it's unrecognized.
struct StreamStartPlayer: Codable, Equatable {
    let codec: String
    let sampleRate: Int
    let channels: Int
    let bitDepth: Int
    let codecHeader: String?

    enum CodingKeys: String, CodingKey {
        case codec
        case sampleRate = "sample_rate"
        case channels
        case bitDepth = "bit_depth"
        case codecHeader = "codec_header"
    }
}

/// Artwork stream configuration in stream/start per spec.
/// Contains per-channel config with resolved dimensions.
struct StreamStartArtwork: Codable, Equatable {
    /// Configuration for each active artwork channel, array index is the channel number
    let channels: [StreamArtworkChannelConfig]
}

/// Negotiated visualizer stream configuration in `stream/start`.
struct StreamStartVisualizer: Codable, Equatable {
    let types: [VisualizerType]
    let rateMax: Int
    let tracksDownbeats: Bool?
    let spectrum: SpectrumConfiguration?

    enum CodingKeys: String, CodingKey {
        case types
        case rateMax = "rate_max"
        case tracksDownbeats = "tracks_downbeats"
        case spectrum
    }

    init(
        types: [VisualizerType] = [.loudness],
        rateMax: Int = 1,
        tracksDownbeats: Bool? = nil,
        spectrum: SpectrumConfiguration? = nil
    ) {
        self.types = types
        self.rateMax = rateMax
        self.tracksDownbeats = tracksDownbeats
        self.spectrum = spectrum
    }
}

/// Stream end message — ends streams for specified roles (or all if omitted)
struct StreamEndMessage: SendspinMessage, Equatable {
    static let typeString = "stream/end"
    let type = Self.typeString
    let payload: StreamEndPayload

    private enum CodingKeys: String, CodingKey { case type, payload }

    init(payload: StreamEndPayload = StreamEndPayload()) {
        self.payload = payload
    }
}

struct StreamEndPayload: Codable, Equatable {
    /// Roles to end streams for. If nil, ends all active streams.
    /// Typed as `[String]?` because the spec allows application-specific roles
    /// (prefixed with `_`), making this an open set.
    let roles: [String]?

    init(roles: [String]? = nil) {
        self.roles = roles
    }
}

/// Group update message
struct GroupUpdateMessage: SendspinMessage, Equatable {
    static let typeString = "group/update"
    let type = Self.typeString
    let payload: GroupUpdatePayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct GroupUpdatePayload: Codable, Equatable {
    /// Per spec, playback_state is a closed set: `'playing' | 'stopped'`.
    /// Unlike roles, there's no extensibility mechanism for custom states.
    let playbackState: PlaybackState
    let groupId: String
    let groupName: String

    enum CodingKeys: String, CodingKey {
        case playbackState = "playback_state"
        case groupId = "group_id"
        case groupName = "group_name"
    }
}

// MARK: - Clear Messages

/// Stream clear message — instructs client to clear buffers without ending the stream.
/// Used for seek operations.
struct StreamClearMessage: SendspinMessage, Equatable {
    static let typeString = "stream/clear"
    let type = Self.typeString
    let payload: StreamClearPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct StreamClearPayload: Codable, Equatable {
    /// Which roles to clear. If nil, clears all roles.
    /// Typed as `[String]?` because the spec allows application-specific roles
    /// (prefixed with `_`), making this an open set.
    let roles: [String]?

    init(roles: [String]? = nil) {
        self.roles = roles
    }
}
