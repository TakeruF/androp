# 兼容性

简体中文 · [English](compatibility.en.md)

更新：2026-10-17。包括已记录试验与开发者对两台OPPO更广测试的确认。验证状态记录在仓库，不作为应用UI的品牌限制。1.2.0主打正式Huawei Share支持，机型／限额界定范围，鸿蒙星河互联共存仍实验性。

| 设备／功能 | 状态 | 证据／限制 |
| --- | --- | --- |
| OPPO Find X9 Pro，中国ColorOS17/Android17，互传17.2.36 | 已实机验证 | 多场景含同Wi-Fi双向、散列一致 |
| OPPO Pad 4 Pro | 已实机验证双向 | 发现、平板类型及同Wi-Fi双向；型号与广度由开发者2026-10-17确认 |
| 其他OPPO | 未验证 | 不能从已测机型保证 |
| 小米 | 未验证 | 兼容互传联盟设备为目标 |
| 荣耀 | 未验证 | 同上 |
| vivo | 未验证 | 同上 |
| 其他参与品牌 | 未验证 | 型号／地区／软件可能影响 |
| Apple Silicon Mac/macOS27.0.1 | 已验证 | host、Python engine、Finder扩展 |
| Intel／更早macOS | 未验证 | 1.2.0目标14且检查同捆库，无旧OS实机，DMG仅arm64 |
| 与鸿蒙星河互联同时运行 | 实验性 | 完成鸿蒙星河互联传输后退出、用anDrop替代分享，可能发现／传输冲突 |
| 通知中心动作按钮 | 尚未实测 | 已实现；实测通过应用内批准 |
| 重启后登录启动 | 未验证 | 已实现，未重启测试 |
| Wi-Fi Direct | 未实现 | 两端已处同LAN |
| Google Quick Share | 未实现 | 不同体系 |
| Huawei Share | 1.2.0正式支持 | Pura70/HarmonyOS7同LAN双向、空／日文名／8 MiB与内容验证；后续修复限额见[测试](testing.md) |
| 其他Huawei/HarmonyOS | 未验证 | 协议支持不代表全部机型／OS实测 |

[荣耀官方介绍](https://www.honor.com/cn/support/content/zh-cn15883773/)描述跨品牌互传联盟，不验证anDrop。新报告仅含型号/系统与分享服务版本/方向/一般网络/结果，去序列号、私名、账号、IP、文件名。

## 厂商与型号元数据

只读调查确认被动识别OPPO并区分同账号名手机／平板，未通过无线分享取得精确型号。见[设备识别](device-identification.md)，与跨品牌传输兼容是不同证据。
