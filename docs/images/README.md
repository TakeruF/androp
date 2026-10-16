# Documentation images / 文档画面

These PNGs are rendered from the production `RecipientView` and `SettingsView` with fictional data. They are illustrative UI captures, **not evidence of device compatibility or an actual transfer**.

这些 PNG 使用实际应用的设备选择、发送进度和设置界面，填入虚构数据生成。它们用于说明操作，**不代表真实设备连接、传输或品牌兼容性验证**。

| Filename | Scene |
| --- | --- |
| `recipients-zh.png`, `recipients-en.png` | Four fictional phones/tablets with brand badges and local-name controls |
| `sending-zh.png`, `sending-en.png` | Synthetic 42% outgoing transfer of `Project.pdf` |
| `settings-zh.png`, `settings-en.png` | Mock `Studio Mac`, `~/Downloads`, languages and notification settings |

## Regenerate on macOS

From the repository root, with the Swift build tools described in [building](../building.md):

```sh
python3 scripts/render-docs.py
```

The script compiles a disposable copy of the production UI and appends `scripts/DocumentationPreview.swift`. It uses a separate bundle identifier and a volatile preferences domain. The system Computer Name getter is replaced with a fixed mock value in that disposable build only. No app delegate is installed, no window is shown, and Bluetooth, notifications, the transfer engine and login items are not started. It renders the views directly to 2× PNGs. It does not read real history, connect to devices or change the installed app.

Review all six images after changing UI or localization. The capture of a SwiftUI view does not include macOS window shadows, the menu bar, permission dialogs or system notification banners; those are not simulated here. Build/runtime logs belong outside this folder.

Project-authored documentation is GPL-3.0-only. Manufacturer artwork visible in these images retains its owners’ separate rights; see [brand provenance](../../Resources/BrandLogos/README.md). SF Symbols are rendered as part of the macOS app interface, not supplied here as standalone symbol assets.
