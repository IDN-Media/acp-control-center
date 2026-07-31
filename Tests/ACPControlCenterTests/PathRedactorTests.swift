import Foundation
import Testing
@testable import ACPControlCenter

/// Tests for `PathRedactor` ensuring home-prefix replacement is safe,
/// deterministic, and never produces false-positive partial matches.
struct PathRedactorTests {
    // MARK: - Home prefix redaction

    @Test
    func replacesHomePrefixWithTilde() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        #expect(redactor.redact("/Users/alice/.local/bin/kiro-cli") == "~/.local/bin/kiro-cli")
    }

    @Test
    func redactsURLVariant() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        let url = URL(fileURLWithPath: "/Users/alice/Library/Logs/test.log")
        #expect(redactor.redact(url) == "~/Library/Logs/test.log")
    }

    @Test
    func homeDirExactMatchBecomesTilde() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        #expect(redactor.redact("/Users/alice") == "~")
    }

    // MARK: - No partial-prefix false matches

    @Test
    func doesNotMatchPartialUsername() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        // "/Users/alice2" must NOT be matched — it's a different user.
        #expect(redactor.redact("/Users/alice2/Documents/file.txt") == "/Users/alice2/Documents/file.txt")
    }

    @Test
    func doesNotMatchShorterPrefix() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        #expect(redactor.redact("/Users/alic/something") == "/Users/alic/something")
    }

    // MARK: - Non-home paths unchanged

    @Test
    func nonHomePrefixPathUnchanged() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        #expect(redactor.redact("/opt/homebrew/bin/kiro-cli") == "/opt/homebrew/bin/kiro-cli")
    }

    @Test
    func rootPathUnchanged() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        #expect(redactor.redact("/") == "/")
    }

    @Test
    func tmpPathUnchanged() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        #expect(redactor.redact("/tmp/test.log") == "/tmp/test.log")
    }

    // MARK: - Trailing slash and symlink normalization

    @Test
    func homeWithTrailingSlashNormalized() {
        let home = URL(fileURLWithPath: "/Users/bob/")
        let redactor = PathRedactor(homeURL: home)
        #expect(redactor.redact("/Users/bob/Library/file") == "~/Library/file")
    }

    // MARK: - Edge cases

    @Test
    func emptyPathUnchanged() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        #expect(redactor.redact("") == "")
    }

    @Test
    func deeplyNestedPathRedacted() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        let deep = "/Users/alice/Library/Application Support/Kiro/logs/session/q-client.log"
        #expect(redactor.redact(deep) == "~/Library/Application Support/Kiro/logs/session/q-client.log")
    }

    // MARK: - Text redaction (embedded paths)

    @Test
    func redactTextReplacesEmbeddedHomePath() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        let text = "missing under /Users/alice/.kiro"
        #expect(redactor.redactText(text) == "missing under ~/.kiro")
    }

    @Test
    func redactTextReplacesMultipleEmbeddedPaths() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        let text = "read /Users/alice/.kiro/logs and /Users/alice/Library/file.log"
        #expect(redactor.redactText(text) == "read ~/.kiro/logs and ~/Library/file.log")
    }

    @Test
    func redactTextDoesNotMatchPartialUsername() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        let text = "file at /Users/alice2/Documents/secret.txt not found"
        #expect(redactor.redactText(text) == "file at /Users/alice2/Documents/secret.txt not found")
    }

    @Test
    func redactTextHandlesHomeDirAtEndOfString() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        let text = "path is /Users/alice"
        #expect(redactor.redactText(text) == "path is ~")
    }

    @Test
    func redactTextHandlesMultipleBareHomeOccurrences() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        let text = "first /Users/alice, second /Users/alice; partial /Users/alice2"
        #expect(redactor.redactText(text) == "first ~, second ~; partial /Users/alice2")
    }

    @Test
    func redactTextPreservesNonPathText() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        let text = "no paths in this string at all"
        #expect(redactor.redactText(text) == "no paths in this string at all")
    }

    @Test
    func redactTextEmptyInput() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        #expect(redactor.redactText("") == "")
    }

    @Test
    func redactTextMixedValidAndPartialPrefixes() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let redactor = PathRedactor(homeURL: home)
        let text = "found /Users/alice/.kiro but /Users/alice2/.kiro is different"
        #expect(redactor.redactText(text) == "found ~/.kiro but /Users/alice2/.kiro is different")
    }
}
