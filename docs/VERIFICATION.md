# 1.5.0 / Build 10 验证范围

## 实现与分发对应

本次发布保留已验收的 Build 10 原始程序和源码附件，不把后来尚未重新打包的修正混入旧 IPA。原始实现提交为 `e4bad4f263aff4a17b0cb63bfe332769622c83b4`；该值用于来源标识，不是本仓库的新公开提交。

| 附件 | SHA-256 |
| --- | --- |
| `FrpModelChat-1.5.0-build10-reviewed-unsigned.ipa` | `2637ebf7f269f32108c25512626c1717a74df3c36882c3747127fb3a56f11f59` |
| `FrpModelChat-1.5.0-build10-reviewed-source.zip` | `534e257f8700f1c9dc1cc65424af34070378e4d212407cdf8b15c11fd35a5e24` |

原始源码 ZIP 恰含 65 个文件，逐字节对应该实现提交，七个 shell 脚本保留 0755 权限。GitHub 自动源码归档另外包含公开发行说明、审计脚本和 CI；README 的发行入口更新不改变程序实现。`release.json` 记录原始清单，`scripts/audit_release.py` 核对受保护的原始文件及发行允许列表。

## 已有本地证据

- 从原始源码包隔离运行：实时活动策略 8/8、控制器 33/33、聊天 47/47，以及更新版本/HTTPS 响应/容量/旧回调 fixtures 均通过。
- 开发方的 iPhoneOS 与 Simulator Release 构建通过；合成状态下 ActivityKit 和系统锁屏/通知中心 UI 测试通过。
- 发布方核验原始 IPA 的版本及主/扩展标识、5 个主程序文件与 2 个扩展文件、空默认配置、ZIP CRC、个人路径及指定测试标记的 UTF-8/UTF-16 扫描；未读取真实 Keychain 或配置。
- 用户确认其手机锁屏卡片已经出现。具体系统和安装工具未确认，不能据此推广到全部设备，也不能把显示恢复归因于未交付的后续修正。

## GitHub 检查与附件

本仓库的 [Checks](https://github.com/dneo9527-ctrl/frp-model-chat-ios/actions/workflows/checks.yml) 对每次提交独立执行允许列表/实现完整性审计、Go race 与本机回环 STCP、Swift 回归、未签名 iPhoneOS 构建和构建产物审计。源码通过 CI 不表示 GitHub 构建字节与原始 IPA 可复现一致，实际分发附件以本页列出的原始哈希为准。

发布流程在准确公开提交的 CI 通过后，先核验草稿附件的实际下载、大小、GitHub digest、SHA-256 和 CRC，再公开并匿名下载复核。最终完成状态和准确提交以 [v1.5.0 Release](https://github.com/dneo9527-ctrl/frp-model-chat-ios/releases/tag/v1.5.0) 为准；本节不预先宣称尚未结束的运行通过。

## 已知边界

IPA 未签名；App Store、TestFlight、Apple 签名及公证均未在本次发行完成。主程序最低 iOS 15、实时活动最低 iOS 16.2；iOS 15 真机尚未单独验收。

实时活动更新期间若卡片被移除，首次显式恢复可能不生效。后续错误分类、提示和恢复竞态的本地修正没有进入本 IPA，纳入时需主程序和扩展一起提升 Build、重建、重测并生成新附件。

停止移除、强杀、网络切换、长时后台和不同设备/签名工具没有完整真机验收。系统可移除卡片并限制活动时长；不能保证 FRPC 永久运行或强杀后立即移除卡片。没有 XTCP 直连，也不使用播放器伪装保活。更新源默认空，没有在线版本服务或自动安装。
