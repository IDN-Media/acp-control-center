# Release

This document explains how to build, sign, notarize, and publish ACP Control
Center releases.

## Artifacts

Releases publish a ZIP containing `ACPControlCenter.app`:

```text
dist/ACPControlCenter-<version>-macos.zip
dist/ACPControlCenter-<version>-macos.zip.sha256
```

A DMG is not produced for the current release path. A ZIP is enough for GitHub
Releases and Homebrew.

## Prerequisites

- Xcode 16+ / Swift 6 toolchain
- macOS 14+ deployment target
- For signed/notarized releases: Apple Developer Program with a Developer ID
  Application certificate

## Build an unsigned ZIP (contributor mode)

```bash
Scripts/package-release.sh 0.1.0-preview.1
```

This produces an unsigned ZIP in `dist/`. It is useful for local smoke tests
and for contributors who do not have signing credentials.

## Build a signed and notarized ZIP (maintainer mode)

The signing inputs come from the environment, never from the repository:

```bash
export ACC_SIGNING_IDENTITY="Developer ID Application: IDN Media..."
export ACC_TEAM_ID="XXXXXXXXXX"
export ACC_NOTARY_PROFILE="ACCNotaryProfile"

Scripts/package-release.sh 0.1.0-preview.1 --sign
```

### Set up the notary keychain profile

```bash
xcrun notarytool store-credentials "ACCNotaryProfile" \
  --key /path/AuthKey_XXXXXX.p8 \
  --key-id KEYID12345 \
  --issuer ISSUER-UUID
```

This stores credentials in the local Keychain, not in the repository.

## Verify a signed build

```bash
codesign --verify --deep --strict --verbose=2 ACPControlCenter.app
xcrun stapler validate ACPControlCenter.app
spctl --assess --type execute --verbose=4 ACPControlCenter.app
```

## Publish a GitHub Release

1. Tag the release:

   ```bash
   git tag v0.1.0-preview.1
   git push origin v0.1.0-preview.1
   ```

2. Create a GitHub Release from the tag.
3. Attach:
   - `ACPControlCenter-0.1.0-preview.1-macos.zip`
   - `ACPControlCenter-0.1.0-preview.1-macos.zip.sha256`
4. Copy release notes that summarize the MVP lifecycle (observability,
   safe managed wrapper setup, migration, edit/history/rollback,
   verification) plus install instructions.

## Homebrew

A Homebrew cask (`IDN-Media/homebrew-tap`) is planned. It will point at the
GitHub Release ZIP and its sha256. This is not yet published.

## Future

- CI signing/release automation (requires organization approval for macOS
  runner usage and secret storage).
- DMG packaging if non-developer manual install becomes a goal.
