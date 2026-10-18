# Jesus

A small, native macOS menu bar app for offline file conversion and compression.

**Start dragging a file (or several) anywhere, then press ⇧ Shift.** A ring of
actions opens around the file — Compress on top, conversions around it. Keep Shift
held, drag onto one and let go. Releasing Shift closes the ring. Shift-clicking to
select files never opens it: only pressing Shift while already holding the mouse does. The result is saved
next to the original. Nothing is uploaded and originals are never modified.

You can also use **Open With › Jesus** in Finder, or **Choose Files…** from the
menu bar icon. Press Esc or click elsewhere to close the menu. Hover sounds and
haptics can be turned off in **Settings…** (⌘,). No Accessibility
permission is needed.

## Build

Requires macOS 15+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh            # builds build/Jesus.app
./build.sh --install  # also copies it to /Applications
```

## Permissions

Run `Support/make-signing-cert.sh` once before building. It adds a local
code-signing certificate to your login keychain so macOS remembers Jesus's
permissions across rebuilds (an ad hoc signature looks like a new app every
build). Then choose **Allow Access to All Folders…** in the menu bar menu and turn
on Jesus under Full Disk Access, so it never asks folder by folder.

## What it handles

| Kind | Convert to |
|---|---|
| Images | JPG, JPEG, PNG, WebP, HEIC, TIFF, AVIF, BMP, PDF |
| Video | MP4, MOV, MKV, WebM, AVI, WMV, GIF, MP3 |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA |
| PDF | DOCX, Pages, PPTX (a slide per page), XLSX (a sheet per page), JPG, PNG, TXT, Markdown |
| Documents (DOCX, DOC, ODT, RTF, HTML, TXT, Markdown) | DOCX, Pages, PDF, TXT, Markdown, HTML, PNG, JPG |
| Subtitles | SRT ↔ VTT |
| Archives | Unzip, ZIP |

Pages appears only when Pages is installed, since only Pages can write Pages files.

**Compress** re-encodes images, video, audio and PDFs smaller, and zips everything else.

Everything uses built-in macOS frameworks (ImageIO, AVFoundation, PDFKit,
`afconvert`, `ditto`, `tar`). If [ffmpeg](https://ffmpeg.org) is installed
(`brew install ffmpeg`), Jesus also offers MP3, MKV, WebM, AVI, WMV, OGG, Opus and WMA and can
read formats like MKV, WebM and AVI. WebP output uses `cwebp` (`brew install webp`).

If a compressed result isn't smaller than the original, it's discarded and the
result says "Already optimized".

## License

MIT — see [LICENSE](LICENSE). Contributions welcome: open an issue or a pull request.
