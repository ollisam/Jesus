import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// One entry in the quick action menu.
enum Action: Hashable {
    case convert(OutputFormat)
    case compress(CompressionLevel)

    /// Text on the radial button.
    var label: String {
        switch self {
        case .compress: "Compress"
        case .convert(.extract): "Unzip"
        case .convert(let format): format.ext.uppercased()
        }
    }

    /// Tooltip.
    var title: String {
        switch self {
        case .compress: "Compress"
        case .convert(.extract): "Extract archive"
        case .convert(let format): "Convert to \(format.label)"
        }
    }
}

enum CompressionLevel: String, CaseIterable, Identifiable {
    case smallest, balanced, best
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smallest: "Smallest"
        case .balanced: "Balanced"
        case .best: "Best Quality"
        }
    }

    var imageQuality: Double {
        switch self {
        case .smallest: 0.5
        case .balanced: 0.7
        case .best: 0.85
        }
    }

    var maxPixel: Int? {
        switch self {
        case .smallest: 1600
        case .balanced: 2560
        case .best: nil
        }
    }

    var audioBitRate: Int {
        switch self {
        case .smallest: 96_000
        case .balanced: 160_000
        case .best: 256_000
        }
    }

    var videoPresets: [String] {
        switch self {
        case .smallest: [AVAssetExportPreset1280x720]
        case .balanced: [AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1920x1080]
        case .best: [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
        }
    }

    var ffmpegCRF: Int {
        switch self {
        case .smallest: 30
        case .balanced: 26
        case .best: 22
        }
    }
}

enum FileKind: Int, CaseIterable, Identifiable, Comparable {
    case image, video, audio, pdf, document, subtitle, archive, other

    var id: Int { rawValue }
    static func < (a: FileKind, b: FileKind) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .pdf: "PDFs"
        case .document: "Documents"
        case .subtitle: "Subtitles"
        case .archive: "Archives"
        case .other: "Other Files"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .subtitle: "captions.bubble"
        case .archive: "archivebox"
        case .other: "folder"
        }
    }

    var formats: [OutputFormat] {
        let list: [OutputFormat] = switch self {
        case .image: [.jpg, .jpeg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf]
            .filter { $0 == .webp || ImageEngine.canWrite($0) }
        case .video: [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3]
        case .audio: [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
        case .pdf: [.docx, .pages, .pptx, .xlsx, .jpg, .png, .txt, .md]
        case .document: [.docx, .pages, .pdf, .txt, .md, .html, .png, .jpg]
        case .subtitle: [.srt, .vtt]
        case .archive: [.extract, .zip]
        case .other: []
        }
        return list.filter { (!$0.needsFFmpeg || FFmpeg.isAvailable) && ($0 != .pages || IWork.hasPages) }
    }

    private static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar"]
    private static let extraVideoExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "3gp", "ogv"]
    private static let extraAudioExtensions: Set<String> = ["ogg", "oga", "opus", "wma", "ape"]
    private static let documentTypes: [UTType] = [
        .rtf, .rtfd, .flatRTFD, .plainText, .html, .webArchive,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
    ].compactMap { $0 }

    static func detect(_ url: URL) -> FileKind {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true && values?.isPackage != true { return .other }

        let ext = url.pathExtension.lowercased()
        if ext == "srt" || ext == "vtt" { return .subtitle }
        if archiveExtensions.contains(ext) { return .archive }
        if extraVideoExtensions.contains(ext) { return .video }
        if extraAudioExtensions.contains(ext) { return .audio }

        guard let type = values?.contentType else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .archive) { return .archive }
        if documentTypes.contains(where: type.conforms) { return .document }
        return .other
    }
}

enum OutputFormat: String, CaseIterable, Identifiable, Hashable {
    case jpg, jpeg, png, heic, tiff, webp, avif, gif, bmp, pdf  // jpg and jpeg differ only in extension
    case mp4, mov, m4v, webm, mkv, avi, wmv
    case m4a, mp3, wav, aiff, flac, ogg, opus, wma
    case docx, doc, rtf, odt, html, txt, md, epub, pages, pptx, xlsx
    case srt, vtt
    case zip, extract

    var id: String { rawValue }

    var label: String {
        switch self {
        case .extract: "Extract"
        case .zip: "ZIP Archive"
        case .webp: "WebP"
        case .txt: "Plain Text"
        case .md: "Markdown"
        case .pages: "Pages"
        default: rawValue.uppercased()
        }
    }

    var ext: String {
        switch self {
        case .extract: ""
        default: rawValue
        }
    }

    private var aliases: Set<String> {
        switch self {
        case .jpg: ["jpg", "jpe"]
        case .tiff: ["tif", "tiff"]
        case .html: ["html", "htm"]
        case .md: ["md", "markdown"]
        case .aiff: ["aif", "aiff"]
        case .mov: ["mov", "qt"]
        case .extract: []
        default: [ext]
        }
    }

    func matches(_ url: URL) -> Bool { aliases.contains(url.pathExtension.lowercased()) }

    static func of(_ url: URL) -> OutputFormat? { allCases.first { $0.matches(url) } }

    var utType: UTType? {
        switch self {
        case .jpg, .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .webp: .webP
        case .avif: UTType("public.avif")
        case .gif: .gif
        case .bmp: .bmp
        default: nil
        }
    }

    var isLossy: Bool { [.jpg, .jpeg, .heic, .webp, .avif].contains(self) }
    var isOpaque: Bool { [.jpg, .jpeg, .bmp].contains(self) }
    var needsFFmpeg: Bool { [.webm, .mkv, .avi, .wmv, .mp3, .ogg, .opus, .wma].contains(self) }

    var avFileType: AVFileType? {
        switch self {
        case .mp4: .mp4
        case .mov: .mov
        case .m4v: .m4v
        case .m4a: .m4a
        default: nil
        }
    }

    var documentType: NSAttributedString.DocumentType? {
        switch self {
        case .docx: .officeOpenXML
        case .doc: .docFormat
        case .rtf: .rtf
        case .odt: .openDocument
        case .html: .html
        case .txt: .plain
        default: nil
        }
    }
}

enum ConversionError: LocalizedError {
    case unreadable, unsupported, needsFFmpeg, message(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file couldn't be read."
        case .unsupported: "This conversion isn't supported."
        case .needsFFmpeg: "This format needs ffmpeg. Install it with “brew install ffmpeg”."
        case .message(let text): text
        }
    }
}
