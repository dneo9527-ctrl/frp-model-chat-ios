import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("updateSource") private var updateSource = ""
    @StateObject private var updates = AppUpdateController()
    @EnvironmentObject private var tunnel: FrpcController
    @EnvironmentObject private var activity: ConnectionActivityController

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 14) {
                        BrandMark(size: 60)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Frp 模型对话").font(.title3.bold())
                            Text("随身连接，自己的模型。")
                                .font(.subheadline).foregroundColor(.secondary)
                            Text("\(updates.installedVersion) · Build \(updates.installedBuild)")
                                .font(.caption.monospaced()).foregroundColor(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                Section(header: Text("外观")) {
                    Picker("主题", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }.pickerStyle(.segmented)
                }
                Section(header: Text("锁屏连接状态"), footer: Text("连接时显示，停止后移除。系统允许划掉卡片，单次最长约 8 小时；状态超过 60 秒未验证时显示待确认。强制关闭应用后未必立即消失。")) {
                    Toggle("显示 FRPC 实时活动", isOn: Binding(get: { activity.enabled }, set: { activity.setEnabled($0) }))
                        .disabled(!activity.isSupported)
                    Text(activity.message).font(.footnote).foregroundColor(.secondary)
                        .accessibilityIdentifier("live-activity-status")
                    if activity.canRestore {
                        Button("恢复锁屏卡片") { activity.restore() }
                    }
                }
                Section(header: Text("版本与更新"), footer: Text("检查更新只读取版本清单。新版需通过原安装渠道安装；应用不会静默替换自身。")) {
                    Button { updates.check(source: updateSource) } label: {
                        HStack {
                            Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if updates.isChecking { ProgressView() }
                        }
                    }.disabled(updates.isChecking)
                    Text(updates.message).font(.footnote).foregroundColor(.secondary)
                    if let checked = updates.lastChecked {
                        HStack {
                            Text("上次检查")
                            Spacer()
                            Text(checked, style: .time)
                        }.font(.caption).foregroundColor(.secondary)
                    }
                    if let release = updates.release {
                        Text(release.notes).font(.subheadline).textSelection(.enabled)
                        Link(destination: release.releasePage) {
                            Label("查看新版发布页", systemImage: "arrow.up.right.square")
                        }
                        Text(release.releasePage.host ?? "").font(.caption).foregroundColor(.secondary)
                    }
                    DisclosureGroup("更新源设置") {
                        TextField("HTTPS 版本清单地址", text: $updateSource)
                            .keyboardType(.URL).textContentType(.URL)
                            .autocapitalization(.none).disableAutocorrection(true)
                            .accessibilityLabel("更新源地址")
                        Text("当前没有预设的公开更新源。仅填写你信任的发布者提供的清单地址。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Section(header: Text("本机与隐私")) {
                    Label("聊天记录仅保存在本机，不随设备备份同步。", systemImage: "iphone")
                    Label("连接配置保存在本机钥匙串。", systemImage: "key")
                    Label("消息经你的 STCP 隧道发送到远端 Ollama。", systemImage: "point.3.connected.trianglepath.dotted")
                }.font(.footnote)
                Section(header: Text("本版新增")) {
                    feature("锁屏连接状态", detail: "连接 · 重连 · 运行时长 · 停止后移除")
                    feature("更清爽的聊天空间", detail: "统一主题 · 紧凑状态栏 · 自适应输入区")
                    feature("消息与会话整理", detail: "代码块复制 · 会话搜索 · 重命名")
                    feature("连接信息更清楚", detail: "手动刷新模型 · 最近验证时间 · STCP 链路")
                }
                Section(header: Text("连接方式"), footer: Text("当前使用 STCP，经 VPS 中转；XTCP 直连尚未包含。")) {
                    Text("手机 → VPS frps → 电脑 frpc → Ollama")
                        .font(.footnote.monospaced()).textSelection(.enabled)
                    HStack { Text("frp 内核"); Spacer(); Text(tunnel.frpVersion).foregroundColor(.secondary) }
                }
            }
            .background(AppTheme.background)
            .navigationTitle("设置")
            .onChange(of: updateSource) { _ in updates.sourceChanged() }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
        }.navigationViewStyle(.stack)
    }

    private func feature(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundColor(.secondary)
        }.padding(.vertical, 2)
    }
}
