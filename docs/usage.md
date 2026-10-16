# Usage and troubleshooting

## Send and receive

Enable Bluetooth and Wi-Fi on both devices and join the same local network. Keep anDrop On in the menu bar.

To send from the Mac, select files in Finder → Share → anDrop, choose the phone and approve on the phone. If the extension is not visible, open anDrop once and enable its Share extension in macOS settings. The menu bar's Send Files action is also available.

To receive, select files in the phone's built-in compatible 互传 feature, choose the Mac and approve the request in anDrop's notification or menu bar. The default destination is Downloads itself. Files are not opened automatically.

Folders should be compressed first. Send files with identical base names in separate transfers. One transfer runs at a time. Notification banners follow macOS notification and Focus settings; progress and approval remain available in the menu bar.

## Device name limit

The default name follows macOS Computer Name. Nearby names have a **15 UTF-8 byte** limit: up to 15 ASCII characters, typically 5 Chinese characters, or fewer emoji. Shortening preserves complete characters. Transfer confirmations use the full Computer Name. The settings UI also explains this limit.

## Phone not found

Unlock the phone, enable its sharing feature and check discoverability. Some phones limit visibility to contacts/own devices or turn off everyone-visible mode automatically. The tested OPPO offers **Everyone (10 minutes)**. Expiry can explain the phone disappearing from the Mac's recipient list; re-enable visibility when needed.

This is different from the phone being unable to find the Mac because another Mac app interferes with anDrop's Bluetooth advertising. Also check the same Wi-Fi, Bluetooth, Local Network permission, and whether the network isolates clients.

## Petal Interconnect

Concurrent discovery remains experimental. macOS may merge Bluetooth advertising data from multiple apps, causing anDrop's name to disappear. Transfers have succeeded, but the conflict can recur after app updates or restarts.

While Petal runs, anDrop shortens its discovery name to **A** and keeps a Dock icon. Once Petal quits, anDrop returns to menu-bar-only operation and its normal nearby name.

**Settings → Repair Discovery with Petal** restarts Petal and re-registers anDrop's advertisement. Finish active Petal transfers first because restarting can interrupt them. anDrop never restarts Petal automatically. Repair does not guarantee recovery; quitting Petal while receiving is the current fallback.

## Privacy on your local network

Nearby devices can see the advertised device name while sharing is enabled. The full Computer Name is used in transfer negotiation. Local transfer history includes peer names and file paths; use Clear History in Settings to remove it. The app does not use a cloud service or analytics endpoint.
