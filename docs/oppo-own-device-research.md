# OPPO 仅联系人与本人设备发现调查

简体中文 · [English](oppo-own-device-research.en.md)

调查：2026-10-16，anDrop revision `a1126e5`。本文描述该修订的历史状态，当前信任机制见[受信任设备](trusted-discovery.md)。

## 结论与证据范围

OPPO区分联系人与同OPPO/HeyTap账号设备，个人Mac对应后者。改anDrop名字、记蓝牙ID或添加同名联系人都不能建立这种关系。Apple设备支持提供可能的互通方向，但 **anDrop尚未被证明是同账号设备**；现有公开发现／传输没有账号感知发现通道。本次未发送身份声明、改可见性、登录、配对或传文件。

| 包 | 版本 | 职责 |
| --- | --- | --- |
| `com.coloros.oshare` |17.2.36|分享UI与传输编排|
| `com.heytap.accessory` |17.6.16|Pantaconnect发现与分布式上下文|

已有OShare APK与安装文件SHA-256一致；AccessoryFramework从手机只读复制并核对。未读账号库／通讯录。

- OShare：`18a7b0eeda843a91379862a5f3b346befa18dbae6b8cc6cb7d2efb364c0704c4`
- AccessoryFramework：`538e5665ea6c709827063cc8b2f2dc86c82d432252c41ca4606526be7497ec78`

这些是特定版本实现发现，不是厂商规范。反编译存在错误／畸形控制流，仅采用可读调用链和资源，不将不明分支当可工作协议。私有APK／源码留仓库外。

## 联系人与本人设备的含义

OShare联系人助手查询电话号码联系人，E.164规范化后比较派生hash。观察的16 B记录含salt及SIM1/SIM2/账号号码三条；单项用截短SHA-256与salt字节。Pantaconnect另有支持无国家码号码的新数据源，因此不能认为该助手覆盖所有包格式。

local／remote／mutual／no contact分别记录。该发现订阅中same-account、remote-contact、mutual-contact可通过仅联系人门槛，all-devices另可通过。单方通讯录加号码不证明对方允许发现；这不是名字或蓝牙配对历史，anDrop当前不提供匹配联系人数据。

1. 账号发现：OShare订阅Pantaconnect `OSHARE_DISCOVERED_MODE`，接收 `is_same_account`／`identity_relationship`等。这是另一服务的输出，不能在现有广播里设一个开关实现。
2. Android常驻发现：加密TLV带账号相关信息，账号管理器粗略比较两端账号hash字节，不等同更强连接认证。
3. 传输时比较：部分BLE/P2P路径交换账号ssoid派生加密值；短ssoid通常SHA256，长值保留。与Pantaconnect发现hash是否等价未证。
4. Apple路径：另有iBeacon/GATT、设备元数据、is_same_account，UI消费该字段；单字段不证明所有权认证、仅联系人发现或传输许可。

常驻TLV调用GUK provider，由OPPO crypto engine按key label/version以HKDF派生密钥再加解密。APK中的标签不是底层密钥，复制账号hash到现有anDrop广播不构成实现；也不能反向断言所有Apple客户端必须有OPPO安全硬件。

## Apple与Mac支持范围

手机资源明确列：同账号或联系人的兼容OPPO/OnePlus/realme，以及登录同账号、最新版OPPO Connect的iPhone/iPad。该特定说明未列Mac，不能据此称Mac实测通过。[ColorOS官方Mac说明](https://www.coloros.com/article/A00000087/)另述同账号同WLAN自动连接，证明OPPO Connect产品关系，不证明anDrop或仅联系人分享页行为。Mac已有O+Connect16.2.20，只看应用元数据，未读／复用凭据。

当时host广播8881/GATT9999，engine扫3333/3334并用9897/9898等协商，无OPPO登录/身份交换/Pantaconnect常驻实现。当时Trusted Devices Only基于CoreBluetooth ID的本地接收筛选，不会向手机登记Mac为账号设备；后来发送者ID修正也不等于OPPO账号关系。Apple公开 [startAdvertising](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:))仅规定local-name/service-UUID键，不能直接追加任意Android广播。扫描与合适的GATT客户端仍是不同方向，不应过早断言需外接无线设备。

## 可行性与下一步

| 方案 | 判断 |
| --- | --- |
| 改名／加同名联系人／本地信任 | 不提供所需号码／账号身份 |
| 只加is_same_account | 可能影响某条显示路径，不足证明所有权或仅联系人运行 |
| 重现Android常驻发现 | 还需包处理/GUK，现有代码不足直接移植 |
| 官方Apple账号／发现路线 | 最相关研究方向，Mac资格、账号配置和后续传输待证 |
| 官方OPPO Connect | 有官方同账号自动连接，是另一产品流程 |

个人设备产品目标为首次所有权／账号设置一次，随后正常Finder分享，无每次手动连接；尚未实现，也不声称可无账号做到。下一最小证明应使用本人设备建立Apple路线账号／发现交换，再分别验证：手机保持仅联系人且公开超时后仍被发现、OPPO自身识别Mac为同账号而非复制标志、双向传输及内容一致、重启/蓝牙轮换/锁屏解锁后保持。不能因名字、短hash、peer布尔值取消确认或称认证成功；本调查未改产品行为。

## 本地分析定位

以下只作匹配私有APK的符号指针，不分发厂商源码：

| 发现 | 包内符号 |
| --- | --- |
| 电话号码匹配 | OShare `com.oplus.oshare.utils.p.g/h`, `d0` |
| 账号标识转换 | OShare `com.oplus.oshare.utils.AccountManger.S/y` |
| 上下文服务边界 | OShare `com.oplus.oshare.utils.DcpManager.e/G/k/s` |
| 传输时账号比较 | OShare `com.oplus.oshare.ble.impl.j`, `w`; `r9.b/g` |
| Apple UI元数据 | OShare `w9.b.b` |
| 设备支持说明 | OShare resources `feature_support_coloros_same_account_device_new`, `feature_support_oppo_link_latest_same_account` |
| 发现资格 | AccessoryFramework `com.oplus.pantaconnect.dcp.subscribe.a` |
| 加密发现与账号关系 | AccessoryFramework `com.oplus.pantaconnect.alwaysonservice.b.h`, `account.a.e`, `account.f.e` |
| 加密依赖 | AccessoryFramework `se.f`, `com.oplus.ndsf.client.g.p/d/f` |
| Apple发现构造 | AccessoryFramework `com.oplus.pantaconnect.beacon.usecase.f.b/c` |
