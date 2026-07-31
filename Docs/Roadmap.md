# Roadmap

## Implemented: Read-Only MVP (Slices 1–3)

The current implementation provides read-only observability:

- Menu bar status label with compact credit display (8 pt)
- Live credit refresh via `kiro-cli chat --no-interactive '/usage'`
- Local log fallback with clear source attribution
- Bounded CLI discovery across selected, known, `PATH`, and app-bundle paths
- Manual executable selection with persisted path and recovery states
- Separate account refresh, CLI search, and Xcode rescan actions
- Latest observed model activity and attribution
- ACP wrapper configuration display (model, effort, syntax validity)
- Diagnostic summary (`--diagnostic` flag) with home-directory path redaction
- Freshness classification (available / aging / stale)

## Implemented: ACP Wrapper Lifecycle — Work Package A

Provider observation and lifecycle classification enable state-aware UX:

### Structured provider observation

- `ACPWrapperReader.readProviderObservation()` returns typed
  `ACPProviderObservation` (noProvider, configuredPathMissing, wrapperInvalid,
  wrapperValid) instead of requiring downstream parsing of error strings.

### Lifecycle classification

Pure, testable `ACPWrapperLifecycleClassifier` combines provider observation
with structured managed-artifact inspection to produce one of seven states:

- `noProvider` — no ACP provider configured, no managed wrapper
- `configuredPathMissing` — Xcode references a missing file, no managed wrapper
- `unmanagedWrapperInvalid` — Xcode points to a broken wrapper not owned by ACC
- `managedWrapperInvalid` — managed target contains an invalid/unsafe/unrecognized entry
- `unmanagedWrapperActive` — Xcode uses a valid wrapper not owned by ACC
- `managedWrapperInactive` — managed wrapper exists but Xcode is not using it
- `managedWrapperActive` — Xcode actively uses the valid managed wrapper

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

### State-aware dashboard UX

Each state drives a specific action button and sheet flow:

| State | Button | Flow |
|-------|--------|------|
| noProvider | Set Up ACP Wrapper… | First-time setup |
| configuredPathMissing | Create Managed Replacement… | First-time setup with guidance |
| unmanagedWrapperInvalid | — | Read-only notice |
| managedWrapperInvalid | View Problem… | Truthful problem notice (ACC will not overwrite) |
| unmanagedWrapperActive | — | Read-only notice |
| managedWrapperInactive | Finish Xcode Setup… | Copy path, Reveal, Rescan |
| managedWrapperActive | — | Status only |

### First-time safe setup flow

- Requires ready validated Kiro CLI
- Structured optional model ID and effort
- Full generated preview before write
- First-install-specific API rejects any existing entry at managed target
- Re-checks destination immediately before install (race detection)
- Explicit native confirmation before write
- `/bin/zsh -n` validation, private permissions, atomic install, read-back
- Automatic cleanup on verification failure (no backup needed for first install)
- Post-install transitions to `managedWrapperInactive` with Xcode instructions
- No write on launch, refresh, rescan, opening setup UI, cancel, or preview

### Automatic internal restore

If a general install (future work) fails post-write verification, the
previous wrapper is automatically restored from the internal backup. This
is an automatic safety mechanism, not a user-facing manual rollback feature.

## Planned: Work Package B — Unmanaged Wrapper Migration

- Explicit migration flow for unmanaged wrappers to the managed target
- Preview-based migration with user confirmation
- Preserves original unmanaged wrapper unchanged (copies, not moves)

## Planned: Work Package C — Managed Editing & Observability

- Edit-in-place for existing active managed wrapper (with preview/confirm)
- Backup history UI and manual rollback UI (user-facing restore)
- Configured-vs-observed model comparison
- Restart guidance when Xcode picks up wrapper changes

## Later: Model Discovery

- Discover model suggestions from a stable provider-supported local catalog
- Model ID validation against known catalog

## Later: Observed-Client Attribution Research

Currently, `origin=AI_EDITOR` with `client=kiro-ide` cannot reliably
distinguish Kiro IDE from an Xcode ACP session using the same backend.
Future research may identify stronger signals to provide confident Xcode
ACP attribution. Until then, this combination is displayed as "AI editor
(unconfirmed)".

## Non-goals

- This app will never execute the ACP wrapper as an agent
- This app will never open Kiro IDE or submit prompts
- This app will never read or store authentication credentials
- This app will never persist account usage data, log content, prompts,
  credentials, or telemetry to disk

Future Work Package C backups will be local configuration artifacts created
only before an explicitly confirmed managed-wrapper edit. Work Package A does
not create backups because it rejects every existing destination.
