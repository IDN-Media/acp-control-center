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

## Privacy and read-only constraints

The current baseline is read-only. Any future write-capable feature (such as
the planned Wrapper Manager) requires:

- Explicitly approved scope documented in the roadmap
- User confirmation before every write operation
- Preview of the intended change before execution
- Atomic file replacement (write to temp file, then rename)
- Post-write validation (syntax check + read-back verification)
- Backup of the previous file state with rollback on validation failure
- Test coverage for the backup, read-back, and rollback paths

Within the current read-only scope:

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
- [ ] **Write safety gate:** If this PR introduces any file-write
  capability, it includes user confirmation, atomic replace, pre-write
  backup, post-write validation, rollback on failure, and test coverage for
  all of the above. Read-only PRs may skip this gate.
