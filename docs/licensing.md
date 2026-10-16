# Licensing

## Project license

Project-authored code, documentation and icon assets use **GPL-3.0-only**, with the copyright label **anDrop contributors**. The complete license text is in [LICENSE](../LICENSE). Source files carry SPDX identifiers. This is a development project, provided without warranty under that license.

An earlier prototype imported the GPL-3.0 mtapy protocol module. The present engine does not import or bundle it. GPL-3.0 was selected for this project to keep distribution aligned with that development lineage, rather than asserting a permissive-only provenance. This is a project licensing choice; merely reading another project's protocol documentation is not itself asserted here to determine a license obligation.

The referenced mtapy revision's README, license field and LICENSE say GPL-3.0, despite an inconsistent MIT classifier in its package metadata. The original license text is retained. CatShare's MIT attribution is retained as a research reference. See [NOTICE.md](../NOTICE.md).

## Third-party components

`ThirdPartyNotices/README.txt` records the inspected package versions and license identifiers. The license files alongside it apply to their respective upstream components, not to the whole application. Original upstream copyright notices must be kept, including upstream authors' names.

Python and native runtime libraries have their own license texts. PyObjC uses macOS system libffi; no separate libffi runtime is included in the inspected build. PyInstaller's bootloader exception and Apache-licensed runtime files are described in its [official licensing documentation](https://pyinstaller.org/en/stable/license.html) and the included `pyinstaller-COPYING.txt`. The community hooks license distinguishes build hooks from embedded runtime hooks.

## Distribution

Keep LICENSE, NOTICE and the applicable dependency licenses with redistributed copies. When distributing an app binary, provide the corresponding source and build instructions for that exact version in accordance with GPL-3.0, and review the actual bundled dependencies. Do not assume a moving branch is the corresponding source for an older binary. See the [GPL-3.0 text](https://www.gnu.org/licenses/gpl-3.0.html).

No vendor APK, decompiled vendor source, vendor artwork or signing material is included. Product names describe interoperability targets; no trademark permission or vendor certification is implied.
