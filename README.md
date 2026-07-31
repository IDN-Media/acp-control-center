# ACP Control Center

An unofficial macOS menu bar app (SwiftUI `MenuBarExtra`) providing read-only
observability into your local ACP environment — currently supporting Kiro CLI
as its initial integration for account credit usage, observed model/session
activity, and Xcode ACP wrapper configuration.

> ACP Control Center is an independent, unofficial project and is not
> affiliated with or endorsed by Kiro or AWS. Code signing and distribution
> configuration are still pending.

## Current scope: Read-Only MVP

This is the implemented read-only vertical slice. It reads local files and
invokes `kiro-cli` for version and usage metadata only. **It never writes
to any Kiro, Xcode, or wrapper file.** Wrapper management (writing
model/effort changes) is planned as a future phase and is not implemented.

## What it reads

| Source | Default path | Purpose |
|--------|-------------|---------|
| Kiro CLI | `~/.local/bin/kiro-cli` | version + executable check (`--version`) |
| Live usage | `kiro-cli chat --no-interactive '/usage'` | live credit usage, plan, reset date |
| Usage logs (fallback) | `~/Library/Application Support/Kiro/logs/**/q-client.log` | credit usage when live fails |
| Agent logs | `~/.kiro/logs/*/kiro.log` | observed model ID, agent mode, attribution |
| Xcode ACP plist | `~/Library/Developer/Xcode/CodingAssistant/ACP/*.plist` | configured wrapper path |
| ACP wrapper script | (path from plist) | parsed as text — never executed |

All readers accept injected paths for testing.

## Menu bar label

The app displays a compact 8 pt status label in the menu bar:

- Loading: `👻 …`
- Success: `👻 USED / LIMIT` (e.g. `👻 771.21 / 1000`)
- Fallback: `👻 USED / LIMIT ⚠`
- Unavailable: `👻 —`

The label uses `.medium` weight, `.rounded` design, and `.monospacedDigit()`
for stable numeric width without a fixed frame.

## Requirements

- macOS 14+
- Xcode 16+ / Swift 6 toolchain
- No third-party dependencies (Foundation, SwiftUI, Observation, Testing)
- Live refresh requires `kiro-cli` installed and user logged in

## Build

The canonical project file is `ACPControlCenter.xcodeproj` (manually
maintained, never generated). `Package.swift` is the secondary SwiftPM path.

```bash
# Xcode
open ACPControlCenter.xcodeproj
# ⌘B to build, ⌘U to test

# SwiftPM CLI
swift build
```

## Test

```bash
# SwiftPM
swift test

# Xcode project (CI-compatible)
xcodebuild test \
  -project ACPControlCenter.xcodeproj \
  -scheme ACPControlCenter \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO
```

All tests use sanitized fixtures — no test reads real user data.

## Run

```bash
swift run ACPControlCenter
```

For a smoke test without opening the menu:

```bash
swift run ACPControlCenter --diagnostic
```

## Documentation

- [Architecture](Docs/Architecture.md) — project structure, live/fallback
  flow, reader resource design
- [Privacy](Docs/Privacy.md) — data boundaries, network activity, no-sandbox
  rationale
- [Roadmap](Docs/Roadmap.md) — implemented MVP, planned wrapper manager
  phases, attribution research

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Licensed under the [Apache License 2.0](LICENSE).

## Security

See [SECURITY.md](SECURITY.md). Never paste raw Kiro logs or credentials
into public issues.

## Known limitations

- Read-only display only — no wrapper writing in this slice
- `origin=AI_EDITOR` displayed as "AI editor (unconfirmed)" — cannot
  reliably distinguish Kiro IDE from Xcode ACP
- Dashboard performs an initial refresh and supports manual refresh, but does
  not continuously watch local files
- Live `/usage` parser depends on current CLI text format; falls back
  gracefully if format changes
