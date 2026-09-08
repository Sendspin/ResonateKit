import Foundation

// MARK: - Command Messages

/// Command sent from client to server (e.g. play, pause, skip)
struct ClientCommandMessage: SendspinMessage, Equatable {
    static let typeString = "client/command"
    let type = Self.typeString
    let payload: ClientCommandPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ClientCommandPayload: Codable, Equatable {
    let controller: ControllerCommand?
}

struct ControllerCommand: Codable, Equatable {
    /// Command type per spec
    let command: ControllerCommandType
    /// Group volume (0-100), only when command is `.volume`
    let volume: Int?
    /// Group mute state, only when command is `.mute`
    let mute: Bool?
    /// Absolute playback position in milliseconds, only when command is `.seek`.
    let positionMs: Int?
    /// Signed position offset in milliseconds, only when command is `.seekRelative`.
    let offsetMs: Int?

    enum CodingKeys: String, CodingKey {
        case command
        case volume
        case mute
        case positionMs = "position_ms"
        case offsetMs = "offset_ms"
    }

    init(
        command: ControllerCommandType,
        volume: Int? = nil,
        mute: Bool? = nil,
        positionMs: Int? = nil,
        offsetMs: Int? = nil
    ) {
        self.command = command
        self.volume = volume
        self.mute = mute
        self.positionMs = positionMs
        self.offsetMs = offsetMs
    }
}

/// Command sent from server to client (e.g. volume, mute, set_output_delay)
struct ServerCommandMessage: SendspinMessage, Equatable {
    static let typeString = "server/command"
    let type = Self.typeString
    let payload: ServerCommandPayload

    private enum CodingKeys: String, CodingKey { case type, payload }
}

struct ServerCommandPayload: Codable, Equatable {
    let player: PlayerCommandObject?

    init(player: PlayerCommandObject? = nil) {
        self.player = player
    }
}

/// Player command object within server/command
struct PlayerCommandObject: Codable, Equatable {
    /// Command type per spec
    let command: PlayerCommand
    /// Volume value (0-100), present when command is `.volume`
    let volume: Int?
    /// Mute state, present when command is `.mute`
    let mute: Bool?
    /// Output delay in ms (0-5000), present when command is `.setOutputDelay`
    let outputDelayMs: Int?

    enum CodingKeys: String, CodingKey {
        case command
        case volume
        case mute
        case outputDelayMs = "output_delay_ms"
    }

    init(command: PlayerCommand, volume: Int? = nil, mute: Bool? = nil, outputDelayMs: Int? = nil) {
        self.command = command
        self.volume = volume
        self.mute = mute
        self.outputDelayMs = outputDelayMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(PlayerCommand.self, forKey: .command)
        volume = try container.decodeIfPresent(Int.self, forKey: .volume)
        mute = try container.decodeIfPresent(Bool.self, forKey: .mute)
        outputDelayMs = try container.decodeIfPresent(Int.self, forKey: .outputDelayMs)

        let valid: Bool = switch command {
        case .volume:
            volume.map { (0 ... 100).contains($0) } == true
                && !container.contains(.mute) && !container.contains(.outputDelayMs)
        case .mute:
            mute != nil && !container.contains(.volume) && !container.contains(.outputDelayMs)
        case .setOutputDelay:
            outputDelayMs.map { (0 ... maxOutputDelayMs).contains($0) } == true
                && !container.contains(.volume) && !container.contains(.mute)
        }
        guard valid else {
            throw DecodingError.dataCorruptedError(
                forKey: .command,
                in: container,
                debugDescription: "Player command has an invalid argument set or range"
            )
        }
    }
}
