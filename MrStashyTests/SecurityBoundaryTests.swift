import Foundation
import Testing
@testable import MrStashy

struct SecurityBoundaryTests {
    @Test func redactsAuthorizationCookiesAndSignedQueryValues() {
        let input = "Authorization: Bearer.secret Cookie=session-cookie https://cdn.example.test/file.mp4?token=abc123&safe=1"
        let output = SensitiveLog.redact(input)

        #expect(!output.contains("Bearer.secret"))
        #expect(!output.contains("session-cookie"))
        #expect(!output.contains("abc123"))
        #expect(output.contains("[REDACTED]"))
    }

    @Test func archiveVariantDropsCredentialsAndSignedQuery() throws {
        let source = try #require(URL(string: "https://cdn.example.test/file.mp4?token=abc123&expires=99#fragment"))
        let variant = MediaVariant(
            id: UUID(), url: source,
            headers: ["Authorization": "Bearer secret", "Cookie": "session=secret", "Referer": "https://example.test"],
            expirationDate: .now, width: 1920, height: 1080, bitrate: 1_000_000, fps: 30,
            isHDR: false, codec: "h264", container: "mp4", hasSeparateAudio: false,
            estimatedBytes: 1024, qualityLabel: "source", cleanliness: .original
        )

        let archived = variant.safeArchiveCopy
        #expect(archived.url.absoluteString == "https://cdn.example.test/file.mp4")
        #expect(archived.headers == ["Referer": "https://example.test"])
    }

    /// The shape a real request actually uses: the secret follows a space, not a separator.
    @Test func redactsASpaceSeparatedBearerHeader() {
        let output = SensitiveLog.redact("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature")

        #expect(!output.contains("eyJhbGciOiJIUzI1NiJ9"))
        #expect(!output.contains("payload.signature"))
        #expect(output.contains("[REDACTED]"))
    }

    @Test func rawDiscordUserTokenIsRejected() {
        #expect(throws: ResolverError.authenticationRequired) {
            try KeychainStore.saveDiscordBotToken("one.two.three")
        }
    }
}
