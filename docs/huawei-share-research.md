# 华为分享 / HarmonyOS 7 实机调查

简体中文 · [English](huawei-share-research.en.md) · [文档目录](README.md)

调查日期：2026-10-17 JST。对象：HUAWEI Pura 70。本页按阶段整理原始调查，保留关键协议、证据路径、失败与验证边界。阶段编号沿用原记录；phase33/34 的图标与接收修复是两条并行记录。以下历史构建状态不代表当前发行状态；1.2.0 的正式支持范围见[兼容性](compatibility.md)、[测试记录](testing.md)与[更新说明](releases/1.2.0.md)。

## 已确认与未解决的事项

- 不运行 鸿蒙星河互联、不加载其库、不切换 Wi-Fi，在现有同一局域网上，anDrop 本体与 Pura 标准华为分享完成双向三文件传输、Downloads 保存、全内容与 SHA-256 比较、quarantine 和 complete 历史确认。同名重收保留原文件并另存。phase18 的完整构建覆盖空文件、日文名与 8 MiB。
- phase16 确认亮屏且未打开手机分享页时的发现、持久 Mac ID 在“仅分享过的设备可见”下的后续发送，以及取消、Mac 侧 TCP 断开后的重传。屏幕关闭／锁定发现、Wi-Fi 本身断开恢复及手机长期身份认证仍未完成。
- 照片专用 type1 分支进入 build11012，build11013 保留。phase37 使用产品 `offer()` 的通知试验中，用户实机确认绿色图片图标。视频、文档与混合批次不声明为照片。PDF／Office／视频的接收许可前专用显示仍未解决。
- 标准 `RecvSessionV1` 中，用户改为所有人可见后，`verifyMode` 从 0（拒绝）变为 1（证书链验证）。通信密钥交换成功不等于共享授权完成。该路径要求受 Huawei 根信任的证书链，并核对证书公钥与交换公钥。不能将此条件套用于已工作的 Apple 兼容路径。
- phase38 重现 Apple 接收路径构造时的 7 个主要命令、6 个控制命令及接收确认事件链；该表未发现新增图标输入。它不能排除其他会话、其他版本或后续动态注册。phase35–38 未修改产品代码或安装版。

## 设备与比较环境

| 项目 | 观测值 |
| --- | --- |
| 手机 | HUAWEI Pura 70 / ADY-AL10 |
| 产品软件 | `7.0.0.109(SP6C00E105R5P2)`；更新页 HarmonyOS `7.0.0.109 SP6` |
| 系统属性 / API | `const.ohos.fullname=OpenHarmony-7.0.0.105`，API `26`；该属性不是产品版本 |
| 分享应用 | `com.huawei.hmos.instantshare`，`7.0.0.545` |
| 诊断连接 | HDC 成功，ADB 无目标；USB 用于操作与内容读取，实际共享使用 Wi-Fi |
| 比较应用 | 鸿蒙星河互联 / `com.EMUIInterconnect.app`，`1.0.0` / build `1005.1`，`/Applications/EMUI Interconnect.app` |

使用已有安装。`mas info 6775134178` 返回 1.0.0，`mas outdated` 无 鸿蒙星河互联。通用 App Store 页的 1.0.1 不能证明 Mac 版有更新，因此没有更新。

用户要求共享时不更换 Wi-Fi。鸿蒙星河互联 的“高速传输模式”原来开启，说明为“开启后，每次传输都将直连华为设备 WLAN”。关闭后，77 B 合成文件成功 Mac→Pura→Mac，回传内容及 SHA-256 一致。高速模式可能与此前停顿有关，但未排除其他状态变化。8 MiB 日文名文件也显示发送完成，观测到现有 en0→wlan0 TCP，前后 IP 不变；未创建或加入热点。这证明现有 LAN 路径，不证明无路由器的 AirDrop 式直连。

## 证据与试验约束

以下证据名相对 ignored 的 `build/huawei-research/`；它们是本地调查产物，不是仓库可下载附件。未附设备序列号、账号、原始 BLE 数据、私钥、厂商二进制或反编译源码。散列仅用于明确标注的合成文件和二进制来源。端口为每次协商值，不能硬编码。

| 合成文件 | 大小与 SHA-256 |
| --- | --- |
| `androp-huawei-probe-20261017.txt` | 77 B；`a6464cd72f201b235a9e48ecdbd1c09a932b71af5992ef5a7e1039fd31e1fd2c` |
| `華為共有検証-20261017-8MiB.bin` | 8,388,608 B，重复 `bytes(range(256))`；`7d212b9c884f5c77896de960ae17cc341cda43b14d6a971f34ca29ebd4badf7f` |
| `androp-independent-HHMMSS.txt` | 60 B 固定合成文本；`56a5e7134c90f0ddcfbfb96bd7c02c2607ed4bb2258059a06cd2b98b53acc0d3` |

比较试验记录：`roundtrip-evidence.json`、`large-lan-sockets-redacted.json`、`network-final-redacted.json`。曾观测端口 33651／33559／46713，仅作为当次证据。

Mac→Pura ping 和 Python UDP5683/5684 曾失败（`EHOSTUNREACH`），反向 ping 与 鸿蒙星河互联 LAN 传输却成功；不能解释为整个 LAN 不通。鸿蒙星河互联／Python／anDrop 的本地网络权限及 鸿蒙星河互联 定位均观测为开启，未改权限。native `/usr/bin/nc` 成功而 Python socket 失败的原因未确定；TCP `nc -s` 也曾失败。发送后立即关闭 stdin 会得到 0 B，保持 stdin 后才收到响应；0 B 不是认证拒绝的证据。

早期文件对话框选错行，将 179 B 候选诊断 JSON 发至同一用户手机；查看器显示内容，因此不能因随后点击拒绝便声称未传输。该 JSON 包含本地 BLE endpoint 与扫描属性，不含认证密钥、账号或联系人。后来用专用 `send-fixtures/` 文件夹，核对文件名和 8.4 MB 后再发。端上试验文件与 JSON、Mac 回传文件均保留；文件管理器被新条款确认阻挡时未代为同意。8 MiB 回传内容随后在 phase11 得到验证。

## BLE 与静态分析线索

| 观测 | 内容／限制 |
| --- | --- |
| 广播 | FE35 Service Data、manufacturer `0x027D`；长度 15/24 B，另次为 13/22 B |
| GATT | `11C8B310-80E4-4276-AFC0-F81590B2177F`，特征 `2B00`／`2B01`，read/write/write-without-response/notify/indicate |
| 其他服务 | FE35（`2A00`–`2A03`）、`C574EDB3-6551-473B-BAD8-65035F07E4A8`；值含义未解析 |
| 比较广告构造 | `FE35`, `933E`，三个生成的 16-bit 值，`0300` 和本地名；探针用随机值，不借用账号／设备 ID |
| LAN 线索 | CoAP `/device_discover`、5684、`coapUri`、`capabilityBitmap`、`wlanIp`、`serviceData` |
| 会话线索 | `IShareEcologyAuthSession`、`IShareReceiverBytesSession`／`IShareSenderBytesSession`、`IShareReceiverFileSession`／`IShareSenderFileSession` |
| 加密／传输线索 | `SoftBusEncryptDataWithSeq`、`TransTdcEncryptWithSeq`、`TransTdcUnPackData`、AES-GCM、ChaCha20-Poly1305、`SetSpeedMode`、WLAN handshake、`NETWORKINFO_NEGO`、`go ble`／`go tcp`、`ParseCompetencyNego`、`secure_version`、`ParsePubKeyHandShake` |

首次 GATT 枚举时 鸿蒙星河互联 也在运行。仅连接当前扫描中明确指定的候选，旧 endpoint 报 `target_not_seen_in_current_scan` 后停止。候选出现与可见性严格因果、准确设备身份及长期稳定性尚未建立。无 鸿蒙星河互联 的 30 秒合成广告／GATT 服务试验未获 read/write/subscription 或文件连接；12 秒不可见及再次全员可见扫描均无候选，不能据此断言开关的效果。CoreBluetooth 报广告成功也不证明全部数据都已上空口。

手机 `hidumper -s 4700` 有 DSoftBus discovery／connection／transmission 与脱敏 iShare 会话。公开 DSoftBus 不是完整 Huawei iShare 认证和传输实现。原有 MTA/OShare 的 `3333`/`3334`、`8881`、GATT `9999`、`9897`/`9898` 与其不同；仅增加品牌或替换 UUID 不能复用 HTTPS/WebSocket 路径。

## 初始独立 LAN、能力与密钥交换

未运行 鸿蒙星河互联、未加载其库、未安装手机应用／证书／账号，HDC 仅检查状态。对明确指定的现有 LAN 地址发送 UDP5684 CoAP CON POST `/device_discover`，收到 ACK 和两条共 756 B 的 JSON，由 `serviceData` 得 TCP33651。服务名和临时 ID 为试验值，响应中的名字／地址／ID 不公开。

24 B SoftBus 头及 `IShareEcologyAuthSession` opening 返回 263 B：magic `0xBABEFACE`、module8、flags1、CODE4、API2、MTU39968。ROUTE_TYPE=0 不是实际路由证明。module9 的 61 B 能力响应为 envelope version1/protocol101/TLV3；tag1 secure_version 为空，按比较 parser 解释为 bit0。

临时 RSA-2048 请求获得 TLV6→2 的 294 B SPKI DER（总响应346 B）。用对方公钥 OAEP-SHA256/MGF1-SHA256 加密 16 B nonce+32 B AES challenge，以自己的临时私钥解响应，再验证 AES-256-GCM，取得 32 B 会话密钥。原始公私钥和会话密钥不落盘。此时只证明密钥协商，未证明共享授权、身份或文件送达。最初 envelope hash 与比较 HMAC 不符，未绕过校验将其设为受信任。

证据：`independent-final-lan-redacted.json`、`independent-everyone-notify-redacted.json`（两特征各订阅3秒，自发通知0）、`independent-auth-open-held-redacted.json`、`independent-public-key-redacted.json`、`independent-key-challenge-redacted.json`、`independent-key-challenge-final-redacted.json`、`independent-lan-listener-redacted.json`。早期探针 `authentication_complete`／`transfer_attempted` 恒为 false，密钥结果另记 `key_challenge.rsa_response_decrypted`／`aes_gcm_tag_verified`／`session_key_bytes`。离线5项覆盖 CoAP 脱敏、Unicode、varint、TCP 分片、超长／截断和 TLV 长度。

鸿蒙星河互联 1.0.0 arm64 静态位置：opening `0x100036f48/0x10006292c`，TCP头 `0x10009f780`，envelope `0x10008ec80`，能力 `0x10008c590/0x1000937bc`，公钥 `0x100093a6c`，challenge `0x100093ea8/0x1000940f8`，OAEP `0x10004d19c`，GCM `0x10004cd70`。仅适用于该二进制；摘录／来源在 `petal-relevant-disassembly.txt`、`petal-static-provenance.json`，大体积中间反汇编已删。

## LAN 信息与通道协商（phase2–3）

60 B offer 通过 AES-GCM command7 发送，标准 UI 明示 `anDrop LAN Probe`／1文件／60 B 后才批准。`user_confirm` 验证后，必须先 command4→5，再 command10；直接发10无后续响应。SSID 为空，仅发送 en0 private IP，不处理 AP 凭据、热点创建／加入。module21 的 auth header 为 `<IIQII>` 24 B，随后 nonce12 B+GCM；严格检查 length。最初仅 offset24 方案通过 GCM，后来进一步确定结构。

MetaNode `DEVICE_NAME`／`DEVICE_TYPE_ID`／`META_NODE_ID`／`FLAG`：Pura 为14/100，探针为12/100和临时64位 ID。JSON 末尾单个 NUL 需处理；收到并验证 `META_DEVICE_INFO_ACK\0` 后，inner type `0xffff0004`／module16／CODE3 交涉 byte 端口。`P2P_IP` 字段虽如此命名，值是已有 LAN IP；仅连接与指定手机 IP 相同的返回地址。

新 TCP 用 module6/flags `0x94`/CODE1/API2，控制密钥加密，内含另一临时32 B密钥；返回 flags `0x95`、MTU4096 的 ACK。原认证连接 inner module17/CODE1538 交涉 file。BUSINESS_TYPE=0 返回 CODE6/ERR_CODE -426115067；修为3得到正常1538、MY_CHANNEL_ID8、P2P_PORT46207，不能将这些实例值固定化。

证据：`next-offer-redacted.json`、`next-network2-redacted.json`、`next-channel4-redacted.json`、`next-final-state-redacted.json`（10项离线测试）；`phase3-meta-pc-nul-redacted.json`、`phase3-port-redacted.json`、`phase3-byte-redacted.json`、`phase3-file-business-redacted.json`、`phase3-final-state-redacted.json`（14项）。后者是正常端口响应，但旧探针没有 `file_channel_acknowledged` 字段。初次 Settings 停顿后来定位到 `next_recv` 和手机未完成接收，取消该待收项后继续；不是 opening 无响应。默认停在 file 端口，只有 `--dfile-settings`／`--send-fixture` 才交换 Settings。

## 独立 DFile 发送与 PC 发现（phase4–5）

2026-10-17 12:18 JST 首次60 B保存成功。DFile type8 Settings：WLAN connection_type2、MTU1472、headerEnc1、capsCheck876。控制加密由 capsCheck bit8 (`0x100`) 单独协商，不能与 headerEnc 混同。未设该位时，加密文件头只得空确认；type11 拥塞控制为明文，不能当认证回复。

DFile GCM 用协商32 B的前16 B，AAD 为64个 ASCII `A`，尾部 tag16 B+nonce12 B。误用整32 B曾产生 `AesGcmDecrypt: data verify error`。比对公开 `SetCryptPara` 与 鸿蒙星河互联 `SetSessionCryptPara` 后修复。验证 type2 ACK 的内外头与 GCM 后才发 ID1正文；正文前 DONE 不是成功。type6 DONE经验证后回 type7（该发送端 ACK payload 为空）。`androp-independent-121840.txt` 经 HDC 读取为60 B且散列一致。证据：`phase4-aes128-controls-redacted.json`、`phase4-content-verification-redacted.json`、`phase4-received-fixture.txt`；紧接着一次收到 `user_reject`，没有覆盖拒绝重试。未完成时尝试 senderCancel，未收 ACK 不计成功；`next_recv` 只是明文等待状态。19项离线通过。

12:22–12:25，两个新会话各发60 B，均验证加密 DONE并读取内容一致，不需重启手机分享服务。2秒内未见上层完成消息，标准 UI 完成通知未捕捉。证据：`phase5-repeat{1,2}-redacted.json`及对应 `-integrity-redacted.json`。

新增 `huawei-receiver-discovery-probe.py`：明确同 LAN 目标、PC12、临时 TCP、最多60秒，默认不批准／保存。mode1 在55秒发27次、收52块 CoAP却无候选或TCP；改 mode10并省略 `coapUri` 后出现候选（两项贡献未分离）。mode10 对应公开 `PUBLISH_MODE_PROACTIVE`。选择77 B合成文件与候选后，Mac 收 module8/CODE4/API2/MTU39968 opening，但此时尚无回复实现，手机显示失败，不是文件接收成功。画面确认电脑图标内有 `Mac`；PC12+`osType:2` 的贡献未分离，不称为鸿蒙电脑身份。20项离线通过。证据：`phase5-receiver-publish-redacted.json`、私有 `phase5-picker-private.jpeg`、`phase5-final-state-redacted.json`。

## 接收侧认证问题与修正（phase6–9）

phase6：最小 CODE4 ACK 无法继续；加入 PKG_NAME/SRC_BUS_NAME/DST_BUS_NAME/REQ_ID 后收到能力与RSA请求。哪些字段必需尚未单独隔离。返回公钥后8秒无下一帧；能力 TRUE/TRUE或省略均相同。`--inspect-offer` 新增后续临时密钥、GCM offer解码和明确拒绝，不批准文件。源 IP 一致只是限定目标。合成 peer 全22项通过，不能代替 Pura 成功。证据：`phase6-receive-auth{2,3,4}-redacted.json`。

phase7：hilog `SessionManagerProtocolV2.cpp:260 ... hash code is not same.` 定位到公钥哈希不符。secure version1/MGF1-SHA1 无效并恢复0；广告／opening 的临时 HMAC ID一致及 `deviceHash` 同步也无效。尝试 DER/PEM/Base64、SHA256/SHA1/MD5、HMAC和字节序未匹配；不能据此断定哈希定义。23项离线通过，证据 `phase7-{version1,consistent-identity,advertised-hash,phone-diagnostics}-redacted.json`。

phase8：五个连接的只读分析；连续三次 DER294 B、envelope16字符、opening6字符不变，同会话能力／公钥 envelope 一致，非请求的简单回显。SPKI／PKCS#1／PEM／模数大小端及Base64/hex、SHA512等和1/2/4/8 B翻转仍无匹配。鸿蒙星河互联 `0x10004c744` 为HMAC-SHA256、`0x10004c8c4→0x10004ca04`导出SPKI、`0x10005dc08`大写字符表确认；`ParsePubKeyHandShake` (`0x100093c3c`) 未发现哈希比较，不能把它等同手机的 ProtocolV2 校验。证据：`phase8-{hash-analysis,stability,echo}-redacted.json`；值仅在内存。

phase9：实际需要 HMAC 前6 B按原字节顺序转12位hex，旧 鸿蒙星河互联 派生方案按little-endian 16-bit组排列。修正如下：

```python
digest = HMAC_SHA256(key=public_der[:16], message=public_der)
protocol_v2_identity = digest[:6].hex().upper()
```

该 ID 用于广告UDID、opening DEVICE_ID/PEER_NETWORK_ID；opening可小写（`strcasecmp`）。envelope仍为前8 B的大写hex，ROUTE_TYPE2不改变en0实际路由。已成功的发送端ID未改。新临时RSA的两次新分享成功 challenge、会话密钥回复、加密offer验证，均回 `user_reject`，未收文件。重复点旧分享页的一次无opening，不算连续成功。offer field7仅10 B，不是固定32 B文件名；保留 `expected_synthetic_offer=false`。

根因证据来自只读 `debugfs` 提取已有SDK `HarmonyOS-7.0.0-B1/phone_all_arm/system.img`，不启动／挂载／修改镜像。`libshare_service.z.so` `Util::GetHashCode` (`0x9213c`) 与plugin `0x13c1d0→0x20aca0→0x13c284` 表明6 B逐字节hex并strcasecmp。模拟器日志行207与实机260不同，不能视为相同二进制。`deviceHash` 在公开 SoftBus 映射到账号hash uint64十进制，并非公钥hash；撤回phase7猜测，探针恢复空值，不复制实机值。24项通过。证据：`phase9-hmos-hash{,-repeat,-repeat2}-redacted.json`、`phase9-static-provenance.json`、`hmos7-*`。

## 独立接收、空文件、大文件与取消（phase10–12）

phase10 新增 `--receive-fixture` 与 `huawei-receive-channels.py`，只批准已知77 B，预览与DFile再核对名字。command4→5/10、MetaNode与ACK之后分别等byte/file TCP，均固定源IP。手机 opening flags `0x90`，ACK `0x91`且需 DEVICE_ID/MTU_SIZE/PKG_NAME/AUTH_STATE。byte在opening后改用16 B数据头。3,599 B预览为byte密钥外层GCM及控制密钥内层envelope；command8 field11为名字、field12为3,503 B，不保存图像内容。回双层加密 command1/field8=`previewOK` 后DFile才到达；需并行读byte/control/file。

核对type1名/件数/77 B后回type2；逐type4验证AEAD、ID、sequence、transaction与已知内容，排他新建、fsync、读取比对，回type6并验证加密type7。`phase10-receive12/13-redacted.json` 均为77 B、内容/散列/DONE ACK一致，保存同名 `.received.txt`，第二次不需重启服务。未捕捉手机UI成功。一次失败需重启分享应用才恢复（未重启OS/Wi-Fi/Bluetooth）；取消visible开关无效。改为等手机MetaNode再应答与重启效果未独立分离。清理 BrokenPipe 不得掩盖原错。默认inspect仍拒绝，已有目标提前拒绝。29项离线通过；`phase10-final-state-redacted.json` 保存终态。

| 阶段／试验 | 结果与证据 |
| --- | --- |
| phase11 Pura→Mac 8 MiB日文名 | 5,900个加密DATA验证、重组、散列一致和DONE ACK；`phase11-large1-redacted.json`及 `.received.txt` |
| phase11 空文件往返 | Mac发送无DATA但仍需头ACK后DONE；手机读取0 B，回传也保存0 B/DONE ACK；`phase11-empty-send2-redacted.json`、`phase11-empty-phone-readback.txt`、`phase11-empty-receive1-redacted.json` |
| phase11 预览后取消 | 控制通道field4 receiverCancel，3秒无field5 ACK；无保存；立即重收成功；`phase11-cancel1/reconnect1-redacted.json` |
| phase12 Mac→Pura 8 MiB日文名 | 5,900帧、DONE与HDC全内容一致；`phase12-large-send1-redacted.json`与readback |
| phase12 发送取消 | 64块／91,008 B入队后控制通道取消无ACK；byte通道双层加密field2 senderCancel得到field3 ACK；`phase12-cancel1-redacted.json`、`phase12-cancel-bytes2-redacted.json` |
| phase12 取消后重发 | 两次重发均保存／散列一致，无服务重启；`phase12-retry{1,2}-redacted.json`及readback |
| phase12 接收取消 | previewOK前byte field4→field5 ACK，无文件；下一次空文件成功；`phase12-receiver-cancel/receiver-retry-redacted.json` |

DATA payload最多1,422 B、整帧1,472 B；逐文件校验ID、连续sequence、transaction及开始0／中间1／结束3。接收当时最多8 MiB内存，完整比对后才发布文件，日志只汇总5,900帧。发送nonblocking、有期限，队列尚有正文不能提前接受DONE。91,008 B是入队量，不是手机落盘量；最终目录无取消文件不证明内部临时文件删除。

取消ACK前可能有command1/field15的26,955 B通知，需要有界跳过，仅存结构／长度。`--fixture-source`固定本地basename/大小/散列；`--send-empty-fixture`和`--send-large-fixture`只生成合成数据。初始shared模式拒绝，Everyone后成功不等于账号配对。phase11/12结束读回shared selected=true、IP不变/en0、鸿蒙星河互联及试验nc为0，保留试验文件。测试分别36／40项；终态 `phase11-final-state-redacted.json`、`phase12-final-state-redacted.json`。

## 显式任意文件与三文件批次（phase13）

`huawei-file-batch.py`移除固定内容依赖。合成三点：`androp13-日本語メモ.txt` 81 B、`androp13-empty.txt` 0 B、`androp13-random.bin` 1,048,593 B，总1,048,674 B。三个 `--send-file` 一次发送，ID1–3全部DONE后HDC读取均一致。回传带 `--reference-file` 时按名字／大小匹配乱序ID；无参照的 `--accept-files` 再收时只核对协议与内容完整性，随后独立比较名字集合、全内容和散列。`reference_content_verified=false`仅表示未预置参照。

初次回传4 KiB MTU导致SendBytes失败；改65,536后双层解码预览10,418 B（field11=67，field12=10,287），739个DATA、1头、1加密DONE ACK成功。field12不保存。证据：`phase13-batch-send1-redacted.json`、`phase13-send-readback-redacted.json`、`phase13-batch-receive{1,2}-redacted.json`、`phase13-unreferenced-receive-redacted.json`、对应 `.received/`、`phase13-receive-readback-redacted.json`。

当时边界：1–16文件、各8 MiB／合计16 MiB；仅显式普通文件，拒绝symlink和目录，检测读取期间大小/mtime变化。名字UTF-8 1–255 B，拒绝路径分隔符/NUL/控制字符/`.`/`..`/末尾空白或点/冒号和Unicode规范化、大小写冲突。预览名字1,024 B、opaque60,000 B、byte frame65,536 B。支持头分片、各ID头ACK/DONE，部分DONE不能完成全批，offer/头件数和总大小必须一致。全内容验证后排他创建新 `.received/`，不解释远程路径、不自动打开；写盘失败可能留下部分已验证文件，未实现整批原子保存。显式 `--accept-files` 仅为指定端的一次测试批准，默认仍拒绝，不能替代产品确认／身份认证。47项通过；`phase13-final-state-redacted.json`确认shared/IP/en0/无试验进程。

## 接入本体与完整构建（phase14–18）

phase14 新增 `Sources/huawei_runtime.py`、`Sources/HuaweiLANDiscovery.swift`，用隔离开发bundle连接现有宛先／request／decision／进度／历史。UDP由native读取数据报及内核源，TCP用实测native nc；专用process group限定取消范围。CoAP检查版本、token、option/resource、Uri-Host、可选Content-Format、尾单NUL、mode和能力；不将Uri-Host作目标，要求广告IP等于内核源且同子网，拒绝重复JSON/模糊端口/余数据。10秒失效并更新同ID端口；后续通道固定手机IP。密钥仅内存、诊断仅固定code/phase/异常类型。

实机PC发现、三点确认与拒绝成功，拒绝历史declined且Downloads无文件；批准后仅staging内容一致。`linkat`曾等待，不能断言权限原因；改 `renamex_np(RENAME_EXCL)` 不覆盖、冲突改名、quarantine、失败rollback，成功放置前不发DONE。该阶段保存修正后未实测。因长期对端认证未解，历史版本Trusted-only拒绝Huawei，Everyone提示英中。后续信任实现见[架构](architecture.md)。UI工具同时无法取Finder窗口，未把自动代批当验证。157 Python／21 Swift，全构建、self-check、签名、macOS14检查通过；Homebrew Python因最低OS被正确拒绝，Sparkle helper改顺序签名避免 `.cstemp`竞争。证据：`phase14-decline-evidence-redacted.json`、`phase14-staging-recovery-redacted.json`、`phase14-app-receive1-redacted.json`（非complete）、`phase14-final-state-redacted.json`。

phase15 用户解锁Mac并自行授权Downloads后，Finder专用目录三点用“打开方式”交给开发版（不是Finder共享扩展追试）。手机Everyone、打开分享页后发现；本体发送81 B日文名／0 B／1,048,593 B，total1,048,674，UI100%与engine complete，HDC三点一致。反向标准Huawei Share→本体“接收”→Downloads，三点内容/散列/quarantine/历史complete一致，再收得到 ` (1)`且原文件保留。8 MiB此时仅探针验证。证据：`phase15-app-send-redacted.json`、`phase15-app-receive-redacted.json`、`phase15-history-redacted.json`、`phase15-app-receive-collision-redacted.json`、`phase15-final-state-redacted.json`。终态恢复shared，未置换安装版。

phase16 修正冷发现：待机Pura bitmap192，没有SHARE bit256，打开分享页时448；旧过滤要求256错误丢弃。phone14/pad17允许无256，其他类型仍需它，3.5秒在关闭分享页状态发现并发送40 B、读取一致。息屏／锁定只有空ACK或无响应，BLE唤醒未实现；Everyone仍可能192。Mac chooser打开时误用mode1回复，会从手机候选消失；unicast回复固定mode10，仅主动broadcast探索mode1，实机确认chooser打开时仍显示Mac。

新ID在shared拒绝；同RSA键K先Everyone成功，再shared和重启后均成功。保存RSA2048到 `~/Library/Application Support/anDrop/Huawei/identity.pem` 0600，派生12位ID/envelope/UDID/META_NODE_ID；损坏或宽权限不覆盖，临时键继续并记 `huawei_identity_unavailable`。Mac持久身份不是手机认证，手机记忆期限未知；3次观察到用户未点击也完成，原因未知，不归因anDrop。

16 MiB发送取消后无最终文件、重发一致；接收约6.5 MB取消后Downloads无文件且清staging，重收 `(1)`一致。强杀Mac nc收／发立即failed，再收 `(2)`及重发一致，手机服务PID不变。产品此时关闭连接而未发送取消消息，手机显示失败；不是Wi-Fi断网验证。完成／取消竞争中 `killpg` EPERM曾误报权限问题，改为已退出并优先已记录complete。还修复host先退时emit BrokenPipe阻断nc清理、文件预检/清理阻塞事件循环（TCC仅推测）、清理10分钟前自有非symlink `.anDrop-Huawei-*`（会话最长90秒）、将deadline/closed/incomplete/BrokenPipe映射连接中断。170 Python／21 Swift通过，新回归先在旧码失败；13发送与4接收文件散列一致。完整重建虽通过静态检查，当次未在手机出现，原因未定；该实机矩阵使用phase15 host+源码engine及同UI JSON命令，不能称完整冻结版重测。

证据：`phase16-summary-redacted.json`、`phase16-cold-send1-redacted.json`、`phase16-sharedonly-send1-redacted.json`、`phase16-persist-{1,2,3}-*-redacted.json`、`phase16-ephemeral-everyone-redacted.json`、`phase16-phone-readback/`、`phase16-fixtures/`、`phase16-final-state-redacted.json`；研究私钥ignored。

phase17 构成A完整冻结版（仅显示名/启动设置Info键/host重签不同，核对机器码与engine相同）无需改网络设置就发现并UI发送79 B日文名+空+8 MiB，总8,388,687，HDC全一致。反向opening后Downloads `opendir`线程等待，未批准／保存；主loop仍运行，不把它确认为TCC。构成B新增native UDP固定 `huawei_transport_failed`/phase/errno诊断，同错60秒抑制，不增SO_REUSEPORT；瞬时接口/监听错误释放后重试，接口获取进线程，后处理只拒当前Huawei future。173 Python／22 Swift；占用UDP5684实测EADDRINUSE只记一次transport_bind，不发送、不停旧监听。B完整构建通过但该阶段未设备追试。证据：`phase17/{full-build-send,build-provenance,transport-conflict,final-state}-redacted.json`。未修改另一任务的AppUpdates；历史上Claude负责限定Swift诊断review，Codex负责UI/Python。不能从ad-hoc签名影响权限的Apple说明直接确认本次原因，未改OS权限数据库。

phase18 用户确认Downloads授权与手机解锁后，重新从最新完整构建复制测试，不换源码engine、不注入命令，核对机器码/冻结engine一致，正常文件夹选择器重选Downloads。双向79 B日文名／空／8 MiB全内容与散列一致；反向三点quarantine、complete=total8,388,687，再收 `(1)`保留原件。首次双方批准主体未观察，不能称自动批准；再次Mac确认实际点击。发送前shared、结束却Everyone，期间非本次操作，原因未定，恢复并读取shared；不能声称整个发送期间始终shared。探索连续失败用1/2/4/8/16/30秒退避并汇总，不取消已进行发送；175 Python／22 Swift通过。证据：`phase18/{full-build-receive,full-build-collision-receive,full-build-send,build-provenance,final-source-manifest,final-state}-redacted.json`。终态IP/en0不变，无鸿蒙星河互联/dev host/engine/nc，持久键0600且不变；安装版观察为Everyone但未改、不恢复未经证实旧值。取消/TCP矩阵未在此完整版重跑。

## 候选UI与本地安装（phase19–21）

phase19 移除名称铅笔，图标右键提供Rename Device／Hide from Candidates，设置Hidden Devices可离线恢复。仅本地aliasKey哈希与展示元数据，不改信任／接收／engine。发现、选择、发送前均过滤；活动tile保留且禁止进行中修改；ID改变可能成为新候选。实候选依次验证右键、重命名、隐藏、重启持久、探索前列表、恢复和再发现，最后恢复原值；26 Swift（新增4）及UI构建/签名/self-check通过，engine同phase18。进行中保留只review，未新增传输测试。证据：`phase19/{native-ui,restart-persistence,build-provenance,final-source-manifest}-redacted.json`。

phase20 原样同捆Huawei官方96px PNG，来源/散列记manifest，实候选红logo+phone角标确认。computer用 `desktopcomputer` / Computer / 电脑，共享模型覆盖候选/历史/记忆/隐藏。合成Huawei/HONOR/Xiaomi PC及Huawei phone图标通过；Huawei type12→computer仍需SHARE bit，phone/pad例外不扩大，不猜HONOR/Xiaomi wire值。176 Python／27 Swift，全构建/签名/self-check/macOS14通过，未试PC硬件或新增传输。证据：`phase20/{verification,final-source-manifest}-redacted.json`。

phase21 用户要求装入现有应用，保留正式bundle ID、Developer ID和designated requirement；phase20 engine重建host/share扩展，无开发Info键。1.1.0及设置备份 `build/local-install-20261017/`；退出时已下载官方1.1.1被应用，又另行备份。全bundle替换 `/Applications/anDrop.app` 为本地1.1.1/build11001，确认host/engine各1、UDP5684、Finder扩展注册、UI新功能、签名及构建一致。接收范围/信任/记忆/别名/共享名/语言/目录/更新设置不变，27条历史按JSON记录相同（编码顺序变）。此阶段无新传输、未发布。证据在该目录 `build-verification-redacted.json`、`installed-redacted.json`、`running-verification-redacted.json`、`share-extension-redacted.json`。

## 照片接收兼容修复（phase22–23）

phase22 用户568,811 B单张接收在批准后ValueError/0 B；原诊断phase被归并／丢弃，不能断言超限。未看私照，用合成JPEG76,263 B通过USB仅准备，再Files→标准分享→LAN探针重现 `unsupported batch preview`。实际tag11=18 B、12=44,849 B、13=78 B；旧版只允许11/12。batch允许有序、不重复11/12/13，13最多8 KiB，保留UTF8/60,000 B缩略图/外帧限制，拒绝未知／空／超长13。先保存后正常byte EOF曾导致失败，改为已认证预览ACK后仅移除帧间正常EOF，部分头/payload仍失败，file DONE ACK必须验证。179 Python／28 Swift通过，固定receive/preview/frame/metadata/data诊断不含原错／图／名字。证据：`phase22/reproduction-summary-redacted.json`、`jpeg-before-fix2-redacted.json`、`jpeg-after-fix-redacted.json`、`jpeg-after-eof-fix-redacted.json`。首次仅保存不算DONE ACK成功。

同正式ID/Developer ID完整build11002安装，保留设置/历史，签名/self-check/macOS14通过。安装本体实际点击“接收”，Downloads76,263 B、全内容/散列/quarantine/complete、手机“已发送”确认；`phase22/native-photo-receive-redacted.json`、`installed-fix-redacted.json`、`final-state-redacted.json`。这是合成JPEG，不是用户原照片复测。

phase23 用户两张1,588,795 B批准约9秒后失败，报告单独不能定位。两份合成JPEG重现：MTU65,536之后无预览、`receive channels response deadline`，手机 `CheckSendLen fail, len=89852`。预览MTU改1 MiB，外帧加28 B GCM，缩略图最多批准件数×60,000 B，其余验证保持。实机预览89,852 B/tag12 89,633 B，两文件共152,526 B、内容/散列/DONE ACK一致。`phase23/{before,after-mtu,probe-integrity}-redacted.json`；181 Python／28 Swift。完整本地build11003安装，旧版验证ZIP备份、正式签名/self-check/模块一致；原私照本体重收仍未证明。

## 文档分类、文件名与保存顺序（phase24–30）

| 阶段 | 修改、结果与边界 |
| --- | --- |
| phase24 / build11003 | PDF被图库打开：command7/tag1 sendType原固定1、tag6件数固定1，改普通文件type3并让tag3/6为实际件数，混合批仍文件。181 Python。安装版直接比对已含修改，未再替换；发现无响应，修后PDF实机未证。`phase24/verification-redacted.json` |
| phase25 / build11004 | tag7 `previewSummary`原是原始首文件名；实机旧SDK处理 `0x1e54d4→0x1e5c94` 需要扩展名计数JSON，如 `{".pdf":1}`。全批计数，小写扩展名，不假冒未知／无扩展名；不是MIME栏。183 Python（Huawei84），签名/self-check/源码一致。仍待实际类型显示。`phase25/package-redacted.json` |
| phase26 / build11005 | 用户仍未知类型；增加byte通道双层加密command8/tag11的 `\|` 连接文件名，核对command1/tag8 previewOK后才继续。184 Python。实机state显示preview ACK/DFile DONE，但用户0件，旧保存目录为空；不能将协议完成称保存成功。`phase26/package-redacted.json`，`phase25/preview-tests.log` |
| phase27 / build11006 | `GetTypeByCount` (`0x1884f8`)启发单件type8、多件3，184 Python。报告中107,735,062 B（102.74 MiB）PDF在preparing前超8 MiB，未发offer，不能判断类型修正。另一个685,593 B PDF仍0件／未知，故type8未解决。`phase27/package-redacted.json`、`reported-failure-redacted.json` |
| phase28 / build11007–11008 | 临时元数据观察Pura→Mac单PDF1,302,264 B、`%PDF-1.7`、Downloads散列。command7 tag顺2/3/4/5/6/7/1，type3，件数1，folder0，tag7扩展名JSON；command8 tag11名字8 B/tag12预览37,226 B，无显式MIME。撤回单PDF=8，恢复3；补鸿蒙星河互联恒发tag13的date_added/date_taken/detail_time缺省-1/-1/空串，不编造时间。1592初值100，否定缺tag8导致0假说。184 Python重跑通过（首次随机CoAP token0xff旧测试偶发UnicodeDecodeError），build11008去临时观察后安装；用户仍0件。`phase28/native-pdf-receipt-redacted.json`、`package-redacted.json` |
| phase29 / build11009 | 手机 `SessionOpenedEvent# in 12 status do not need session opened`：仅state6/8注册file schema。改为file连接+DFile Settings之后、正文头之前发预览，要求前置条件且用byte key `keys[-2]`。185 Python。state12错误不再复现，但Mac拒预览回复，仍未发正文。`phase29/` |
| phase30 / build11010 | 首响应不是previewOK而是command1/tag15头像26,955 B（鸿蒙星河互联 `ISHARE_ECOLOGY_SAVE_AVATER`）。仅双层AEAD通过后有界跳过此项（每项64 KiB，最多读4次），必须等tag8 previewOK，未知/拒绝/busy/改密钥/无ACK仍失败。186 Python。618 B PDF与908 B DOCX实机保存 `Docs/Huawei Share`，手机SHA-256等于Mac；屏幕件数／类型／打开应用未由读盘证明。`phase30/send-state-private.json`、`synthetic-preview-redacted.json`、`synthetic-avatar-fixed-redacted.json`、`synthetic-word-redacted.json`、`receipt-redacted.json`、`package-redacted.json` |

各本地版保存旧bundle并核对同Developer ID／designated requirement、完整签名、engine self-check、安装脚本一致和host/engine各1进程；这些检查不是每种格式的实机证据。phase30发现普通诊断仍未记录临时state的详细失败原因，尚未改善。

## 批准前占位图与原生预览路径（phase31–32）

用户确认build11010 PDF可用PDF应用打开；保存列表PDF／DOCX图标分别正确，Word实际打开编辑未证。批准前“？”文档和“1个文件 | 共374.2 KB”是通用占位，不是未知格式错误。初始command7增加tag11名字的独立618 B试验传输完成但图标无变化，撤回实验，源码恢复安装版一致，未装新版；证据 `phase31/offer-name-experiment.py`、`offer-name-redacted.json`。

旧SDK HuaweiShare.hap 7.0.0.205：`PreviewDialog.getBaseInfo`取previewData JSON前3项；`ReceiveNormalCard.isThumbnailValid`要求非空及 `data:image/...;base64,`，无效固定83886525 `file_placeholder.svg`（问号）。`UtdThumbnails.UNKNOWN`的83886614是另一图，不可混同。旧Apple handler `0x1e5348`处理tag7扩展汇总、11名字、13日期，无tag12分支。实机UI为7.0.0.545，未拿到同版HAP，旧UI条件不能视为全分支实证。

phase32 纠正“系统目录拒绝意味着所有文件不可读”：正常HDC `file recv`成功读已知路径、未提权改设置。

| 实机库 | 字节 | SHA-256 |
| --- | ---: | --- |
| `/system/lib64/libshare_service_plugin.z.so` | 1,835,304 | `681c401dfe48931b8e57c0865a9f2f71a49797541c016412c3206e1d48437468` |
| `/system/lib64/libshare_service.z.so` | 889,096 | `5d8d04dd71916e8938c453cdad1e6c0e4f5ae92950863867ee68f48f2dbd4263` |

实机Apple `HandlePreviewDataCommand` `0x16c134`只接字符串tag2/7/10/11/13，无12/68；后续 `HandlePreviewRecvInfo` `0x16b5e0`只11/13。不能在这两处添加图片字段就宣称可用，也不能推论所有Apple路径都无图片输入。

标准RecvSessionV1：`PackSendPreview` `0xb71d0`打包tag68，`HandleBytesDataString` `0xd1cfc`存receiver+1504，`ProcessRecvPreview` `0xd12c4`送RecvPreview+64 previewData。候选格式 `[{"thumbnail":"data:image/png;base64,..."}]`，不是扩展名／MIME。`scripts/research/huawei_preview_dispatch.py`用Unicorn执行真实限定AArch64片段：Apple初始／后续全256tag与标准68共513分支，132 B合成1px PNG JSON正确复制。C++字符串操作为stub，不含完整服务／IPC／UI／认证。

ShareReceiver选择envelope101→Apple、100且transType0–2→标准；初始command192/tag215是十进制transType，不是文件类别。标准 `IShareAuthSession` opening得module8/CODE4/API2/MTU39968；module100/192/tag215=0被实机log识别。能力tag234=0/215=0/213=1/211=31得到tag234=15和tag212长21 B两响应，只记tag/长度；能力全含义未知。随后protocol0/tag16公钥在state1不处理，静态需state2；不是替换Apple密钥流程就可工作。额外初始通知仍未到state2，未发文件名/图片/正文。anDrop占5684时并行CoAP5685仅ACK，故对明确已知目标端口另行opening验证，不称新发现。

`huawei_standard_capabilities.py`只复现opening/能力，最多两响应，不含账号/持久配对/密钥文件/预览/传输。证据 `phase32/{dispatch-emulation,standard-opening-redacted,standard-knock-redacted,standard-capabilities-redacted,standard-capabilities-public-key-redacted,standard-file-session-public-key-redacted,standard-capabilities-repro-redacted,native-runtime-evidence-redacted,final-audit-redacted}.json`。名称含public-key不等于已发送，字段无 `public_key_sent` 的那次没有发送。验证513分支、脱敏、5种坏响应、语法/diff，安装build11010源码一致，研究nc退出。

## 照片分类与复原照片接收（两条 phase33–34）

图标调查phase33：用户06:02绿色图片与06:59问号（均1件374.2 KB）符合sendType1→3变化。实机native `ProcessRecvPreview`从 `0x16d9c0`把3/4/8→file，1→`0x16dc70/0x16dd14` SendBean，4个离线实际分支通过。旧UI中IOS+SendBean且previewText JSON失败时设 `isAllImageVideo=true`；SendBean是字符串，不是wire数字1。无thumbnail的媒体用83886599 `ic_file_image.svg`（绿 `#70df66`–`#4eba45`），普通文件用83886525。所以绿色不是实际缩略图证明，问号也不是文本分类。

旧UI `createFileShowInfo`先JSON.parse/Object.values成功有记录才用previewTextSummary或mime_type。名字和类型独立：receiver+1400→RecvPreview+88 allFileNameData，+1584→+112 previewInfo；serializer `0x182f14/0x182f24`分别标注。tag13 `ParseMediaInfo` (`0x19b430→0x13592c`)构造日期map，不是previewText生成。把名字改JSON或加初始tag11不能设置previewInfo；该阶段未改产品。

图标实现phase34 / build11012：仅全照片扩展名JPEG/PNG/HEIC/HEIF/AVIF/WebP/GIF/BMP/TIFF→type1，MOV/MP4/M4V/WebM等video单列，视频/文档/混合/未知→type3及真实扩展计数。大小写不敏感、用最后扩展名，不查内容、不生成缩略图、不猜video wire2、不拆批；保留file注册/command8顺序、日期和正文。90项Huawei测试，通过复制旧11011，仅换动态加载Python模块与build号，self-check/同签名/designated requirement/源码一致后安装11012。此阶段未实测图标／保存。证据 `phase34/`。

接收修复phase33 / build11011：复原照片receive_preview失败，但同时间另一张complete，不能断言照片损坏或复原导致。旧batch强制非空tag12却自身普通文件发11/13不一致，改可省略／为空12/13，保留名字非空UTF8≤1024、缩略图60000×件数、日期8192、顺序/重复/未知/外帧/全部DFile检查；固定fixture不改。188 Python通过；复制build11010仅换明文模块及build、同签名/self-check后装11011；原照片成功未证。`phase33/package-redacted.json`、`python-tests.log`。

接收诊断phase34 / build11013：用户重试report ed9229b9仍失败，未解决。不再猜上限；新增固定previewIssue=`field_layout/name_size/thumbnail_size/metadata_size/repeated_preview`，previewFields只记最后认证command8的tag/字节数；Python/Swift均最多32项，tag0–255/bytes0–1MiB，丢值/名字/图/额外键，兼容旧报告。191 Python／29 Swift。安装前发现并行11012已安装，保留其余4模块并升11013，确认同签名/self-check/host engine各1。不是解决版；`phase34/package-redacted.json`。

## 标准路径密钥与专用图标调查（phase35–36）

phase35（20:00–20:09 JST）仅临时键和合成元数据，无正文、无手机批准、无设置/账号/联系人/配对改变。`huawei_offer_classification.py`用产品offer测试照片type1、视频type3、混合type3，均密钥成功后 `user_reject`，原因未定，未见图标。标准protocol100/command192内tag193=3触发tag195 `CMD_CAN_CONTINUE_CONNECT`；tag194不是认证开始，依据注册 `0x10309c/0x1030a8`及 `HandleAuthSendTypeCommand` `0xc67dc`。

protocol0 tag16公钥→tag17公钥；tag18为OAEP-SHA256/MGF1-SHA256加密nonce16+临时AES32，响应tag23和tag19；用原nonce/临时AES验证48 B tag19，得32 B通信键。**tag23=0是拒绝共享**（`0xbca3c–0xbcb14`），1证书链、2 HiChain、3联系人不匹配。`HandleGetAesKey` `0x113d84`检查可见性并可能查recent/contact。确认含义前曾单次发合成PNG command64，log `Can not get preview data in: 2, try later`，3秒后tag200 senderCancel，无ACK且state14；只证到handler，不证JSON解析/UI/保存。此后仅复现密钥，任何mode均 `sharing_authorized=false`，不再重发未授权预览。

扩展真实片段仿真：标准字符串16分支、state5分支，加原513/4分类分支及132 B复制通过。command64映射：

| tag | 接收字段 | 用途 |
| --- | --- | --- |
| 65 | +1472 | 字符串，非文件名列表 |
| 68 | +1504 → RecvPreview+64 | previewData 图片JSON |
| 71 / 75 | +1424 → +88 | allFileNameData |
| 73 | +1608 → +112 | previewInfo |
| 76 | +1528 → +200 | packageInfo |
| 78 | +1632 → +136 | previewExtra |
| 80 | +736 → +264 | 类型汇总 |

`ParsePreviewData` `0xd3538→0x197980`仅state10/12解析，1/2/14延期。旧UI全图片=ALL_PICTURE，图片+视频或仅视频=PICTURE_AND_VIDEO，均可能绿色占位；文案区分视频不证明图标区分。98 Huawei测试覆盖密钥/授权分离、mode、GCM改nonce/键、重复缺字段/坏帧。安装版此时11013，源脚本一致，未覆盖；证据 `phase35/*-redacted.json`、`dispatch-emulation.json`，所有研究探针退出。

phase36 用现有anDrop RSA只读比较（不借其他应用身份）：只键和加tag22 MetaNode ID均通信键通过但verifyMode0，后者另回tag24 64 B。新增 `--identity-key`／`--send-node-id`，拒symlink/非本人/宽权限/非普通/超8 KiB/非RSA2048，不创建改写。99 Huawei测试通过。现有键Apple照片offer10秒无批准／拒绝、取消ACK也无，不能称图标或成功。DevEco见已解锁主页但通知观察不稳，未改可见性／产品。

旧UI Office资源：Word83886618、Excel83886591、PowerPoint83886608、PDF83886607，仅证明发送缩略图资源定义，不证明接收端按扩展自动选择。video overlay83886084取决 `thumbnails[0].utd` 属于VIDEO。`mime_type`交给 `getUtdBelongsToType`，不应盲当HTTP MIME；资源ID也不是UTD。previewData图片、previewText类型/件数、thumbnail.utd三者独立。

历史Claude只读委派结果经核对才采用：首次绝对“Apple无其他路径”证据不足；“无HiChain”因搜反汇编而非ELF字符串注释错，已纠正。实机 `0x11d494/0x11d498`引用HiChainVerify.cpp，`0x11d4a8/0x11d4ac`引用AuthDevice；`0xbce00`后拒空accountID。不能据此宣称PIN配对或同账号即可工作；peerUserId片段不能给出信任建立流程。记录 `phase36/claude-*.json`，未改产品。

## Everyone、绿色照片图标与证书条件（phase37）

用户确认改Everyone后，同现有anDrop键/MetaNode ID，标准verifyMode从0→1且通信键GCM通过：可见性影响本次拒绝，但mode1只是附加证书验证入口，未发预览／正文。`phase37/everyone-key-exchange-redacted.json`。

同状态下产品offer照片type1通知重试，用户确认许可前为绿色图片图标。`everyone-photo-retry-redacted.json`分别保存探针与用户观察；这是通知分类证明，不是本次保存／内容／视频文档显示证明。研究通知nc期限由8秒改seconds+12以覆盖10秒观察和取消；第二次写出取消但无ACK，未接收或发正文；固定停止原因/语法通过，产品和安装版未改。

`CheckCertChainValid`依次验证root `0x11e6f8`、CA `0x11e704`、chain `0x11e710`、公钥证书 `0x11e72c`，`0x11e754`比证书与CCMP交换公钥。service `ValidRootCert` wrapper `0xb78dc→0x88bc0`创建X509 store，`0x88bf0/0x88c04/0x88c18`加载三根，`0x88c58`校验输入：

| ELF地址 | 根Subject CN |
| --- | --- |
| `0x37741` | Huawei CBG Root CA |
| `0x37436` | Huawei CBG Root CA G2 |
| `0x37eb0` | Huawei CBG ECC Equipment Root CA 3 |

`InitCertChainMode` `0xb78d0→0x89094`在 `0x891b0`调用HksAttestKey。公开根不能给anDrop自身键签证书，独立RSA满足该条件未证；未试自签／借其他应用私钥。`root-store-addresses.json`记录来源。Claude“可见性难以改变mode1”与实测不符不采纳；PLT `0x19af30`实际是 `DiscoverManager::GetDetectableType`，不是未知mode selector。

展开SHT_RELR得AppleRecvSession vtable `0x1a0160`+120 (`0x1a01d8`)→`0x1745b4`，为OnAuthBytesReceived。单个认证回调不能排除其他数据通知；不能把标准证书要求套给已用独立键显示许可前通知的Apple路径。command dispatcher `0x16c6d4`搜session+1672，`0x16c708`比较命令ID与节点。Apple `0x1711b4→0x1711d0`和下级 `0x16c7c4`经表分发，但当时未找到构造。能力项实际4字符串（`0x16c5c8/0x16c60c/0x16c614/0x16c61c`）+2 bool（`0x16c63c/0x16c65c`），不是6 bool。AppleSendSession `0x1687ac/0x1689bc`同offset不是接收表。证据 `apple-vtable-relocations.json`、`apple-bytes-target.txt`、`claude-command-map.json`。

## 接收命令注册表重现（phase38）

`ShareReceiver::Init` `0x1020c4`分配2192 B，allocation+32为AppleRecvSession，`0x1020f4–0x10210c`设已知vtable，证实构造归属。`scripts/research/huawei_command_registry.py`只接受phase32 SHA-256，在Unicorn执行 `0x102238–0x102a34`；stub C++ map/function wrapper/析构，抽取key和handler，不是完整服务／认证／网络／UI。

对象+1736（构造调用 `0x102960`）7项，function wrapper vtable+48指向：

| wire command | 实现 | 功能 |
| --- | --- | --- |
| 1 | `0x16c6d4` | 下级控制表 |
| 2 | `0x16c530` | HandleCompetencyNegoReq |
| 4 | `0x16c3cc` | HandleNetworkinfoNegoReq |
| 7 | `0x16c128→0x16c134` | 初始预览／接收确认元数据 |
| 10 | `0x16beb0` | HandleLogicalConnectionInfo |
| 8 | `0x16b5e0` | 文件名／日期 |
| 11 | `0x16b4a4` | HandleCertifyInfo，OpenIdHash→session+920 |

command10 sub1/2→内部601/610 (`0x16bf40–0x16bfd4`)，11仅sub1 (`0x16b518–0x16b598`)，不是新图片输入。command2四字符串两bool，4网络字符串。已遍历tag的7/8之外未发现新图片／previewInfo写入。

对象+1664、root+1672控制表：2→`0x16c7ec` senderCancel；10→`0x16c8bc`传输错；5→`0x16c9f8`接收取消ACK；12→`0x16caa0`发送取消完成；13→`0x16cb48`物理信息请求；16→`0x16cd4c`认证keep-alive。对象+1760的2/4/7/8/11是字段处理后的结束回调。7结束 `0x16b134`设state10并发内部事件11，+1360表将其映射 `0x16d758 ProcessRecvPreview`。+1360共45内部事件，不能当wire命令发送。

7个vtable手读与仿真一致，抽取6控制/45事件/5结束回调；改1 B二进制执行前拒绝。证据 `phase38/registry-emulated.json`、`validation.json`、`claude-map.json`。Claude的key/ADR地址一致，但将+1360称level-one、+1736/+1760称非command map与执行链矛盾，不采纳。DevEco mirroring准备未取到手机画面、坐标报noWindowsAvailable，关闭菜单恢复IDE；无新通知／文件、不启鸿蒙星河互联。

已解决构造表未知，未解决专用图标。绿色是type1默认图，不是PDF／Office／视频预览。该构造表未发现额外图片输入，不等于其他实现／新版／后续注册绝不存在。下一证据应为正当认证标准路径自身键的方法，或鸿蒙星河互联→同手机确有专用图标及其发送结构；不追加猜测MIME/tag、不暴力试种别、不替换产品。

## 大容量 Mac→Huawei 发送（2026-10-17）

发送从各8 MiB／合计16 MiB扩为各4 GiB／合计16 GiB、最多16件。此阶段接收仍各8 MiB／合计16 MiB；之后发行接收上限见[使用说明](usage.md)，不可混同历史与当前。

1 MiB读块生成独立磁盘snapshot，worker按1,422 B加密发送，不整文件转bytes；检普通文件/冲突/大小/复制变化，准备取消等复制结束清理。实验sequence<16384限制改wire uint32，公开头blockSequence32位、文件大小64位。60秒改无写入进展上限，维持辅助通道、发送时读ACK避免nc stdout填满双向阻塞，正文中更新进度。

64 MiB socketpair逐块GCM/散列一致，覆盖32位sequence、超128 ACK、分片头、模拟总时长超60秒，Python跟踪内存<16 MiB；32 MiB snapshot<8 MiB。疏文件提前拒各>4 GiB/总>16 GiB；检复制前限额、准备取消、源文件变化后snapshot独立及snapshot修改拒绝。209 Python／29 Swift通过。只证明本机实现与内存，不证明Pura64 MiB或GiB落盘；大容量实机内容验证未完成。

## 复现、公开接口与下一步

```sh
python scripts/huawei-lan-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --private-endpoint build/huawei-research/peer-private.json
python scripts/huawei-auth-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --port '<fresh advertised port>' --capabilities --public-key --key-challenge
python scripts/huawei-share-probe.py --seconds 15
python scripts/huawei-share-probe.py --seconds 15 --advertise
python scripts/huawei-share-probe.py --private-targets build/huawei-targets-private.json
python scripts/huawei-share-probe.py --seconds 8 \
  --connect-target '<current endpoint>' --inspect-share --notify-only
python scripts/huawei-transfer-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --port '<fresh advertised port>' --seconds 60 --network-lan --send-large-fixture \
  --output build/huawei-research/large-send-redacted.json
python scripts/huawei-transfer-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --port '<fresh advertised port>' --seconds 60 --network-lan --send-large-fixture \
  --cancel-after-chunks 64 --cancel-via-bytes \
  --output build/huawei-research/cancel-bytes-redacted.json
python scripts/huawei-transfer-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --port '<fresh advertised port>' --network-lan --send-file '<file1>' --send-file '<file2>' \
  --output build/huawei-research/batch-send.json
python scripts/huawei-receiver-discovery-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --seconds 60 --accept-files --output build/huawei-research/batch-receive.json
python3 scripts/research/huawei_standard_capabilities.py \
  --peer-ip '<current phone LAN IP>' --port '<confirmed advertised port>' \
  --output build/huawei-research/phase32/standard-capabilities-repro-redacted.json
build/huawei-research/phase32/venv/bin/python scripts/research/huawei_preview_dispatch.py \
  build/huawei-research/phase32/libshare_service_plugin.z.so \
  --output build/huawei-research/phase32/dispatch-emulation.json
```

BLE默认不读写、订阅、配对或传文件，不输出名字/地址/raw payload。`--inspect-share`才读订阅2B00/2B01并只记长度，`--notify-only`省读；`--serve-discovery --advertise`公开空临时GATT，只记访问次数／长度。`--advertise`临时公开 `anDrop H Probe`，不是传输服务；退出停止。`--private-targets`显式0600保存endpoint。仿真需研究venv装Unicorn和本地匹配库，不随产品分发。

DevEco `@hms.collaboration.harmonyShare.d.ts` 的 knockShare/gesturesShare/dataReceive/SharableTarget.share是HarmonyOS应用API，不是Mac互联SDK。部分系统扩展需 `ACCESS_INSTANTSHARE_PRIVATE_ABILITY`，并非所有公开Share Kit API都需该权限。HAP、modules.abc/resources.index仍拒绝；两个库可按已知路径正常读取。旧Share Engine codelab面向Android/Linux/Windows/EMUI，不能当HarmonyOS7/macOS独立客户端SDK证据。

实现目标是anDrop↔标准华为分享，无鸿蒙星河互联运行／库／安装依赖，不用额外手机应用替代互通。UI复用Finder、菜单栏、候选、批准、进度、历史、保存；发现/认证/帧/LAN/DFile单独分流。先同LAN，不切SSID/建热点/高速回退。继续分别验证：锁屏BLE唤醒、长期对端身份、产品取消消息、Wi-Fi离开恢复、从未安装鸿蒙星河互联的Mac、大容量实机保存、专用图标。协议、发现、授权、落盘、内容、发行各自举证，不把合成peer、USB准备、GATT连接或密钥协商当完整互通。

公开参考（原调查引用，本文整理未重新联网验证）：[Huawei Pura与Apple共享](https://consumer.huawei.com/cn/support/content/zh-cn16090700/)、[鸿蒙星河互联步骤](https://consumer.huawei.com/en/support/content/en-us16107421/)、[App Store](https://apps.apple.com/in/app/petal-interconnect/id6775134178?platform=vision)、[旧Windows Codelab](https://developer.huawei.com/consumer/cn/codelab/ShareKit-Windows/)、[DSoftBus](https://github.com/openharmony/communication_dsoftbus)、[CoAP RFC7252](https://www.rfc-editor.org/rfc/rfc7252)、[DFile参考](https://github.com/openharmony/communication_t2stack/tree/31448e0839d111ff99213c7de15aea6622e7c300)、[SoftBus设备种类](https://github.com/openharmony/communication_dsoftbus/blob/master/interfaces/kits/lnn/lnn_device_info_struct.h)、[TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)、[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。

公开DFile头/实现用于比对Settings/头/DATA/DONE、16 B TCP头与opening响应，非产品新增依赖；本地checkout位于ignored研究目录。
