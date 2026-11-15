# 声明与致谢

简体中文 · [English](NOTICE.en.md)

项目原创代码按 GPL-3.0-only 分发，基于 [TakeruF/androp](https://github.com/TakeruF/androp) 的协议与相互操作研究。这是独立应用，不受 Apple 或 Android 设备厂商背书。

ZIPFoundation 0.9.20 使用 MIT 许可。完整许可保存在 `App/Resources/ZIPFoundation-LICENSE.txt` 并包含在构建的应用中；其隐私清单通过 Swift Package Manager 包含。保留本仓库根目录的协议研究致谢与第三方许可沿革。

P-256 派生与固定 AES-CBC IV 匹配现有互传协议。按会话固定 TLS 证书只保证控制和下载连接的一致性，不是独立验证的对方身份。接收必须手动确认；设备名称和发现广播均不能授权自动接收。
