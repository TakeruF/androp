# File types and completion

[简体中文](FILE-FORMATS.md) · English

Since 0.2.0, types are declared from extensions. Common formats use the same MIME types as macOS; Apple Uniform Type Identifiers supplement others. Unknown / generic binary data uses `file/*`. This neither converts content nor proves that bytes match the extension.

| File / batch | Declaration |
| --- | --- |
| PDF / TXT | `application/pdf` / `text/plain` |
| JPEG / PNG / HEIC | `image/jpeg` / `image/png` / `image/heic` |
| MP4 / MOV | `video/mp4` / `video/quicktime` |
| MP3 / M4A | `audio/mpeg` / `audio/mp4` |
| Office / common archives | Corresponding concrete MIME |
| Multiple files of one type | The same concrete MIME |
| Different formats, all image / audio / video | `image/*` / `audio/*` / `video/*` |
| Mixed, unknown, extensionless or `.bin` | `file/*` |

Uppercase extensions, non-ASCII names and `?` / `#` inside filenames are supported. Classification considers the whole batch, not just its first item. `.tar.gz` stays gzip; a ZIP file is still declared ZIP.

Alliance preparation fixes the MIME, count and original total size. BLE `type` before approval and WebSocket `sendRequest.mimeType` use the same value. HTTP `/download` retains `Content-Type: application/zip` because the carrier is ZIP. Original names, extensions and bytes are preserved. Huawei uses a [separate type summary and DFile transport](HUAWEI.en.md).

Incoming declarations are advisory, not a substitute for ZIP path, count, size, CRC and saved-file SHA-256 checks. Received files and links are never opened automatically.

Progress uses actual ZIP bytes and can differ from original size. Unknown HTTP length shows received bytes without a guessed percentage. Sending the last byte still requires peer completion notification. Valid completion is processed once and is not reversed by a later normal close; unconfirmed completion is distinguished.

Automated tests cover PDF, image and mixed-batch declarations, real TLS / WebSocket / HTTP ZIP traffic, names, counts, sizes, content, progress and completion. Peer approval icons, gallery registration, codecs and Live Photo interpretation require hardware testing. Ordinary bidirectional transfer success does not establish all these behaviors.
