# 参与开发

请先阅读 README、安装和隐私说明，并使用与 `go/go.mod` 兼容的 Go、macOS 和 Xcode。依赖由 go.mod/go.sum 锁定；提交依赖变更时保留上游许可。

运行 `go -C go mod download all` 后执行 Go race 与回环 STCP 检查；Swift 回归和未签名构建命令见 README。UI 验收只使用可丢弃的模拟器和合成配置，不能连接真实服务器或读取用户 Keychain。

公开源码允许列表和 Build 10 来源记录位于 `release.json`。修改应用实现或增加文件时，应显式更新相应发行记录、版本和审计约束，不能继续把旧 IPA 描述成包含新代码。主程序与扩展的版本和 Build 必须同步。

Issue 请包含应用版本、系统版本、安装方式、脱敏的复现步骤和预期结果。不要上传服务器、Token、访问密钥、聊天、完整设备状态或未脱敏诊断记录。安全问题按 [SECURITY.md](SECURITY.md) 处理。
