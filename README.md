# AudioCommander

macOS command-line/desktop audio player — decodes legacy tracker and speech formats
(S3M, XM, MOD, VOC, and more) via a Swift front-end linked against a vendored
multi-format C decoder library.

## Building

```sh
./build.sh          # universal binary, macOS 13+
```

## Project layout

- `src/` — Swift front-end
- `vendored/` — C decoder library sources
- `tools/` — test helpers and audio fixtures
- `Info.plist`, `Resources/` — macOS app bundle metadata
