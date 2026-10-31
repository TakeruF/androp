# anDrop Privacy Policy

Last updated: November 1, 2026

anDrop is developed and provided by **TakeruF**. This policy covers the macOS app and its Finder Share extension, including the GitHub distribution and any Mac App Store distribution. Their update mechanisms differ as described below.

## Files and nearby devices

anDrop uses Bluetooth to discover compatible nearby devices and your local network to send and receive files. File contents and transfer metadata, including file names and sizes, are exchanged with the other device involved in the transfer. File transfers do not pass through a developer-operated server, and anDrop does not automatically upload your files to TakeruF.

Your sharing name, which defaults to the Mac's Computer Name, is visible to nearby devices. Discovery and connection use device identifiers, device type/manufacturer information and local network addresses. The selected receiver or sender receives the information needed to complete the transfer. You can change the sharing name in Settings. Bluetooth and local-network permissions are controlled by macOS.

## Information stored on your Mac

anDrop stores settings, selected-folder access bookmarks, device aliases, hidden-device preferences, remembered devices and trust records locally. Trust records use protocol sender-ID or transfer-public-key digests. The app also stores local cryptographic identity material used for compatible transfers. These records are not an Apple, Android or manufacturer account pairing.

Local transfer history can contain device names, file names, local file paths, dates, transfer sizes and results. Received files remain in Downloads or the save folder you select. Temporary copies may be created inside the app's storage to stage shared files or convert Live Photos; converted files are saved or sent as part of the operation you request. The app does not scan your Photos library to build a profile of you.

## Diagnostics and support

anDrop keeps a bounded recent diagnostic log and failure snapshots on your Mac to help investigate transfer problems. They can include transfer stages, error codes, file types and counts, device manufacturer/type, app and macOS versions, and the names and bundle identifiers of Mac apps running when a transfer starts or fails. The app's structured diagnostic reports exclude file contents, file names, device names, network addresses and cryptographic keys.

Diagnostics are not automatically sent. If you choose to report a problem, anDrop prepares an email draft with a report attached. You can review, edit or cancel it before sending. If you send it to **support@takeruf.com**, TakeruF receives your email address, message and attachments, including anything you add yourself. Do not include files or information you do not want to share. Your email provider also processes the message under its own terms.

Support information is used to respond to your request, investigate problems and improve anDrop. It is retained while needed for those purposes and deleted when no longer needed, except where retention is required by law or to resolve a dispute. You can request deletion by contacting the same address. TakeruF does not sell support information or use it for advertising.

## Internet connections and distribution channels

- **GitHub version:** Sparkle checks the update feed and downloads signed updates from GitHub. Automatic checks and installation are enabled by default and can be disabled in Settings → Updates. Update requests expose ordinary connection information, such as your public IP address and HTTP client/version information, to GitHub and its delivery providers. File contents, transfer history and diagnostic reports are not attached to update requests; Sparkle system profiling is disabled.
- **Mac App Store version:** Sparkle and its GitHub update checks are excluded. Updates are handled by Apple through the Mac App Store under Apple's privacy practices. This statement describes that distribution configuration and does not announce App Store availability.
- **Links you open:** Opening this policy, the repository or another external link makes your browser connect to that website, which may receive ordinary connection information. The takeruf.com policy page is separate from the app's local file-transfer function.

anDrop contains no advertising or analytics SDK and does not send automatic usage analytics to TakeruF. It does not require an anDrop account. GitHub, Apple, website hosting and email providers process information for their respective services under their own policies. See [GitHub's privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) and [Apple's privacy policy](https://www.apple.com/legal/privacy/).

## Retention, deletion and your choices

You can clear transfer history in Settings, remove trust or remembered-device records, and change aliases or hidden-device preferences. Clearing history does not delete received files, trust settings, diagnostic files or reports you have copied elsewhere. Recent diagnostics rotate within fixed limits rather than being kept indefinitely by the app.

Settings and trust records remain until you change or remove them, or remove the app's stored data. Uninstalling the app does not necessarily remove its macOS container, preferences, older Application Support data or files saved outside the container. To remove remaining local data, first quit anDrop, then remove its app container/preferences and any legacy `Library/Application Support/anDrop` data from your user Library. Keep received files or exported reports you still need; delete unwanted copies from their save locations. Doing so can reset permissions, device trust and the app's local identity. macOS backups and copies on other devices are managed separately by you.

You can revoke file/folder, Bluetooth, local-network and notification permissions in macOS. Revoking a permission may prevent the related function from working. Quitting anDrop stops its discovery and transfer service. Trusted-device automatic acceptance can be disabled, and untrusted incoming transfers require approval in Everyone mode.

App Sandbox and scoped file permissions limit access to the app's storage, Downloads and files/folders you authorize. Network and device protections have limits; no software can guarantee absolute security, and a remembered device is not proof of a person's identity.

## Policy changes and contact

The current public policy is available at [takeruf.com/en/projects/androp/privacy](https://takeruf.com/en/projects/androp/privacy). Material changes to data handling will be reflected in this policy with an updated date.

For privacy questions or requests concerning information you sent to TakeruF, contact **[support@takeruf.com](mailto:support@takeruf.com)**. Describe the request without sending passwords, private keys or unnecessary personal information.
