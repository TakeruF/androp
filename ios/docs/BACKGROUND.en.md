# Background transfers and progress

[简体中文](BACKGROUND.md) · English

Since 0.4.0, iOS / iPadOS 26 or later uses `BGContinuedProcessingTask` to continue already-started transfers when permitted by the OS and report actual bytes and state through the system Live Activity. Supported iPhones can show it in Dynamic Island. No remote notifications or dedicated server are involved.

## Starting and finishing

Sending submits continued processing when the user selects a recipient. Receipt submits it after the user chooses “受信する”; the app never grants incoming approval automatically in the background. A short UIKit background-execution allowance protects setup handoff. Once transfer starts, the user can go Home or switch apps.

Progress comes from actual transferred bytes, never elapsed-time estimates. Finishing ZIP transmission still requires peer confirmation, while receipt still requires integrity checks; neither is considered successful before these finish. The system stop button, expiry notification or force-quitting the app ends the transfer. The OS controls presentation update frequency.

## Share sheet

1. Share from Files, Photos or another app to anDrop and choose a recipient.
2. After “anDrop本体を開くと送信を開始します”, choose “準備を完了”.
3. Manually open the main anDrop app to start sending, then switch apps if desired.
4. If the main app is already visible in iPad Split View, use “準備済みの送信を開始” there.

This version does not depend on the extension opening the main app automatically. The extension copies files to one private App Group handoff slot, preserving transport and routing identifiers. The main app validates files, count, size, names and job ownership, then confirms the recipient again. Cross-process Alliance matching uses the discovery identifier, not an assumption that Bluetooth UUIDs match between processes.

Only one handoff may be prepared. Closing sharing without a selected recipient removes that draft. Completion, failure or cancellation removes that job's private copies; stale preparation is cleaned on later use. Original files selected in the main app remain available for resending.

## OS limits and validation

If continued processing is denied, the app asks the user to keep it open. Systems before iOS 26 use foreground transfer, including an open sharing extension. This is not a permanent background discovery or receiving service.

Each task registers its full unique identifier under the permitted wildcard prefix. State and terminal changes update system progress; ordinary byte updates are throttled to about four per second. See [Apple's continued-processing documentation](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados).

`scripts/test-background-device.sh` reads the team from `ANDROP_DEVELOPMENT_TEAM`. It tests sending, approval followed by background receipt, and sharing handoff with synthetic 20 MiB TLS traffic within the device. It does not operate OPPO / Huawei. On exit it restores normal launch and removes the test helper and runner without deleting user history or files. Run it only when intentionally testing an unlocked device.

An earlier iPhone 16 development build showed real byte progress and completed in the background. Final hardware verification of the latest paths is still pending; Huawei background interoperability remains unverified. See [validation scope](VALIDATION.en.md).
