# Usage and troubleshooting

[简体中文](usage.md) · English

## Send and receive

Enable Bluetooth and Wi-Fi on both devices and join the same local network. Receiving is enabled whenever anDrop is running. Quit anDrop to stop receiving.

To send from the Mac, select files in Finder → Share → anDrop, choose the receiving device and approve there. If the extension is not visible, open anDrop once and enable its Share extension in macOS settings. The menu bar's Send Files action is also available.

To receive, select files in the device's built-in compatible 互传 feature, choose the Mac and approve the request in anDrop's notification or menu bar. The default destination is Downloads itself. Files are not opened automatically.

Folders should be compressed first. Send files with identical base names in separate transfers. Outgoing transfers to different devices can run concurrently. Receiving remains exclusive. Notification banners follow macOS notification and Focus settings; progress and approval remain available in the menu bar.

## Recognizing recipients

The recipient grid uses an official brand logo in a circle with a phone/tablet badge and the sharing name below it. A sharing name can be the account holder's name and can be identical on several devices. The badge uses explicitly recognized advertisement metadata; unknown manufacturers or types remain generic. A tooltip and accessibility label also include the device category. This is not exact model identification.

Use the device icon context menu → **Rename Device…** to give a device a local name such as “Work phone” or “Travel tablet”. Names may contain up to **40 characters**, including Chinese characters; the edit dialog states the limit. Leave the field empty to return to the advertised sharing name. The name stays on this Mac and does not rename the Android device or its account.

If the sharing name and device category are both identical, a short device code appears. Make only one device discoverable initially if you need to identify which physical device to name. Devices are never merged merely because their account names match.

For the examined version-11 advertisement, the app uses its advertised device ID and refreshes the current Bluetooth connection endpoint. This prevents temporary duplicate rows when a Bluetooth address changes. Other formats fall back to the Mac's Bluetooth identifier. If the underlying device ID changes, the alias may need to be entered again; the app does not guess a match from an account name. Advertised IDs are not authentication and never grant automatic acceptance. Outgoing transfer history uses the selected name and device category; incoming requests retain the sender's own sharing name.

## Device name limit

The default name follows macOS Computer Name. Nearby names have a **15 UTF-8 byte** limit: up to 15 ASCII characters, typically 5 Chinese characters, or fewer emoji. Shortening preserves complete characters. Click the pencil beside the nearby name in Settings to set a custom sharing name of up to 15 UTF-8 bytes. Leave it blank to restore the system name; this does not rename your Mac. Transfer confirmations use the full sharing name. The settings UI also explains this limit.

## Device not found

Unlock the receiving device, enable its sharing feature and check discoverability. Some phones limit visibility to contacts/own devices or turn off everyone-visible mode automatically. The tested OPPO offers **Everyone (10 minutes)**. Expiry can explain the phone disappearing from the Mac's recipient list; re-enable visibility when needed.

This is different from the phone being unable to find the Mac because another Mac app interferes with anDrop's Bluetooth advertising. Also check the same Wi-Fi, Bluetooth, Local Network permission, and whether the network isolates clients.

## 鸿蒙星河互联

**We recommend quitting 鸿蒙星河互联 before sharing with anDrop.** anDrop can replace 鸿蒙星河互联's Huawei Share file-sharing function and send and receive files independently. Finish any transfers in 鸿蒙星河互联 before quitting it, then retry in anDrop.

Coexistence remains experimental. macOS may merge Bluetooth advertising data from multiple apps, causing anDrop's name to disappear. Transfers have succeeded, but conflicts can recur after app updates or restarts. When a send or receive fails and 鸿蒙星河互联 is still running, anDrop shows a popup recommending that you quit 鸿蒙星河互联 and try again. It does not quit 鸿蒙星河互联 automatically, and the recommendation does not establish that 鸿蒙星河互联 caused that failure.

While 鸿蒙星河互联 runs, anDrop shortens its discovery name to **A** and keeps a Dock icon. Once 鸿蒙星河互联 quits, anDrop returns to menu-bar-only operation and its normal nearby name.

If you need to keep both apps running, **Settings → Repair Discovery with 鸿蒙星河互联** restarts 鸿蒙星河互联 and re-registers anDrop's advertisement. Finish active 鸿蒙星河互联 transfers first because restarting can interrupt them. anDrop never restarts 鸿蒙星河互联 automatically. Repair does not guarantee recovery; quitting 鸿蒙星河互联 is the recommended approach.

## Privacy on your local network

Nearby devices can see the advertised device name while sharing is enabled. The full Computer Name is used in transfer negotiation. Local transfer history includes peer names and file paths; use Clear History in Settings to remove it. The app does not use a cloud service or analytics endpoint.

## When a recipient disappears

The chooser shows devices with a receiving advertisement heard within the last 10 seconds. It refreshes once per second, so a device normally disappears about 10–11 seconds after its last advertisement. Closing the chooser, switching anDrop off, or a scanner error clears its discovery cache. Reopening starts a fresh search. The screen also clears results if it receives no discovery updates for six seconds (checked every two seconds), or if the sharing service restarts.

A send request rechecks freshness before preparing files; an expired route is not reused. Expiry does not cancel a transfer already started. A device can still go offline between selection and connection, which produces a normal connection error.

anDrop cannot read another device's “everyone for 10 minutes” countdown. It observes Bluetooth advertisements rather than assuming that a device stays visible for a fixed ten-minute period. The exact OS visibility-switch time is not available to the Mac, so removal is not instantaneous.

## Sending progress

Click a recipient to start sending immediately. The share window stays open and keeps other nearby devices clickable. Click another recipient to send the same files there too, even while the first transfer is running. Each recipient has its own progress and result; clicking a started recipient again does not duplicate the send. A blue ring grows clockwise around that recipient's icon, and the percentage appears below its name. The percentage uses bytes written to the outgoing ZIP response, including ZIP overhead, so empty files and batches also have a defined total. It is transport progress, not a measurement of the recipient's disk writes.

Preparing, Waiting and Connecting use an indeterminate ring without a fabricated percentage. After all response bytes have been sent, the ring is full and the status is Finishing until the peer confirms completion. Only then does it say Sent. Failure and cancellation are separate terminal states.

Cancel dismisses the picker before a send starts. During sending, each active recipient has its own Cancel action; **Cancel All** stops all active sends and pending retries. A failed or declined recipient can be retried without resending to successful recipients or interrupting another send. Clicking another window keeps sending in the background; use Show Progress in the menu bar to return. The chosen recipient remains in this transfer view even if it stops advertising. It is a snapshot of the active transfer, not a discoverable recipient available for a new send. Normal discovery still expires independently.

## Share popup behavior

The recipient popup has no title bar or traffic-light window buttons. Its footer has Cancel before sending, Cancel All during sending, and Done after all recipients have a terminal result. Clicking a device starts sending without a separate Send button. Escape performs the same action. While a transfer is active, clicking another window moves the popup into the background and the transfer continues. After all recipients succeed, clicking outside the popup or switching focus to another window dismisses it. Failed and cancelled transfers retain their result until dismissed.

## Receive connection errors

A compatible sender may label the recipient as having rejected a transfer when anDrop aborts after a connection failure. That message alone does not mean the Mac user pressed Decline. anDrop now briefly retries transient failures while opening the initial connection. It does not retry certificate/protocol failures or resume partial files automatically.

If receiving still fails, keep the sender's sharing screen open and verify both devices use the same Wi-Fi, then send again. Notifications show an actionable explanation; local diagnostics identify the failing stage without putting IP addresses or internal Python objects into the notification.

The name is centered below the avatar and wraps to at most two lines. The popup grows to a bounded height, then scrolls only the recipient list with fixed header/actions. The compact rename sheet has no app-icon header. Earlier pencil controls described in [validation](testing.en.md) were replaced by the icon context menu. Hide from Candidates filters only outgoing candidates; Settings → Hidden Devices restores them, including offline records.

## Receive scope and trusted devices

Choose **Trusted Devices Only** or **Everyone** in the menu bar or Settings. Every transfer still requires approval in both modes; trusting a device never enables automatic acceptance.

**Visibility is different from AirDrop Contacts Only.** Other devices can still see this Mac in their sharing picker. **Trusted Devices Only rejects transfer requests from devices that are not in the trusted list; it does not hide anDrop from them.** Trusted devices still require approval. AirDrop Contacts Only performs contact matching before responding during discovery ([Apple Platform Security](https://support.apple.com/guide/security/airdrop-security-sec2261183f4/web)); anDrop’s current alliance discovery uses a public Bluetooth advertisement. See [discovery limits and receive filtering](trusted-discovery.en.md).

Open Settings → **Trusted Devices…** to add devices from previous transfers even when they are offline. New devices need one transfer in Everyone mode first. Device rows use manufacturer artwork with a phone/tablet badge. Verify the requesting device yourself. Different local identifier suffixes distinguish devices with identical names. Remove trust or forget a remembered device at any time.

Alliance devices use a hash of the self-reported protocol sender ID. Huawei devices use a SHA-256 fingerprint of the transfer public key, checked after the peer proves possession of its private key. Neither uses account names, device names or IP addresses for authorization. To enroll Huawei after updating, receive a file in Everyone mode and add its new record; older Huawei history has no key and cannot be migrated. Receive and enroll again if the key or identifier changes. Nearby advertisements remain visible. Trusted-only mode rejects unlisted requests before showing approval or downloading files. Every accepted transfer still requires approval. Removing trust does not interrupt an already-started transfer.

Mac → Huawei sends allow up to 16 files, 4 GiB each and 16 GiB total. Local large-file verification does not establish GiB-scale physical receipt. Huawei receiving currently accepts up to 16 files and 16 MiB total, including a single file up to 16 MiB. This receive limit is separate from the larger outgoing-file limits.

Control Center integration is no longer included. Use the menu bar or Settings for receiving options. The former panel is preserved as an [independent UI prototype](../Prototypes/ReceivePanel/README.en.md), outside the installed app. If an old control remains after upgrading, remove that anDrop item in Edit Controls.
