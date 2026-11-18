import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct ConnectionActivityAttributes: ActivityAttributes {
    typealias ContentState = TunnelActivityContent
    let sessionID: UUID
    let slot: Int
    let startedAt: Date
}
