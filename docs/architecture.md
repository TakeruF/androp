# 架构

简体中文 · [English](architecture.en.md)

| 组件 | 职责 |
| --- | --- |
| `Sources/main.swift` | AppKit菜单栏、SwiftUI设置／候选、通知、登录启动、CoreBluetooth peripheral和GATT |
| `Sources/ShareViewController.swift` | Finder共享扩展，将所选URL交给host |
| `Sources/BrandLogos.swift` | 缓存本地官方品牌图，不在运行时下载 |
| `Sources/TransferProgress.swift` | 发送阶段、有界百分比和候选快照 |
| `Sources/discovery.py` | macOS重复广播回调与候选过期 |
| `Sources/ReceiveAccessPolicy.swift` | 按本地可信endpoint做GATT检查 |
| `Sources/Peer.swift` | 候选展示、别名key、同名区分 |
| `Sources/peer_metadata.py` | 保守解析广播及endpoint变化后的候选身份 |
| `Sources/Localization.swift` | 英语／简体中文、系统语言回退 |
| `Sources/engine.py` | BLE central扫描、协议、本地HTTPS/WebSocket、归档验证与保存 |

host与同捆engine通过进程管道JSON lines通信，不用网络listener作本地IPC。蓝牙发现，正文走现有LAN；Mac接收广告8881/GATT9999，发送扫描兼容service data再与选定设备协商。平台／厂商差异需实机测试。

联盟路径使用P-256及观测到的AES-CBC协商格式，发送方HTTPS提供ZIP、TLS WebSocket交换控制；接收下载证书固定为同会话WebSocket证书。这是会话一致性，不是独立认证对端身份。归档检查件数/总大小/危险路径/不支持类型，完成文件不覆盖、加quarantine、每次批准。尚未独立安全审计。

不运行时导入mtapy；[NOTICE](../NOTICE.md)记录原型及参考。Wi-Fi Direct/Google Quick Share未实现。1.2.0正式Huawei Share使用独立native LAN发现、同捆Python RSA/AES-GCM/DFile。机型范围见[兼容性](compatibility.md)，限额见[使用](usage.md)，鸿蒙星河互联共存仍实验性。

## 受信任设备接收筛选

host将CoreBluetooth central UUID列表与别名分开保存，在返回状态／缓存数据前检查GATT读和整批写；未知subscription不发通知，排队通知送达时重查，不用nil subscriber广播。engine独立筛ready、派生接收密钥前检查UUID，批准后再查接收状态和政策。名字／广播ID不授予信任，无批准不下载，已批准传输可在移除信任后完成。

候选来自完成接收，需手动登记。联盟记录 `sender:`+自报senderId的SHA256，不是认证凭据。Huawei记录 `huawei-key:`+规范DER RSA公钥SHA256，仅在有效GCM offer证明私钥持有后交runtime；raw key不写探针证据。发现ID/名字/IP/账号名不能授权。公钥连续性是本机登记，不是厂商／账号认证。身份变化需Everyone新收再登记，旧Huawei历史无key不能迁移；离线记录可管理。仅联盟sender允许GATT元数据协商，Huawei key不打开该入口。两协议均在提示／数据前拒未知、批准后重查且每次确认。发现仍公开，见[信任与发现](trusted-discovery.md)。

host运行、蓝牙Wi-Fi可用即接收，无持久总开关；退出停广告／engine，无线不可用停新请求和广告。控制中心已移除，[独立接收面板原型](../Prototypes/ReceivePanel/README.md)保留原生glass/SF Symbols/演示，正式构建不产WidgetKit/App Intents/App Group快照，旧control URL打开普通设置。

点击候选立即发送，持续发现让其他候选仍可点击。首次保留批次，后续点击复用原批次且不丢新排队Finder选择。host每目标独立文件列表/request ID；engine按ID+目标预留会话，独立密钥/归档/socket/取消任务，Huawei有独立进程组。接收独占，发送活跃时拒新接收。重复request ID幂等，同目标重复活动发送拒绝。

每tile独立进度/结果/重试/取消；全部取消停活动和待重试，完成关闭结果，仅全成功可点外关闭。发送中切其他窗口仍继续。
