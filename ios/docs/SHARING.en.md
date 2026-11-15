# Sending from the share sheet

[简体中文](SHARING.md) · English

Since 0.3.0, anDrop imports files shared by Files, Photos and other apps. Since 0.4.0, iOS 26 or later hands off to the main app for continued background processing.

1. Open the main app first, allow Bluetooth and Local Network access, and connect both devices to the same Wi-Fi.
2. Select files / photos in another app and share to anDrop. Scroll the recipient row or open More if it is not visible.
3. Check imported names and types, then choose a recipient. Alliance recipients must enable visible sharing.
4. On iOS 26 or later, choose “準備を完了” and manually open the main app to start. If it is already visible in iPad Split View, choose “準備済みの送信を開始” there.
5. The recipient approves transfer. Once it starts, switching apps is supported. Wait for peer completion confirmation rather than treating transmitted bytes alone as success.

Older systems require completing the transfer inside the open extension; closing it during transfer cancels it. The extension only sends; open the main app to receive. Huawei endpoints registered by IP in the main app are also checked, but [Huawei sending remains experimental and hardware-unverified](HUAWEI.en.md).

The limit is 16 files / 64 MiB of original data. Folders, URL/text objects and dedicated Live Photo pair conversion are unsupported; text files can be shared as files. Declared file/image/movie activation types control extension visibility, while every imported item is validated separately.

Provider file URLs take priority and are copied before temporary-URL callbacks return, preserving names and bytes. File/data representations and bounded legacy item fallback are supported. Collisions rename private copies only. Late callbacks cannot recreate preparation after cancellation. The iOS 26 handoff copies into the private App Group and does not depend on provider temporary files remaining present.

“診断ログをコピー” copies bounded extension diagnostics; scroll down if necessary. Counts and known stages are recorded before import succeeds. Errors contain limited reasons / codes, excluding paths, filenames, contents, IPs, keys and unknown error descriptions. The user chooses whether to send diagnostics.

See [background transfers](BACKGROUND.en.md) and [validation scope](VALIDATION.en.md).
