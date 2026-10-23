# Diagnostics: developer reference

[简体中文](diagnostics.md) · English

Introduced in development1.0.1/10006 and first publicly released with 1.1.0. Failure notifications and Settings export structured JSON and use the system mail-sharing service to create an attached draft. The user reviews, completes and sends it; the app has no automatic log-upload path.

## Fields and collection boundaries

- appVersion/macOS/architecture describe the app and Mac at export.
- events contain time, direction, state, phase, allowed error/exception types and errno, never arbitrary raw error text or protocol messages.
- Receive network offers retain only `networkMode` (`lan` / `direct`) and the transfer identifier; connection attempts retain a bounded `attempt` (1–4). When a connection error has no numeric errno, `connectionIssue` may distinguish `local_address_family_mismatch`, `multiple_socket_errors`, `interface_unavailable` or `errno_unavailable`. These are fixed diagnostic classifications, not proof of a particular network or app causing the failure. Addresses, interface names and raw exception text are omitted.
- `control_message.messageType` retains only fixed WebSocket frame types, such as `text`, `binary`, `close` or `error`. `control_action.protocolAction` retains only `wlanBandwidth`, `versionNegotiation`, `sendRequest` and `status`, with other actions classified as `other`. Message bodies are omitted.
- `send_offer_fields.offerFields` and `offerKind` retain only allowed BLE negotiation field names and the fixed classification `lan_request` / `lan_accepted` / `lan_rejected` / `direct_request` / `reuse_request` / `other`. Names such as `ip`, `ssid`, `psk` and `key` may appear; their values are never recorded. Unknown field names are discarded.
- Fixed error classifications now distinguish `TypeError`, `UnicodeDecodeError`, `ConnectionTimeoutError`, `SocketTimeoutError` and `ClientConnectionResetError`, among others. Unknown types remain `OtherError`. These distinguish frame handling, connection and read failures; they do not establish VPN or another connectivity app as the cause.
- Received Live Photo conversion records only the fixed result codes `live_photo_converted` / `live_photo_conversion_failed`, without filenames, paths, identifiers, images, video or raw conversion errors. Original received files are retained when conversion fails. A conversion result does not establish playback in Photos or on another phone.
- context.fileTypes/fileCount contain extension categories/count, unknown extensions as other, never filenames. fileTypesScope is all_files/first_file_only/not_available; an incoming first file is not misrepresented as the whole batch before full metadata arrives.
- peerBrand/peerKind are protocol-provided manufacturer and phone/tablet category, or unknown.
- **peerOS is always not_provided_by_protocol**: current transfer traffic does not supply Android/ColorOS versions. A protocol version is not an OS version. User mail asks for receiver OS/version if known; Settings does not expose this implementation detail.
- appsAtStart/appsAtFailure sample NSWorkspace application names and bundle IDs at first observed transfer/failure. Prohibited activation-policy background processes are excluded. This is not a full process list and contains no command lines, executable paths or window titles. Duplicate name/ID pairs are removed, maximum200. If failure is the first observation, both samples may coincide.
- selectedTransfer is a random transfer identifier, not device identity. Reports omit trust identifiers, device names, filenames/contents, network addresses and keys. Failure snapshots may contain nearby filtered events from other transfers, without their device/app context.

Only newly structured diagnostics are exported, never old raw status/last-transfer/last-protocol files. Retention:300 events,20 failure snapshots,10 exports; directory0700/files0600 at anDrop/Diagnostics under user Application Support. Clearing transfer history does not clear diagnostics; manage files through the diagnostic Finder entry. Older failures may lack logs, explicitly marked detailedLogAvailable.

The mail template asks for issue/reproduction, expected behavior, receiver model/OS/version and VPN/device-connectivity apps. The attachment includes running-app samples, so both UI/mail ask the user to review before sending. If mail sharing is unavailable, retain the report and advise manual attachment to support@takeruf.com.

Older reports can contain `live_photo_imported` / `live_photo_import_failed`. Current reception saves `.pvt` files without automatic Photos import. Successful OShare ZIP conversion removes the transport archive; a failed cleanup records only `live_photo_cleanup_failed`, without paths or raw errors.
