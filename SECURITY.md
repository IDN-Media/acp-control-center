# Security Policy

## Supported versions

This project is pre-release. Security reports are accepted against the
`main` branch only.

## Reporting a vulnerability

Once GitHub private vulnerability reporting is enabled for this repository,
please use it to report security issues confidentially.

Until that is available, do **not** open a public issue for security
vulnerabilities. Instead, contact the repository owner through the channels
listed in their GitHub profile.

## What to report

- Unintended file writes (the app must remain read-only)
- Credential or token exposure through any code path
- Sensitive data (ARNs, user IDs, emails, prompts) leaking into UI,
  diagnostics, or logs
- Process injection or command injection via reader inputs
- Unintended network requests beyond the documented `kiro-cli` invocations

## What NOT to include in reports or public issues

- **Never paste real Kiro CLI logs** — they may contain session tokens,
  profile ARNs, or personal identifiers.
- **Never paste real credentials, API keys, or tokens.**
- You may use the app's `--diagnostic` output as a starting point, but
  **review and redact local usernames, filesystem paths, or any other
  context you consider sensitive** before posting publicly. Diagnostics
  exclude known credential and identity fields but may still contain
  system-specific paths.

## Response expectations

This is a personal pre-release project. Response times are best-effort only.
There is no formal bug bounty program.

## Threat surfaces

The primary data-handling threat surfaces for this app are:

1. **Log file parsing** — malformed log content could trigger unexpected
   behavior in JSON deserialization or line scanning.
2. **Process execution** — the app executes `kiro-cli` and `/bin/zsh -n`
   with controlled arguments; path injection via plist content is a surface.
3. **Plist deserialization** — untrusted plist files under the Xcode ACP
   directory are parsed for wrapper paths.
4. **Live CLI output parsing** — text output from `kiro-cli` is parsed with
   regex; unexpected formats fail gracefully to fallback.
