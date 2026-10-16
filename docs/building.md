# Building anDrop

## Requirements

- macOS with the Xcode command line tools and a Swift compiler supporting Swift 6 and `-default-isolation MainActor` (Swift 6.2+).
- Python 3.14 with the packages pinned in `requirements.txt`.
- A build machine matching the desired CPU architecture. The development build was arm64; Intel has not been tested.

The recorded toolchain is macOS 27.0.1, Swift 6.4 and Python 3.14.7. The bundle declares macOS 14 as its minimum; this is not evidence of validation on macOS 14.

```sh
python3.14 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python build.py
```

Build output: `build/anDrop.app`. The script builds the Swift host and Finder extension, freezes the Python engine with PyInstaller, copies licenses, signs the result, and verifies its signature. Temporary staging keeps extended filesystem attributes from invalidating signatures.

After a full build, `.venv/bin/python build.py --ui-only` reuses its engine for a UI-only change. Rebuild fully whenever the engine or dependencies change.

## Signing and installation

By default the build is ad-hoc signed. To use a configured signing identity, provide it locally through the `ANDROP_SIGN_IDENTITY` environment variable. Never commit a certificate, private key, identity string or Apple team identifier.

The default bundle identifier is `org.androp.mac`; `ANDROP_BUNDLE_ID` can override it locally. Use a namespace you control for a public signed release. A changed bundle identifier can reset macOS permissions, preferences, login registration and extension registration.

Quit an existing copy before installing the built app in Applications. Open it and grant Bluetooth, Local Network, notifications and destination-folder access as requested. For local builds, follow macOS's normal approval flow; the project does not disable system security settings.

Developer ID signatures expose the signing certificate's identity. A source repository with anonymous contributor metadata does not anonymize a signed app. No signed binary, certificate or notarization credential is committed here. Notarization is not automated by this script.

## Licenses and verification

```sh
.venv/bin/python collect-licenses.py
.venv/bin/python -m unittest discover -s tests -v
codesign --verify --deep --strict build/anDrop.app
```

The collector reads installed package metadata, Python's license and available Homebrew native-library licenses. It preserves the protocol-reference licenses already checked in. Review the inventory against the actual bundle before distributing a new build. See [licensing](licensing.md) and [publication privacy](publication.md).
