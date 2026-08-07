#if DEBUG
import AVFoundation
import CoreServices
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Real media files, generated on the device for the screenshot run.
///
/// The screenshot fixture used to point at `https://example.invalid/one.png`, so every thumbnail,
/// every replica, and the video player rendered a placeholder glyph. A visual review that cannot
/// show the media UI is not a visual review. These helpers write an actual PNG, an actual
/// animated GIF, and an actual H.264 clip into the archive, so the captures show what a person
/// really sees. Nothing here is compiled into a Release build.
enum SyntheticMedia {
    /// A tall poster in the given hues, so photo and video tiles are visibly different shapes.
    static func photoPNG(width: Int = 1_080, height: Int = 1_350, seed: Int = 0) -> Data? {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            draw(frame: 0, of: 1, in: context.cgContext, size: size, seed: seed)
        }
        return image.pngData()
    }

    /// A short looping animation, written as a genuine animated GIF.
    static func animatedGIF(width: Int = 480, height: Int = 480, frames: Int = 12) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.gif.identifier as CFString, frames, nil
        ) else { return nil }
        let fileProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]
        ] as CFDictionary

        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        for index in 0 ..< frames {
            let image = renderer.image { context in
                draw(frame: index, of: frames, in: context.cgContext, size: size, seed: 2)
            }
            guard let cgImage = image.cgImage else { continue }
            CGImageDestinationAddImage(destination, cgImage, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    /// A short landscape H.264 clip. Returns `nil` when the encoder is unavailable, so a caller
    /// can fall back rather than ship a zero-byte file that would only fail to play.
    static func videoMP4(
        to destination: URL,
        width: Int = 1_280,
        height: Int = 720,
        seconds: Double = 6,
        fps: Int32 = 24
    ) async -> Bool {
        try? FileManager.default.removeItem(at: destination)
        guard let writer = try? AVAssetWriter(outputURL: destination, fileType: .mp4) else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let total = Int(Double(fps) * seconds)
        let size = CGSize(width: width, height: height)
        for index in 0 ..< total {
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let pixelBuffer = buffer else { break }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) {
                // Core Graphics draws bottom-up into a pixel buffer; flipping keeps the frame
                // the right way up rather than mirrored.
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                draw(frame: index, of: total, in: context, size: size, seed: 1)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            if !adaptor.append(pixelBuffer, withPresentationTime: time) { break }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    /// One frame of the generated artwork: a moving diagonal gradient with a progress ring, which
    /// makes it obvious in a screenshot that the media is real and is playing.
    private static func draw(frame: Int, of total: Int, in context: CGContext, size: CGSize, seed: Int) {
        let progress = total <= 1 ? 0 : Double(frame) / Double(total)
        let palettes: [[UIColor]] = [
            [UIColor(red: 0.40, green: 0.30, blue: 0.92, alpha: 1), UIColor(red: 0.24, green: 0.72, blue: 0.82, alpha: 1)],
            [UIColor(red: 0.95, green: 0.30, blue: 0.44, alpha: 1), UIColor(red: 1.00, green: 0.72, blue: 0.26, alpha: 1)],
            [UIColor(red: 0.16, green: 0.60, blue: 0.36, alpha: 1), UIColor(red: 0.10, green: 0.43, blue: 0.72, alpha: 1)]
        ]
        let palette = palettes[abs(seed) % palettes.count]
        let shift = CGFloat(progress)
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [palette[0].cgColor, palette[1].cgColor, palette[0].cgColor] as CFArray,
            locations: [0, 0.5, 1]
        ) else { return }
        context.saveGState()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: -size.width * shift, y: 0),
            end: CGPoint(x: size.width * (1 + shift), y: size.height),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()

        // A ring that fills as the clip advances, so a paused frame and a playing one differ.
        let radius = min(size.width, size.height) * 0.22
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        context.setLineWidth(radius * 0.16)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.28).cgColor)
        context.addArc(center: centre, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        context.strokePath()
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineCap(.round)
        context.addArc(
            center: centre, radius: radius,
            startAngle: -.pi / 2,
            endAngle: -.pi / 2 + .pi * 2 * CGFloat(max(progress, 0.02)),
            clockwise: false
        )
        context.strokePath()
    }
}
#endif
