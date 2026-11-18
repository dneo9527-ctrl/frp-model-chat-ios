# 1.5.0 · FRPC 锁屏实时活动

连接时自动创建系统实时活动，在锁屏和支持的灵动岛显示状态、配置编号、STCP / VPS 中转和本次任务运行时长。纯黑与中性灰主题保留。

## 状态含义

- **正在连接**：已开始启动隧道，尚未通过模型接口检查。
- **已连接**：当前运行实例通过真实 Ollama 模型接口检查，包括有效的空模型列表。
- **正在重连**：网络断开、接口检查失败或底层临时退出后处于有界重试过程。
- **正在停止**：停止请求已提交，等待底层任务真正释放。
- **状态待确认**：最后一次状态超过 60 秒未确认；隐藏递增计时，保留上次接口确认时间，点按打开应用检查。
- 底层停止完成或终止性失败后立即请求移除卡片。重连保留同一运行计时，新一次连接创建新计时。

“运行时长”包含连接和重连等待时间，不是成功连接时长。卡片不显示服务器地址、IP 所属国家、密钥、模型名称或聊天内容；没有添加 IP 查询服务或遥测。

“上次确认”来自模型接口成功响应；没有成功响应时显示“尚未确认连接”。计时本身不代表持续在线，过期卡片不再显示递增时长。

## 使用与系统边界

主应用仍支持 iOS 15；实时活动需要 iOS 16.2+。连接时应用需在前台才能新建卡片。设置 → 锁屏连接状态可关闭，划掉卡片或系统结束卡片后可在应用前台显式恢复。普通通知权限与实时活动开关并不相同；若系统禁止实时活动，应用会提示去 iPhone 设置开启。

这是 ActivityKit 实时活动，不是播放器，也不以音频或其他虚假后台任务维持。系统允许用户划掉，并限制单次活动约 8 小时。实时活动本身不保证 FRPC 在后台持续运行。应用挂起、被强制关闭或系统回收时无法保证立即更新/移除；过期分支显示待确认，冷启动时清理上次进程遗留卡片。本版没有 APNs 推送服务或自动后台重建卡片。

Apple 文档：
- https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- https://developer.apple.com/documentation/activitykit/activityauthorizationinfo/areactivitiesenabled
- https://developer.apple.com/documentation/activitykit/activitystate/stale

## 签名与安装

IPA 新增 `ConnectionStatusWidget.appex` 扩展，标识为 `com.doc.frpmodelchat.connection-status`。主标识和钥匙串服务保持不变。重新签名时须包含扩展，扩展标识仍需以主标识为前缀，版本号需一致。不需要 App Group、推送证书或额外定位授权来显示卡片。应通过已有安装渠道覆盖安装，保留旧 IPA；不要为更新先卸载含本机记录的应用。

## 验证范围

具体结果见同版本交付中的 ACCEPTANCE.json 与项目 verification/live-activity-build10。模拟数据系统卡片测试与 Controller 真状态回归分别记录，不能将前者冒充真实 VPS/真机锁屏验收。真机强杀、锁屏长时后台、8 小时时限和重新签名安装仍需现场验证。
