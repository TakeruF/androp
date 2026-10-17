# Documentation images

[简体中文](README.md) · English

These PNGs are rendered from the production recipient, settings and trusted-device SwiftUI views with fictional data. They are illustrative UI captures, **not evidence of device compatibility or an actual transfer**.

| Filename | Scene |
| --- | --- |
| `recipients-zh.png`, `recipients-en.png` | Six fictional phone/tablet/computer candidates, including Huawei, with brand/type badges |
| `sending-zh.png`, `sending-en.png` | Independent synthetic 42% and 68% sends of `Project.pdf` to OPPO and Huawei recipients |
| `trusted-zh.png`, `trusted-en.png` | Offline OPPO phone/tablet and Huawei phone from fictional history, with trust controls |
| `settings-zh.png`, `settings-en.png` | Mock `Studio Mac`, `~/Downloads`, languages, notifications, automatic updates and footer links |

## Regenerate on macOS

From the repository root, with the Swift build tools described in [building](../building.en.md):

```sh
python3 scripts/render-docs.py
```

The script compiles a disposable copy of the production UI and appends `scripts/DocumentationPreview.swift`. It uses a separate bundle identifier and a volatile preferences domain. The system Computer Name getter is replaced with a fixed mock value in that disposable build only. No app delegate is installed, no window is shown, and Bluetooth, notifications, the transfer engine and login items are not started. The mock Settings and recipient viewports are expanded to include all controls in each image; the real app uses bounded, scrollable windows. The version label comes from `release.json`. It renders the views directly to 2× PNGs and removes EXIF, text and timestamp metadata. It does not read real history, connect to devices or change the installed app.

Review all eight images after changing UI or localization. The capture of a SwiftUI view does not include macOS window shadows, the menu bar, permission dialogs or system notification banners; those are not simulated here. Build/runtime logs belong outside this folder.

Project-authored documentation is GPL-3.0-only. Manufacturer artwork visible in these images retains its owners’ separate rights; see [brand provenance](../../Resources/BrandLogos/README.en.md). SF Symbols are rendered as part of the macOS app interface, not supplied here as standalone symbol assets.

The removed receive panel’s earlier mock captures are archived with its [standalone prototype](../../Prototypes/ReceivePanel/README.en.md); they are not current application features.
