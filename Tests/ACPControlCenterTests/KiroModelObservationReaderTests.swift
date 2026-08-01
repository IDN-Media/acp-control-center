import Foundation
import Testing
@testable import ACPControlCenter

/// Tests for `KiroModelObservationReader` covering kiro-cli vs AI_EDITOR
/// attribution and preservation of the literal `auto` model value.
struct KiroModelObservationReaderTests {
    /// Copies a fixture log into a fresh temp directory laid out like the
    /// real logs root (`<root>/<session>/kiro.log`).
    private func makeLogsRoot(withFixtures fixtureNames: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (index, fixtureName) in fixtureNames.enumerated() {
            let sessionDir = root.appendingPathComponent("session\(index)")
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let sourceURL = FixtureLocator.url("model/\(fixtureName)")
            let destinationURL = sessionDir.appendingPathComponent("kiro.log")
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
        return root
    }

    @Test
    func kiroCLIClientIsAttributedToKiroCLI() throws {
        let root = try makeLogsRoot(withFixtures: ["model-kiro-cli.log"])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = KiroModelObservationReader(logsRoot: root)
        let result = reader.readLatestObservation()

        guard case .success(let observation) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(observation.clientName == "kiro-cli")
        #expect(observation.source == .kiroCLI)
        #expect(observation.modelID == "claude-opus-4.6")
    }

    @Test
    func aiEditorOriginIsAmbiguousNotXcodeACP() throws {
        let root = try makeLogsRoot(withFixtures: ["model-ai-editor.log"])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = KiroModelObservationReader(logsRoot: root)
        let result = reader.readLatestObservation()

        guard case .success(let observation) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(observation.clientName == "kiro-ide")
        #expect(observation.origin == "AI_EDITOR")
        // Must be surfaced as aiEditor, never claimed as Xcode ACP.
        #expect(observation.source == .aiEditor)
    }

    @Test
    func autoModelIDIsPreservedLiterally() throws {
        let root = try makeLogsRoot(withFixtures: ["model-auto.log"])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = KiroModelObservationReader(logsRoot: root)
        let result = reader.readLatestObservation()

        guard case .success(let observation) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(observation.modelID == "auto")
    }

    @Test
    func allObservedModelIDsDeduplicatesInNewestFileOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let older = root.appendingPathComponent("older")
        let newer = root.appendingPathComponent("newer")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        try writeModelLog(
            to: older.appendingPathComponent("kiro.log"),
            models: ["model-old", "model-shared"]
        )
        try writeModelLog(
            to: newer.appendingPathComponent("kiro.log"),
            models: ["model-new", "model-shared"]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: older.appendingPathComponent("kiro.log").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)],
            ofItemAtPath: newer.appendingPathComponent("kiro.log").path
        )

        let reader = KiroModelObservationReader(logsRoot: root)
        #expect(reader.allObservedModelIDs() == ["model-new", "model-shared", "model-old"])
    }

    private func writeModelLog(to url: URL, models: [String]) throws {
        let lines = models.map { model in
            let message = "[q-developer-converse] Sending GenerateAssistantResponse "
                + "modelId=\(model) agentMode=vibe origin=AI_EDITOR streaming=true"
            return """
            {"timestamp":"2026-07-16T10:02:05.531Z","level":"info","message":"\(message)"}
            """
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @Test
    func missingLogsRootReturnsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = KiroModelObservationReader(logsRoot: root)
        let result = reader.readLatestObservation()

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
        guard case .missing = error else {
            Issue.record("Expected .missing, got \(error)")
            return
        }
    }

    @Test
    func unknownClientAndOriginYieldsUnknownSource() {
        let source = KiroModelObservationReader.classifySource(clientName: "some-other-client", origin: "SOME_OTHER_ORIGIN")
        #expect(source == .unknown)
    }
}
