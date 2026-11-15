# OPPO and iPhone / iPad hardware validation

[简体中文](OPPO-TESTING.md) · English

Run hardware operations only when intentionally arranged by the tester. This uses Alliance sharing, not Huawei Share. Start with a small synthetic text file, then expand formats and size. Each batch permits 16 files / 64 MiB of original data. One success does not establish every model or format.

## Preparation

- Enable Bluetooth and connect both devices to the same Wi-Fi. Guest networks / AP isolation can prevent device communication.
- Allow anDrop's Bluetooth and Local Network access. Enable OPPO sharing and visibility, temporarily choosing Everyone if needed.
- Keep the main app in front through discovery and approval. Stay in front throughout on systems before iOS 26 or when continued processing is unavailable.

## Both directions and content

iPhone → OPPO: create a sample in the main app or select explicit files, choose the recipient and approve on OPPO. Check completion acknowledgment and the recipient's saved names, sizes and contents.

OPPO → iPhone: choose anDrop through standard sharing, press “受信する”, then inspect Received and SHA-256. Receiving a duplicate name must preserve the existing file. Check that rejection and cancellation permit later retry.

Then test images, video, PDF / Office, unknown extensions and mixed batches separately, recording peer icons and gallery behavior. Transmitting every byte is not completion: wait for a valid completion message and independently inspect peer-side saving.

## Background and sharing

After sending starts or receipt is approved, go Home during data transfer. Check system progress, Dynamic Island / Lock Screen presentation and actual completion. Force-quitting is not an ordinary background switch; it cancels transfer.

Share-sheet sending uses recipient selection → “準備を完了” → open the main app. In iPad Split View with the main app already visible, use “準備済みの送信を開始”. Then test switching apps, the system stop button and retry.

`background_progress` reports actual background bytes; `background_transfer_finished` records background state and success at completion. Events with `verification=local` are development-only local traffic, not physical OPPO results.

## Recording results

Record direction, models / OS, app version, file count / total size, final stage and both endpoints' results. Keep raw diagnostics, captures, screenshots and real files in private testing storage, outside public commits. Publish reviewed model / software / result summaries only; see [validation](VALIDATION.en.md).
