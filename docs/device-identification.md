# 设备厂商与型号识别

简体中文 · [English](device-identification.en.md)

调查：2026-10-16，已有OPPO Find X9 Pro，中国ColorOS17/Android17、分享服务17.2.36；后续被动试验含同分享／账号名的OPPO平板。0.1.1已将观测品牌与大类用于候选UI。

| 信息 | 结果 | 限制 |
| --- | --- | --- |
| 分享显示名 | BLE Service Data3334可得 | 用户／账号标签，不证明型号或真实身份 |
| 品牌 | 连接前从3333 flags识别OPPO | 自报协议元数据，不是认证硬件身份 |
| 手机／平板 | 同时被动发现可区分 | 大类，不是具体产品型号 |
| 具体型号 | 此无线分享路径未取得 | 广播／状态响应无型号字段 |
| USB/ADB型号 | 可作本地诊断基准 | 不是正常无需连接发现方案 |

只读探针以已知显示名选设备，报告去掉名字和地址，不改设置、不发传输请求。3333为22 B、receiver role、format11、flags9 (`0x09`)，3334为不公开名字，无manufacturer-specific广告。此格式bit0x08为OPPO、0x10为realme、0x02为tablet，0x09仅OPPO位；另一轮无连接扫描重现，既有USB厂商字段亦一致。这是该格式发现，不保证其他品牌／未来版本通用。

临时BLE连接枚举并读9897，仅有key/pv/state/version，无型号／厂商，公钥不保留。标准180A、2A29、2A24均未出现，属于可选[Device Information Service](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/DIS_v1.2/out/en/index-en.html)。USB基准型号PLG110未在无线数据出现；不能凭知道测试机型号就给任意附近设备贴该型号。

## 同账号名的两个设备

后续同时观察phone flags9和tablet11 (`0x0B`)，同分享名、不同协议ID，均无local/peripheral name，未取得平板具体型号。macOS endpoint在观测期间改变而协议ID保持，旧按endpoint保留会短暂重复。0.1.1以已识别format11、非零12位hex ID聚合，重发现更新endpoint；不同ID即使同名也独立。仅证明此次稳定，不保证重置／账号／固件后终身稳定。

本地别名按该候选身份SHA256，未知格式退回endpoint。身份仅组织列表，不用来认证或跳过批准。

## 其他格式与产品含义

[CatShare发现实现](https://github.com/kmod-midori/CatShare/blob/067348d3d9207206e120b2afe2837c6101f73f41/app/src/main/java/moe/reimu/catshare/ShareActivity.kt)解另一种6 B记录，以service UUID带品牌码；[映射](https://github.com/kmod-midori/CatShare/blob/067348d3d9207206e120b2afe2837c6101f73f41/app/src/main/java/moe/reimu/catshare/utils/DeviceUtils.kt)含OPPO/realme/vivo/小米/OnePlus/魅族/Samsung/Lenovo，不含HONOR，未知应保留未知。这是参考，不是实机兼容性。本次手机使用3333/3334而非6 B格式，跨格式品牌位不可互换，一处品牌位在另一处可能是能力位。

UI使用圆形官方logo、phone/tablet角标、原分享名和可选Mac本地别名，无需预配对。未知／矛盾数据保留通用，不从名字或UUID猜。支持解析格式不等于所有厂商都实测。

精确型号需要支持协议显式字段、可选标准信息响应或独立验证机制。名字恰含产品名不可靠；其他vendor通道也许有更多信息，但尚未作为此应用传输前发现路径验证。不声称精确型号普遍不可能，只说明已查路径未提供。

不附厂商源码、真实名/地址/序列号/raw抓包；解析与身份测试用合成数据。
