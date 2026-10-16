# Compatibility / 兼容性

Last physical-device test: **2026-10-16**. Validation status belongs in this repository, not in device-brand restrictions in the app UI.

| Device or feature | Status | Evidence / limitation |
| --- | --- | --- |
| OPPO Find X9 Pro, Chinese ColorOS 17 / Android 17, 互传 17.2.36 | **Physically tested / 已实机验证** | Same-Wi-Fi file transfer in both directions; matching hashes |
| Other OPPO models | **Untested / 未验证** | No compatibility guarantee from the tested model |
| Xiaomi / 小米 | **Untested / 未验证** | Compatible 互传联盟 devices are a target |
| HONOR / 荣耀 | **Untested / 未验证** | Compatible 互传联盟 devices are a target |
| vivo | **Untested / 未验证** | Compatible 互传联盟 devices are a target |
| Other participating brands | **Untested / 未验证** | Model, region and software version may matter |
| Apple Silicon Mac, macOS 27.0.1 | **Tested / 已验证** | Native host, Python engine, Finder extension |
| Intel Mac / earlier macOS | **Untested / 未验证** | Declared app minimum is macOS 14; not a tested support range |
| Petal Interconnect running concurrently | **Experimental / 实验性** | Successful transfers, but recurrent discovery conflicts |
| Notification Center action buttons | **Not physically verified / 尚未实测** | Implemented; incoming files were accepted through the app during tests |
| Open at Login after reboot | **Untested / 未验证** | Implemented; reboot not tested |
| Wi-Fi Direct | **Not implemented / 未实现** | Both devices must already share a local network |
| Google Quick Share / Huawei Share | **Not implemented / 未实现** | Different sharing systems |
| HarmonyOS devices | **Untested / 未验证** | No claim of support |

The [official HONOR guide](https://www.honor.com/cn/support/content/zh-cn15883773/) documents cross-brand 互传联盟 sharing. It does not validate anDrop on those devices.

For a new compatibility report, include only device model, OS/share-service versions, direction, general network setup and outcome. Remove serial numbers, personal device names, account identifiers, IP addresses and filenames from logs or screenshots.

## Manufacturer and model metadata

A follow-up read-only investigation confirmed passive OPPO brand identification from the test phone's Bluetooth advertisement. Exact model information was not obtained through the examined wireless sharing path. See [the device-identification report](device-identification.md); this is separate from cross-brand transfer compatibility.
