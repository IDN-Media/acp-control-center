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

## Next: Safe ACP Wrapper Manager (Slice 4)

Planned future slice — **not yet implemented**.

### Phase 1: Catalog & Preview

- Enumerate available models and effort levels from a local catalog
- Preview what a wrapper change would look like before writing

### Phase 2: Atomic Validated Write

- Write wrapper changes atomically (temp file → rename)
- Create timestamped backup of existing wrapper before modification
- Validate syntax (`/bin/zsh -n`) on the new file immediately after write
- Read back and verify the written content matches intent
- Automatic rollback to backup if validation fails

### Phase 3: Confirmation & Rollback UI

- User confirmation before any write operation
- Visible backup path and one-click rollback
- History of recent wrapper changes

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

Note: Explicit user-approved wrapper backups (Slice 4) are configuration
artifacts stored locally for rollback purposes. They are not "user data
persistence" in the telemetry/analytics sense — they contain only the
wrapper script text that the user chose to modify.
