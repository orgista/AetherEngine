import Foundation
import Testing
@testable import AetherEngine

struct WritableSegmentBudgetTests {
    @Test func probeWritesAndRemovesItsFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(WritableSegmentBudget.probe(in: directory, limit: 2 << 20) == 2 << 20)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
