import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
enum DocumentEngine {
    static func convert(_ src: URL, to dst: URL, format: OutputFormat) async throws {
        try await write(try read(src), title: Naming.base(of: src), to: dst, format: format)
    }

    /// PDF → editable text formats, slides (one page per slide) or a spreadsheet (one sheet per page).
    /// Rendering stays off the main thread; only writing rich text hops onto it.
    nonisolated static func convertPDF(_ src: URL, to dst: URL, format: OutputFormat) async throws {
        let document = try PDFEngine.open(src)
        switch format {
        case .txt:
            try PDFEngine.text(src, to: dst)
        case .pptx:
            try await Office.pptx(slides: PDFEngine.slides(document), to: dst)
        case .xlsx:
            try await Office.xlsx(sheets: PDFEngine.tables(document), to: dst)
        default:
            let text = PDFEngine.attributedText(document)
            guard text.length > 0 else { throw ConversionError.message("This PDF has no text (it may be scanned).") }
            try await write(text, title: Naming.base(of: src), to: dst, format: format)
        }
    }

    /// Lays the document out on pages, then renders each page as an image.
    nonisolated static func images(_ src: URL, in dir: URL, base: String, format: OutputFormat,
                                   progress: ProgressHandler) async throws -> URL {
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: pdf) }
        try await MainActor.run { try printPDF(try read(src), to: pdf) }
        return try PDFEngine.images(pdf, in: dir, base: base, format: format, progress: progress)
    }

    private static func write(_ text: NSAttributedString, title: String, to dst: URL,
                              format: OutputFormat) async throws {
        switch format {
        case .pdf:
            try printPDF(text, to: dst)
        case .md:
            try Markup.render(text, as: .markdown).write(to: dst, atomically: true, encoding: .utf8)
        case .epub:
            try await EPUB.write(title: title, body: Markup.render(text, as: .xhtml), to: dst)
        case .pages:
            let docx = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
            defer { try? FileManager.default.removeItem(at: docx) }
            try await write(text, title: title, to: docx, format: .docx)
            try await IWork.exportToPages(docx, to: dst)
        default:
            guard let type = format.documentType else { throw ConversionError.unsupported }
            var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if type == .plain || type == .html { attributes[.characterEncoding] = String.Encoding.utf8.rawValue }
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
            try data.write(to: dst, options: .atomic)
        }
    }

    private static func read(_ src: URL) throws -> NSAttributedString {
        let type = (try? src.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let isRich = [UTType.rtf, .rtfd, .flatRTFD, .html].contains { type?.conforms(to: $0) == true }
        if let type, type.conforms(to: .plainText), !isRich {
            var encoding = String.Encoding.utf8
            let string = try (try? String(contentsOf: src, usedEncoding: &encoding))
                ?? String(contentsOf: src, encoding: .isoLatin1)
            return NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.black,
            ])
        }
        return try NSAttributedString(url: src, options: [:], documentAttributes: nil)
    }

    private static func printPDF(_ text: NSAttributedString, to dst: URL) throws {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = dst

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.textStorage?.setAttributedString(text)
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw ConversionError.message("The PDF couldn't be created.") }
    }
}

enum PDFEngine {
    static func open(_ src: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: src), document.pageCount > 0 else { throw ConversionError.unreadable }
        if document.isLocked { throw ConversionError.message("This PDF is password-protected.") }
        return document
    }

    static func text(_ src: URL, to dst: URL) throws {
        let document = try open(src)
        try (document.string ?? "").write(to: dst, atomically: true, encoding: .utf8)
    }

    /// The text of every page with its fonts, for DOCX, Markdown and Pages.
    static func attributedText(_ document: PDFDocument) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.attributedString, page.length > 0 else { continue }
            if text.length > 0 { text.append(NSAttributedString(string: "\n\n")) }
            text.append(page)
        }
        return text
    }

    /// One table per page. PDF text has no table structure, so each word is located on the page:
    /// words at the same height form a row, and a gap wider than about a character starts a new cell.
    static func tables(_ document: PDFDocument) -> [(name: String, rows: [[String]])] {
        let wordPattern = try! NSRegularExpression(pattern: #"\S+"#)
        return (0..<document.pageCount).map { index in
            let name = "Page \(index + 1)"
            guard let page = document.page(at: index), let string = page.string else { return (name, []) }
            let text = string as NSString

            let words = wordPattern.matches(in: string, range: NSRange(location: 0, length: text.length))
                .compactMap { match -> (text: String, frame: CGRect)? in
                    guard let frame = page.selection(for: match.range)?.bounds(for: page), !frame.isEmpty else { return nil }
                    return (text.substring(with: match.range), frame)
                }
                .sorted { $0.frame.midY > $1.frame.midY }  // top of the page first

            var lines: [[(text: String, frame: CGRect)]] = []
            for word in words {
                if let first = lines.last?.first,
                   abs(first.frame.midY - word.frame.midY) < min(first.frame.height, word.frame.height) * 0.5 {
                    lines[lines.count - 1].append(word)
                } else {
                    lines.append([word])
                }
            }

            let rows = lines.map { line -> [String] in
                var cells: [String] = []
                var previous: CGRect?
                for word in line.sorted(by: { $0.frame.minX < $1.frame.minX }) {
                    if let previous, word.frame.minX - previous.maxX <= previous.height * 0.8 {
                        cells[cells.count - 1] += " " + word.text
                    } else {
                        cells.append(word.text)
                    }
                    previous = word.frame
                }
                return cells
            }
            return (name, rows)
        }
    }

    /// Every page as a JPEG, with its size in points, for slides.
    static func slides(_ document: PDFDocument) throws -> [(image: Data, size: CGSize)] {
        try (0..<document.pageCount).compactMap { index in
            try Task.checkCancellation()
            guard let page = document.page(at: index), let image = render(page, scale: 2) else { return nil }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return (data as Data, pageSize(page))
        }
    }

    /// One image for a single-page PDF, otherwise a folder with one image per page.
    static func images(_ src: URL, in dir: URL, base: String, format: OutputFormat,
                       progress: ProgressHandler) throws -> URL {
        let document = try open(src)
        let count = document.pageCount
        let folder = count == 1 ? dir : Naming.unique(in: dir, "\(base) Pages", "")
        if count > 1 { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }

        do {
            var last = folder
            let digits = String(count).count
            for index in 0..<count {
                try Task.checkCancellation()
                guard let page = document.page(at: index), let image = render(page, scale: 2) else { continue }
                let number = String(repeating: "0", count: digits - String(index + 1).count) + String(index + 1)
                last = count == 1 ? Naming.unique(in: dir, base, format.ext)
                                  : folder.appendingPathComponent("\(base) \(number).\(format.ext)")
                guard let dest = CGImageDestinationCreateWithURL(last as CFURL, format.utType!.identifier as CFString, 1, nil)
                else { throw ConversionError.unsupported }
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                CGImageDestinationFinalize(dest)
                progress(Double(index + 1) / Double(count))
            }
            return count == 1 ? last : folder
        } catch {
            if count > 1 { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
    }

    static func compress(_ src: URL, to dst: URL, level: CompressionLevel, progress: ProgressHandler) throws {
        let document = try open(src)
        switch level {
        case .smallest:
            try rasterize(document, to: dst, dpi: 110, quality: 0.55, progress: progress)
        case .balanced:
            guard document.write(to: dst, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            else { throw ConversionError.message("The PDF couldn't be saved.") }
        case .best:
            guard document.write(to: dst, withOptions: [.saveImagesAsJPEGOption: true])
            else { throw ConversionError.message("The PDF couldn't be saved.") }
        }
    }

    /// Re-renders every page as a JPEG. Smallest output, but text is no longer selectable.
    private static func rasterize(_ document: PDFDocument, to dst: URL, dpi: CGFloat, quality: Double,
                                  progress: ProgressHandler) throws {
        guard let context = CGContext(dst as CFURL, mediaBox: nil, nil) else { throw ConversionError.unsupported }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let image = render(page, scale: dpi / 72),
                  let jpeg = jpegImage(image, quality: quality) else { continue }
            var box = CGRect(origin: .zero, size: pageSize(page))
            context.beginPage(mediaBox: &box)
            context.draw(jpeg, in: box)
            context.endPage()
            progress(Double(index + 1) / Double(document.pageCount))
        }
        context.closePDF()
    }

    private static func pageSize(_ page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .mediaBox)
        return page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    private static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let size = pageSize(page)
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.transform(context, for: .mediaBox)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// A JPEG-backed CGImage, which Quartz embeds in the PDF as-is.
    private static func jpegImage(_ image: CGImage, quality: Double) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum SubtitleEngine {
    private struct Cue {
        var start: String
        var end: String
        var text: [String]
    }

    static func convert(_ src: URL, to dst: URL, format: OutputFormat) throws {
        let raw = try (try? String(contentsOf: src, encoding: .utf8)) ?? String(contentsOf: src, encoding: .isoLatin1)
        let cues = parse(raw)
        guard !cues.isEmpty else { throw ConversionError.message("No subtitles were found in this file.") }

        let blocks = cues.enumerated().map { index, cue in
            let times = format == .srt
                ? "\(cue.start.replacingOccurrences(of: ".", with: ",")) --> \(cue.end.replacingOccurrences(of: ".", with: ","))"
                : "\(cue.start) --> \(cue.end)"
            return (["\(index + 1)", times] + cue.text).joined(separator: "\n")
        }
        let body = blocks.joined(separator: "\n\n") + "\n"
        try (format == .vtt ? "WEBVTT\n\n" + body : body).write(to: dst, atomically: true, encoding: .utf8)
    }

    private static func parse(_ raw: String) -> [Cue] {
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        return text.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n").map(String.init)
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[index].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0]),
                  let end = timestamp(parts[1].split(separator: " ").first.map(String.init) ?? "") else { return nil }
            return Cue(start: start, end: end, text: Array(lines[(index + 1)...]))
        }
    }

    /// Normalizes "HH:MM:SS,mmm", "HH:MM:SS.mmm" or "MM:SS.mmm" to "HH:MM:SS.mmm".
    private static func timestamp(_ value: String) -> String? {
        let fields = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard fields.count == 2 || fields.count == 3 else { return nil }
        let seconds = fields[fields.count - 1].split(separator: ".")
        let millis = seconds.count > 1 ? String(seconds[1].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) : "0"
        guard let h = fields.count == 3 ? Int(fields[0]) : 0,
              let m = Int(fields[fields.count - 2]),
              let s = Int(seconds[0]),
              let ms = Int(millis) else { return nil }
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}

enum ArchiveEngine {
    static func zip(_ src: URL, to dst: URL) async throws {
        try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, dst.path])
    }

    /// Extracts like Archive Utility: a single top-level item lands directly beside
    /// the archive, multiple items go into a folder named after it.
    static func extract(_ src: URL, into dir: URL, base: String) async throws -> URL {
        let temp = try unpack(src, near: dir)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await runUnpack(src, into: temp)

        let contents = try topLevel(temp)
        let fm = FileManager.default
        if contents.count == 1, let item = contents.first {
            let dst = Naming.unique(in: dir, item.deletingPathExtension().lastPathComponent, item.pathExtension)
            try fm.moveItem(at: item, to: dst)
            return dst
        }
        let dst = Naming.unique(in: dir, base, "")
        try fm.createDirectory(at: dst, withIntermediateDirectories: false)
        for item in contents { try fm.moveItem(at: item, to: dst.appendingPathComponent(item.lastPathComponent)) }
        return dst
    }

    /// Converts any supported archive (tar.gz, 7z, rar…) to ZIP.
    static func rezip(_ src: URL, to dst: URL) async throws {
        let temp = try unpack(src, near: dst.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: temp) }
        try await runUnpack(src, into: temp)

        let contents = try topLevel(temp)
        if contents.count == 1, let item = contents.first {
            try await zip(item, to: dst)
        } else {
            try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", temp.path, dst.path])
        }
    }

    private static func unpack(_ src: URL, near dir: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dir, create: true)
    }

    private static func runUnpack(_ src: URL, into folder: URL) async throws {
        if src.pathExtension.lowercased() == "zip" {
            try await Shell.run("/usr/bin/ditto", ["-x", "-k", src.path, folder.path])
        } else {
            try await Shell.run("/usr/bin/tar", ["-xf", src.path, "-C", folder.path])
        }
    }

    private static func topLevel(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
    }
}
