import Foundation

extension SendspinConnection {
    /// Ask the server to remove this client from its current group.
    func leaveGroup() async throws {
        do {
            try await sendWrapped(ClientLeaveMessage(), requireRunningLifecycle: true)
        } catch let error as SendspinClientError {
            throw error
        } catch {
            throw SendspinClientError.sendFailed(error.localizedDescription)
        }
    }
}
