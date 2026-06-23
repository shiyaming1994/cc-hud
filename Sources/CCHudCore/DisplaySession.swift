import Foundation

public struct DisplaySession: Identifiable, Sendable {
    public let session: Session
    public let dup: Int?      // 同名项目序号（1 起），唯一时 nil
    public var id: String { session.id }
}
