# Receive-panel prototype

[简体中文](README.md) · English

This UI is preserved for possible reuse. **It is excluded from the shipped app.** There is no current Control Center integration. Use the menu bar or Settings to choose a receive scope.

## Preview

On macOS, run from the repository root using the Swift toolchain in the building guide:

```sh
python3 Prototypes/ReceivePanel/preview.py
python3 Prototypes/ReceivePanel/preview.py --english
```

The standalone preview uses in-memory mock state. The switch and scope rows are interactive, but do not start anDrop, advertise Bluetooth, send files, read transfer history, change preferences or quit the installed app. Press Escape to exit. Chinese is the default; `--english` selects English.

| Simplified Chinese (fictional data) | English (fictional data) |
| --- | --- |
| ![Chinese receive-panel preview](preview-zh.png) | ![Receive-panel preview](preview-en.png) |

These archived captures show the SwiftUI layout. The live preview adds the native glass surface and follows system appearance. They do not establish real transfer compatibility.

## What is preserved

- `ReceiveControlsView.swift`: standalone bindings for on/off and receive scope, SF Symbols, native switch, full-row selection, hover and increased-contrast handling.
- `makeReceiveControlsContent`: regular `NSGlassEffectView` on macOS 26+, standard popover material on earlier systems.
- Original geometry: 308 pt width, 42 pt header, 32 pt rows, 26 pt symbol circles, 16 pt outer corners.
- English and Simplified Chinese. Selected symbols use the system accent color.

For reintegration, bind the switch to actual radio/host availability and the scope to the host’s trusted-device policy; turning off previously quit the host. `radiosAvailable` can disable the switch. Connect `dismiss` to the host-owned panel. Keep the existing warning that untrusted devices can still discover the Mac and their transfer requests are rejected.

The previous WidgetKit/App Intents extension, presentation-only App Group state and host window integration remain in Git history at commit `95e72ee`. Apple’s public Controls API did not allow embedding this custom panel inside the system Control Center; the former control opened a separate host-owned panel. Restoring that integration requires a deliberate build/signing/registration change; this prototype does not register an extension.

Project source and captures are GPL-3.0-only. SF Symbols are rendered in the macOS interface, not redistributed as standalone artwork.
