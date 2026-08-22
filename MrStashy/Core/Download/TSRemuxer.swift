import AVFoundation
import CoreMedia
import Foundation

/// Rewrites an MPEG transport stream (the segments Kick and most HLS hosts serve) into a
/// plain MP4 without touching the compressed pictures or sound: the H.264/H.265 and AAC
/// payloads are carried over as they are, so nothing is re-encoded and nothing is lost.
enum TSRemuxer {
    enum Failure: Error { case noStreams, unsupportedCodec, writer(String) }

    private struct PES {
        var pid: Int
        var pts: Int64?
        var dts: Int64?
        var data: Data
    }

    private struct StreamInfo {
        var pid: Int
        var type: UInt8
    }

    // MARK: Public

    static func remux(_ input: URL, to output: URL) async throws {
        let data = try Data(contentsOf: input, options: .mappedIfSafe)
        let packets = try demux(data)
        guard let video = packets.video, !video.units.isEmpty else { throw Failure.noStreams }
        try await write(video: video, audio: packets.audio, to: output)
    }

    // MARK: Demux

    private struct VideoTrack {
        var isHEVC: Bool
        var units: [(pts: Int64, dts: Int64, nalUnits: [Data])]
        var sps: [Data]
        var pps: [Data]
        var vps: [Data]
    }

    private struct AudioTrack {
        var frames: [(pts: Int64, data: Data)]
        var sampleRate: Int
        var channels: Int
        var objectType: Int
    }

    private static func demux(_ data: Data) throws -> (video: VideoTrack?, audio: AudioTrack?) {
        let packetSize = 188
        guard data.count >= packetSize else { throw Failure.noStreams }
        // Some files carry a 4-byte timecode before each packet (192-byte packets).
        let stride = data.count >= 192 * 2 && data[0] == 0x47 && data[192] == 0x47 && data[188] != 0x47 ? 192 : 188
        var pmtPID: Int?
        var streams: [Int: StreamInfo] = [:]
        var pending: [Int: PES] = [:]
        var completed: [PES] = []
        var videoPID: Int?
        var audioPID: Int?

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = stride == 192 ? 4 : 0
            // Resync if the first byte is not a sync byte.
            while offset < bytes.count, bytes[offset] != 0x47 { offset += 1 }
            while offset + packetSize <= bytes.count {
                defer { offset += stride }
                guard bytes[offset] == 0x47 else { continue }
                let payloadStart = (bytes[offset + 1] & 0x40) != 0
                let pid = (Int(bytes[offset + 1] & 0x1F) << 8) | Int(bytes[offset + 2])
                let adaptation = (bytes[offset + 3] >> 4) & 0x03
                var position = offset + 4
                if adaptation == 2 || adaptation == 3 {
                    let length = Int(bytes[position])
                    position += 1 + length
                }
                guard adaptation != 2, position < offset + packetSize else { continue }
                let end = offset + packetSize

                if pid == 0 {
                    // Program association table: find the program map PID.
                    var table = position
                    if payloadStart { table += 1 + Int(bytes[table]) }
                    guard table + 8 < end else { continue }
                    let sectionLength = (Int(bytes[table + 1] & 0x0F) << 8) | Int(bytes[table + 2])
                    var entry = table + 8
                    let sectionEnd = min(end, table + 3 + sectionLength - 4)
                    while entry + 4 <= sectionEnd {
                        let program = (Int(bytes[entry]) << 8) | Int(bytes[entry + 1])
                        let mapPID = (Int(bytes[entry + 2] & 0x1F) << 8) | Int(bytes[entry + 3])
                        if program != 0 { pmtPID = mapPID }
                        entry += 4
                    }
                    continue
                }
                if let pmtPID, pid == pmtPID, streams.isEmpty {
                    var table = position
                    if payloadStart { table += 1 + Int(bytes[table]) }
                    guard table + 12 < end else { continue }
                    let sectionLength = (Int(bytes[table + 1] & 0x0F) << 8) | Int(bytes[table + 2])
                    let infoLength = (Int(bytes[table + 10] & 0x0F) << 8) | Int(bytes[table + 11])
                    var entry = table + 12 + infoLength
                    let sectionEnd = min(end, table + 3 + sectionLength - 4)
                    while entry + 5 <= sectionEnd {
                        let type = bytes[entry]
                        let streamPID = (Int(bytes[entry + 1] & 0x1F) << 8) | Int(bytes[entry + 2])
                        let esLength = (Int(bytes[entry + 3] & 0x0F) << 8) | Int(bytes[entry + 4])
                        streams[streamPID] = StreamInfo(pid: streamPID, type: type)
                        if (type == 0x1B || type == 0x24), videoPID == nil { videoPID = streamPID }
                        if (type == 0x0F || type == 0x11), audioPID == nil { audioPID = streamPID }
                        entry += 5 + esLength
                    }
                    continue
                }
                guard pid == videoPID || pid == audioPID else { continue }

                if payloadStart {
                    if let finished = pending.removeValue(forKey: pid) { completed.append(finished) }
                    // PES header: 00 00 01 <stream id> <length:2> <flags:2> <header length>
                    guard position + 9 <= end, bytes[position] == 0, bytes[position + 1] == 0, bytes[position + 2] == 1 else { continue }
                    let flags = bytes[position + 7]
                    let headerLength = Int(bytes[position + 8])
                    var pts: Int64?
                    var dts: Int64?
                    var cursor = position + 9
                    if (flags & 0x80) != 0, cursor + 5 <= end {
                        pts = timestamp(bytes, at: cursor)
                        cursor += 5
                    }
                    if (flags & 0x40) != 0, cursor + 5 <= end {
                        dts = timestamp(bytes, at: cursor)
                    }
                    let payloadOffset = position + 9 + headerLength
                    guard payloadOffset <= end else { continue }
                    pending[pid] = PES(pid: pid, pts: pts, dts: dts ?? pts, data: Data(bytes[payloadOffset ..< end]))
                } else if var current = pending[pid] {
                    current.data.append(contentsOf: bytes[position ..< end])
                    pending[pid] = current
                }
            }
        }
        completed.append(contentsOf: pending.values)
        completed.sort { ($0.dts ?? 0) < ($1.dts ?? 0) }

        var video: VideoTrack?
        if let videoPID, let info = streams[videoPID] {
            video = VideoTrack(isHEVC: info.type == 0x24, units: [], sps: [], pps: [], vps: [])
            for pes in completed where pes.pid == videoPID {
                guard let pts = pes.pts else { continue }
                let nalUnits = annexBUnits(in: pes.data)
                var frameUnits: [Data] = []
                for unit in nalUnits {
                    guard let first = unit.first else { continue }
                    let type = video!.isHEVC ? Int((first >> 1) & 0x3F) : Int(first & 0x1F)
                    if video!.isHEVC {
                        switch type {
                        case 32: if !video!.vps.contains(unit) { video!.vps.append(unit) }
                        case 33: if !video!.sps.contains(unit) { video!.sps.append(unit) }
                        case 34: if !video!.pps.contains(unit) { video!.pps.append(unit) }
                        case 35, 39, 40: continue // AUD, SEI: not needed in MP4
                        default: frameUnits.append(unit)
                        }
                    } else {
                        switch type {
                        case 7: if !video!.sps.contains(unit) { video!.sps.append(unit) }
                        case 8: if !video!.pps.contains(unit) { video!.pps.append(unit) }
                        case 9, 6, 12: continue // AUD, SEI, filler
                        default: frameUnits.append(unit)
                        }
                    }
                }
                if !frameUnits.isEmpty {
                    video!.units.append((pts, pes.dts ?? pts, frameUnits))
                }
            }
        }

        var audio: AudioTrack?
        if let audioPID {
            var frames: [(Int64, Data)] = []
            var sampleRate = 44_100
            var channels = 2
            var objectType = 2
            for pes in completed where pes.pid == audioPID {
                guard var pts = pes.pts else { continue }
                let adts = adtsFrames(in: pes.data)
                for frame in adts {
                    sampleRate = frame.sampleRate
                    channels = frame.channels
                    objectType = frame.objectType
                    frames.append((pts, frame.payload))
                    pts += Int64(1024 * 90_000 / max(1, frame.sampleRate))
                }
            }
            if !frames.isEmpty { audio = AudioTrack(frames: frames, sampleRate: sampleRate, channels: channels, objectType: objectType) }
        }
        return (video, audio)
    }

    private static func timestamp(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int64 {
        let high = Int64((bytes[index] >> 1) & 0x07) << 30
        let middle = Int64(bytes[index + 1]) << 22 | Int64(bytes[index + 2] >> 1) << 15
        let low = Int64(bytes[index + 3]) << 7 | Int64(bytes[index + 4] >> 1)
        return high | middle | low
    }

    /// Splits Annex B byte-stream data on its start codes into raw NAL units.
    private static func annexBUnits(in data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var index = 0
        var unitStart: Int?
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start = unitStart {
                    var end = index
                    if end > start, bytes[end - 1] == 0 { end -= 1 } // 4-byte start code
                    if end > start { units.append(Data(bytes[start ..< end])) }
                }
                index += 3
                unitStart = index
                continue
            }
            index += 1
        }
        if let start = unitStart, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }

    private struct ADTSFrame {
        var payload: Data
        var sampleRate: Int
        var channels: Int
        var objectType: Int
    }

    private static let sampleRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]

    private static func adtsFrames(in data: Data) -> [ADTSFrame] {
        var frames: [ADTSFrame] = []
        let bytes = [UInt8](data)
        var index = 0
        while index + 7 <= bytes.count {
            guard bytes[index] == 0xFF, (bytes[index + 1] & 0xF0) == 0xF0 else { index += 1; continue }
            let protectionAbsent = (bytes[index + 1] & 0x01) == 1
            let objectType = Int((bytes[index + 2] >> 6) & 0x03) + 1
            let rateIndex = Int((bytes[index + 2] >> 2) & 0x0F)
            let channels = Int(((bytes[index + 2] & 0x01) << 2) | ((bytes[index + 3] >> 6) & 0x03))
            let frameLength = (Int(bytes[index + 3] & 0x03) << 11) | (Int(bytes[index + 4]) << 3) | Int(bytes[index + 5] >> 5)
            let headerLength = protectionAbsent ? 7 : 9
            guard frameLength > headerLength, index + frameLength <= bytes.count else { break }
            frames.append(ADTSFrame(payload: Data(bytes[(index + headerLength) ..< (index + frameLength)]), sampleRate: sampleRates[safe: rateIndex] ?? 44_100, channels: channels == 0 ? 2 : channels, objectType: objectType))
            index += frameLength
        }
        return frames
    }

    // MARK: Write

    private static func write(video: VideoTrack, audio: AudioTrack?, to output: URL) async throws {
        guard !video.sps.isEmpty, !video.pps.isEmpty else { throw Failure.unsupportedCodec }
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoDescription = try videoFormatDescription(video)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoDescription)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw Failure.writer("video input") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioDescription: CMAudioFormatDescription?
        if let audio {
            let description = try audioFormatDescription(audio)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: description)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
                audioDescription = description
            }
        }

        // Timestamps start wherever the broadcast was; shift everything so the file starts at 0.
        let videoStart = video.units.map(\.dts).min() ?? 0
        let audioStart = audio?.frames.map(\.pts).min() ?? videoStart
        let origin = min(videoStart, audioStart)

        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let lengthPrefixed = video.units.map { unit -> (pts: Int64, dts: Int64, data: Data) in
            var payload = Data()
            for nal in unit.nalUnits {
                var length = UInt32(nal.count).bigEndian
                payload.append(Data(bytes: &length, count: 4))
                payload.append(nal)
            }
            return (unit.pts, unit.dts, payload)
        }
        let timescale: CMTimeScale = 90_000
        var videoIndex = 0
        var audioIndex = 0
        let audioFrames = audio?.frames ?? []
        let audioTimescale = CMTimeScale(audio?.sampleRate ?? 44_100)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "stashy.remux")
            let group = DispatchGroup()
            var failure: Error?

            group.enter()
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData {
                    guard videoIndex < lengthPrefixed.count else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    let unit = lengthPrefixed[videoIndex]
                    let next = videoIndex + 1 < lengthPrefixed.count ? lengthPrefixed[videoIndex + 1].dts : unit.dts + 3_003
                    let duration = max(1, next - unit.dts)
                    do {
                        let sample = try sampleBuffer(data: unit.data, description: videoDescription, pts: CMTime(value: unit.pts - origin, timescale: timescale), dts: CMTime(value: unit.dts - origin, timescale: timescale), duration: CMTime(value: duration, timescale: timescale))
                        if !videoInput.append(sample) {
                            failure = failure ?? Failure.writer(writer.error?.localizedDescription ?? "video append")
                            videoInput.markAsFinished()
                            group.leave()
                            return
                        }
                    } catch {
                        failure = failure ?? error
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    videoIndex += 1
                }
            }

            if let audioInput, let audioDescription {
                group.enter()
                audioInput.requestMediaDataWhenReady(on: queue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard audioIndex < audioFrames.count else {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        let frame = audioFrames[audioIndex]
                        let pts = CMTime(value: frame.pts - origin, timescale: timescale)
                        do {
                            let sample = try sampleBuffer(data: frame.data, description: audioDescription, pts: pts, dts: pts, duration: CMTime(value: 1024, timescale: audioTimescale))
                            if !audioInput.append(sample) {
                                failure = failure ?? Failure.writer(writer.error?.localizedDescription ?? "audio append")
                                audioInput.markAsFinished()
                                group.leave()
                                return
                            }
                        } catch {
                            failure = failure ?? error
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        audioIndex += 1
                    }
                }
            }

            group.notify(queue: queue) {
                if let failure {
                    writer.cancelWriting()
                    continuation.resume(throwing: failure)
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: Failure.writer(writer.error?.localizedDescription ?? "finish"))
                    }
                }
            }
        }
    }

    private static func videoFormatDescription(_ video: VideoTrack) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        if video.isHEVC {
            let sets = video.vps + video.sps + video.pps
            let pointers = sets.map { [UInt8]($0) }
            let sizes = pointers.map(\.count)
            let status = withParameterSets(pointers) { base in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: base, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
            guard status == noErr, let description else { throw Failure.unsupportedCodec }
            return description
        }
        let sets = [video.sps[0], video.pps[0]]
        let pointers = sets.map { [UInt8]($0) }
        let sizes = pointers.map(\.count)
        let status = withParameterSets(pointers) { base in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: base, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { throw Failure.unsupportedCodec }
        return description
    }

    private static func withParameterSets(_ sets: [[UInt8]], _ body: (UnsafePointer<UnsafePointer<UInt8>>) -> OSStatus) -> OSStatus {
        var pointers: [UnsafePointer<UInt8>] = []
        var buffers: [UnsafeMutableBufferPointer<UInt8>] = []
        for set in sets {
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
            _ = buffer.initialize(from: set)
            buffers.append(buffer)
            pointers.append(UnsafePointer(buffer.baseAddress!))
        }
        defer { buffers.forEach { $0.deallocate() } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    private static func audioFormatDescription(_ audio: AudioTrack) throws -> CMAudioFormatDescription {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Double(audio.sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(audio.channels), mBitsPerChannel: 0, mReserved: 0
        )
        let rateIndex = sampleRates.firstIndex(of: audio.sampleRate) ?? 4
        // AudioSpecificConfig: 5 bits object type, 4 bits rate index, 4 bits channels.
        let config: [UInt8] = [UInt8((audio.objectType << 3) | (rateIndex >> 1)), UInt8(((rateIndex & 1) << 7) | (audio.channels << 3))]
        var description: CMAudioFormatDescription?
        let status = config.withUnsafeBufferPointer { cookie in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &streamDescription, layoutSize: 0, layout: nil, magicCookieSize: cookie.count, magicCookie: cookie.baseAddress, extensions: nil, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { throw Failure.unsupportedCodec }
        return description
    }

    private static func sampleBuffer(data: Data, description: CMFormatDescription, pts: CMTime, dts: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else { throw Failure.writer("block buffer") }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw Failure.writer("block copy") }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: blockBuffer, formatDescription: description, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw Failure.writer("sample buffer") }
        return sample
    }
}
