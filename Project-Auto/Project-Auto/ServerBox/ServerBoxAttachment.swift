import Foundation

/// Host grants are scoped to one chat model instance, so separate Agent windows do not share SSH access.
@MainActor
final class ServerBoxAttachment {
    private(set) var hostID: UUID?

    func attach(_ id: UUID?) { hostID = id }
    func detach() { hostID = nil }
}
