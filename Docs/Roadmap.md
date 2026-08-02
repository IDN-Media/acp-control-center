# Roadmap

## Implemented

### Local observability

- Menu bar status label with compact credit display (8 pt)
- Live credit refresh via `kiro-cli chat --no-interactive '/usage'`
- Local log fallback with clear source attribution
- Bounded CLI discovery across selected, known, `PATH`, and app-bundle paths
- Manual executable selection with persisted path and recovery states
- Separate account refresh, CLI search, and Xcode rescan actions
- Latest observed model activity and attribution
- Observed model ID suggestions from local Kiro logs plus `auto`
- ACP wrapper configuration display (model, effort, syntax validity)
- Diagnostic summary (`--diagnostic` flag) with home-directory path redaction
- Freshness classification (available / aging / stale)

### ACP wrapper lifecycle

Provider observation and lifecycle classification enable state-aware UX:

- `ACPWrapperReader.readProviderObservation()` returns typed
  `ACPProviderObservation` (noProvider, configuredPathMissing, wrapperInvalid,
  wrapperValid) instead of requiring downstream parsing of error strings.
- Pure, testable `ACPWrapperLifecycleClassifier` combines provider observation
  with structured managed-artifact inspection to produce one of seven states:
  - `noProvider` — no ACP provider configured, no managed wrapper
  - `configuredPathMissing` — Xcode references a missing file, no managed wrapper
  - `unmanagedWrapperInvalid` — Xcode points to a broken wrapper not owned by ACC
  - `managedWrapperInvalid` — managed target contains an invalid/unsafe/unrecognized entry
  - `unmanagedWrapperActive` — Xcode uses a valid wrapper not owned by ACC
  - `managedWrapperInactive` — managed wrapper exists but Xcode is not using it
  - `managedWrapperActive` — Xcode actively uses the valid managed wrapper

### Managed wrapper actions

- First-time managed wrapper setup
- Managed replacement when Xcode points to a missing path
- Explicit migration from an unmanaged wrapper to ACC's managed format
- In-place model/effort edits for existing managed wrappers
- Backup history UI and manual rollback
- Post-install verification details (model, effort, managed path)
- Automatic restore of the previous managed wrapper on failed replacement

### Ownership validation

A canonical-path artifact is considered a valid ACC-managed wrapper only when
ALL conditions hold:

- filesystem entry exists at the exact canonical path
- regular file (not directory, device, or other)
- not a symbolic link (including dangling symlinks)
- executable
- contains the exact deterministic `# ACC-MANAGED-WRAPPER` ownership marker
  in the expected generated header position
- parses as the narrow generated ACP invocation format
- passes `/bin/zsh -n` syntax validation

Inspection errors fail closed with a structured invalid reason — they are
never treated as "absent". Xcode ACP plist files remain read-only.

## Next: release readiness

- Developer ID signing and notarization
- Repeatable release archive (`.zip` or `.dmg`)
- GitHub Release packaging and install instructions
- README screenshot and onboarding polish

## Later: model discovery

- Discover model suggestions from a stable provider-supported local catalog if
  Kiro exposes one
- Validate manually entered model IDs against a known catalog when such a
  catalog exists

## Later: observed-client attribution research

Currently, `origin=AI_EDITOR` with `client=kiro-ide` cannot reliably
distinguish Kiro IDE from an Xcode ACP session using the same backend. Future
research may identify stronger signals to provide confident Xcode ACP
attribution. Until then, this combination is displayed as "AI editor
(unconfirmed)".

## Later: refresh automation

- Optional local file watching or auto-refresh for usage logs, model logs, and
  Xcode ACP plist changes
- Keep manual refresh/rescan controls even if file watching is added

## Non-goals

- This app will never execute the ACP wrapper as an agent
- This app will never open Kiro IDE or submit prompts
- This app will never read or store authentication credentials
- This app will never persist account usage data, log content, prompts,
  credentials, or telemetry to disk
- This app will never modify Kiro files or Xcode ACP plist files
