# 安装、更新与卸载

## 下载和核对

从 [v1.5.0 Release](https://github.com/dneo9527-ctrl/frp-model-chat-ios/releases/tag/v1.5.0) 下载三个附件到同一目录：

- `FrpModelChat-1.5.0-build10-reviewed-unsigned.ipa`
- `FrpModelChat-1.5.0-build10-reviewed-source.zip`
- `SHA256SUMS`

macOS 可在该目录执行 `shasum -a 256 -c SHA256SUMS`，Linux 可执行 `sha256sum -c SHA256SUMS`。两项均应通过。校验文件用于确认下载完整性，不提供 Apple 代码签名。

## 安装条件

主程序最低 iOS 15；锁屏实时活动需要 iOS 16.2+ 和系统授权。最低部署版本只证明编译支持，旧版 iOS 真机尚未逐一验收。

IPA 未签名。使用设备既有兼容的安装流程，或自行重新签名后安装。不要把本包理解为 App Store、TestFlight 或可直接安装的企业签名包。本项目不提供签名证书、设备授权或签名服务，也不保证某个系统或安装工具兼容。

重新签名必须同时处理主 App 和 `ConnectionStatusWidget.appex`，保持主程序与扩展 Bundle ID 的前缀关系，以及相同的 1.5.0 / Build 10 版本。原始标识为 `com.doc.frpmodelchat` 和 `com.doc.frpmodelchat.connection-status`。签名身份或 Bundle ID 的变化可能影响 Keychain 访问。

首次打开后，在“连接”中选择配置 1/2/3，自行填写服务器、Token、访问密钥，保存并连接；等待“模型接口可用”再切换到“聊天”选择模型。首次配置和更新源均为空，需要自行准备 frps、电脑发布端 frpc 和 Ollama。本应用不会迁移原 FrpClient 的配置或聊天记录。

## 升级和回退

保留旧 IPA，并先自行备份重要本机数据。在签名和应用标识兼容的情况下，使用原有安装方式覆盖安装；不要为了升级先删除 App。不同安装工具的签名和数据保留行为未逐一验收。

应用支持手动检查用户配置的 HTTPS 更新源，默认更新源为空；本次未部署在线版本清单，GitHub Release 不会自动推送或安装到手机。可以从 Release 下载并手动安装。清单格式见 [UPDATE-FEED.md](UPDATE-FEED.md)。

回退需要自行保留的旧包和兼容安装流程。新旧版历史数据兼容性没有完整回退验收，不能保证覆盖回退后所有数据可读。

## 卸载

先停止连接，再从系统删除 App。删除 App 会移除其私有容器中的聊天记录；Keychain 可能按 iOS 的规则继续保留相关项目，不能把卸载视为保证清除所有凭据。公开问题报告不要包含真实服务器、Token、访问密钥、聊天或设备标识。
