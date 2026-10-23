# 诊断报告：开发者说明

简体中文 · [English](diagnostics.en.md)

此功能从 1.0.1（10006）开发构建引入，随 1.1.0 首次公开发布。失败通知和设置可导出结构化 JSON 报告，并通过系统邮件共享服务创建带附件的反馈草稿。用户自行检查、补充和发送；应用没有自动上传日志的入口。

## 字段与采集边界

- `appVersion`、`macOS`、`architecture`：生成报告时的应用版本、Mac 系统版本与架构。
- `events`：时间、传输方向、状态、阶段、允许的错误代码／异常类型及 errno。未导出任意原始错误文本或协议消息。
- 接收网络协商仅保留 `networkMode`（`lan`／`direct`）及本次传输标识；连接尝试保留有界的 `attempt`（1–4）。连接错误缺少数字 errno 时，`connectionIssue` 可区分 `local_address_family_mismatch`、`multiple_socket_errors`、`interface_unavailable` 或 `errno_unavailable`。这些是固定诊断分类，不代表已确认某个网络或应用导致失败；不记录地址、网络接口名称或原始异常文本。
- `control_message.messageType`：只保留 WebSocket 帧的固定类型，如 `text`、`binary`、`close` 或 `error`。`control_action.protocolAction` 只保留 `wlanBandwidth`、`versionNegotiation`、`sendRequest`、`status`，其他动作归为 `other`；不保留消息正文。
- `send_offer_fields.offerFields`、`offerKind`：只记录 BLE 网络协商中出现的允许字段名，以及 `lan_request`／`lan_accepted`／`lan_rejected`／`direct_request`／`reuse_request`／`other` 分类。字段名如 `ip`、`ssid`、`psk`、`key` 可以出现，但它们的值不会记录。未知字段名丢弃，不把远端自定义文本作为诊断字段。
- 错误类型进一步区分 `TypeError`、`UnicodeDecodeError`、`ConnectionTimeoutError`、`SocketTimeoutError`、`ClientConnectionResetError` 等固定类型；未知类型仍为 `OtherError`。这些分类用于区分协议帧处理、连接和读取超时，不自动判定 VPN 或其他互联软件是原因。
- Live Photo 接收转换只记录 `live_photo_converted`／`live_photo_conversion_failed` 固定结果代码，不记录文件名、路径、标识、图像、视频或原始转换错误。接收原文件保留，转换失败不会删除它们；转换结果代码也不等于已经在照片图库或其他手机上验证可播放。
- `context.fileTypes`、`fileCount`：扩展名分类与文件数量。未知扩展名归为 `other`，不导出原文件名。`fileTypesScope` 区分 `all_files`、`first_file_only`、`not_available`；多文件接收尚未取得完整文件列表时，不将首个文件当作全部类型。
- `peerBrand`、`peerKind`：协议提供的厂商与手机／平板分类；没有数据时为 `unknown`。
- **`peerOS` 固定为 `not_provided_by_protocol`**：当前互传通信没有提供对方 Android／ColorOS 等系统的版本。协议版本不是系统版本，不可用于推断。面向用户的邮件模板请求填写“接收端系统及版本（如知道请填写）”，不在设置说明中展示此实现限制。
- `appsAtStart`、`appsAtFailure`：宿主首次观察到本次传输及失败时，Mac 上运行的应用名称和 bundle ID。使用 NSWorkspace 的应用列表，排除 activationPolicy 为 prohibited 的后台进程；这不是完整进程清单，不含命令行、可执行路径或窗口标题。同名同标识去重，最多 200 项。若首次观察就是失败，两个采样时点可能一致。
- `selectedTransfer`：单次传输的随机标识，不是设备身份。报告不含信任标识、设备名称、文件名／内容、网络地址或密钥。失败快照也可能包含附近时间其他传输的已过滤事件，但不包含它们的设备信息或应用采样。

应用仅导出新建的结构化诊断报告，不附加旧的 status／last-transfer／last-protocol 原始文件。保留最近 300 条事件、20 次失败快照与 10 份导出报告；目录权限 0700、报告文件权限 0600。文件位于用户 Application Support 下的 anDrop/Diagnostics。清除传输历史不会清除诊断目录；可从诊断界面的访达入口自行管理。更早或旧版本的失败可能没有日志，`detailedLogAvailable` 会明确标记。

邮件模板包含问题与复现步骤、预期结果、接收端设备型号、系统及版本、VPN／手机互联类应用使用情况。自动附件包含运行应用清单，因此界面与邮件都要求发送前检查。邮件服务不可用时保留报告，并提示手动附加到发给 support@takeruf.com 的邮件。

旧报告可能包含 `live_photo_imported`／`live_photo_import_failed`。当前接收仅保存 `.pvt` 文件，不自动导入“照片”。OShare ZIP 转换成功后删除传输压缩包，清理失败仅记录 `live_photo_cleanup_failed`，不含路径或原始错误文本。
