# anDrop for iPhone and iPad

简体中文 · [English](README.en.md)

iOS / iPadOS 原生互传实验客户端，源码位于本仓库的 `ios/`。当前为 **0.5.0 (9) 预览版**，最低支持 iOS / iPadOS 17。它与仓库根目录的 macOS 正式版分别构建，尚无 App Store 或 TestFlight 发行。

## 功能与边界

- 通过 CoreBluetooth 发现兼容的互传设备，使用 P-256、原协议的 AES-CBC 协商、TLS / WebSocket 控制与 HTTPS ZIP 传输。
- 收到文件前手动确认；检查文件名、路径、数量、总大小、CRC 和 SHA-256，同名文件另存，不自动打开文件。
- 从“文件”“照片”等应用的系统共享菜单导入，保留原文件名和内容。每批最多 **16 个文件、原始总大小 64 MiB**。
- iOS / iPadOS 26 起，为已经开始的传输接入系统持续后台任务与进度显示；支持的 iPhone 可在 Dynamic Island 显示。后台执行仍由系统决定。
- **华为分享试验发送**：同一 Wi-Fi，通过用户指定的 IPv4 地址确认设备，使用独立的 RSA / AES-GCM / DFile 路径。华为实机尚未验证；尚不支持华为向本应用发送或自动发现。

用户已报告 OPPO 与 iPhone 16 的双向传输成功。它不代表所有型号、格式或当前版的后台路径已完成实机验证。最新后台功能的完整实机验证待完成；HUAWEI Pura 70 / HarmonyOS 7 是计划验证目标。见[验证记录](docs/VALIDATION.md)。

Wi-Fi Direct、常驻后台接收、Google Quick Share、Live Photo 转换及直接共享 URL / 文本尚未支持。用户界面目前为日语。

## 使用

1. 打开 anDrop，允许蓝牙与本地网络访问，与对方连接同一 Wi-Fi。
2. 本体发送时选文件，再选择附近设备；对方开启兼容互传及可见性，并确认接收。
3. 接收时保持本体在前台，直到看到请求并按“受信する”。文件保存在“文件”→“我的 iPhone / iPad”→“anDrop”→“Received”。
4. 其他应用共享：选择“anDrop”和接收设备。iOS 26 起按“準備を完了”，手动打开 anDrop 本体后开始发送；开始后可切换应用。旧系统须保持共享界面打开。
5. 如系统提示后台不可用，保持本体在前台直到传输结束。

[共享步骤](docs/SHARING.md) · [文件格式](docs/FILE-FORMATS.md) · [后台传输](docs/BACKGROUND.md) · [华为试验发送](docs/HUAWEI.md) · [OPPO 验证](docs/OPPO-TESTING.md)

诊断仅保存在应用内，记录固定阶段、件数、大小和有限错误代码；不记录文件名、内容、IP、设备名称或密钥。导出与发送诊断由用户操作。

## 开发

在 `ios/` 中使用 Xcode 27.2 / Swift 6.3 和 XcodeGen。配置正本是 `project.yml`。

```sh
cd ios
xcodegen generate
swift test --no-parallel
xcodebuild -project anDrop.xcodeproj -scheme anDrop \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

本仓库不指定个人签名团队。实机开发须使用自己的团队，在 Xcode 中配置可用的应用 ID、共享扩展 ID 和 App Group；如改名，同步修改 `project.yml`、生成的项目以及 `App/BackgroundTransfer.swift` 的 App Group / 后台任务前缀。本体和扩展的 App Group 必须一致。不要提交个人签名配置、证书或描述文件。

设备脚本从环境变量接收团队：`ANDROP_DEVELOPMENT_TEAM=YOUR_TEAM_ID scripts/install-device.sh <device-udid>`。后台实机测试使用同一变量及 `scripts/test-background-device.sh <unlocked-device-udid>`。脚本会安装、运行应用；只在明确计划实机测试时运行。共享 UI 测试使用 `scripts/test-simulator.sh <simulator-udid>`。

`Core/` 可在 macOS 上测试；`App/` 是本体，`ShareExtension/` 是共享扩展，`TestSupport/` 是测试工具。测试辅助应用不嵌入产品。iOS 产品不使用 Python 运行时、外部进程或私有 API。

## 许可与公开材料

GPL-3.0-only，参考本仓库 macOS 协议实现；ZIPFoundation 0.9.20 使用 MIT 许可。保留 [LICENSE](LICENSE)、[NOTICE.md](NOTICE.md) 及依赖声明。未捆绑厂商标志。

公开提交仅包含审核后的源码、配置、合成测试代码和文档。真实诊断、截图、抓包、私有样本、开发签名身份、设备标识及构建成果不在此目录中发布。既有 macOS 发行资产与这个 iOS 预览源码分开。
