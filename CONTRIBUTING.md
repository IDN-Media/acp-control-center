# Contributing

Unless explicitly stated otherwise, contributions intentionally submitted for
inclusion in this project are provided under the Apache License 2.0, without
additional terms or conditions. See [LICENSE](LICENSE).

## Project structure rules

- **`ACPControlCenter.xcodeproj`** is the canonical project file. It is
  manually maintained and committed directly. Never add XcodeGen,
  `project.yml`, or any generated project tooling.
- **`Package.swift`** is the secondary SwiftPM path for CLI builds. SwiftPM
  automatically discovers source files under the existing `Sources/` and
  `Tests/` target directories; the same files must still be added manually to
  the appropriate `.xcodeproj` target.

## Running quality checks

SwiftLint is pinned through the `SwiftLintPlugins` Swift package. It does not
require a global Homebrew installation. Run lint before compiling so lint and
compiler failures remain separate:

```bash
swift package plugin \
  --allow-writing-to-package-directory \
  swiftlint --strict
```

The plugin requests write permission because its optional `--fix` mode can
edit source files; the command above performs linting only.

SwiftLint is intentionally enforced as a command plugin and a separate CI job,
not as an automatic build-tool phase. This keeps lint diagnostics separate
from compiler output and avoids verbose prebuild failures exposing unrelated
build-process environment values.

Both test paths must also pass:

```bash
# SwiftPM
swift test

# Xcode project (CI-compatible, no signing)
xcodebuild test \
  -project ACPControlCenter.xcodeproj \
  -scheme ACPControlCenter \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO
```

## Adding source files

1. Add the `.swift` file under `Sources/ACPControlCenter/` or
   `Tests/ACPControlCenterTests/`.
2. Add a `PBXFileReference` and `PBXBuildFile` entry to
   `ACPControlCenter.xcodeproj/project.pbxproj` in the appropriate
   target.
3. Test fixtures placed under `Tests/ACPControlCenterTests/Fixtures/` are
   already covered by the package's `.copy("Fixtures")` declaration. Add any
   resource outside that directory explicitly to both build paths.

## Fixture requirements

All test fixtures must use sanitized placeholder values:

- Profile ARNs: `arn:aws:codewhisperer:us-east-1:000000000000:profile/EXAMPLE`
- User IDs: `EXAMPLE-USER-ID`
- Request IDs: `EXAMPLE-REQUEST-ID`
- Home paths: `/Users/exampleuser`
- Conversation/turn IDs: `sess_EXAMPLE0001`, `turn_EXAMPLE0001`

Never use real personal data, credentials, or session identifiers in fixtures.

## Privacy and write constraints

The current baseline provides read-only observability plus a narrow confirmed
managed-wrapper write boundary:

**Read-only surface (no writes ever):**
- All Kiro log readers, model observers, and usage parsers
- Xcode ACP plist files (always read-only, owned by Xcode)
- Unmanaged wrapper files (never modified)
- Kiro files and credentials

**Narrow confirmed write boundary (Work Package A):**
- Writes only under `~/.local/share/acp-control-center/wrappers/`
- First-time install only (rejects any existing entry at target)
- Requires preview + explicit user confirmation
- Uses first-install-specific API with pre-write destination checks
- Validates ownership via exact path + marker + parse + syntax

Any future expansion of the write surface (Work Packages B, C) requires:

- Explicitly approved scope documented in the roadmap
- User confirmation before every write operation
- Preview of the intended change before execution
- Atomic file replacement (write to temp file, then rename)
- Post-write validation (syntax check + read-back verification)
- Backup of the previous file state when an operation can replace existing data
- Test coverage for the backup, read-back, and rollback paths

Within the current scope:

- Never add code that reads authentication tokens or credentials.
- Never add code that submits prompts or opens Kiro IDE.
- Never retain profile ARNs, emails, user IDs, request IDs, or conversation
  content in domain models or UI state.

See [Docs/Privacy.md](Docs/Privacy.md) for the complete data boundary
specification.

## Pull request guidance

- Keep PRs focused on a single concern.
- Include test coverage for new readers or parsers.
- Ensure both `swift test` and `xcodebuild test` pass locally.
- Do not introduce third-party runtime dependencies without prior discussion.
  `SwiftLintPlugins` is the only pinned build-time dependency.
- Match the existing code style (Swift 6 concurrency, `@MainActor` view
  model, `Result`-based reader outputs).

## Pull request checklist

- [ ] SwiftLint passes with no warnings or errors
- [ ] `swift test` passes
- [ ] `xcodebuild test` passes (CODE_SIGNING_ALLOWED=NO)
- [ ] New source files belong to the intended `.xcodeproj` target and are
      discovered by the corresponding SwiftPM target
- [ ] No real credentials, tokens, or personal data in fixtures
- [ ] No new network requests beyond documented CLI invocations
- [ ] **Write safety gate:** If this PR introduces file writes, it includes
  user confirmation, race-safe atomic installation/replacement, post-write
  validation, and relevant failure-path tests. Replacement flows also require
  a pre-write backup and rollback coverage. Read-only PRs may skip this gate.
