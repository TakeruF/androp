# App Sandbox

[简体中文](sandbox.md) · English

The native app and Finder Share extension use App Sandbox. The bundled Python
engine and Live Photo converter inherit the native host's static sandbox. This
limits access to the app container, Downloads and files/folders explicitly granted
by the user. It does not authenticate nearby devices or replace protocol checks.

## Files and process boundaries

The host requests Bluetooth, incoming/outgoing network, Downloads read/write,
user-selected read/write and app-scoped bookmark entitlements. The Share extension
has only App Sandbox and user-selected read-only access. Each inherited executable
has exactly `com.apple.security.app-sandbox` and `com.apple.security.inherit`.
No temporary filesystem exception, App Group or Photos library entitlement is used.

After copying provider-owned files inside its callback, the Share extension sends
implicit URL bookmarks through `androp://share?bookmark=…`. Raw path-only handoffs
are rejected. The extension opens its own containing app explicitly rather than
using the system's default handler for the shared URL scheme. The host retains
the granted URLs while selected or available for
retry. It sends fresh implicit bookmarks over the existing private JSON-lines pipe
to the already-running engine. Each outgoing operation retains and releases its
own grants, including cancellation. The converter receives its own input/destination
bookmarks over stdin; granting access to the engine alone does not grant a child
converter access. Huawei's sender works from snapshots inside the app container.

Custom save folders use persistent app-scoped bookmarks, refreshed when stale.
The host restores access on launch and passes an implicit bookmark to the engine.
An old path string, corrupt bookmark or revoked grant requires reselecting the
folder; receiving remains disabled until access is available. The default save
folder remains Downloads. Folder changes are disabled during transfers.

The host explicitly supplies its container home and temporary directory to Python.
MIME classification uses Python's built-in mappings without reading system MIME
configuration. The production bundle includes a container migration manifest for
`Library/Application Support/anDrop`, preserving the Huawei identity location.
macOS migrates the application's preferences separately. Builds with an alternate
Bundle ID omit that manifest so testing does not migrate installed-app data.

Huawei receive control, preview and file channels use owned TCP sockets. Peer
checks use the accepted socket's kernel source address, retaining the discovered
peer restriction without inspecting an `nc` child through `lsof`. Receiving keeps
macOS's automatically applied quarantine metadata; it adds quarantine when absent
and fails publication if marking fails. It never clears or downgrades OS flags.

## Updates and artifact checks

Direct-distribution builds enable Sparkle's Installer XPC service and grant only
the two documented bundle-specific Mach lookup exceptions. The existing network
client entitlement makes a separate Downloader service unnecessary. Store builds
exclude Sparkle and those exceptions. Sandbox support alone does not establish
Mac App Store eligibility or approval.

Both the build and release-preparation paths run `scripts/check-sandbox.py` against
the signed artifact, checking the host, extension, inherited executables and
updater configuration. Signature verification and the macOS 14 runtime check
remain separate gates.

## Local verification

Use a Python environment compatible with macOS 14; the current Homebrew Python
on a newer build machine may require a newer OS. Keep the installed app untouched:

```sh
ANDROP_BUNDLE_ID=org.androp.mac.sandbox-validation \
ANDROP_OUTPUT="$PWD/build/sandbox/anDrop.app" python build.py
python scripts/check-sandbox.py build/sandbox/anDrop.app
python scripts/test-sandbox.py --app build/sandbox/anDrop.app
```

Set `ANDROP_SIGN_IDENTITY` locally when using Developer ID signing. A UI-only
build can reuse a complete engine via `ANDROP_ENGINE_APP=/path/to/anDrop.app`;
Python changes require a full rebuild.

`test-sandbox.py` builds a uniquely identified test app, uses dummy files and
synthetic video, and launches its child before obtaining dynamic file grants.
It checks actual kernel denial of an unselected file in host and child, bookmark
relay, production ZIP/Huawei publication and quarantine in a custom folder,
owned TCP peer/read/write behavior, the built native converter, and persistent
destination restoration in a second process. It does
not access a personal Photos library or contact a phone. Temporary build/fixture
files are removed; macOS-owned containers with unique test IDs remain untouched.

Basic OPPO/Huawei round trips with content hashes and actual Finder Share passed;
see [physical verification](testing.en.md#app-sandbox-branch-validation-2026-10-31).
Before promoting this branch, verify actual Photos Share invocation, save-folder revocation/reselection,
identity/settings migration from the installed version, login-item behavior and
a complete Sparkle install/relaunch. Synthetic checks do not prove these flows.

References: [Apple file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox),
[sandbox inheritance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html),
[container migration](https://developer.apple.com/documentation/security/migrating-your-app-s-files-to-its-app-sandbox-container),
[automatic quarantine](https://developer.apple.com/forums/thread/811450),
[Sparkle sandbox integration](https://sparkle-project.github.io/documentation/sandboxing/).
