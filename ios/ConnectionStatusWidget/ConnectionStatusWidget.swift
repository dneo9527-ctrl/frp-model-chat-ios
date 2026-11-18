import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ConnectionStatusWidgetBundle: WidgetBundle {
    var body: some Widget { ConnectionStatusWidget() }
}

struct ConnectionStatusWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ConnectionActivityAttributes.self) { context in
            ConnectionCard(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "frpmodelchat://connection"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("FRPC", systemImage: symbol(context)).font(.headline).foregroundColor(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.isStale {
                        Text("待确认").font(.caption)
                    } else {
                        Text(context.attributes.startedAt, style: .timer).monospacedDigit().font(.caption)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(context)).font(.headline)
                        Text("配置 \(context.attributes.slot + 1) · STCP · VPS 中转")
                            .font(.caption).foregroundColor(.gray)
                        ConfirmationTime(confirmedAt: context.state.confirmedAt)
                            .font(.caption2).foregroundColor(.gray)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: symbol(context)).foregroundColor(.white)
            } compactTrailing: {
                Text(context.isStale ? "待确认" : compactTitle(context.state.phase))
                    .font(.caption2)
            } minimal: {
                Image(systemName: symbol(context)).foregroundColor(.white)
            }
            .keylineTint(.gray)
            .widgetURL(URL(string: "frpmodelchat://connection"))
        }
    }
    private func compactTitle(_ phase: TunnelActivityPhase) -> String {
        switch phase {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .reconnecting: return "重连中"
        case .stopping: return "停止中"
        }
    }
    private func title(_ context: ActivityViewContext<ConnectionActivityAttributes>) -> String {
        context.isStale ? "FRPC 状态待确认" : context.state.phase.title
    }
    private func symbol(_ context: ActivityViewContext<ConnectionActivityAttributes>) -> String {
        context.isStale ? "questionmark.circle" : context.state.phase.symbol
    }
}

private struct ConnectionCard: View {
    let context: ActivityViewContext<ConnectionActivityAttributes>
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: context.isStale ? "questionmark.circle" : context.state.phase.symbol)
                .font(.system(size: 27, weight: .medium)).foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(Color(white: 0.16)).clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(context.isStale ? "FRPC 状态待确认" : context.state.phase.title)
                    .font(.headline).foregroundColor(.white)
                Text("配置 \(context.attributes.slot + 1) · STCP · VPS 中转")
                    .font(.caption).foregroundColor(Color(white: 0.72))
                ConfirmationTime(confirmedAt: context.state.confirmedAt)
                    .font(.caption2).foregroundColor(Color(white: 0.72))
                Text(context.isStale ? "点按打开应用核对" : "点按查看连接")
                    .font(.caption2).foregroundColor(Color(white: 0.72))
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                if context.isStale {
                    Image(systemName: "exclamationmark.circle")
                        .font(.title3).foregroundColor(.white)
                    Text("请核对连接").font(.caption2).foregroundColor(Color(white: 0.72))
                } else {
                    Text("运行时长").font(.caption2).foregroundColor(Color(white: 0.72))
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .multilineTextAlignment(.trailing).foregroundColor(.white)
                }
            }.frame(width: 80)
        }.padding(16)
    }
}

private struct ConfirmationTime: View {
    let confirmedAt: Date?
    var body: some View {
        if let confirmedAt {
            (Text("上次确认 ") + Text(confirmedAt, style: .time))
        } else {
            Text("尚未确认连接")
        }
    }
}
