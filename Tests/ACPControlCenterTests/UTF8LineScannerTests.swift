import Foundation
import Testing
@testable import ACPControlCenter

struct UTF8LineScannerTests {
    @Test
    func scansLinesAcrossChunkBoundariesAndFinalLineWithoutNewline() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("alpha\nbeta-long\ngamma".utf8).write(to: url)

        var lines: [String] = []
        try UTF8LineScanner.scan(url, chunkSize: 3) { lines.append($0) }

        #expect(lines == ["alpha", "beta-long", "gamma"])
    }

    @Test
    func skipsOversizedLineWithoutNewline() throws {
        // A single line exceeding maxLineBytes with no trailing newline
        // should be skipped entirely.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let oversized = String(repeating: "X", count: 20)
        try Data(oversized.utf8).write(to: url)

        var lines: [String] = []
        try UTF8LineScanner.scan(url, chunkSize: 4, maxLineBytes: 10) { lines.append($0) }

        #expect(lines.isEmpty)
    }

    @Test
    func skipsOversizedLineFollowedByValidLine() throws {
        // An oversized line followed by a valid line: only the valid line
        // should be emitted.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let oversized = String(repeating: "A", count: 20)
        let content = oversized + "\nvalid\n"
        try Data(content.utf8).write(to: url)

        var lines: [String] = []
        try UTF8LineScanner.scan(url, chunkSize: 5, maxLineBytes: 10) { lines.append($0) }

        #expect(lines == ["valid"])
    }

    @Test
    func oversizedLineSpanningManyChunksIsSkipped() throws {
        // An oversized line spanning multiple chunks with a valid line after.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let oversized = String(repeating: "B", count: 50)
        let content = oversized + "\ngood"
        try Data(content.utf8).write(to: url)

        var lines: [String] = []
        try UTF8LineScanner.scan(url, chunkSize: 8, maxLineBytes: 10) { lines.append($0) }

        #expect(lines == ["good"])
    }

    @Test
    func exactBoundaryLineIsEmitted() throws {
        // A line exactly at maxLineBytes should be emitted (not skipped).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let exactLine = String(repeating: "C", count: 10)
        let content = exactLine + "\nshort\n"
        try Data(content.utf8).write(to: url)

        var lines: [String] = []
        try UTF8LineScanner.scan(url, chunkSize: 4, maxLineBytes: 10) { lines.append($0) }

        #expect(lines == [exactLine, "short"])
    }

    @Test
    func normalLinesWithSmallChunksAllEmitted() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("one\ntwo\nthree\n".utf8).write(to: url)

        var lines: [String] = []
        try UTF8LineScanner.scan(url, chunkSize: 2, maxLineBytes: 100) { lines.append($0) }

        #expect(lines == ["one", "two", "three"])
    }

    @Test
    func multipleOversizedLinesAreAllSkipped() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let big1 = String(repeating: "D", count: 15)
        let big2 = String(repeating: "E", count: 15)
        let content = big1 + "\n" + big2 + "\nok\n"
        try Data(content.utf8).write(to: url)

        var lines: [String] = []
        try UTF8LineScanner.scan(url, chunkSize: 4, maxLineBytes: 10) { lines.append($0) }

        #expect(lines == ["ok"])
    }
}
