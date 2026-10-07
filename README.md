# AudioCommander

Dual-pane macOS audio player — plays modern formats natively and decodes legacy
tracker and speech formats (S3M, XM, MOD, VOC, and more) via a Swift front-end
linked against a vendored multi-format C decoder library.

## Releases

Prebuilt universal binaries (x86_64 + arm64) are published on the
[Releases](https://github.com/Kafaferanterenous/audio-commander-MacOS/releases)
page. Download the `.zip`, unzip, and drag `AudioCommander.app` to `/Applications`.

### First launch on macOS

The builds are ad-hoc signed only (no Apple Developer ID, no notarization), so
macOS Gatekeeper will refuse to open the app the first time. When you see
"AudioCommander can't be opened" (or a "damaged" warning), allow it manually:

1. Right-click (or Control-click) `AudioCommander.app` and choose **Open**, then
   click **Open** in the dialog. …or…
2. Go to **System Settings → Privacy & Security**, scroll to **Security**, and
   for the AudioCommander message click **Open Anyway** (you may need to unlock
   the panel with your password/Touch ID).

You only need to do this once per downloaded build. If Gatekeeper reports the
app is "damaged", follow the same **Open Anyway** path.

## Building

```sh
./build.sh          # universal binary, macOS 13+
```

## Project layout

- `src/` — Swift front-end
- `vendored/` — C decoder library sources
- `tools/` — test helpers and audio fixtures
- `Info.plist`, `Resources/` — macOS app bundle metadata