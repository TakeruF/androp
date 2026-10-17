# 测试与验证记录

简体中文 · [English](testing.en.md)

最初记录于2026-10-16，后续条目保留各阶段构建与日期。仅总结已观察试验，不是认证或所有文件／设备／网络可用保证。历史UI与限额随后可能改变。

## 实机结果

Apple Silicon/macOS27.0.1、OPPO Find X9 Pro中国ColorOS17/Android17、互传17.2.36，同Wi-Fi，无厂商桌面预连接。USB/ADB协助准备／检查，传输走BLE协商和LAN，最终前已移除诊断手机app。

| 方向／项目 | 试验 | 结果 |
| --- | --- | --- |
| Finder→anDrop→手机 | 8 MiB、空、日文名49 B同批 | 三点接收／SHA256一致 |
| 手机原生互传→Mac | 8 MiB | 直接Downloads／SHA256一致 |
| 手机→Mac同名冲突 | 已有文件 | 保留原件、数字后缀 |
| Mac接收 | quarantine | 属性存在 |
| UI | 英中设置/Finder共享 | 目视确认 |
| 鸿蒙星河互联共存 | 双向 | 部分成功，后续发现又失败 |

附近名字节限额和确认完整Computer Name已查，不公开实际私名／路径。

## 自动化

```sh
.venv/bin/python -m unittest discover -s tests -v
swift test
```

0.1.1/build7为46 Python/10 Swift：密钥/加密/协议、日文/空/冲突、拒穿越/绝对路径/symlink、大小不符不输出、短暂路由及aiohttp错误、持续路由/初始reset/refusal有界重试、TLS/HTTP不重试、offer timer不取消活动接收、英中安全错误、权限/取消不重试、同名phone/tablet独立、未知/冲突/未来格式回退、endpoint轮换仍同候选且用最新route、别名/同名/40字符、10秒失效及拒过期、scanner启动/运行错/迟回调/不完整/只发广告、准备时关闭chooser保留route、含空ZIP进度/失败写/取消、关联拒绝不覆盖别的活动任务、进度边界及字节发完与peer完成分离。

## 仓库打包与发现追试

迁入仓库后9测试及arm64 ad-hoc全构建deep/strict签名通过，bundle含LICENSE/NOTICE/依赖和中性ID。之前实机早于这些打包/About变化，未重传。

手机与tablet同账号名、不同协议ID与brand/type同时被动可见，endpoint变而ID此轮稳定，未确定平板具体型号／未传文件。首native chooser通过Finder显示独立项，平板别名只影响自身。最终英中真实两候选、OPPO圆logo/phone/tablet SF Symbols确认，别名重启只留tablet后清除，10品牌图AppKit加载/manifest hash一致，完整及UI构建签名通过，无发送。

## 候选过期追试

用户关手机可见后约55秒剩余观测无新广告；是无线观察，不是UI开关精确时间测量，10秒边界/错误单测，未计时自然10分钟。安装版Finder chooser继续零候选、无scanner错误、不重现旧项，签名通过，无发文件。macOS adapter用固定Bleak3.0.2自定义backend重复广告，升级依赖需复查，不为保活连接设备；UI还清静默流/蓝牙关/engine重启/chooser关闭。

## 发送进度追试

build5 Finder发64 MiB到OPPO，更新0/~4/23/40/60/84%，最后ZIP67,109,030 B（正文67,108,864，差为ZIP），Finishing后peer完成，native满蓝环Sent。ADB断开未核手机散列。早次等批准超时不算成功；合成37% native预览验证logo/角标/英语，只是展示。英中阶段单测、全/UI签名通过；菜单回进度未在此次实测，手机保留文件。

## 待验证与清理

其他品牌／型号、Intel、旧OS、登录重启、长睡醒、大容量、满盘、真实中断、通知动作需各自测试。鸿蒙星河互联修复尽力而为，“先开anDrop总能解决”被重复试验否定，见[使用](usage.md)。早期试验后恢复手机联系人／本人可见、清醒屏设置、卸诊断app、删生成fixtures，raw日志／截图不提交。发现追试为用户临时公开两端，未改永久设置。

## 无标题popup（build6）

UI-only编译/签名通过，真实AppModel/RecipientPanel合成预览查去标题/圆角/背景；发送态失焦仍在，成功态失焦关闭，未启BLE/文件，build5实机边界不扩大。

## 平板接收恢复（build7）

用户平板发送在正文前Mac reset、平板称接收者拒绝，原reset原因未定。初始WebSocket元数据/正文前最多10秒4次重试route/reset/refused/abort；TLS/证书/HTTP/权限/取消不重试，无TLS降级或部分下载重放。15秒offer timer仅接收任务未起前到期，旧timer问题单测证实但不等于原reset原因。

后续真实平板首host-unreachable、第二连成，83,249 B直接Downloads完成，用户确认/本机大小一致，未比发送散列，只证明该次恢复。通知用本地化可操作错误，不含endpoint/对象/名字，私诊断记阶段/类/errno/attempt，raw不提交。

## 名称与自适应布局（build8–9）

build8真实grid合成短名/两行名旁pencil，点tablet铅笔只开改名取消、不发，UI编译签名通过。build9 Example一行独立居中、紧凑一排/sheet、40候选滚到最后header/footer固定、10logo+类型，均合成无BLE/传输。后续右键菜单取代铅笔。

## 接收范围、控制中心与身份历史

51 Python覆盖未列设备密钥前拒、已列仍批准、待批撤销和名字无关；10 Swift。独立UUID UserDefaults测离线候选/重名/增删忘/持久信任/运行即接收/endpoint/一次旧历史清理，未改安装版设置。签名通过，独立按count读回删除无endpoint历史、保留有身份记录。控制扩展注册／用户确认gallery和最初file-picker，后来单Receive项打开host panel；build36已移除。虚构英中UI复用品牌/角标，OPPO/vivo白绿白蓝、小米原橙。这些不证明其他厂商或加密身份。

## 历史GATT信任边界（后被senderId验证取代）

54 Python：未知/缺central无ready、停接收拒subscription、已批准后移信任仍保控制。13 Swift：未知/可信/坏值/不可接收、大小写UUID、仅已批准会话豁免，完成会话不豁免新offer。待批不豁免，撤销测试保留；GATT callbacks使用政策，单测不证明新ATT实机兼容。OShare17.2.36闻8881即加候选、不先读GATT，故不实现选择可见，见[机制](trusted-discovery.md)。

## 移除控制中心与单取消（build36）

安装仅Finder扩展，旧WidgetKit卸注册/删tile，无control-state entitlement/App Intents，签名通过。独立Prototypes/ReceivePanel保留英中虚构图和预览，验证范围/关禁行/Escape/无标题glass，不改真实设置。popup当时单footer Cancel在发前关、五活跃阶段取消对应ID、终态Done/Escape同动作、失焦后台继续。一次性native model用JSON sink无engine测正确ID/状态，54 Python/15 Swift；英中图重生，不重传。后续多目标流程见下。

## 1.0.0发行准备

官方Python3.14.7及固定wheels全构建，80 Mach-O arm64/最低14通过，无构建机库，不等于14实机。hardened signed engine清Python/DYLD环境后ready正常退出无stderr，无BLE/文件。54 Python/15 Swift；未来App Store无Sparkle typecheck不代表商店认证。

隔离UUID生产AppUpdates+Sparkle2.10.0，用loopback feed/合成UI/签名1.0.0DMG从0.9.9自动检查下载出现中文ready；Later留旧版，模拟活动传输禁安装，Restart and Update安装重启1.0.0，手动显示最新。关自动检查/下载独立读回并冷启保持，不改安装版。feed/archive签名，追加字节由Sparkle和嵌入公钥独立验证拒绝，不导私钥。

冻结479 code filename无绝对路径，所查常量无owner/home/team，source/history也查；只是聚焦隐私检查，不是任意数据自动匿名保证。英中生产虚构图重生，设置仅演示viewport扩展，真实可滚动。未新增手机传输。实际macOS26-only binary在最低14检查被正确拒。

应用随后公证/staple/deep-strict/Gatekeeper Notarized Developer ID通过，Developer ID DMG只读挂载/校验/251 file-link manifest与公证export相同。安装保偏好历史，设置显示1.0.0与两更新选项/链接，host/engine运行。2026-10-17发布[v1.0.0](https://github.com/TakeruF/androp/releases/tag/v1.0.0)，三资产匿名重下字节一致、SHA256和appcast/DMG Ed25519独立验。安装版读公开feed显示1.0.0最新，鸿蒙星河互联停后accessory/Dock隐藏，14实机待证。

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

## 1.0.1（10003）：Finder 共享窗口的焦点交接（修复不完整）

此构建将共享扩展的打开顺序改为：先完成扩展请求，再在完成回调中打开 anDrop。该修改未解决用户报告的问题；用户随后确认仍会一闪即逝。真正导致失去焦点的原因见 10004 节。

安装正式签名构建后，使用合成文本文件从 Finder 的共享菜单验证了：应用已运行时打开、取消后再次共享、应用退出后由共享扩展启动。三次均能检查到正确文件和接收设备列表，但检查工具重新选择了应用，影响了焦点状态，因此这些结果不能证明共享后窗口持续处于前台。此次验证针对共享入口与窗口交接，没有发送用户文件，也不计为新的端到端文件传输测试。编译、严格签名校验和 80 个 Mach-O 的 macOS 14／arm64 检查通过。

回调遵循 Apple 的 [completeRequest(returningItems:completionHandler:) 文档](https://developer.apple.com/documentation/foundation/nsextensioncontext/completerequest(returningitems:completionhandler:))，在扩展完成请求后交接；过期回调不会再次打开应用。

## 1.0.1（10004）：修正应用注册类型导致的失焦

10003 的应用包仍声明 `LSUIElement=false`（普通应用），而运行时在未使用 鸿蒙星河互联 时切换为 accessory（菜单栏应用）。Finder 打开共享 URL 时，Launch Services 将应用恢复为 regular；两秒周期的环境检查又改回 accessory。该切换异步取消激活，将焦点交还 Finder。窗口实际仍存在，但被遮住。

诊断构建连续记录应用激活状态、窗口可见／key 状态和激活策略，复现了 `regular + active + key` → `accessory + inactive + not key`。只在策略切换后立即激活，或在首次失活通知里激活，都仍会被后续的 Finder 激活覆盖，因此未采用这些补救方案。

正式修复是将应用包声明为 `LSUIElement=true`，与其常驻行为保持一致。共享打开时不再从 regular 切换到 accessory。保留现有 鸿蒙星河互联 运行时使用 regular 策略的逻辑；本轮未重新验证 鸿蒙星河互联 的实际蓝牙广告共存。

诊断构建中，修复后共享从始至终保持 accessory、active、key；验证期间不重新选择 anDrop 窗口。安装正式 10004 后，分别在应用已运行、完全退出的状态下从 Finder 发起共享，并独立只读检查前台应用仍是 anDrop；安装包与构建产物一致，诊断宿主已移除。此次没有传输用户文件，也不计为新的端到端传输测试。

## 1.0.1（10006）：失败日志与邮件反馈

- **99 项 Python 测试、21 项 Swift 测试通过**。新增覆盖字段过滤、敏感原始数据排除、失败上下文跨重启保留、未知历史日志、路径标识校验、事件／导出数量限制、文件类型采集范围更新，以及运行应用清单去重。
- 私有诊断宿主模拟发送与接收失败，两种通知均提供“查看日志”；实际点击发送失败通知的该操作后，正确打开设置中的对应诊断报告。模拟不代表新的实机传输测试，测试入口不包含在生产包中。
- 安装生产版后，确认既有设置与信任设备保留。诊断页面可预览 JSON；“在访达中显示”选中了生成的日志文件。“向开发者报告问题…”打开系统邮件草稿，收件人为 support@takeruf.com，附带 JSON，并包含复现步骤、预期结果、设备型号、系统版本及 VPN／互联应用情况的填写栏。两次验证草稿均未发送且已放弃保存。
- 相对旧版失败记录，报告明确显示没有详细日志；不伪造历史采样。OS 采集限制只在开发者文档及结构化字段中说明，用户可在邮件中补充系统版本。
- 最终安装 **1.0.1（10006）**，保留本机既有 bundle identifier。通过 Developer ID 深度／严格签名验证；80 个 Mach-O 文件通过 arm64／最低 macOS 14 检查。安装宿主与构建产物逐字节一致，确认无私有 QA 触发入口；已移除两条模拟传输历史并私下归档相应日志。

本轮验证覆盖自动化、模拟失败通知与生产版日志／邮件 UI；没有新增真实手机传输或实际发送反馈邮件，也没有重新公证或发布 GitHub Release。未配置邮件客户端时的手动附件提示已实现，但本轮没有删除现有邮件配置来实测该分支。

## 1.1.0（11000）：正式发布构建

将上述 1.0.1 开发构建的修复及诊断反馈功能汇总为 1.1.0。使用与 1.0.0 相同的应用识别符和更新公钥，保持更新兼容；构建号提升为 11000。完整重建宿主、共享扩展与 Python 引擎，99 项 Python 测试和 21 项 Swift 测试再次全部通过。

Apple 公证完成，应用附带公证票据并通过 stapler、Gatekeeper 与 Developer ID 深度／严格签名校验。80 个 Mach-O 文件通过 arm64／最低 macOS 14 检查，未引用构建机库。DMG 使用 Developer ID 签名；appcast 与更新包通过 Sparkle 签名，已核对版本、架构、下载地址、长度及 SHA-256。只发布 DMG、appcast.xml 与 SHA256SUMS.txt，不发布私有公证记录或真实设备日志。本次发布构建没有新增手机实机传输测试，沿用前述明确列出的实测边界。

1.1.0 已作为 GitHub 最新正式版本公开。通过未认证的 GitHub API 确认 latest 指向 v1.1.0，并从公开链接下载三项资产，与本机构建逐字节一致；latest/download/appcast.xml 内容及签名验证通过。当前 Mac 已安装同一公证产物并成功启动，既有应用识别符及签名团队与 1.0.0 一致。这里只验证更新文件的发布、可下载性与签名，没有把它表述为已实测一次 1.0.0 → 1.1.0 的 Sparkle 安装过程。


## 1.1.1（11001）：接收完成通知的 Finder 操作

移除接收完成通知“在访达中显示”操作的 `foreground` 选项，避免系统同时激活 anDrop、触发重新打开应用时的设置窗口。已有的 Finder 文件定位处理保持不变。

99 项 Python 测试与 21 项 Swift 测试通过。完整重建宿主、共享扩展与 Python 引擎，通过 Developer ID 深度／严格签名校验；80 个 Mach-O 文件通过 arm64／最低 macOS 14 检查，未引用构建机库。应用识别符、自动更新公钥与订阅地址保持一致，构建号从 11000 提升为 11001。

通知中心未能通过本轮 UI 操作工具取得可操作状态，因此未完成实际点击通知按钮的修复后验证。临时模拟通知宿主未写入传输历史，已退出并移除；测试入口不包含在生产包中。本轮没有新增手机／平板传输测试。

Apple 公证与票据验证、Gatekeeper、DMG 内容一致性检查均通过。DMG 使用 Developer ID 签名；自动更新包与 appcast 签名通过验证，版本、架构、最低系统、下载地址、文件长度和 SHA-256 已核对。仅发布 DMG、appcast.xml 与 SHA256SUMS.txt。

## 候选右键与隐藏（2026-10-17开发版）

图标右键Rename/Hide替代铅笔，设置管理持久隐藏并离线恢复，只筛发送候选不改接收/信任，ID变可重现。真实Pura候选依次右键/改名/隐藏/重启保留/设置恢复/再发现，最后清试值，截图无铅笔。4新增模型测试存元数据不存raw身份、重名/发现持久/恢复，26 Swift与UI编译/签名/frozen self-check通过，engine同phase18完整双向三点版。活动传输tile保持只review未实传。私证据 `build/huawei-research/phase19/`，早铅笔记录只属旧构建。

## Huawei图与computer类型（2026-10-17开发版）

本地原样官方96px favicon/manifest，Huawei/HUAWEI均支持；computer用desktopcomputer与英中Computer/电脑，覆盖候选/历史/记忆/隐藏。合成Huawei手机PC/HONOR小米PC/OPPO手机平板只证明展示。Huawei type12=公开0x0C，PC仍需SHARE，idle phone/pad例外不扩大，不猜HONOR/Xiaomi wire。新测试PC gate/本地化/隐藏roundtrip，176 Python/27 Swift，完整签名/self-check/目标OS通过，实候选logo/phone确认，无新传输/PC实机声明。`build/huawei-research/phase20/verification-redacted.json`。

## 照片预览修复（2026-10-17本地11002）

合成JPEG复现Pura Files图片发送失败：认证preview在11/12后加13，旧严格两项拒。batch有界允许11/12/13，13≤8KiB，拒未知/空/重复/超长并保全DFile名/大小/加密/内容；预览ACK后正常byte EOF不阻止file DONE ACK，截断仍失败。固定阶段/transfer ID诊断无原文/图。

179 Python/28 Swift，同ID/设置完整冻结Developer ID本地1.1.1/11002安装。native批准合成76,263 B JPEG，Downloads/quarantine/complete，内容SHA256一致/手机Sent，历史保留并留运行。未打开/重测用户原私照。`build/huawei-research/phase22/`。

## Huawei信任登记（2026-10-17）

完成接收携 `huawei-key:`+规范DER RSA SHA256，仅有效加密offer证明私钥后暴露；手动登记可trusted-only，不是账号认证。旧历史无key或key变需Everyone新收再加，发现ID/名/IP不能登记授权。

216 Python/30 Swift，追加配置回归及36 runtime通过：未知/变key/复制key坏加密、批准拒绝、待批撤销/停接收、拒发现ID、Huawei信任不开联盟GATT。生产AppModel隔离设置验证完成候选/元数据/增删忘/持久，英中渲染检查。

完整engine重建签名，本地11019保ID/designated requirement、安装字节/设置一致。native看两旧信任与Huawei说明；用户Pura接收完成、保存大小=总量、持久key、native Add→Remove并保两旧条，未读私内容，`build/huawei-trust/`留备份/脱敏。

下一trusted-only同key到批准，证明连续性，但单张thumbnail70,883 B超过估计60,000/件而receive_preview/thumbnail_size失败，不是信任拒绝。改缩略图受既有1MiB总preview预算而不绑件数，外帧仍MTU+28、完整性/已知唯一tag/名日期/DFile边界保留。107 Huawei测试含23/70,883/97实际形状的双重加密/大单图/超限/分片/认证失败。11020只外置模块重签host/扩展，同指定要求，冻结archive/native不变，三信任/模式保留；原失败照片该版成功尚待。

11021诊断仅白名单模块名/有界行号，无路径/原错/locals/内容，完整重建，108 Huawei/31 Swift。10,990,916 B后来batch行151超旧8MiB单件但没超16MiB合计。随后两张2,685,997/2,979,527 B trusted-only成功、大小=complete总量/同登记key/用户确认，不看私内容，11020泛错未重现、原因未定。

11022将单件接收与合计同为16MiB，参照/合成发送fixture旧限不变，合计内存/件数不变，外batch重签，109 Huawei含实际失败边界/16MiB/总超限。安装重启保三信任及trusted-only，10,990,916 B在最终变更后未重收。备份/结果 `build/huawei-trust/`。

## 多目标（2026-10-17本地构建）

最初勾选+Send，多目标独立request/进度/结果/取消/重试，仅全成功可点外关。213 Python/29 Swift后加Huawei取消隔离；生产Swift模型覆盖多选/重复/隐藏消失/独立终态/活跃同伴重试/只取消活动/保后续选择。两隔离BLE模拟与真实loopback HTTPS/WebSocket并发传日文/空/二进制全字节一致；mock Huawei subprocess与真实OShare重叠、取消不影响同伴。英中生产图/完整打包签名runtime通过，备份安装匹配host/engine重启无启动错。仅模拟peer，不证明Huawei/OPPO实机同时收妥。

## 点击立即发送（2026-10-17 UI更新）

取代勾选+Send：点候选即发，其他保持可点击，发现持续到关窗，已开tile即使停广告仍保，无勾选/独立Send。模型回归覆盖活跃时后续点击、去重、Finder排队新批时保原批、后发现新目标、隐藏/缺失/过期route拒、接收独占/独立重试取消/旧选择回归。30 Swift/5并发集成/生产模型通过，英中视图检查，复用安装engine，实机同时收妥仍未证。

## 鸿蒙星河互联退出建议（2026-10-17源码）

英中README/设置建议完鸿蒙星河互联传输退出，用anDrop独立华为分享，共存实验性。新失败即时查bundle进程而不等timer，排本地化非模态弹窗，不挡其他传输/批准，同批失败合并一弹窗，不自动退出或断言因果。

生产AppModel隔离设置日志，只在OS边替换进程探测/弹窗，测收发/英中/UI状态过期时无进程/进程先于timer/成功拒绝取消不弹/重复并发/关闭/弹中进度/展示前退出/终止；英中原生alert渲染检查，Sparkle+arm64/macOS14 typecheck通过。无新实传／安装替换。

## 1.2.0/12000：发行验证

正式Huawei Share主打。当前完整219 Python/31 Swift，含编译native AppModel/loopback并发/分类/有界Huawei收发/信任。官方Python3.14.7完整冻结、Huawei self-check/Developer ID/arm64最低14通过，发行bundle ID保持，声明按精确runtime和官方Python文档更新。

Apple公证/staple/Gatekeeper通过。public资产DMG/签名appcast/SHA256；source/history/assets与private日志/archive/device证据分别审查。8张英中生产虚构图重生目视，含Huawei候选/独立进度/信任/隐藏/自动安装/1.2.0，演示viewport扩大，真实可滚动。打包无新实机，最终16MiB边界、GiB发送、Huawei+OPPO同时、14实机/Intel仍待。

### 公开分发与安装更新

历史发布检查GitHub Latest=v1.2.0，三资产匿名重下与本机逐字节一致，canonical latest/download/appcast.xml亦同；独立验DMG Ed25519/feed/版本build/最低OS/架构/DMG内容/票据/Gatekeeper/不变designated requirement。

安装的1.1.1/11022通过Sparkle到1.2.0/12000并重启，host/engine/Finder字节同公证版；信任/记忆/别名/隐藏/范围/目录/名/语言保持，设置1.2.0与Huawei无实验标签，后续公开feed显示最新。证明更新安装运行，不是新手机传输。

## 1.2.1：受信任设备自动接收（2026-10-18）

完整 **226 项 Python 测试和 31 项 Swift 测试**通过。新增覆盖两种接收范围下默认自动接收、关闭后恢复确认、“所有人”中的未登记发送者仍需确认、仅信任模式拒绝未知设备、关闭接收，以及华为传输公钥匹配。真实 loopback TLS/WebSocket/HTTP 接收在已登记发送者场景下无需确认，文件内容校验通过。编译后的生产 AppModel 验证设置持久化及两种范围下传给引擎的配置。

完整冻结引擎已重建；从发行二进制提取的字节码通过两协议、两接收范围、默认开启及关闭自动接收的 smoke 检查。Developer ID 构建中 80 个 Mach-O 文件通过 arm64/macOS 14 最低版本检查。中英文设置截图使用虚构数据从生产视图重新生成并目视检查。本次变更未进行新的手机实机传输。

Apple 公证、staple 及 Gatekeeper 检查通过。最终签名 DMG、签名 appcast 和 SHA-256 清单为唯一公开资产；包含完整冻结引擎，沿用既有发行包标识和 designated signing requirement。

公开验证确认 GitHub Latest 为 v1.2.1；三项发行资产匿名重新下载后与本机已验证文件逐字节一致。规范地址与旧仓库地址的 latest appcast 均返回已签名的 1.2.1 feed。

已安装的 1.2.0/12000 通过 Sparkle 发现、下载并安装更新，重启后为 **1.2.1/12100**。主程序、引擎、Finder 扩展字节与公证发行版一致，签名、票据和 Gatekeeper 检查通过。设置指纹确认信任记录、记忆设备、别名、隐藏设备、接收范围、保存目录、共享名称、语言及启用状态保持。原生设置显示受信任设备自动接收默认开启，随后检查更新提示 1.2.1 已是最新。证明公开分发、更新安装及运行界面，不是新的实机传输验证。
