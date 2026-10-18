import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageEngine {
    private static let writableTypes = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    static func canWrite(_ format: OutputFormat) -> Bool {
        if format == .pdf { return true }
        guard let type = format.utType else { return false }
        return writableTypes.contains(type.identifier)
    }

    static func write(_ src: URL, to dst: URL, format: OutputFormat, quality: Double?,
                      maxPixel: Int?, keepMetadata: Bool) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { throw ConversionError.unreadable }
        let count = CGImageSourceGetCount(source)
        let isGIFSource = OutputFormat.gif.matches(src)

        if format == .pdf {
            try writePDF(src, source, pages: isGIFSource ? 1 : count, to: dst)
            return
        }

        // Keep animation when writing GIF; every other format takes the first frame.
        let frames = format == .gif ? count : 1
        guard let type = format.utType,
              let dest = CGImageDestinationCreateWithURL(dst as CFURL, type.identifier as CFString, frames, nil)
        else { throw ConversionError.unsupported }

        if format == .gif, frames > 1,
           let fileProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
           let gif = fileProps[kCGImagePropertyGIFDictionary] {
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
        }

        for index in 0..<frames {
            guard var image = image(from: source, at: index, maxPixel: maxPixel) else {
                throw ConversionError.unreadable
            }
            if format.isOpaque, image.hasAlpha, let flat = flattened(image) { image = flat }
            var props = properties(source, at: index, format: format, keepMetadata: keepMetadata)
            if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        }

        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.message("The image couldn't be saved as \(format.label).")
        }
    }

    /// Decodes a frame with its orientation applied, optionally downscaled.
    static func image(from source: CGImageSource, at index: Int, maxPixel: Int?) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        var limit = max(width, height) > 0 ? max(width, height) : 4096
        if let maxPixel { limit = min(limit, maxPixel) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    private static func properties(_ source: CGImageSource, at index: Int, format: OutputFormat,
                                   keepMetadata: Bool) -> [CFString: Any] {
        let original = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        var props: [CFString: Any] = [:]

        if keepMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                props[key] = original[key]
            }
        }
        if format == .gif { props[kCGImagePropertyGIFDictionary] = original[kCGImagePropertyGIFDictionary] }

        // Orientation is already baked into the pixels.
        props[kCGImagePropertyOrientation] = 1
        var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        if format == .tiff { tiff[kCGImagePropertyTIFFCompression] = 5 }  // LZW
        props[kCGImagePropertyTIFFDictionary] = tiff
        return props
    }

    private static func writePDF(_ src: URL, _ source: CGImageSource, pages: Int, to dst: URL) throws {
        guard let context = CGContext(dst as CFURL, mediaBox: nil, nil) else { throw ConversionError.unsupported }
        for index in 0..<pages {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            guard let image = embeddableJPEG(src, source, props) ?? image(from: source, at: index, maxPixel: nil) else { continue }
            let dpi = max(props[kCGImagePropertyDPIWidth] as? Double ?? 72, 1)
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    /// An upright JPEG can go into a PDF untouched instead of being re-encoded.
    private static func embeddableJPEG(_ src: URL, _ source: CGImageSource, _ props: [CFString: Any]) -> CGImage? {
        guard CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              (props[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              let provider = CGDataProvider(url: src as CFURL) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func flattened(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

/// macOS reads WebP but can't write it, so encoding goes through `cwebp` (brew install webp).
enum WebPEncoder {
    static let path: String? = ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp", "/opt/local/bin/cwebp"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func encode(_ src: URL, to dst: URL) async throws {
        guard let path else { throw ConversionError.message("WebP needs cwebp. Install it with “brew install webp”.") }
        // cwebp can't read HEIC or RAW, so hand it an upright PNG.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try ImageEngine.write(src, to: temp, format: .png, quality: nil, maxPixel: nil, keepMetadata: true)
        try await Shell.run(path, ["-quiet", "-q", "85", "-metadata", "exif,icc", temp.path, "-o", dst.path])
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
