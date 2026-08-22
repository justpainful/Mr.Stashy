import Foundation

/// Just enough of HTTP Live Streaming to save a finished clip: master playlists with several
/// renditions, media playlists with byte-ranged segments, fMP4 initialisation sections, and
/// AES-128 encrypted segments. Live streams are not a file and are refused.
enum HLSPlaylist {
    struct Rendition: Sendable {
        var url: URL
        var bandwidth: Int
        var width: Int?
        var height: Int?
        var codecs: String
    }

    struct Segment: Sendable {
        var url: URL
        var duration: Double
        var byteRange: (length: Int, offset: Int)?
        var key: Key?
        var sequence: Int
    }

    struct Key: Sendable, Equatable {
        var uri: URL
        var iv: Data?
    }

    struct Media: Sendable {
        var segments: [Segment]
        var initialization: (url: URL, byteRange: (length: Int, offset: Int)?)?
        var isComplete: Bool
        var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }
    }

    static func isMaster(_ text: String) -> Bool { text.contains("#EXT-X-STREAM-INF") }

    static func renditions(in text: String, base: URL) -> [Rendition] {
        var result: [Rendition] = []
        var pending: [String: String]?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if !line.isEmpty, !line.hasPrefix("#"), let info = pending {
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                let resolution = info["RESOLUTION"]?.split(separator: "x").compactMap { Int($0) }
                result.append(Rendition(url: url, bandwidth: Int(info["BANDWIDTH"] ?? "") ?? 0, width: resolution?.first, height: resolution?.last, codecs: info["CODECS"] ?? ""))
                pending = nil
            }
        }
        return result.sorted { lhs, rhs in
            let lhsPixels = (lhs.width ?? 0) * (lhs.height ?? 0)
            let rhsPixels = (rhs.width ?? 0) * (rhs.height ?? 0)
            if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }
            return lhs.bandwidth > rhs.bandwidth
        }
    }

    static func media(in text: String, base: URL) -> Media {
        var segments: [Segment] = []
        var initialization: (url: URL, byteRange: (length: Int, offset: Int)?)?
        var duration = 0.0
        var byteRange: (length: Int, offset: Int)?
        var lastRangeEnd = 0
        var key: Key?
        var sequence = 0
        var complete = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let parts = line.dropFirst("#EXT-X-BYTERANGE:".count).split(separator: "@")
                let length = Int(parts.first ?? "") ?? 0
                let offset = parts.count > 1 ? (Int(parts[1]) ?? 0) : lastRangeEnd
                byteRange = (length, offset)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let info = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = info["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                    var range: (length: Int, offset: Int)?
                    if let raw = info["BYTERANGE"] {
                        let parts = raw.split(separator: "@")
                        range = (Int(parts.first ?? "") ?? 0, parts.count > 1 ? (Int(parts[1]) ?? 0) : 0)
                    }
                    initialization = (url, range)
                }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let info = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                if info["METHOD"] == "NONE" {
                    key = nil
                } else if info["METHOD"] == "AES-128", let uri = info["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                    var iv: Data?
                    if let hex = info["IV"] { iv = Data(hex: hex.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "0X", with: "")) }
                    key = Key(uri: url, iv: iv)
                } else {
                    // SAMPLE-AES / DRM: cannot and must not be read.
                    key = Key(uri: URL(string: "drm://unsupported")!, iv: nil)
                }
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line == "#EXT-X-ENDLIST" {
                complete = true
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                segments.append(Segment(url: url, duration: duration, byteRange: byteRange, key: key, sequence: sequence))
                if let byteRange { lastRangeEnd = byteRange.offset + byteRange.length }
                byteRange = nil
                sequence += 1
            }
        }
        return Media(segments: segments, initialization: initialization, isComplete: complete)
    }

    /// `KEY="a,b",OTHER=1` → dictionary, respecting quoted commas.
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var current = ""
        var inQuotes = false
        var parts: [String] = []
        for character in text {
            if character == "\"" { inQuotes.toggle() }
            if character == ",", !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        for part in parts {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(part[part.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            result[key] = value
        }
        return result
    }
}

extension Data {
    init?(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
