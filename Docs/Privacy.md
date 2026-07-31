# Privacy

ACP Control Center is a local-only macOS menu bar utility. This document
describes exactly what data it accesses, how it handles that data, and what
network activity it initiates.

## Local paths accessed

| Path | What is read | What is discarded |
|------|-------------|-------------------|
| Selected path, `~/.local/bin/kiro-cli`, `/opt/homebrew/bin/kiro-cli`, `/usr/local/bin/kiro-cli`, `PATH` entries, and known Kiro app-bundle locations | Existence, executable bit, `--version` output | — |
| `~/Library/Application Support/Kiro/logs/**/q-client.log` | Usage fields: `currentUsage`, `usageLimit`, `currentOverages`, `subscriptionTitle`, `overageStatus`, `nextDateReset` | Profile ARNs, user IDs, request IDs, emails, prompts, conversation content |
| `~/.kiro/logs/*/kiro.log` | Model ID, agent mode, origin, client name | Conversation IDs (logged structurally but never retained), turn IDs, prompts, file paths |
| `~/Library/Developer/Xcode/CodingAssistant/ACP/*.plist` | Wrapper executable path | All other plist fields |
| ACP wrapper script (path from plist) | Model flag, effort flag, syntax validity | Script body (parsed as text, never executed) |
| `~/.local/share/acp-control-center/wrappers/` | Managed wrapper | Only structured executable/model/effort configuration chosen by the user is written |

CLI discovery checks only this bounded candidate list; it never recursively
scans arbitrary directories. All readers accept injected paths in their
initializers so tests never touch real user data.

## Network activity

The app itself makes **no direct network requests**. The single indirect
network operation is:

```
kiro-cli chat --no-interactive '/usage'
```

This is a documented Kiro CLI control-plane slash command that:

- Queries the Kiro service for current credit usage metadata.
- Is handled entirely by `kiro-cli` internally (authentication, TLS, etc.).
- **Does not send user code, prompts, or conversation content** from this app.
- **Does not read token files or call private APIs** — authentication is
  managed by the CLI process.
- Has a bounded 20-second timeout enforced by the app.

If this request fails for any reason, the app falls back to local log data.

## No token or credential access

The app never reads, stores, or transmits:

- OAuth tokens, refresh tokens, or bearer credentials
- AWS credentials, profile ARNs, or session tokens
- Kiro login state files
- Any authentication material

All authentication is delegated to the `kiro-cli` process, which manages its
own credential lifecycle.

## Transient temporary files

Process output (stdout/stderr from `kiro-cli --version`, `/usage`, and
`/bin/zsh -n`) is transiently buffered in private temporary files under the
system temporary directory. These files:

- Are created in a unique directory with POSIX 0700 permissions.
- Have individual POSIX 0600 permissions (owner read/write only).
- Are removed best-effort immediately after the process exits.
- Contain only the raw output of bounded subprocess invocations.

In the event of a crash or abnormal termination, a temp file may remain on
disk until the operating system's periodic temp-directory cleanup removes it.
Captured reads from these files are bounded to 1 MiB per stream; larger
output is truncated with a clear marker.

The app does **not** persist analytics, caches, databases, credentials, or
process output. It can persist the selected CLI path in `UserDefaults` and,
only after preview plus confirmation, one app-managed wrapper. No executable
content from an existing wrapper or authentication material is copied.

## Managed-wrapper writes

Wrapper writes are restricted to the app's private no-space managed directory.
Generated scripts contain only:

- the selected Kiro CLI executable path;
- fixed HOME and PATH values from an internal allowlist;
- optional user-selected model and effort arguments;
- a deterministic ownership marker comment (`# ACC-MANAGED-WRAPPER`).

The app shows the complete script before installation. It does not accept
arbitrary environment variables or arbitrary shell fragments. Installation
uses private directories (`0700`), an executable wrapper (`0700`), destination
race checks, syntax validation, atomic first installation, and read-back
verification. Existing destinations are rejected rather than replaced. Xcode
ACP plist files remain read-only.

The lifecycle classifier determines whether a wrapper is app-owned using
ALL of the following conditions at the single managed target path:

- Exact canonical URL equality (standardized path match)
- Regular file (not symlink, directory, or device)
- Executable permission
- Contains `# ACC-MANAGED-WRAPPER` ownership marker in header position
- Parses as a valid ACP invocation
- Passes `/bin/zsh -n` syntax validation

Symlinks that resolve to the managed target are not treated as owned.
Inspection failures fail closed — they are never treated as "absent" or
"valid". The Xcode ACP plist remains read-only.

## Diagnostic output

The `--diagnostic` CLI flag produces a plain-text summary containing only:

- File paths (with the user's home-directory prefix replaced by `~`)
- Existence and permission checks
- Version strings
- Numeric credit values
- Plan names and overage status strings
- Freshness timestamps
- Wrapper configuration flags (model, effort)

It explicitly excludes: ARNs, emails, user IDs, request IDs, conversation
IDs, turn IDs, prompts, and message content.

**Note:** While home-directory prefixes are redacted and known identity
fields are excluded, users should still review diagnostic output and redact
any remaining local usernames, paths, or other context they consider
sensitive before sharing publicly.

## No App Sandbox

The app runs **without App Sandbox** because the file locations it reads
(under `~/Library/Application Support/Kiro/`, `~/.kiro/`, `~/.local/bin/`,
and `~/Library/Developer/Xcode/`) live outside any sandboxed container. The
app requests no network entitlements beyond what `kiro-cli` performs
internally.

## Data retention

The app retains parsed observations in ephemeral in-memory state. Durable
local state is limited to the optional selected CLI path plus explicitly
installed managed wrapper. There are no caches, databases, analytics,
credential stores, or persisted process output.
