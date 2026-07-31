## Summary

<!-- Brief description of what this PR does -->

## Changes

<!-- List the key changes -->

## Testing

- [ ] `swift test` passes
- [ ] `xcodebuild test -project ACPControlCenter.xcodeproj -scheme ACPControlCenter CODE_SIGNING_ALLOWED=NO` passes
- [ ] New source files belong to the intended `.xcodeproj` target and are
      discovered by the corresponding SwiftPM target

## Privacy checklist

- [ ] No real credentials, tokens, or personal data in fixtures
- [ ] No new network requests beyond documented CLI invocations
- [ ] **Write safety gate:** If this PR introduces file-write capability, it
  includes user confirmation, atomic replace, pre-write backup, post-write
  validation, rollback on failure, and test coverage for all of the above.
  (Read-only PRs: check this box to acknowledge no writes are introduced.)

---

> ⚠️ Do not attach raw Kiro CLI logs or credentials to this PR.
> You may use `--diagnostic` output but review and redact local
> usernames/paths or other sensitive context before posting.
