# Compatibility

[简体中文](compatibility.md) · English

Compatibility update: **2026-10-17**. Coverage includes recorded tests and the developer’s confirmation of broader testing on both OPPO devices. Validation status belongs in this repository, not in device-brand restrictions in the app UI.

Official Huawei Share support is the headline feature of the 1.2.0 release. Model coverage and transfer limits describe the scope of this support. 鸿蒙星河互联 coexistence remains experimental.

| Device or feature | Status | Evidence / limitation |
| --- | --- | --- |
| OPPO Find X9 Pro, Chinese ColorOS 17 / Android 17, 互传 17.2.36 | **Physically tested** | Multiple physical test scenarios, including same-Wi-Fi transfers in both directions; matching hashes |
| OPPO Pad 4 Pro | **Physically tested in both directions** | Multiple physical test scenarios, including discovery, tablet identification and same-Wi-Fi transfers in both directions; model and broader coverage confirmed by the developer on 2026-10-17 |
| Other OPPO models | **Untested** | No compatibility guarantee from the tested model |
| Xiaomi / 小米 | **Untested** | Compatible 互传联盟 devices are a target |
| HONOR / 荣耀 | **Untested** | Compatible 互传联盟 devices are a target |
| vivo | **Untested** | Compatible 互传联盟 devices are a target |
| Other participating brands | **Untested** | Model, region and software version may matter |
| Apple Silicon Mac, macOS 27.0.1 | **Tested** | Native host, Python engine, Finder extension |
| Intel Mac / earlier macOS | **Untested** | 1.2.0 targets macOS 14 with bundled-binary checks; no physical older-OS validation. Published DMG is arm64 only |
| 鸿蒙星河互联 running concurrently | **Experimental** | Quit 鸿蒙星河互联 after finishing its transfers and use anDrop for Huawei Share file sharing. Discovery or transfer conflicts may occur while both apps run. |
| Notification Center action buttons | **Not physically verified** | Implemented; incoming files were accepted through the app during tests |
| Open at Login after reboot | **Untested** | Implemented; reboot not tested |
| Wi-Fi Direct | **Not implemented** | Both devices must already share a local network |
| Google Quick Share | **Not implemented** | Different sharing system |
| Huawei Share | **Official support in 1.2.0** | Same-LAN transfers in both directions verified on Huawei Pura 70 running HarmonyOS 7, including empty files, Japanese filenames and 8 MiB files with content verification. See [testing](testing.en.md) for subsequent fixes and current limits. |
| Other Huawei / HarmonyOS models | **Untested** | Official protocol support does not establish physical compatibility with every model or OS version |

The [official HONOR guide](https://www.honor.com/cn/support/content/zh-cn15883773/) documents cross-brand 互传联盟 sharing. It does not validate anDrop on those devices.

For a new compatibility report, include only device model, OS/share-service versions, direction, general network setup and outcome. Remove serial numbers, personal device names, account identifiers, IP addresses and filenames from logs or screenshots.

## Manufacturer and model metadata

A follow-up read-only investigation confirmed passive OPPO brand identification and distinguished a phone and tablet sharing the same account name. Exact model information was not obtained through the examined wireless sharing path. See [the device-identification report](device-identification.en.md); this is separate from cross-brand transfer compatibility.
