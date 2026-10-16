# Validation record

Recorded on 2026-10-16. This is a summary of observed tests, not a certification or a claim that all file sizes, devices or network configurations work.

## Physical-device results

Environment: Apple Silicon Mac on macOS 27.0.1 and OPPO Find X9 Pro on Chinese ColorOS 17 / Android 17, sharing service 17.2.36. Both devices used the same Wi-Fi. No vendor desktop preconnection was needed. USB/ADB assisted test setup and inspection; file transfer used Bluetooth negotiation and the local network. The diagnostic phone app was removed before final validation.

| Direction | Test | Result |
| --- | --- | --- |
| Finder → anDrop → phone | 8 MiB binary, empty file, 49-byte file with a Japanese filename in one transfer | All three received; SHA-256 matched |
| Phone's built-in 互传 → Mac | 8 MiB binary | Received directly in Downloads; SHA-256 matched |
| Phone → Mac with an existing same-named file | Name collision | Existing file preserved; new file received with numeric suffix |
| Mac received file | Quarantine metadata | Attribute present |
| UI | English and Simplified Chinese settings, Finder share entry | Visually checked |
| Petal concurrent operation | Both directions | Succeeded in some runs; discovery failed again in later runs |

Tests checked that the nearby name obeys the byte limit and transfer confirmation uses the full Computer Name. Actual personal device names and local file paths are intentionally not recorded here.

## Automated tests

```sh
.venv/bin/python -m unittest discover -s tests -v
swift test
```

Forty-six Python tests and ten Swift tests passed for version 0.1.1 (build 7). They cover:

- Key exchange, encryption round trip and protocol parsing.
- Japanese filenames, empty files and collision handling.
- Rejection of traversal, absolute paths and symlinks.
- Declared-size mismatch without saved output.
- Transient local-route recovery, including aiohttp-wrapped errors.
- Bounded retry for persistent route failure and transient initial receive resets/refusals.
- TLS/HTTP rejection without retry, active receiver protection from the offer timer, and safe localized error messages.
- Permission errors and cancellation without retry.
- Same-account phone/tablet metadata and separate recipients.
- Unknown/conflicting metadata and future-version fallback.
- Bluetooth endpoint rotation while retaining one protocol recipient and the latest connection route.
- Alias persistence by device identity, same-name disambiguation and the 40-character Unicode limit.
- Discovery expiry at the ten-second boundary, removal of cached connection routes, and rejection of stale sends.
- Scanner startup/runtime failure, late callbacks, partial packets, sender-only advertisements and endpoint rotation.
- Closing the chooser during file preparation without losing the already-selected route.
- ZIP response byte counts including empty payloads, failed writes and cancellation.
- Correlated send rejection without replacing another active transfer.
- Progress range limits, indeterminate phases and the distinction between all bytes sent and receiver-confirmed completion in English and Chinese.

## Repository packaging verification

After moving the source into this repository, all nine automated tests passed and a full arm64 ad-hoc build passed deep/strict signature verification. The resulting bundle contains LICENSE, NOTICE and dependency notices and uses a neutral default bundle identifier. Physical-device transfers above predate these packaging and About-dialog changes; they were not repeated for this import.

## Recipient discovery follow-up

The phone and a second OPPO device advertising the tablet flag were visible simultaneously with the same account name. Their brand/type flags and separate protocol IDs were observed without a preconnection. Bluetooth endpoint IDs changed during testing; protocol IDs remained stable within the observation. The tablet's model was not established. File transfer was not tested during this discovery probe; a later tablet-to-Mac result is recorded below.

The first native chooser revision was opened through Finder Share and showed the phone and tablet as distinct entries. A temporary tablet alias changed only that entry. The final version uses an official brand logo in a circle, phone/tablet badge and sharing name, with the same identity and alias handling.

The final chooser was visually checked through Finder Share in English and Simplified Chinese with two real recipients. Official OPPO artwork and the SF Symbols phone/landscape-tablet badges rendered correctly. The tablet alias persisted through restart without appearing on the phone, then was cleared. All ten bundled images loaded through AppKit and matched their manifest hashes. The full and subsequent UI builds passed deep/strict signature verification. No file-transfer request was sent during these UI checks.

## Recipient expiry follow-up

A phone and tablet were observed through live advertisements. During a user-operated visibility-off test on the phone, new phone advertisements stopped; none arrived for the remaining approximately 55 seconds of that observation. This was a radio observation, not a timestamped measurement of the native UI switch. The ten-second expiry and error paths were checked separately by automated tests. A natural ten-minute timeout was not timed in this run.

The installed build was opened from Finder Share after the visibility-off test. Discovery updates continued normally with zero recipients and no scan error; the stopped recipients did not reappear. The full signed build passed deep/strict signature verification. No file was sent in this follow-up.

The macOS scanner adapter explicitly requests repeat advertisement delivery while the chooser is open. It uses a custom Bleak backend with the pinned 3.0.2 implementation; dependency upgrades must recheck this adapter. It does not connect to a device just to keep its row alive. The UI additionally expires a silent discovery stream and clears on Bluetooth-off, engine restart and chooser closure.

## Outgoing progress follow-up

A 64 MiB test file was sent to the OPPO phone through Finder Share with build 5. The native app received outgoing byte updates at 0%, approximately 4%, 23%, 40%, 60% and 84%, followed by the full 67,109,030-byte ZIP response. It then entered Finishing and received the peer's completion acknowledgement. The file payload was 67,108,864 bytes; the difference is ZIP overhead. The final native window showed a full blue ring and Sent. A receiver-side file hash was not checked in this run because ADB was disconnected.

An earlier attempt timed out waiting for acceptance and showed the failure state. A separate native preview with synthetic data verified the final 37% ring, readable logo, device badge and English percentage label; that preview is not an additional real transfer measurement. Automated tests cover phase labels in English and Chinese.

The final full build and UI refinement passed deep/strict signature verification. The percentage is based on response bytes written by the Mac; receiver storage completion is reported separately after its protocol acknowledgement. Reopening progress through the menu bar is implemented but was not exercised during this short real transfer. The temporary test file remains on the receiving phone.

## Remaining validation

Other brands/models, Intel, older macOS, reboot/login, prolonged sleep/wake use, large files, full-disk conditions, interrupted real-device transfers and Notification Center action buttons need additional testing. The automated tests do not replace those checks.

Petal repair remains best effort. Repeated tests disproved the assumption that starting anDrop first always solves the advertisement conflict. See [usage](usage.md).

## Test cleanup

After the earlier file-transfer tests, temporary phone-wide discoverability was restored to the contacts/own-devices setting. The testing-only screen-awake setting was reset, the diagnostic app was uninstalled, and generated phone fixtures were removed. Raw logs, screenshots and protocol captures are not committed.

For the recipient follow-up, the user manually enabled temporary visibility on both devices. No permanent visibility, screen-awake or phone-app setting was changed by this follow-up.

## Titleless popup follow-up (build 6)

The UI-only build passed compilation and deep/strict signature verification. Native previews using the same AppModel and RecipientPanel checked title-bar removal, rounded corners and the original window background color. With a synthetic sending state, focusing an outside window and closing that window revealed the still-open progress popup. With a synthetic successful state, the same focus change dismissed the popup; closing the outside window left no recipient popup. The preview used no Bluetooth or file transfer. The earlier build-5 physical-device transfer result is unchanged; no new file transfer was performed for this UI-only change.

## Tablet receive recovery (build 7)

The user reported a failed tablet-to-Mac receive: the Mac had a connection-reset error before receiving file data, while the tablet displayed a recipient-rejected message. The original reset's precise cause was not established.

Build 7 adds a bounded retry only while establishing the initial WebSocket, before transfer metadata or file bytes are exchanged. Retryable startup errors include temporary route unavailability, connection reset, refusal and abort. The whole connection retry window is at most ten seconds with up to four attempts; TLS/certificate failures, HTTP rejection, permission failure and cancellation are not retried. There is no TLS downgrade or replay of partial downloads. The earlier fifteen-second offer timer now expires only before a receive task starts, avoiding cancellation of an already-active connection attempt. The timer flaw was verified by tests, not identified as the definitive cause of the user's original reset.

In a subsequent physical tablet-to-Mac test, the first connection attempt encountered the macOS host-unreachable error. Attempt two connected, and one 83,249-byte file completed download, saving and the completion exchange. The user confirmed success; local checks confirmed one saved file of that size directly in Downloads. A sender-side hash comparison was not performed. This demonstrates recovery in that attempt, not a guarantee that every connection reset is recoverable.

Notifications now use localized, actionable messages for transfer errors rather than raw exception strings containing endpoints, object addresses or filenames. Local diagnostic summaries record phase, error class, numeric error code and attempt number; raw captures are excluded from the repository.

## Inline rename control (build 8)

A native preview with the same recipient grid verified the SF Symbols pencil beside a short name and a two-line name. Clicking the tablet pencil opened that device's name editor without starting a transfer; the editor was cancelled. The UI-only build passed compilation and deep/strict signature verification. No additional physical transfer was performed for this layout change.

## Adaptive recipient layout (build 9)

A native preview using the production views checked a one-line “Example” label, centered independently of the pencil; compact one-row height; and the compact name-edit sheet. A 40-device fixture scrolled to the final recipients while retaining the fixed header and footer. Ten bundled manufacturer logos were also displayed with phone/tablet badges. Fixtures used synthetic peers and no Bluetooth or file transfer. The UI build passed compilation and deep/strict signature verification.

## Receive scope, Control Center and identity history update

- Python suite: 51 tests pass, including rejection before key exchange for unlisted devices, mandatory approval for listed devices, revocation while approval is pending, and name-independent filtering.
- Swift identity/progress suite: 10 tests pass.
- Native model smoke checks ran in a fresh UUID-named UserDefaults test suite, without modifying the installed app’s settings. Offline history candidates, same-name device separation, Add/Remove/Forget, persisted trust, running=receiving, endpoint metadata, and the one-time legacy-history cleanup passed.
- The installed build’s deep strict signature check passed. The one-time removal of history records without endpoint identifiers was independently read back by count; identified history was retained.
- macOS registered the control extension. A user confirmed gallery visibility and the initial control-to-file-picker invocation during development. At that development stage, one Receive control opened the host-owned receive-scope panel. This integration was subsequently removed in build 36; its UI is preserved in the standalone prototype.
- Production UI renders with fictional data cover English/Chinese receive scope and trusted-device history. Manufacturer artwork and phone/tablet badges are reused from the recipient chooser; OPPO/vivo use white logos on green/blue, and Xiaomi retains official orange artwork.
- These checks do not establish physical-device coverage for other manufacturers or cryptographic peer authentication.


## Historical GATT trust-boundary follow-up (superseded by sender-ID verification)

- Python suite: **54 tests pass**, including no ready notification for an unlisted
  or missing central, disabled-receiver subscription rejection, and a transfer
  already accepted before trust removal retaining its control channel.
- Swift suite: **13 tests pass**. New production-policy tests cover unknown,
  trusted, malformed and unavailable-receiver cases, case-insensitive UUIDs and
  the accepted-session exemption. A completed session grants no exemption for
  a new offer.
- Pending confirmation is excluded from the accepted-session exemption; existing
  revocation-before-acceptance tests continue to pass.
- GATT read/write/notification callbacks now apply that policy. Unit tests do
  not establish physical-device compatibility of the changed ATT responses.
- Read-only analysis of OShare `17.2.36` established that its `8881` discovery
  path adds a candidate directly from advertising data before any GATT read.
  These changes therefore do **not** implement selective visibility. See the
  [investigation and remaining limitation](trusted-discovery.md).

## Control Center removal and single Cancel action (build 36)

- The installed app contains only the Finder Share extension. The old WidgetKit extension was unregistered and its existing anDrop tile removed. The host has no control-state App Group entitlement or App Intents metadata. The signed bundle passed deep/strict verification.
- The compact receive panel is preserved outside the production build in `Prototypes/ReceivePanel`, with English/Chinese fictional captures and an independent interactive preview. Native preview checks verified scope selection, the switch disabling scope rows, Escape dismissal and the titleless system-glass wrapper. No production preferences or device trust records were changed by the preview.
- The recipient popup now has one footer action: Cancel closes an unsent picker, targets the active transfer while preparing/waiting/connecting/sending/confirming, and becomes Done after a terminal result. Escape uses the same action. Outside clicks during sending still allow background transfer.
- A disposable native-model check exercised the production cancel action with a local JSON-lines sink and no transfer engine: unsent closure, cancellation of the correct ID in all five active phases, and closure after a cancelled result passed.
- Existing Python tests: **54 passed**. Swift identity/progress/policy tests: **15 passed**. The English and Chinese sending screenshots were regenerated from production views with mock data and show one Cancel button.
- This UI/integration update did not repeat a physical-device file transfer.

## Version 1.0.0 release preparation

- The full app was rebuilt with the official Python 3.14.7 macOS runtime and pinned binary wheels. All **80 bundled Mach-O files** passed an arm64/macOS 14.0 deployment-target check; no load commands referred to the development machine’s library paths. This does not establish execution on physical macOS 14 hardware.
- The signed hardened-runtime engine started with Python/DYLD environment overrides removed, emitted ready and exited normally with no stderr output. No file transfer or Bluetooth scan was started by this engine smoke check.
- **54 Python tests and 15 Swift tests passed.** The future App Store build switch was separately typechecked without importing Sparkle; this is not store validation.
- A separate UUID-identified fixture compiled the production AppUpdates implementation and embedded Sparkle 2.10.0. It used a loopback-only HTTP feed, synthetic UI and a signed 1.0.0 DMG; it had no transfer engine or Bluetooth advertising. From 0.9.9, automatic checking/download produced the Chinese ready dialog, Later retained the old version, a simulated active transfer disabled installation, and Restart and Update installed and relaunched **1.0.0**. A manual check then displayed Sparkle’s Chinese up-to-date dialog.
- Disabling automatic checks/downloads was reflected in the UI, independently read back from that disposable fixture’s persistent preferences and retained after a cold relaunch. The fixture did not change the installed anDrop preferences.
- Both the signed feed and update archive were verified. Appending bytes to the test archive caused signature verification to fail, using both Sparkle’s tool and an independent verification with the embedded public Ed25519 key. Private signing keys were not exported.
- Frozen Python archives contained **479 code filenames**, none absolute; no project-owner name, private home path or signing-team identifier was found in their inspected string constants. The Git history and intended source changes were also screened for those private values. This is a focused publication check, not a claim that arbitrary data can be automatically anonymized.
- Chinese and English documentation captures were regenerated from production views with fictional data. The mock Settings viewport is expanded to show the update controls and license/repository links. Normal Settings remains scrollable.
- No additional physical-device transfer was performed for the updater/packaging change. Earlier physical test results above remain scoped to their recorded builds.

The minimum-OS check was also exercised with an actual macOS 26-only binary and correctly rejected it when macOS 14 was declared.

The 1.0.0 application subsequently passed Apple notarization. The exported application’s stapled ticket validated, deep/strict code-signature verification succeeded, and Gatekeeper reported `source=Notarized Developer ID`. The Developer ID-signed DMG mounted read-only, its checksums matched, and all **251 file/link entries** matched the notarized export. Installation from that DMG retained preferences/history and matched the same manifest. The installed Chinese Settings view showed 1.0.0, both update settings enabled, and the license/repository links. Host and bundled engine processes remained running.

Published on 2026-10-17 as [v1.0.0](https://github.com/TakeruF/cn-android-share/releases/tag/v1.0.0). All three assets were downloaded again without GitHub authentication and matched the local release artifacts. Their SHA-256 checksums and the Ed25519 signatures of both appcast and DMG verified independently with the embedded public key. The installed production app read that public feed and displayed Sparkle’s Chinese confirmation that 1.0.0 was current. With Petal stopped, the installed host reported accessory activation policy (Dock hidden). macOS 14 physical-device testing remains outstanding.


## 1.0.1 连接与受信任设备修复（2026-10-17）

### 修复内容

- **受信任设备误拒绝**：实机连续接收时，同一手机出现了 5 个不同的 CoreBluetooth central UUID，但协议 `senderId` 保持一致。发送时使用的 peripheral UUID 也不能直接作为接收身份。现在先完成必要的控制连接，再检查发送端协议标识的 SHA-256；只有通过接收范围检查后，才显示接收确认并下载文件。不会根据同名、账号名称、IP 地址或机型自动信任设备。
- **多网络环境**：从已启用的局域网接口选择地址，优先选择与对端同网段的接口；忽略 VPN 默认路由、未启用接口和标记为 inactive 的接口。Darwin 的接口绑定只作用于本次传输的套接字，不修改系统路由或 VPN 设置。对端明确拒绝某个地址时，可尝试其他局域网地址。
- **互联连接复用**：允许使用协议提供的可达 IP/端口，包括带有直连信息的端点；复用地址只取自同一次蓝牙协商。不会仅因消息含有 SSID 就立即判定失败。无法从 Mac 访问的厂商私有直连网络仍不能凭空连通，也不会自动切换用户的 Wi-Fi。
- **时序与速度测量**：蓝牙确认和 TLS 连接不再要求固定先后顺序，两者的对端地址匹配后才提供下载。UDP 速度测量失败不再直接终止已建立的控制连接；接收端如实返回测量值 0，由协议继续协商。
- **错误提示**：局域网权限、VPN 路由、其他互联连接和网络隔离均可能影响传输，不再把所有连接问题归因于“未连接同一 Wi-Fi”。

### 自动化验证

**90 项 Python 测试、16 项 Swift 测试通过。** TLS/WebSocket/HTTP 集成测试实际建立本机加密连接，仅替代蓝牙传输层。

| 场景 | 结果 |
| --- | --- |
| 蓝牙确认先于／晚于 TLS 建连 | 均成功，文件内容一致 |
| 确认地址与实际连接来源不符 | 不提供下载 |
| 多局域网地址，首个地址被明确拒绝 | 尝试下一个地址并成功 |
| VPN 接口、inactive 接口、错误地址／端口 | 正确排除或拒绝 |
| UDP 探测无回应／发送失败，控制连接正常 | 不因探测失败直接中断 |
| 同名未信任发送端、缺少标识、协议标识变化 | 不下载文件 |
| 接收确认打开后移除信任或关闭接收 | 不下载文件 |
| 用户拒绝、错误文件数量 | 不下载文件 |
| 中途取消下载 | 清理临时文件，不留下部分接收文件 |
| 多文件、中文／日文文件名、空文件、8 MiB 二进制文件 | 内容与原文件一致 |
| 连续交替允许／拒绝 | 不沿用上一次会话的授权 |

### 实机验证

使用开发诊断宿主运行相同生产传输代码，仅为合成测试文件自动回复接收确认。调试入口、原始日志、真实设备标识及个人文件均不包含在生产应用和公开仓库中。

| 场景 | 观察结果 |
| --- | --- |
| OPPO 互联连接平板时，手机 → Mac | 成功，内容一致 |
| OPPO 互联连接手机时，手机 → Mac | 成功，含 8 MiB 文件 SHA-256 校验 |
| OPPO 互联连接手机时，Mac → 手机 | 成功；从手机实际保存位置读取 8 MiB 文件并校验 SHA-256 |
| 同一手机使用新蓝牙 UUID，再次以受信任设备接收 | 成功 |
| 将实机排除出信任名单 | 拒绝，未显示接收确认／未下载 |
| “所有人”下手动拒绝的等价确认操作 | 正确拒绝 |
| 日文文件名 | 接收成功，内容一致 |
| “仅限受信任的设备”与“所有人”交替 6 次 | 全部接收成功，内容一致 |
| 手机单独发送 0 字节文件 | OPPO 系统互传在发起连接前提示“无法发送大小为零的文件”；没有进入 anDrop 接收流程 |

最初两次 Mac → 手机测试未及时操作手机上的悬浮接收按钮，因而超时；操作该按钮后完成了上述传输。这些超时不计为成功测试。空文件的真实手机发送能力也不计为通过。

### 验证边界与升级说明

- 观察到了蓝牙标识变化，可解释旧版的受信任设备误拒绝。原报告的“互联后必定无法传输”未能在所有连接状态下稳定重现；修复版在上述已连接状态下通过，但不能据此保证所有厂商和网络组合。
- 新信任记录依赖对端自报的协议标识，**不是密码学配对或身份认证**，不能防止知道该标识的设备冒充。始终保留每次接收确认。见 [信任与发现机制](trusted-discovery.md)。
- 旧蓝牙 UUID 记录不会按名称自动迁移。需要在“所有人”下成功接收一次，再从历史添加。若切换账号或厂商重新生成协议标识，也需重新核实后添加。
- 其他品牌的实机、物理多网卡切换、厂商隔离直连网络、macOS 14 实机尚未验证。网络接口排序及明确拒绝后的重试有自动化覆盖，但不等于这些环境的实测。
- 最终安装阶段 Mac 自动锁定；未要求用户解锁。正式签名构建的启动和包验证与上述诊断构建的实机传输证明分别记录，不把启动成功当成一次新的端到端传输。


最终正式构建为 **1.0.1（10001）**，已安装到 `/Applications/anDrop.app`，通过 Developer ID 深度／严格签名校验。80 个 Mach-O 文件通过 arm64／最低 macOS 14 检查，未引用构建机库路径。另直接运行安装包内的生产引擎，完成 3 次真实 TLS/HTTP 场景：受信任接收、同名未信任拒绝、更换蓝牙 UUID 后再次接收；日文文件和空文件内容一致、拒绝场景无下载、没有 UDP 探测包时仍完成传输。引擎正常退出且无 stderr；之后正常宿主与引擎均成功启动，手机互传重新列出了 Mac。生产应用不包含诊断宿主的测试命令入口。此构建尚未作为新的 GitHub Release 发布或重新提交公证。


## 1.0.1（10002）：互联连接中的手机向 Mac 发送失败

2026-10-17 的后续用户试验再次复现了 **手机 → Mac** 失败。前一个构建的成功记录只覆盖当时的连接状态，并未解决此次发现的网络端点切换问题。

### 根因及修复

失败时，手机先通过蓝牙提供 WLAN 地址和端口；该监听端点随后关闭，手机又在同一次协商中提供热点信息及新的端口。旧代码只处理第一条网络消息，后续消息因已有接收任务而被忽略，于是不断连接已经失效的端口，最终报告 `ECONNREFUSED`（macOS errno 61）。这不是“用户必然没有开启局域网权限”的证据。

现在在 TLS 控制连接建立之前接收端点更新：取消旧的建连尝试，保留当前协议会话、信任检查和接收确认流程。对于同一蓝牙会话提供的新热点端口，可使用该会话已经提供、且位于直连局域网内的手机 WLAN 地址访问；不扫描网络、不使用其他设备的历史地址，也不切换 Mac 的 Wi-Fi。

TLS 控制连接一旦建立，就不再允许后续消息改换端点。重复端点不会重启连接，端点变更次数有上限；用户取消与端点替换同时发生时，取消优先，不启动新的接收尝试。另修复速度测量 UDP 端口被占用时错误终止整个接收的问题：此时继续尝试 TLS，并报告实际测量值 0。

### 回归验证

- **99 项 Python 测试、16 项 Swift 测试通过**，其中新增实际 TLS/HTTP 集成场景：旧端口拒绝连接 → 收到新热点端口 → 经同一会话的 LAN 地址接收成功；相同切换流程中的未信任发送者仍被拒绝，未发起下载。
- 验证了已建立连接不可改换、重复通知不重启、过期会话不能建连、变更次数受限、切换过程中取消、接收任务尚未开始时取消，以及 UDP 端口被占用后的正常下载。
- 实机在 OPPO Connect 连接手机时复现了旧构建的交替成功／失败；修复后，同样的“旧 WLAN 端点关闭后通知新端口”流程出现 `receive_endpoint_replaced`，随后完成接收并通过内容校验。没有为了每次试验强行停止手机互传进程或断开 OPPO Connect。
- 初版自动操作脚本在“发送完成”的卡片上再次点击时，有两次未实际发起传输；这两次不计为成功，也不计为网络修复失败。后续脚本改为退出分享页面再重新打开，保留互传进程和互联连接。

此修复处理的是同一协议会话中的端点更新，不保证所有厂商的热点服务均能通过 WLAN 访问。仍只宣称已记录的实机与模拟协议覆盖。

正式生产构建 **1.0.1（10002）** 已安装并启动。在 OPPO Connect 保持手机已连接的状态下，通过正常应用的接收确认完成了手机 → Mac 的 **8 MiB** 传输，历史状态为完成，保存文件的 SHA-256 与源文件一致。生产包通过 Developer ID 深度／严格签名验证；80 个 Mach-O 文件通过 arm64／最低 macOS 14 检查，未引用构建机库路径。此构建尚未发布为新的 GitHub Release，也未重新提交公证。

## 1.0.1（10003）：Finder 共享窗口的焦点交接

Finder 共享扩展原先先打开 anDrop，再结束扩展请求。共享面板关闭时，宿主应用可能重新获得焦点，遮住刚打开的接收设备窗口，让用户感觉窗口一闪即逝。现在先完成扩展请求，再在完成回调中打开 anDrop；没有使用定时抢回焦点或将窗口始终置顶的方式。

安装正式签名构建后，使用合成文本文件从 Finder 的共享菜单验证了：应用已运行时打开、取消后再次共享、应用退出后由共享扩展启动。三次均显示正确文件和接收设备列表，窗口保持可操作。此次验证针对共享入口与窗口交接，没有发送用户文件，也不计为新的端到端文件传输测试。编译、严格签名校验和 80 个 Mach-O 的 macOS 14／arm64 检查通过。

回调遵循 Apple 的 [completeRequest(returningItems:completionHandler:) 文档](https://developer.apple.com/documentation/foundation/nsextensioncontext/completerequest(returningitems:completionhandler:))，在扩展完成请求后交接；过期回调不会再次打开应用。
