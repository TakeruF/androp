# Android / OPPO 接收通知的文件类型声明

简体中文 · [English](android-file-type-research.en.md)

调查日期：2026-10-17 JST。对象为调查时的 anDrop 工作树及已有本地 OShare 反编译资料（记录版本17.2.36）。前半是修改前静态调查，后半记录实现与实机反馈。其他 Android 厂商显示尚未确认。

## 结论

**Mac→OPPO 可以声明类型，但批准前通知使用 BLE 初始请求中加密的 `type`。仅修改后续 WebSocket `sendRequest.mimeType` 无法修复初始通知。** 最初遗漏这一层，使 build11015 在用户 PDF 复测中显示未改善；后续 BLE 修正见末尾。

截图中的问号图标符合 `file/*` 回退未知图标的实现，但未捕获当次真实载荷，因此不能把该截图的具体原因视为独立实机定论。

## anDrop 与 OPPO 处理路径

修改前 `Sources/engine.py` 的 `Engine.send` 在 sendRequest 中发送fileName/fileCount/totalSize/mimeType，mimeType固定 `file/*`，先发原首文件名。下述确认卡路径不会从该名字自动补扩展名。HTTP `/download` 的 `Content-Type: application/zip` 描述传输封装，通知 MIME 描述内容；不能为图标将HTTP类型改图片／PDF。协商协议版本为1。

本地分析目录 `work/oshare-source/sources/`，厂商源码／APK未复制进本仓库。

| 步骤 | 符号与发现 |
| --- | --- |
| 请求解析 | `eb.d.i` 保留JSON mimeType，`f()`返回；另有thumbnail与尺寸字段 |
| LAN接收 | `fa.g.s0` 将sendRequest解析为eb.d |
| 确认卡 | `fa.g.E0/G0`→`ConfirmSeedlingCard.F0`→`C0`，传名字与MIME，不传显式扩展名／预览URI |
| 图标选择 | `ConfirmSeedlingCard.b.g`无URI时先显式扩展名，否则 `h0.a(mimeType)`，交 `FilePreviewSrcUtils.a` |
| 卡片更新 | startSeedling把 `b.g()`作为previewSrc |
| 媒体分类 | `h0.m/h/o`按image/audio/video前缀判断 |
| 文档／压缩 | MIME→扩展名表及扩展名→图标规则 |
| 回退 | `file/*`不匹配，进入 `images.preview_unknow` |

因此LAN路径仅把名字改.pdf不足，声明application/pdf才有意义；这不是批准前BLE路径的完整证据。

## 静态确认的声明与图标

| 内容 | MIME | 图标 |
| --- | --- | --- |
| JPEG / PNG | `image/jpeg` / `image/png` | 图片 |
| 视频 | `video/mp4` | 视频 |
| 音频 | `audio/mpeg` | 音频 |
| PDF | `application/pdf` | PDF |
| 文本 | `text/plain` | TXT |
| Word | `application/vnd.openxmlformats-officedocument.wordprocessingml.document` | Word |
| Excel | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` | Excel |
| PowerPoint | `application/vnd.openxmlformats-officedocument.presentationml.presentation` | PowerPoint |
| ZIP文件本身 | `application/zip` | ZIP |
| 未知／混合 | `file/*` | 未知 |

这些是静态选择结果，不是修改版实机显示证明。image/*也可进图片分类；把PDF等一律text/*会失去具体扩展映射。类型图标与照片缩略图不同，fa.g确认卡并未传preview URI，不能因有thumbnail字段便保证实图预览。version4以后另有image/*、video/*完全匹配和vision/*+number计数分支，不能假定version1媒体混合计数正确。旧Excel MIME `application/vnd.ms-excel`映射 `.xls`，图标却要 `xls`，可能无法专用显示，不以伪造MIME绕过。[Android官方分享文档](https://developer.android.com/develop/ui/compose/sharing/send)与OShare网络协议不同；此处结论来自实际OShare路径。

## 实现与验证范围

1. 单文件由扩展名或macOS类型得到真实MIME；同MIME批次用具体类型，同类图片／音频／视频用wildcard，异种／未知用file/*，不以首文件代表全批。
2. 保持ZIP封装、HTTP头、文件名、内容与批准流程。
3. 分别验证JPEG/PDF/TXT/ZIP/同类多件/混合、视频计数的请求值、批准前图标和文案、完成、保存位置与内容。

用户要求实现后，新增 `Sources/file_types.py` 并连接WebSocket mimeType；压缩文件不冒充内部类型。分类与TLS/WebSocket集成覆盖PDF/JPEG/多图片/混合、原名字/件数/大小、HTTP ZIP与解压全内容，202 Python通过。BLE peer是模拟，不证明OPPO显示或落盘。

完整本地1.1.1/build11015安装至 `/Applications/anDrop.app` 并重启，保留签名要求、ID、更新设置。旧11014备份 `build/android-mime-install/anDrop-before-install.app`。完整签名、macOS14运行库检查、冻结engine自检、安装模块PDF/混合分类、host/engine和发现／广告无错确认，记录 `build/android-mime-install/`，未公开发布。

## build11015 的遗漏与 build11016 实机反馈

用户报告PDF图标未变。安装／运行bundle确为11015，但BLE初始加密type仍file/*。OShare `com.oplus.oshare.ble.impl.w.e`先解type，经 `A()`→`B()`→`ConfirmSeedlingCard.C0`→`R0(..., false)`显示批准前卡，此时WebSocket未连接。原fa.g调查仅覆盖后续路径。

修复为只计算一次MIME，同值用于BLE加密type和WebSocket mimeType。集成测试解BLE请求，覆盖接收者拒绝、从未进入WebSocket时PDF类型也正确。完整build11016同ID/签名要求安装重启，旧版备份 `build/android-mime-fix/anDrop-before-install.app`。203 Python重跑全通过；首次无关Huawei广告测试把随机token内0xff误判为payload边界而失败，单独及全量复查通过，未改该测试。签名/运行库/engine自检/host engine启动通过。

Finder共享将合成PDF `androp-oppo-mime-check.pdf`（618 B）交安装版，选OPPO手机发送。2026-10-17 21:08:23 JST complete；用户确认显示改善。该结论基于用户观察，没有另做手机保存内容独立散列或其他格式实机显示验证。证据在 `build/android-mime-fix/`。
