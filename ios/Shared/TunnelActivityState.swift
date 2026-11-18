import Foundation

/// Deliberately excludes addresses, credentials, model names and chat content.
enum TunnelActivityPhase: String, Codable, Hashable {
    case connecting, connected, reconnecting, stopping

    var title: String {
        switch self {
        case .connecting: return "FRPC 正在连接"
        case .connected: return "FRPC 已连接"
        case .reconnecting: return "FRPC 正在重连"
        case .stopping: return "FRPC 正在停止"
        }
    }
    var symbol: String {
        switch self {
        case .connected: return "checkmark.shield.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .stopping: return "stop.circle"
        }
    }
}

struct TunnelActivityContent: Codable, Hashable {
    var phase: TunnelActivityPhase
    var confirmedAt: Date?
    var updatedAt: Date

    /// Freshness follows the actual health response, never a view refresh.
    var staleDate: Date { (phase == .connected ? confirmedAt ?? updatedAt : updatedAt).addingTimeInterval(60) }
}

struct TunnelActivitySnapshot: Equatable {
    var sessionID: UUID
    var slot: Int
    var startedAt: Date
    var content: TunnelActivityContent
}
