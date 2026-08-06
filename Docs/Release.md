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
Scripts/package-release.sh 0.1.0
```

This produces an unsigned ZIP in `dist/`. It is useful for local smoke tests
and for contributors who do not have signing credentials.

### Opening an unsigned preview build

Unsigned builds trigger a Gatekeeper warning on first launch. To open one of
these preview builds:

```bash
xattr -dr com.apple.quarantine /Applications/ACPControlCenter.app
```

or right-click the app → **Open** → **Open** again, or
System Settings → Privacy & Security → **Open Anyway**.

## Build a signed and notarized ZIP (maintainer mode)

The signing inputs come from the environment, never from the repository:

```bash
export ACC_SIGNING_IDENTITY="Developer ID Application: IDN Media..."
export ACC_TEAM_ID="XXXXXXXXXX"
export ACC_NOTARY_PROFILE="ACCNotaryProfile"

Scripts/package-release.sh 0.1.0 --sign
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
   git tag v0.1.0
   git push origin v0.1.0
   ```

2. Create a GitHub Release from the tag.
3. Attach:
   - `ACPControlCenter-0.1.0-macos.zip`
   - `ACPControlCenter-0.1.0-macos.zip.sha256`
4. Copy release notes that summarize the MVP lifecycle (observability,
   safe managed wrapper setup, migration, edit/history/rollback,
   verification) plus install instructions.

## Homebrew

A Homebrew cask is published in the `IDN-Media/homebrew-tap` tap and points at
the GitHub Release ZIP + sha256:

```bash
brew tap IDN-Media/tap
brew install --cask acp-control-center
```

The build is currently unsigned. On first launch, Gatekeeper may block the
app. Clear the download attribute once with:

```bash
xattr -dr com.apple.quarantine /Applications/ACPControlCenter.app
```

To update a release, bump `version` and `sha256` in
`Casks/acp-control-center.rb` (in the tap repo) to the new values.

## Future

- CI signing/release automation (requires organization approval for macOS
  runner usage and secret storage).
- DMG packaging if non-developer manual install becomes a goal.
