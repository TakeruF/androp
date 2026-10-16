# Usage and troubleshooting

## Send and receive

Enable Bluetooth and Wi-Fi on both devices and join the same local network. Receiving is enabled whenever anDrop is running. Quit anDrop to stop receiving.

To send from the Mac, select files in Finder → Share → anDrop, choose the receiving device and approve there. If the extension is not visible, open anDrop once and enable its Share extension in macOS settings. The menu bar's Send Files action is also available.

To receive, select files in the device's built-in compatible 互传 feature, choose the Mac and approve the request in anDrop's notification or menu bar. The default destination is Downloads itself. Files are not opened automatically.

Folders should be compressed first. Send files with identical base names in separate transfers. One transfer runs at a time. Notification banners follow macOS notification and Focus settings; progress and approval remain available in the menu bar.

## Recognizing recipients

The recipient grid uses an official brand logo in a circle with a phone/tablet badge and the sharing name below it. A sharing name can be the account holder's name and can be identical on several devices. The badge uses explicitly recognized advertisement metadata; unknown manufacturers or types remain generic. A tooltip and accessibility label also include the device category. This is not exact model identification.

Use the pencil button or right-click → **Name on This Mac** to give a device a local name such as “Work phone” or “Travel tablet”. Names may contain up to **40 characters**, including Chinese characters; the edit dialog states the limit. Leave the field empty to return to the advertised sharing name. The name stays on this Mac and does not rename the Android device or its account.

If the sharing name and device category are both identical, a short device code appears. Make only one device discoverable initially if you need to identify which physical device to name. Devices are never merged merely because their account names match.

For the examined version-11 advertisement, the app uses its advertised device ID and refreshes the current Bluetooth connection endpoint. This prevents temporary duplicate rows when a Bluetooth address changes. Other formats fall back to the Mac's Bluetooth identifier. If the underlying device ID changes, the alias may need to be entered again; the app does not guess a match from an account name. Advertised IDs are not authentication and never grant automatic acceptance. Outgoing transfer history uses the selected name and device category; incoming requests retain the sender's own sharing name.

## Device name limit

The default name follows macOS Computer Name. Nearby names have a **15 UTF-8 byte** limit: up to 15 ASCII characters, typically 5 Chinese characters, or fewer emoji. Shortening preserves complete characters. Click the pencil beside the nearby name in Settings to set a custom sharing name of up to 15 UTF-8 bytes. Leave it blank to restore the system name; this does not rename your Mac. Transfer confirmations use the full sharing name. The settings UI also explains this limit.

## Device not found

Unlock the receiving device, enable its sharing feature and check discoverability. Some phones limit visibility to contacts/own devices or turn off everyone-visible mode automatically. The tested OPPO offers **Everyone (10 minutes)**. Expiry can explain the phone disappearing from the Mac's recipient list; re-enable visibility when needed.

This is different from the phone being unable to find the Mac because another Mac app interferes with anDrop's Bluetooth advertising. Also check the same Wi-Fi, Bluetooth, Local Network permission, and whether the network isolates clients.

## Petal Interconnect

Concurrent discovery remains experimental. macOS may merge Bluetooth advertising data from multiple apps, causing anDrop's name to disappear. Transfers have succeeded, but the conflict can recur after app updates or restarts.

While Petal runs, anDrop shortens its discovery name to **A** and keeps a Dock icon. Once Petal quits, anDrop returns to menu-bar-only operation and its normal nearby name.

**Settings → Repair Discovery with Petal** restarts Petal and re-registers anDrop's advertisement. Finish active Petal transfers first because restarting can interrupt them. anDrop never restarts Petal automatically. Repair does not guarantee recovery; quitting Petal while receiving is the current fallback.

## Privacy on your local network

Nearby devices can see the advertised device name while sharing is enabled. The full Computer Name is used in transfer negotiation. Local transfer history includes peer names and file paths; use Clear History in Settings to remove it. The app does not use a cloud service or analytics endpoint.

## When a recipient disappears

The chooser shows devices with a receiving advertisement heard within the last 10 seconds. It refreshes once per second, so a device normally disappears about 10–11 seconds after its last advertisement. Closing the chooser, switching anDrop off, or a scanner error clears its discovery cache. Reopening starts a fresh search. The screen also clears results if it receives no discovery updates for six seconds (checked every two seconds), or if the sharing service restarts.

A send request rechecks freshness before preparing files; an expired route is not reused. Expiry does not cancel a transfer already started. A device can still go offline between selection and connection, which produces a normal connection error.

anDrop cannot read another device's “everyone for 10 minutes” countdown. It observes Bluetooth advertisements rather than assuming that a device stays visible for a fixed ten-minute period. The exact OS visibility-switch time is not available to the Mac, so removal is not instantaneous.

## Sending progress

After choosing a recipient, the share window stays open. A blue ring grows clockwise around that recipient's icon, and the percentage appears below its name. The percentage uses bytes written to the outgoing ZIP response, including ZIP overhead, so empty files and batches also have a defined total. It is transport progress, not a measurement of the recipient's disk writes.

Preparing, Waiting and Connecting use an indeterminate ring without a fabricated percentage. After all response bytes have been sent, the ring is full and the status is Finishing until the peer confirms completion. Only then does it say Sent. Failure and cancellation are separate terminal states.

Cancel Transfer stops the operation. Close dismisses the window while sending continues; reopen it through Show Progress in the menu bar. The chosen recipient remains in this transfer view even if it stops advertising. It is a snapshot of the active transfer, not a discoverable recipient available for a new send. Normal discovery still expires independently.

## Share popup behavior

The recipient popup has no title bar or traffic-light window buttons. It uses the existing Cancel, Close and Done controls. While a transfer is active, clicking another window moves the popup into the background and the transfer continues. After a successful send, clicking outside the popup or switching focus to another window dismisses it. Failed and cancelled transfers retain their result until dismissed.

## Receive connection errors

A compatible sender may label the recipient as having rejected a transfer when anDrop aborts after a connection failure. That message alone does not mean the Mac user pressed Decline. anDrop now briefly retries transient failures while opening the initial connection. It does not retry certificate/protocol failures or resume partial files automatically.

If receiving still fails, keep the sender's sharing screen open and verify both devices use the same Wi-Fi, then send again. Notifications show an actionable explanation; local diagnostics identify the failing stage without putting IP addresses or internal Python objects into the notification.

The rename control uses the SF Symbols `pencil` beside the recipient name, including names wrapping onto two lines. Clicking the icon or name sends files; clicking the pencil opens the local-name editor.

The name itself is centered below the avatar, with the pencil immediately to its right. Short names such as “Example” fit on one line; longer names use up to two lines. The popup grows with the grid up to a bounded height, then scrolls only the recipient list while keeping the header and actions visible. The local-name editor is a compact sheet without an app-icon header.

## Receive scope and trusted devices

Choose **Trusted Devices Only** or **Everyone** in the menu bar or Settings. Every transfer still requires approval in both modes; trusting a device never enables automatic acceptance.

Open Settings → **Trusted Devices…** to add devices from previous transfers even when they are offline. New devices need one transfer in Everyone mode first. Device rows use manufacturer artwork with a phone/tablet badge. Verify the requesting device yourself. Different local identifier suffixes distinguish devices with identical names. Remove trust or forget a remembered device at any time.

This filter uses Bluetooth identifiers remembered by this Mac, not account or device names. It is not cryptographic pairing or authenticated identity. Add a device again if its identifier changes. Nearby advertisements remain visible. Trusted-only mode rejects unlisted requests before showing approval or connecting over Wi-Fi to download files. Removing trust does not interrupt an already-started transfer.

## Control Center (macOS 26 and later)

Open anDrop, then choose Control Center → **Edit Controls** and search for **anDrop**. Add the single **anDrop** control. It opens a compact panel with anDrop and its receive switch in the header, followed by Trusted Devices Only / Everyone. Turning the switch off quits the app. Opening the control starts the app without opening its main Settings window. If Bluetooth or Wi-Fi is unavailable, the switch shows off; enable the radios in macOS Control Center. Public Controls API does not allow a third-party app to embed an AirDrop-style detail panel inside Control Center itself, so this panel opens near the menu bar. If an older Toggle Sharing tile remains after an update, remove that obsolete tile in Edit Controls. This feature uses [Apple’s official Controls API](https://developer.apple.com/documentation/widgetkit/controls-collection).
