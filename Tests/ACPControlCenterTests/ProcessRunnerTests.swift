import Foundation
import Testing
@testable import ACPControlCenter

struct ProcessRunnerTests {
    @Test
    func timeoutTerminatesLongRunningProcess() {
        let runner = ProcessRunner()
        let started = Date()

        let output = runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            timeout: 0.05
        )

        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(output.exitCode != 0)
    }

    @Test
    func capturesStandardOutput() {
        let output = ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["kiro-ok"],
            timeout: 1
        )

        #expect(output.exitCode == 0)
        #expect(output.standardOutput == "kiro-ok")
        #expect(output.standardError.isEmpty)
    }

    @Test
    func boundedStdoutIsTruncatedWithMarker() {
        // Generate output larger than the cap.
        let cap = 64
        let runner = ProcessRunner(maxCapturedOutputBytes: cap)

        // Use printf to emit more than 64 bytes.
        let bigString = String(repeating: "Z", count: 200)
        let output = runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", bigString],
            timeout: 2
        )

        #expect(output.exitCode == 0)
        #expect(output.standardOutput.hasSuffix("\n[output truncated]"))
        // The prefix should be exactly cap bytes decoded.
        let withoutMarker = output.standardOutput
            .replacingOccurrences(of: "\n[output truncated]", with: "")
        #expect(withoutMarker.utf8.count == cap)
    }

    @Test
    func boundedStderrIsTruncatedWithMarker() {
        // Use shell to write to stderr.
        let cap = 32
        let runner = ProcessRunner(maxCapturedOutputBytes: cap)
        let bigString = String(repeating: "E", count: 100)

        let output = runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' '\(bigString)' >&2"],
            timeout: 2
        )

        #expect(output.exitCode == 0)
        #expect(output.standardError.hasSuffix("\n[output truncated]"))
        let withoutMarker = output.standardError
            .replacingOccurrences(of: "\n[output truncated]", with: "")
        #expect(withoutMarker.utf8.count == cap)
    }

    @Test
    func outputWithinCapIsNotTruncated() {
        let cap = 1024
        let runner = ProcessRunner(maxCapturedOutputBytes: cap)
        let output = runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["hello"],
            timeout: 1
        )

        #expect(output.exitCode == 0)
        #expect(output.standardOutput == "hello")
        #expect(!output.standardOutput.contains("[output truncated]"))
    }

    @Test
    func captureLimitIsClampedToOverflowSafeRange() {
        #expect(ProcessRunner(maxCapturedOutputBytes: 0).maxCapturedOutputBytes == 1)
        #expect(
            ProcessRunner(maxCapturedOutputBytes: .max).maxCapturedOutputBytes
                == ProcessRunner.maximumMaxCapturedOutputBytes
        )
    }
}
