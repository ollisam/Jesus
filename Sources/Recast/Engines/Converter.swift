import Foundation

enum Outcome {
    case output(URL)
    case skipped(String)
}

typealias ProgressHandler = @Sendable (Double) -> Void

/// Routes a file to the engine that handles its kind. Every result is written
/// as a new file beside the original; originals are never modified.
enum Converter {
    static func run(_ src: URL, kind: FileKind, action: Action,
                    progress: @escaping ProgressHandler) async throws -> Outcome {
        switch action {
        case .convert(let format): try await convert(src, kind: kind, to: format, progress: progress)
        case .compress(let level): try await compress(src, kind: kind, level: level, progress: progress)
        }
    }

    private static func convert(_ src: URL, kind: FileKind, to format: OutputFormat,
                                progress: @escaping ProgressHandler) async throws -> Outcome {
        if format.matches(src) { return .skipped("Already \(format.label)") }
        let dir = src.deletingLastPathComponent()
        let base = Naming.base(of: src)

        switch format {
        case .extract:
            return .output(try await ArchiveEngine.extract(src, into: dir, base: base))
        case .zip:
            let dst = Naming.unique(in: dir, kind == .archive ? base : src.lastPathComponent, "zip")
            try await cleaningUp(dst) {
                if kind == .archive {
                    try await ArchiveEngine.rezip(src, to: dst)
                } else {
                    try await ArchiveEngine.zip(src, to: dst)
                }
            }
            return .output(dst)
        default:
            break
        }

        if format == .png || format.utType == .jpeg {
            if kind == .pdf {
                return .output(try PDFEngine.images(src, in: dir, base: base, format: format, progress: progress))
            }
            if kind == .document {
                return .output(try await DocumentEngine.images(src, in: dir, base: base, format: format,
                                                               progress: progress))
            }
        }

        let dst = Naming.unique(in: dir, base, format.ext)
        try await cleaningUp(dst) {
            switch kind {
            case .image where format.utType != nil && OutputFormat.of(src)?.utType == format.utType:
                // Same encoding, different extension (JPG ↔ JPEG): copy rather than re-encode.
                try FileManager.default.copyItem(at: src, to: dst)
            case .image where format == .webp && !ImageEngine.canWrite(.webp):
                try await WebPEncoder.encode(src, to: dst)
            case .image:
                try ImageEngine.write(src, to: dst, format: format, quality: format.isLossy ? 0.9 : nil,
                                      maxPixel: nil, keepMetadata: true)
            case .video:
                try await VideoEngine.convert(src, to: dst, format: format, progress: progress)
            case .audio:
                try await AudioEngine.convert(src, to: dst, format: format, bitRate: nil)
            case .pdf:
                try await DocumentEngine.convertPDF(src, to: dst, format: format)
            case .document:
                try await DocumentEngine.convert(src, to: dst, format: format)
            case .subtitle:
                try SubtitleEngine.convert(src, to: dst, format: format)
            case .archive, .other:
                throw ConversionError.unsupported
            }
        }
        return .output(dst)
    }

    private static func compress(_ src: URL, kind: FileKind, level: CompressionLevel,
                                 progress: @escaping ProgressHandler) async throws -> Outcome {
        let dir = src.deletingLastPathComponent()
        let name = "\(Naming.base(of: src)) (compressed)"
        let dst: URL

        switch kind {
        case .archive:
            return .skipped("Already compressed")
        case .document, .subtitle, .other:
            let zip = Naming.unique(in: dir, src.lastPathComponent, "zip")
            try await cleaningUp(zip) { try await ArchiveEngine.zip(src, to: zip) }
            return .output(zip)
        case .image:
            let source = OutputFormat.of(src)
            let format = source.flatMap { $0.utType != nil && ImageEngine.canWrite($0) ? $0 : nil } ?? .jpg
            dst = Naming.unique(in: dir, name, format.ext)
            try await cleaningUp(dst) {
                try ImageEngine.write(src, to: dst, format: format, quality: format.isLossy ? level.imageQuality : nil,
                                      maxPixel: level.maxPixel, keepMetadata: false)
            }
        case .video:
            let format = [OutputFormat.mov, .m4v].first { $0.matches(src) } ?? .mp4
            dst = Naming.unique(in: dir, name, format.ext)
            try await cleaningUp(dst) {
                try await VideoEngine.compress(src, to: dst, format: format, level: level, progress: progress)
            }
        case .audio:
            dst = Naming.unique(in: dir, name, "m4a")
            try await cleaningUp(dst) {
                try await AudioEngine.convert(src, to: dst, format: .m4a, bitRate: level.audioBitRate)
            }
        case .pdf:
            dst = Naming.unique(in: dir, name, "pdf")
            try await cleaningUp(dst) { try PDFEngine.compress(src, to: dst, level: level, progress: progress) }
        }

        if let before = size(of: src), let after = size(of: dst), after >= before {
            try? FileManager.default.removeItem(at: dst)
            return .skipped("Already optimized")
        }
        return .output(dst)
    }

    /// Removes a partially written output if the work fails or is cancelled.
    private static func cleaningUp(_ dst: URL, _ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch {
            try? FileManager.default.removeItem(at: dst)
            throw error
        }
    }

    static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }
}

enum Naming {
    private static let compoundExtensions = [".tar.gz", ".tar.bz2", ".tar.xz"]

    static func base(of url: URL) -> String {
        let name = url.lastPathComponent
        for ext in compoundExtensions where name.lowercased().hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Finder-style unique name: "Photo.jpg", "Photo 2.jpg", "Photo 3.jpg"…
    static func unique(in dir: URL, _ base: String, _ ext: String) -> URL {
        func candidate(_ n: Int) -> URL {
            let url = dir.appendingPathComponent(n == 1 ? base : "\(base) \(n)")
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        var n = 1
        while FileManager.default.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }
}

enum Shell {
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var lastLine: String? {
            lock.withLock {
                String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline).last.map(String.init)
            }
        }
    }

    static func run(_ path: String, _ arguments: [String], in directory: URL? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        let buffer = Buffer()
        pipe.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let tool = URL(fileURLWithPath: path).lastPathComponent
                        continuation.resume(throwing: ConversionError.message(buffer.lastLine ?? "\(tool) failed."))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
