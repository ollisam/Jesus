import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VideoEngine {
    static func isReadable(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).load(.isReadable)) ?? false
    }

    static func convert(_ src: URL, to dst: URL, format: OutputFormat, progress: @escaping ProgressHandler) async throws {
        guard !format.needsFFmpeg, await isReadable(src) else {
            try await FFmpeg.convert(src, to: dst, variants: FFmpeg.arguments(for: format))
            return
        }
        switch format {
        case .mp4, .mov, .m4v:
            // Remux without re-encoding when the codecs allow it.
            try await export(src, to: dst, as: format.avFileType!,
                             presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality],
                             progress: progress)
        case .m4a:
            let audio = try await AVURLAsset(url: src).loadTracks(withMediaType: .audio)
            guard !audio.isEmpty else { throw ConversionError.message("This video has no audio track.") }
            try await export(src, to: dst, as: .m4a, presets: [AVAssetExportPresetAppleM4A], progress: progress)
        case .gif:
            try await gif(src, to: dst, progress: progress)
        default:
            throw ConversionError.unsupported
        }
    }

    static func compress(_ src: URL, to dst: URL, format: OutputFormat, level: CompressionLevel,
                         progress: @escaping ProgressHandler) async throws {
        if await isReadable(src) {
            try await export(src, to: dst, as: format.avFileType!, presets: level.videoPresets, progress: progress)
        } else {
            try await FFmpeg.convert(src, to: dst, variants: [FFmpeg.videoCompression(level)])
        }
    }

    private static func export(_ src: URL, to dst: URL, as fileType: AVFileType, presets: [String],
                               progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: src)
        var lastError: Error = ConversionError.unsupported

        for preset in presets {
            guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType),
                  let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.shouldOptimizeForNetworkUse = true

            let monitor = Task {
                for await state in session.states(updateInterval: 0.2) {
                    if case .exporting(let p) = state { progress(p.fractionCompleted) }
                }
            }
            defer { monitor.cancel() }

            do {
                try await session.export(to: dst, as: fileType)
                return
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                try? FileManager.default.removeItem(at: dst)
            }
        }
        throw lastError
    }

    /// Up to 30 seconds at 12 fps, 480 px on the long side.
    private static func gif(_ src: URL, to dst: URL, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration).seconds
        let fps = 12.0
        let count = max(1, Int(min(duration, 30) * fps))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 24)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 24)

        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw ConversionError.unsupported }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary

        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }
        var done = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            if let image = try? result.image { CGImageDestinationAddImage(dest, image, frameProps) }
            done += 1
            progress(Double(done) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.message("The GIF couldn't be created.") }
    }
}

enum AudioEngine {
    static func convert(_ src: URL, to dst: URL, format: OutputFormat, bitRate: Int?) async throws {
        guard !format.needsFFmpeg, let file = try? AVAudioFile(forReading: src) else {
            try await FFmpeg.convert(src, to: dst, variants: FFmpeg.arguments(for: format, bitRate: bitRate))
            return
        }

        let rate = file.fileFormat.sampleRate
        let depth = file.fileFormat.streamDescription.pointee.mBitsPerChannel > 16 ? 24 : 16
        var variants: [[String]]
        switch format {
        case .m4a:
            let codec = rate > 48_000 ? "aac@48000" : "aac"
            variants = [["-f", "m4af", "-d", codec, "-b", String(bitRate ?? 256_000)], ["-f", "m4af", "-d", codec]]
        case .wav:
            variants = [["-f", "WAVE", "-d", "LEI\(depth)"]]
        case .aiff:
            variants = [["-f", "AIFF", "-d", "BEI\(depth)"]]
        case .flac:
            variants = [["-f", "flac", "-d", "flac"]]
        default:
            throw ConversionError.unsupported
        }

        var lastError: Error = ConversionError.unsupported
        for arguments in variants {
            do {
                try await Shell.run("/usr/bin/afconvert", arguments + [src.path, dst.path])
                return
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                try? FileManager.default.removeItem(at: dst)
            }
        }
        throw lastError
    }
}

/// Optional: if ffmpeg is installed (e.g. via Homebrew), extra formats unlock.
enum FFmpeg {
    static let path: String? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static var isAvailable: Bool { path != nil }

    static func convert(_ src: URL, to dst: URL, variants: [[String]]) async throws {
        guard let path else { throw ConversionError.needsFFmpeg }
        var lastError: Error = ConversionError.unsupported
        for arguments in variants {
            do {
                try await Shell.run(path, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", src.path]
                                    + arguments + [dst.path])
                return
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                try? FileManager.default.removeItem(at: dst)
            }
        }
        throw lastError
    }

    static func arguments(for format: OutputFormat, bitRate: Int? = nil) -> [[String]] {
        let kbps = "\((bitRate ?? 256_000) / 1000)k"
        let h264 = ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "192k"]
        return switch format {
        case .mp3: [["-vn", "-c:a", "libmp3lame", "-q:a", "2"]]
        // Builds without libvorbis fall back to the experimental native encoder, then Opus in Ogg.
        case .ogg: [["-vn", "-c:a", "libvorbis", "-q:a", "5"],
                    ["-vn", "-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-q:a", "5"],
                    ["-vn", "-c:a", "libopus", "-b:a", "160k"]]
        case .opus: [["-vn", "-c:a", "libopus", "-b:a", "128k"]]
        case .wma: [["-vn", "-c:a", "wmav2", "-b:a", "192k"]]
        case .avi: [["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]]
        case .wmv: [["-c:v", "wmv2", "-b:v", "6M", "-c:a", "wmav2", "-b:a", "192k"]]
        case .m4a: [["-vn", "-c:a", "aac", "-b:a", kbps]]
        case .wav: [["-vn", "-c:a", "pcm_s16le"]]
        case .aiff: [["-vn", "-c:a", "pcm_s16be"]]
        case .flac: [["-vn", "-c:a", "flac"]]
        case .webm: [["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]]
        case .mkv: [["-c", "copy"], h264]
        case .mp4, .m4v, .mov: [["-c", "copy", "-movflags", "+faststart"], h264 + ["-movflags", "+faststart"]]
        case .gif: [["-t", "30", "-vf",
                     "fps=12,scale='min(480,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"]]
        default: [[]]
        }
    }

    static func videoCompression(_ level: CompressionLevel) -> [String] {
        var arguments = ["-c:v", "libx264", "-crf", "\(level.ffmpegCRF)", "-preset", "medium", "-pix_fmt", "yuv420p",
                         "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
        if level == .smallest { arguments += ["-vf", "scale='min(1280,iw)':-2"] }
        return arguments
    }
}
