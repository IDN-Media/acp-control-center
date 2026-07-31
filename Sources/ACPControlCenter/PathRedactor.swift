import Foundation

/// Replaces a home-directory prefix with `~` in path strings for diagnostic
/// output. Uses a deterministic, exact-prefix match (no substring or partial
/// replacement) so paths like `/Users/alice2/…` are unaffected when the
/// home is `/Users/alice`.
///
/// The injected `homeURL` parameter defaults to the current user's home
/// directory but allows tests to supply arbitrary prefixes.
struct PathRedactor: Sendable {
    private let homePrefix: String

    /// - Parameter homeURL: The home directory URL whose path prefix will be
    ///   replaced with `~`. Defaults to the current user's home directory.
    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // Standardize path components and remove trailing slashes, then
        // ensure it ends with "/" for a clean prefix match.
        var path = homeURL.standardizedFileURL.path
        if !path.hasSuffix("/") {
            path += "/"
        }
        self.homePrefix = path
    }

    /// Returns `path` with the leading home-directory prefix replaced by `~/`,
    /// or the original path unchanged if it does not start with the home
    /// prefix.
    func redact(_ path: String) -> String {
        guard path.hasPrefix(homePrefix) else {
            // Also handle exact match of the home directory without trailing
            // content (e.g. the home directory itself).
            let homeDirExact = String(homePrefix.dropLast()) // without trailing "/"
            if path == homeDirExact {
                return "~"
            }
            return path
        }
        let relative = String(path.dropFirst(homePrefix.count))
        return "~/" + relative
    }

    /// Convenience: redacts the `.path` of a URL.
    func redact(_ url: URL) -> String {
        redact(url.path)
    }

    /// Redacts all occurrences of the home-directory path prefix within
    /// arbitrary text. This handles cases where paths appear embedded in
    /// error messages or diagnostic strings (e.g. "missing under
    /// /Users/alice/.kiro" → "missing under ~/.kiro").
    ///
    /// Uses exact-prefix semantics: only replaces `/Users/alice/` when
    /// followed by a path continuation — never `/Users/alice2/`.
    func redactText(_ text: String) -> String {
        // The homePrefix includes a trailing slash (e.g. "/Users/alice/").
        // We also need to match the bare home directory at a word boundary.
        let homeDirExact = String(homePrefix.dropLast()) // "/Users/alice"

        var result = text

        // First, replace occurrences of the full prefix with trailing slash.
        // This handles "/Users/alice/.kiro" → "~/.kiro".
        result = result.replacingOccurrences(of: homePrefix, with: "~/")

        // Replace a bare home directory only at the end of the string or when
        // followed by punctuation/whitespace. The negative path-continuation
        // class prevents false matches such as `/Users/alice2`.
        let escapedHome = NSRegularExpression.escapedPattern(for: homeDirExact)
        let bareHomePattern = escapedHome + #"(?=$|[^A-Za-z0-9_./-])"#
        return result.replacingOccurrences(
            of: bareHomePattern,
            with: "~",
            options: .regularExpression
        )
    }
}
