# 华为分享试验发送

简体中文 · [English](HUAWEI.en.md)

0.5.0 (9) 增加同一 Wi-Fi 上的 IP 指定发送。这是华为实机兼容性尚未确认的试验功能。**华为向本应用发送、自动发现和 Wi-Fi Direct 未实现。** HUAWEI Pura 70 / HarmonyOS 7 是计划验证目标，实机测试暂缓。

## 操作

1. 对方打开华为分享，首次使用时设为所有人可见。
2. 在华为 Wi-Fi 设置中查看 IPv4 地址。
3. 在 anDrop 本体展开“Huawei Share（試験）”，输入该地址并按“端末を確認”。
4. 确认加入接收设备列表后，选择文件并点选该设备，在华为侧批准接收。
5. 以对方完成应答为应用的完成判据，并在华为侧确认实际保存结果。

最多 16 文件、原始总大小 64 MiB。仅在确认设备后保存用户输入的 IP，“登録を解除”会移除它。IP 不是信任身份。发送使用十秒内的确认结果或再次确认同一 IP；发现标识改变时停止。Wi-Fi 或对方地址变更后重新确认。

本体已登记的设备也在共享扩展中确认。iOS 26 起使用“选择设备 → 準備を完了 → 手动打开本体”的交接步骤，开始后接入后台任务与系统进度。华为实机后台行为未验证；系统拒绝后台执行时保持本体前台。

## 协议与限制

使用定向 CoAP 单播获取对方端口，不固定协商端口。加密应答中的 IP 必须匹配明确选择的设备。没有广播发送、子网扫描或热点切换。iOS 实机的多播／广播需要额外权限，因此本版不启用自动发现。见 [Apple 说明](https://developer.apple.com/news/?id=0oi77447) 与[本地网络规范](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。

实现采用 macOS 版的 Apple 兼容会话，不绕过需要华为证书的标准会话。当前仅支持 Security.framework 提供的 RSA-2048 / OAEP-SHA256 / MGF1-SHA256；对方要求不同的受保护方式时停止。AES-GCM 控制／数据以及 DFile 内外头都做完整性检查。

本地 RSA 身份保存在 Keychain，用来保持本应用的身份连续性，不是华为厂商证明或账号认证。诊断不保存 IP、文件名、内容或密钥。iOS 产品不嵌入 Python 或其他应用的运行库。

## 本地验证与复现

Mac 参考接收处理通过许可、拒绝、篡改完成应答、发送中止四种条件。成功路径发送七个文件、超过 20 MiB，覆盖空文件、日文原名和 `manifest.json`，验证逐文件内容与 DONE ACK。参考侧仅按已观测的电话顺序发起首次 MetaNode 通知，随后使用未修改的认证、解密和接收逻辑。

这不是华为实机保存、图库登记、速度或稳定性的证明。原始实现参照本仓库 `scripts/huawei-*.py` 与 `Sources/huawei_runtime.py`。

普通 Swift 测试不依赖 Python。准备好仓库根目录的 macOS 开发 Python 环境后，可从 `ios/` 运行可选参考通信：

```sh
ANDROP_HUAWEI_REFERENCE_ROOT="$(git rev-parse --show-toplevel)" swift test --no-parallel
```

实机验证应记录机型、HarmonyOS 版本、方向、件数／总大小、应用诊断阶段及对方保存结果。完成验证前不视为正式兼容性支持。
