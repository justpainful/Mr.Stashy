import AVFoundation
import CommonCrypto
import Foundation
import VideoToolbox

/// Turns what a source serves into one playable file: pairs a video-only stream with its
/// audio, stitches HLS segments, and rewrites transport streams into MP4.
struct MediaAssembler: Sendable {
    var downloader: Downloader

    // MARK: Mux

    /// Combines separate video and audio files into one MP4 without re-encoding.
    static func mux(video: URL, audio: URL, output: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else { throw StashyError.assemblyFailed }
        let videoDuration = try await videoAsset.load(.duration)
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StashyError.assemblyFailed }
        try compositionVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audioAsset.load(.duration)
            let duration = CMTimeMinimum(videoDuration, audioDuration)
            try compositionAudio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        }
        try await export(composition, to: output)
    }

    /// Rewrites a fragmented or oddly-ordered MP4 as a plain, fast-start MP4.
    static func flatten(_ input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        try await export(asset, to: output)
    }

    private static func export(_ asset: AVAsset, to output: URL) async throws {
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw StashyError.assemblyFailed }
        session.shouldOptimizeForNetworkUse = true
        do {
            try await session.export(to: output, as: .mp4)
        } catch {
            throw StashyError.assemblyFailed
        }
    }

    /// Whether this device can decode a codec, so a 4K AV1 file is never saved on a phone
    /// that cannot play it.
    static func canDecode(codec: String?) -> Bool {
        switch codec {
        case "AV1": VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        case "H.265": VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        default: true
        }
    }

    // MARK: HLS

    func downloadStream(_ playlistURL: URL, headers: [String: String], to output: URL, workspace: URL, progress: @Sendable @escaping (DownloadProgress) -> Void) async throws {
        var text = String(decoding: try await downloader.data(playlistURL, headers: headers), as: UTF8.self)
        var mediaURL = playlistURL
        if HLSPlaylist.isMaster(text) {
            guard let best = HLSPlaylist.renditions(in: text, base: playlistURL).first else { throw StashyError.noMedia }
            mediaURL = best.url
            text = String(decoding: try await downloader.data(mediaURL, headers: headers), as: UTF8.self)
        }
        let media = HLSPlaylist.media(in: text, base: mediaURL)
        guard !media.segments.isEmpty else { throw StashyError.noMedia }
        guard media.isComplete else { throw StashyError.noMedia }
        if media.segments.contains(where: { $0.key?.uri.scheme == "drm" }) { throw StashyError.blocked }

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let joined = workspace.appendingPathComponent("stream.bin")
        FileManager.default.createFile(atPath: joined.path, contents: nil)
        let handle = try FileHandle(forWritingTo: joined)
        defer { try? handle.close() }

        var isFragmentedMP4 = false
        if let initialization = media.initialization {
            let bytes = try await fetch(initialization.url, byteRange: initialization.byteRange, headers: headers)
            try handle.write(contentsOf: bytes)
            isFragmentedMP4 = true
        }

        var keys: [URL: Data] = [:]
        var received: Int64 = 0
        let total = media.segments.count
        // Segments are fetched a few at a time but written strictly in order.
        let window = 4
        var index = 0
        while index < total {
            try Task.checkCancellation()
            let batch = Array(media.segments[index ..< min(index + window, total)])
            let results = try await withThrowingTaskGroup(of: (Int, Data).self) { group -> [Data] in
                for (offset, segment) in batch.enumerated() {
                    group.addTask {
                        let data = try await fetch(segment.url, byteRange: segment.byteRange, headers: headers)
                        return (offset, data)
                    }
                }
                var collected = [Data?](repeating: nil, count: batch.count)
                for try await (offset, data) in group { collected[offset] = data }
                return collected.map { $0 ?? Data() }
            }
            for (offset, var data) in results.enumerated() {
                let segment = batch[offset]
                if let key = segment.key {
                    if keys[key.uri] == nil { keys[key.uri] = try await downloader.data(key.uri, headers: headers) }
                    guard let keyData = keys[key.uri], keyData.count == 16 else { throw StashyError.assemblyFailed }
                    let iv = key.iv ?? Self.sequenceIV(segment.sequence)
                    data = try Self.decryptAES128(data, key: keyData, iv: iv)
                }
                if !isFragmentedMP4, offset == 0, index == 0, data.count > 8, data[4 ..< 8] == Data("ftyp".utf8) || data[4 ..< 8] == Data("styp".utf8) {
                    isFragmentedMP4 = true
                }
                try handle.write(contentsOf: data)
                received += Int64(data.count)
            }
            index += batch.count
            let estimated = Int64(Double(received) / Double(max(1, index)) * Double(total))
            progress(DownloadProgress(received: received, expected: estimated))
        }
        try handle.close()

        if isFragmentedMP4 {
            let renamed = workspace.appendingPathComponent("stream.mp4")
            if FileManager.default.fileExists(atPath: renamed.path) { try FileManager.default.removeItem(at: renamed) }
            try FileManager.default.moveItem(at: joined, to: renamed)
            do {
                try await Self.flatten(renamed, output: output)
            } catch {
                // The concatenation is already a valid fragmented MP4; keep it.
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                try FileManager.default.moveItem(at: renamed, to: output)
            }
        } else {
            do {
                try await TSRemuxer.remux(joined, to: output)
            } catch {
                throw StashyError.assemblyFailed
            }
        }
    }

    private func fetch(_ url: URL, byteRange: (length: Int, offset: Int)?, headers: [String: String]) async throws -> Data {
        var merged = headers
        if let byteRange {
            merged["Range"] = "bytes=\(byteRange.offset)-\(byteRange.offset + byteRange.length - 1)"
        }
        let data = try await downloader.data(url, headers: merged)
        if let byteRange, data.count > byteRange.length {
            // The host ignored the range and sent the whole file.
            return data.subdata(in: byteRange.offset ..< min(data.count, byteRange.offset + byteRange.length))
        }
        return data
    }

    private static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(repeating: 0, count: 16)
        var value = UInt64(sequence).bigEndian
        withUnsafeBytes(of: &value) { iv.replaceSubrange(8 ..< 16, with: $0) }
        return iv
    }

    private static func decryptAES128(_ data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count, ivBytes.baseAddress, inputBytes.baseAddress, data.count, outputBytes.baseAddress, output.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw StashyError.assemblyFailed }
        output.count = written
        return output
    }
}
