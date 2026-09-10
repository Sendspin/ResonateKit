import Foundation

/// Client request to leave the current server group.
struct ClientLeaveMessage: SendspinMessage, Equatable {
    static let typeString = "client/leave"
    let type = Self.typeString
    let payload: ClientLeavePayload

    init(payload: ClientLeavePayload = ClientLeavePayload()) {
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case type, payload }
}

/// Empty payload for `client/leave`.
struct ClientLeavePayload: Codable, Equatable, Sendable {
    private enum CodingKeys: CodingKey {}
}
