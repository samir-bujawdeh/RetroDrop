import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum MediaKind: String, Codable {
    case photo, video
}

/// Turns modern Mac photos and videos into files that old iPhones can open:
/// - photos: sRGB JPEG, at most 2048 px on the long side (HEIC, PNG, RAW... all work as input)
/// - videos: H.264 Baseline 3.0 + AAC in .mp4, at most 640x480 at 30 fps, which is what the iPhone 3GS
///   can play (later models play it too)
enum MediaConverter {
    enum ConvertError: LocalizedError {
        case unsupported, unreadable, noVideoTrack, failed(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Not a photo or video."
            case .unreadable: return "Couldn't read the file."
            case .noVideoTrack: return "The video has no picture."
            case .failed(let why): return "Couldn't convert the video (\(why))."
            }
        }
    }

    static let maxPhotoPixels = 2048
    static let thumbPixels = 240
    static let maxVideoLongSide: CGFloat = 640
    static let maxVideoShortSide: CGFloat = 480

    static func kind(of url: URL) -> MediaKind? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension.lowercased())
        guard let type else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return .photo }
        return nil
    }

    // MARK: Photos

    static func convertPhoto(_ src: URL, to dst: URL) throws {
        guard let image = downscaledImage(src, maxPixels: maxPhotoPixels) else { throw ConvertError.unreadable }
        try writeJPEG(image, to: dst, quality: 0.85)
    }

    /// Small JPEG preview for the phone's Safari page.
    static func writeThumbnail(of src: URL, kind: MediaKind, to dst: URL) throws {
        let image: CGImage?
        switch kind {
        case .photo: image = downscaledImage(src, maxPixels: thumbPixels)
        case .video: image = videoFrame(src, maxPixels: CGFloat(thumbPixels))
        }
        guard let image else { throw ConvertError.unreadable }
        try writeJPEG(image, to: dst, quality: 0.75)
    }

    /// Decodes at most `maxPixels` on the long side, with the photo's rotation applied, redrawn into sRGB
    /// (old iOS ignores wide-gamut colour profiles, which would make colours look washed out).
    private static func downscaledImage(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return redrawnInSRGB(image)
    }

    private static func redrawnInSRGB(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))  // transparent PNGs get a white background
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    private static func writeJPEG(_ image: CGImage, to dst: URL, quality: Double) throws {
        guard let out = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ConvertError.failed("can't write \(dst.lastPathComponent)") }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw ConvertError.failed("can't write \(dst.lastPathComponent)") }
    }

    // MARK: Videos

    /// Blocking; call off the main thread. Returns the duration in seconds.
    @discardableResult
    static func convertVideo(_ src: URL, to dst: URL) throws -> Double {
        let asset = AVURLAsset(url: src)
        let (videoTracks, audioTracks, duration) = try blocking {
            (try await asset.loadTracks(withMediaType: .video),
             try await asset.loadTracks(withMediaType: .audio),
             try await asset.load(.duration))
        }
        guard let track = videoTracks.first else { throw ConvertError.noVideoTrack }
        let (natural, transform, fps) = try blocking {
            (try await track.load(.naturalSize), try await track.load(.preferredTransform),
             try await track.load(.nominalFrameRate))
        }

        // Fit inside 640x480 (or 480x640 for portrait), never upscale, even dimensions for H.264.
        let oriented = CGRect(origin: .zero, size: natural).applying(transform).size
        let w = abs(oriented.width), h = abs(oriented.height)
        guard w > 0, h > 0 else { throw ConvertError.unreadable }
        let scale = min(maxVideoLongSide / max(w, h), maxVideoShortSide / min(w, h), 1)
        let outW = Int((w * scale / 2).rounded()) * 2, outH = Int((h * scale / 2).rounded()) * 2

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: outW, height: outH)
        let frameRate = Int32(fps > 0 ? min(fps.rounded(), 30) : 30)
        composition.frameDuration = CMTime(value: 1, timescale: frameRate)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        // Rotate upright, move into view, then shrink to the output size.
        let upright = CGRect(origin: .zero, size: natural).applying(transform)
        let t = transform
            .concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
            .concatenating(CGAffineTransform(scaleX: CGFloat(outW) / w, y: CGFloat(outH) / h))
        layer.setTransform(t, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = composition
        reader.add(videoOut)
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(out)
            audioOut = out
        }

        try? FileManager.default.removeItem(at: dst)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true  // playable while still downloading
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264Baseline30,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading() else { throw ConvertError.failed(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw ConvertError.failed(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String) {
            group.enter()
            let queue = DispatchQueue(label: "RetroDrop.convert.\(label)")
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if let sample = output.copyNextSampleBuffer() {
                        if !input.append(sample) { finished = true }
                    } else {
                        finished = true
                    }
                    if finished {
                        input.markAsFinished()
                        group.leave()
                    }
                }
            }
        }
        pump(videoOut, into: videoIn, label: "video")
        if let audioOut, let audioIn { pump(audioOut, into: audioIn, label: "audio") }
        group.wait()

        if reader.status == .failed {
            writer.cancelWriting()
            throw ConvertError.failed(reader.error?.localizedDescription ?? "read error")
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw ConvertError.failed(writer.error?.localizedDescription ?? "write error")
        }
        return duration.seconds
    }

    private static func videoFrame(_ url: URL, maxPixels: CGFloat) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        let frame = try? blocking { try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image }
        return frame.flatMap(redrawnInSRGB)
    }

    /// Runs async AVFoundation loading from synchronous code (we're always on a background thread here).
    private static func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result.get()
    }
}
