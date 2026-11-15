# 文件类型与完成判定

简体中文 · [English](FILE-FORMATS.en.md)

0.2.0 起按扩展名声明文件类型。常见格式与 macOS 版使用同一 MIME，其他类型通过 Apple Uniform Type Identifiers 补充；无法具体判断时使用 `file/*`。这不转换文件内容，也不验证文件是否真的符合扩展名。

| 文件／批次 | 声明 |
| --- | --- |
| PDF / TXT | `application/pdf` / `text/plain` |
| JPEG / PNG / HEIC | `image/jpeg` / `image/png` / `image/heic` |
| MP4 / MOV | `video/mp4` / `video/quicktime` |
| MP3 / M4A | `audio/mpeg` / `audio/mp4` |
| Office / 常见压缩文件 | 对应具体 MIME |
| 多个同类型文件 | 同一具体 MIME |
| 不同格式的纯图片／音频／视频 | `image/*` / `audio/*` / `video/*` |
| 混合、不明、无扩展名或 `.bin` | `file/*` |

支持大写扩展名、非 ASCII 文件名及文件名内的 `?` / `#`。分类考虑整批，不只看第一项；`.tar.gz` 保持 gzip 类型，ZIP 文件本身仍声明为 ZIP。

互传准备阶段确定 MIME、件数和原始总大小。接收确认前的 BLE `type` 与 WebSocket `sendRequest.mimeType` 使用相同值；HTTP `/download` 的 `Content-Type` 仍是 `application/zip`，因为实际载体是 ZIP。原始名称、扩展名与内容不转换。华为使用[独立的类型摘要与 DFile 路径](HUAWEI.md)。

对方申报类型仅供显示，不代替 ZIP 路径、数量、大小、CRC 和保存后 SHA-256 检查。收到的文件和链接不会自动打开。

进度使用实际 ZIP 字节，可能与原始大小不同；未知 HTTP 长度时只显示已接收字节，不猜比例。字节发送完成后仍需对方完成通知。合法完成通知只处理一次，不因随后正常断开撤销成功；无法确认完成时明确区分。

自动测试覆盖 PDF、图片与混合批次的声明、实际 TLS / WebSocket / HTTP ZIP、原名、件数、大小、内容、进度与完成。对方许可界面的图标、图库登记、编解码器及 Live Photo 解释仍需相应实机测试；普通双向传输成功不代表这些行为已全部验证。
