import AppKit

/// Rich text → Markdown or XHTML: headings (from font size), lists, bold, italic and links.
enum Markup {
    enum Style { case markdown, xhtml }

    private enum Block {
        case heading(Int, String)
        case paragraph(String)
        case item(ordered: Bool, String)
    }

    /// "•", "–", "1.", "1)" followed by space, or Word's "1⇥" (number then tab).
    private static let markerPattern = #"^(([•◦▪▫●○■□‣⁃–\-\*]|\d{1,3}[.)])\s+|\d{1,3}\t)"#

    static func render(_ text: NSAttributedString, as style: Style) -> String {
        let body = bodyFontSize(text)
        var blocks: [Block] = []
        let string = text.string as NSString

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                                   options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let paragraph = text.attributedSubstring(from: range)
            let plain = paragraph.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { return }

            // List items: a typed marker ("•", "1.") or a real text list from Word/RTF.
            let leading = paragraph.string.prefix { $0.isWhitespace }.utf16.count
            let rest = String(paragraph.string.dropFirst(leading))
            if let marker = rest.range(of: markerPattern, options: .regularExpression) {
                let length = rest[marker].utf16.count
                let content = paragraph.attributedSubstring(from: NSRange(location: leading + length,
                                                                          length: paragraph.length - leading - length))
                blocks.append(.item(ordered: rest.first?.isNumber == true, inline(content, style)))
                return
            }
            let attributes = paragraph.attributes(at: 0, effectiveRange: nil)
            if let list = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textLists.last {
                blocks.append(.item(ordered: list.markerFormat == .decimal, inline(paragraph, style)))
                return
            }

            let level = headingLevel(paragraph, plain: plain, body: body)
            blocks.append(level > 0 ? .heading(level, escape(plain, style)) : .paragraph(inline(paragraph, style)))
        }

        return style == .markdown ? markdown(blocks) : xhtml(blocks)
    }

    private static func markdown(_ blocks: [Block]) -> String {
        var out = ""
        var number = 0
        var previousList: Bool?  // ordered? — nil when the previous block wasn't a list item
        for block in blocks {
            var list: Bool?
            let line: String
            switch block {
            case .heading(let level, let text):
                line = String(repeating: "#", count: level) + " " + text
            case .paragraph(let text):
                line = text
            case .item(let ordered, let text):
                list = ordered
                number = previousList == ordered ? number + 1 : 1
                line = (ordered ? "\(number). " : "- ") + text
            }
            // Items of the same list sit on consecutive lines; everything else is a new block.
            if !out.isEmpty { out += list != nil && list == previousList ? "\n" : "\n\n" }
            out += line
            previousList = list
        }
        return out + "\n"
    }

    private static func xhtml(_ blocks: [Block]) -> String {
        var out = ""
        var openList: Bool?  // ordered?
        for block in blocks {
            if case .item(let ordered, _) = block, openList == ordered {
                // stays in the current list
            } else if let ordered = openList {
                out += ordered ? "</ol>\n" : "</ul>\n"
                openList = nil
            }
            switch block {
            case .heading(let level, let text):
                out += "<h\(level)>\(text)</h\(level)>\n"
            case .paragraph(let text):
                out += "<p>\(text)</p>\n"
            case .item(let ordered, let text):
                if openList == nil {
                    out += ordered ? "<ol>\n" : "<ul>\n"
                    openList = ordered
                }
                out += "<li>\(text)</li>\n"
            }
        }
        if let ordered = openList { out += ordered ? "</ol>\n" : "</ul>\n" }
        return out
    }

    /// Inline runs with the same styling are merged, so "**a****b**" never appears.
    private static func inline(_ text: NSAttributedString, _ style: Style) -> String {
        struct Run { var text: String; var bold: Bool; var italic: Bool; var link: URL? }
        var runs: [Run] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let raw = (text.string as NSString).substring(with: range)
                .replacingOccurrences(of: "\u{2028}", with: " ").replacingOccurrences(of: "\n", with: " ")
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let link = attributes[.link] as? URL ?? (attributes[.link] as? String).flatMap(URL.init(string:))
            let run = Run(text: raw, bold: traits.contains(.bold), italic: traits.contains(.italic), link: link)
            if let last = runs.last, last.bold == run.bold, last.italic == run.italic, last.link == run.link {
                runs[runs.count - 1].text += raw
            } else {
                runs.append(run)
            }
        }

        var out = ""
        for run in runs {
            let core = run.text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { out += run.text; continue }
            let lead = String(run.text.prefix { $0 == " " || $0 == "\t" })
            let trail = String(run.text.reversed().prefix { $0 == " " || $0 == "\t" })
            var piece = escape(core, style)
            switch style {
            case .markdown:
                if run.bold && run.italic { piece = "***\(piece)***" }
                else if run.bold { piece = "**\(piece)**" }
                else if run.italic { piece = "*\(piece)*" }
                if let link = run.link { piece = "[\(piece)](\(link.absoluteString))" }
            case .xhtml:
                if run.italic { piece = "<em>\(piece)</em>" }
                if run.bold { piece = "<strong>\(piece)</strong>" }
                if let link = run.link { piece = "<a href=\"\(XML.escape(link.absoluteString))\">\(piece)</a>" }
            }
            out += lead + piece + trail
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func headingLevel(_ paragraph: NSAttributedString, plain: String, body: CGFloat) -> Int {
        guard plain.count <= 160 else { return 0 }
        let size = (paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? body
        let ratio = size / max(body, 1)
        if ratio >= 1.6 { return 1 }
        if ratio >= 1.3 { return 2 }
        if ratio >= 1.12 { return 3 }
        // A short line that's entirely bold reads as a heading too.
        var allBold = true
        paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { font, range, stop in
            let text = (paragraph.string as NSString).substring(with: range)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (font as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) != true {
                allBold = false
                stop.pointee = true
            }
        }
        return allBold && plain.count <= 80 && !plain.hasSuffix(".") ? 3 : 0
    }

    /// The most common font size, weighted by length.
    private static func bodyFontSize(_ text: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { font, range, _ in
            counts[(font as? NSFont)?.pointSize ?? 12, default: 0] += range.length
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }

    private static func escape(_ text: String, _ style: Style) -> String {
        switch style {
        case .xhtml:
            return XML.escape(text)
        case .markdown:
            var out = ""
            for character in text {
                if "\\`*_[]<>".contains(character) { out.append("\\") }
                out.append(character)
            }
            return out
        }
    }
}

enum XML {
    /// Escapes text for XML and drops the control characters XML 1.0 forbids.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default: if scalar.value >= 0x20 { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}

/// Zip-based formats (EPUB, PPTX, XLSX) built from a dictionary of files.
enum Package {
    /// `stored` files go first and uncompressed, as EPUB requires for its mimetype.
    static func write(_ files: [String: String], data: [String: Data] = [:], stored: [String] = [],
                      to dst: URL) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let all = files.mapValues { Data($0.utf8) }.merging(data) { a, _ in a }
        for (path, contents) in all {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
        }
        // -nw: names like "[Content_Types].xml" are literal, not wildcards.
        if !stored.isEmpty {
            try await Shell.run("/usr/bin/zip", ["-X", "-0", "-q", "-nw", dst.path] + stored, in: dir)
        }
        let rest = all.keys.filter { !stored.contains($0) }.sorted()
        try await Shell.run("/usr/bin/zip", ["-X", "-9", "-q", "-nw", dst.path] + rest, in: dir)
    }
}

enum EPUB {
    static func write(title: String, body: String, to dst: URL) async throws {
        let title = XML.escape(title)
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let modified = ISO8601DateFormatter().string(from: Date())
        try await Package.write([
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
                <?xml version="1.0" encoding="UTF-8"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """,
            "OEBPS/content.opf": """
                <?xml version="1.0" encoding="UTF-8"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:language>\(language)</dc:language>
                <meta property="dcterms:modified">\(modified)</meta>
                </metadata>
                <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
                </manifest>
                <spine><itemref idref="text"/></spine>
                </package>
                """,
            "OEBPS/nav.xhtml": """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
                <head><title>\(title)</title></head>
                <body><nav epub:type="toc"><ol><li><a href="text.xhtml">\(title)</a></li></ol></nav></body>
                </html>
                """,
            "OEBPS/text.xhtml": """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(language)">
                <head><title>\(title)</title></head>
                <body>
                \(body)</body>
                </html>
                """,
        ], stored: ["mimetype"], to: dst)
    }
}

/// Minimal Office Open XML writers: one slide per image, one sheet per table.
enum Office {
    private static let ns = """
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
        """
    private static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
    private static let emptyTree = """
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        """

    /// Each image fills one slide; the slide shape follows the first image.
    static func pptx(slides: [(image: Data, size: CGSize)], to dst: URL) async throws {
        guard let first = slides.first else { throw ConversionError.message("This PDF has no pages.") }
        let width = 12_192_000
        let height = min(max(Int(Double(width) * first.size.height / max(first.size.width, 1)), 914_400), 51_206_400)

        var files: [String: String] = [:]
        var images: [String: Data] = [:]
        var overrides = "", slideIDs = "", slideRels = ""

        for (index, slide) in slides.enumerated() {
            let n = index + 1
            images["ppt/media/image\(n).jpeg"] = slide.image
            // Fit the page inside the slide, centered.
            let scale = min(Double(width) / max(slide.size.width, 1), Double(height) / max(slide.size.height, 1))
            let cx = Int(slide.size.width * scale), cy = Int(slide.size.height * scale)
            files["ppt/slides/slide\(n).xml"] = header + """
                <p:sld \(ns)><p:cSld><p:spTree>\(emptyTree)\
                <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(n)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
                <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
                <p:spPr><a:xfrm><a:off x="\((width - cx) / 2)" y="\((height - cy) / 2)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
                <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>\
                </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
                """
            files["ppt/slides/_rels/slide\(n).xml.rels"] = relationships([
                ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
                ("rId2", "image", "../media/image\(n).jpeg"),
            ])
            overrides += #"<Override PartName="/ppt/slides/slide\#(n).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
            slideIDs += #"<p:sldId id="\#(255 + n)" r:id="rId\#(n + 1)"/>"#
            slideRels += #"<Relationship Id="rId\#(n + 1)" Type="\#(rel)/slide" Target="slides/slide\#(n).xml"/>"#
        }

        files["[Content_Types].xml"] = header + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Default Extension="jpeg" ContentType="image/jpeg"/>\
            <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
            <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
            <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
            <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
            \(overrides)</Types>
            """
        files["_rels/.rels"] = relationships([("rId1", "officeDocument", "ppt/presentation.xml")])
        files["ppt/presentation.xml"] = header + """
            <p:presentation \(ns)>\
            <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
            <p:sldIdLst>\(slideIDs)</p:sldIdLst>\
            <p:sldSz cx="\(width)" cy="\(height)"/><p:notesSz cx="6858000" cy="9144000"/>\
            </p:presentation>
            """
        files["ppt/_rels/presentation.xml.rels"] = header + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(rel)/slideMaster" Target="slideMasters/slideMaster1.xml"/>\
            \(slideRels)\
            <Relationship Id="rId\(slides.count + 2)" Type="\(rel)/theme" Target="theme/theme1.xml"/>\
            </Relationships>
            """
        files["ppt/slideMasters/slideMaster1.xml"] = header + """
            <p:sldMaster \(ns)><p:cSld><p:spTree>\(emptyTree)</p:spTree></p:cSld>\
            <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" \
            accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
            <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
            """
        files["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = relationships([
            ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
            ("rId2", "theme", "../theme/theme1.xml"),
        ])
        files["ppt/slideLayouts/slideLayout1.xml"] = header + """
            <p:sldLayout \(ns) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\(emptyTree)</p:spTree></p:cSld>\
            <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
            """
        files["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = relationships([
            ("rId1", "slideMaster", "../slideMasters/slideMaster1.xml"),
        ])
        files["ppt/theme/theme1.xml"] = header + theme

        try await Package.write(files, data: images, to: dst)
    }

    /// One worksheet per table; numbers stay numbers.
    static func xlsx(sheets: [(name: String, rows: [[String]])], to dst: URL) async throws {
        let sheets = sheets.isEmpty ? [("Sheet 1", [])] : sheets
        var files: [String: String] = [:]
        var overrides = "", entries = "", rels = ""

        for (index, sheet) in sheets.enumerated() {
            let n = index + 1
            var rows = ""
            for (r, row) in sheet.rows.enumerated() {
                rows += #"<row r="\#(r + 1)">"#
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let ref = column(c) + String(r + 1)
                    if value.range(of: #"^-?(0|[1-9]\d*)(\.\d+)?$"#, options: .regularExpression) != nil {
                        rows += #"<c r="\#(ref)"><v>\#(value)</v></c>"#
                    } else {
                        rows += #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(XML.escape(value))</t></is></c>"#
                    }
                }
                rows += "</row>"
            }
            files["xl/worksheets/sheet\(n).xml"] = header + """
                <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rows)</sheetData></worksheet>
                """
            overrides += #"<Override PartName="/xl/worksheets/sheet\#(n).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            entries += #"<sheet name="\#(XML.escape(String(sheet.name.prefix(31))))" sheetId="\#(n)" r:id="rId\#(n)"/>"#
            rels += #"<Relationship Id="rId\#(n)" Type="\#(rel)/worksheet" Target="worksheets/sheet\#(n).xml"/>"#
        }

        files["[Content_Types].xml"] = header + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            \(overrides)</Types>
            """
        files["_rels/.rels"] = relationships([("rId1", "officeDocument", "xl/workbook.xml")])
        files["xl/workbook.xml"] = header + """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\(rel)">\
            <sheets>\(entries)</sheets></workbook>
            """
        files["xl/_rels/workbook.xml.rels"] = header + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
            """
        try await Package.write(files, to: dst)
    }

    /// 0 → A, 25 → Z, 26 → AA.
    private static func column(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 {
            name = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + name
            n = (n - 1) / 26
        }
        return name
    }

    private static func relationships(_ items: [(id: String, type: String, target: String)]) -> String {
        header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + items.map { #"<Relationship Id="\#($0.id)" Type="\#(rel)/\#($0.type)" Target="\#($0.target)"/>"# }.joined()
            + "</Relationships>"
    }

    private static let theme = """
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Recast"><a:themeElements>\
        <a:clrScheme name="Recast">\
        <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
        <a:dk2><a:srgbClr val="1F1F1F"/></a:dk2><a:lt2><a:srgbClr val="F2F2F2"/></a:lt2>\
        <a:accent1><a:srgbClr val="0A84FF"/></a:accent1><a:accent2><a:srgbClr val="30D158"/></a:accent2>\
        <a:accent3><a:srgbClr val="FF9F0A"/></a:accent3><a:accent4><a:srgbClr val="FF375F"/></a:accent4>\
        <a:accent5><a:srgbClr val="BF5AF2"/></a:accent5><a:accent6><a:srgbClr val="64D2FF"/></a:accent6>\
        <a:hlink><a:srgbClr val="0A84FF"/></a:hlink><a:folHlink><a:srgbClr val="BF5AF2"/></a:folHlink>\
        </a:clrScheme>\
        <a:fontScheme name="Recast">\
        <a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
        <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>\
        </a:fontScheme>\
        <a:fmtScheme name="Recast">\
        <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>\
        <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\
        <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
        <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>\
        </a:fmtScheme></a:themeElements></a:theme>
        """
}

/// Pages files can only be written by Pages itself, so this option appears only when it's installed.
enum IWork {
    static let hasPages = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages") != nil

    /// Opens a DOCX in Pages and saves it as a Pages document.
    static func exportToPages(_ docx: URL, to dst: URL) async throws {
        try await Shell.run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "tell application id \"com.apple.iWork.Pages\"",
            "-e", "set d to open (POSIX file (item 1 of argv))",
            "-e", "save d in POSIX file (item 2 of argv)",
            "-e", "close d saving no",
            "-e", "end tell",
            "-e", "end run",
            docx.path, dst.path,
        ])
    }
}
