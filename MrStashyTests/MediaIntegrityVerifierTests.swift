import Foundation
import Testing
@testable import MrStashy

struct MediaIntegrityVerifierTests {
    @Test func acceptsKnownImageSignatures() throws {
        let file = try temporaryFile(containing: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        defer { try? FileManager.default.removeItem(at: file) }

        try MediaIntegrityVerifier.validate(file: file, type: .photo)
    }

    @Test func rejectsHtmlAndTooShortAudioWithoutTrapping() throws {
        let html = try temporaryFile(containing: Data("<!doctype html><html>".utf8))
        let short = try temporaryFile(containing: Data([0x00]))
        defer {
            try? FileManager.default.removeItem(at: html)
            try? FileManager.default.removeItem(at: short)
        }

        #expect(throws: ResolverError.self) {
            try MediaIntegrityVerifier.validate(file: html, type: .photo)
        }
        #expect(throws: ResolverError.self) {
            try MediaIntegrityVerifier.validate(file: short, type: .audio)
        }
    }

    private func temporaryFile(containing data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url, options: .atomic)
        return url
    }
}
