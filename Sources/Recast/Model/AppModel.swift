import AppKit
import SwiftUI

struct FileItem: Identifiable {
    enum Status: Equatable {
        case ready
        case working(Double?)
        case done(URL, Int64?)
        case skipped(String)
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .ready, .working: false
            default: true
            }
        }
    }

    let id = UUID()
    let url: URL
    let kind: FileKind
    let size: Int64?
    let isFolder: Bool
    var status: Status = .ready

    init(url: URL) {
        self.url = url
        self.kind = FileKind.detect(url)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        self.size = values?.fileSize.map(Int64.init)
        self.isFolder = values?.isDirectory == true
    }

    var name: String { url.lastPathComponent }

    var detail: String {
        if isFolder { return "Folder" }
        let type = url.pathExtension.uppercased()
        guard let size else { return type }
        return type.isEmpty ? Format.bytes(size) : "\(type) · \(Format.bytes(size))"
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// The files currently in the quick action menu and the action run on them.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// Files the menu offers actions for.
    @Published private(set) var files: [FileItem] = []
    /// Files being (or already) processed; empty while the user is still choosing.
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var action: Action?
    @Published private(set) var isRunning = false

    private var task: Task<Void, Never>?

    var kinds: [FileKind] { Set(files.map(\.kind)).sorted() }
    var isChoosing: Bool { items.isEmpty }
    var outputs: [URL] {
        items.compactMap { if case .done(let url, _) = $0.status { url } else { nil } }
    }

    // MARK: Menu contents

    /// Formats every selected file can be converted to, minus the one they're all already in.
    var conversions: [OutputFormat] {
        guard let first = kinds.first else { return [] }
        let shared = kinds.dropFirst().reduce(first.formats) { list, kind in list.filter(kind.formats.contains) }
        return shared.filter { format in !files.allSatisfy { format.matches($0.url) } }
    }

    /// Everything the radial menu offers, Compress first so it sits at the top.
    var actions: [Action] {
        let compress: [Action] = kinds.allSatisfy { $0 == .archive } ? [] : [.compress(.balanced)]
        return compress + conversions.map { .convert($0) }
    }

    // MARK: Progress

    /// Overall progress of the running job, 0…1.
    var progress: Double {
        guard !items.isEmpty else { return 0 }
        let sum = items.reduce(0.0) { total, item in
            switch item.status {
            case .ready: total
            case .working(let value): total + (value ?? 0)
            default: total + 1
            }
        }
        return sum / Double(items.count)
    }

    var failures: [String] {
        items.compactMap { if case .failed(let message) = $0.status { message } else { nil } }
    }

    /// One line describing the finished job.
    var summary: String {
        if let failure = failures.first {
            return failures.count == items.count ? failure : "\(failures.count) of \(items.count) failed"
        }
        let outputs = outputs
        if outputs.isEmpty {
            if case .skipped(let reason) = items.first?.status { return reason }
            return "Nothing to do"
        }
        if case .compress = action {
            let before = items.compactMap { item -> Int64? in
                if case .done = item.status { item.size } else { nil }
            }.reduce(0, +)
            let after = items.compactMap { item -> Int64? in
                if case .done(_, let size) = item.status { size } else { nil }
            }.reduce(0, +)
            if before > 0, after < before {
                return "\(Format.bytes(after)) · −\(Int((1 - Double(after) / Double(before)) * 100))%"
            }
        }
        return outputs.count == 1 ? "Saved" : "\(outputs.count) files saved"
    }

    // MARK: Files

    /// Replaces the menu's files. Ignored while a job is running.
    func load(_ urls: [URL]) {
        guard !isRunning else { return }
        var seen = Set<URL>()
        let unique = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        files = unique.map(FileItem.init)
        items = []
        action = nil
    }

    func choose() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    /// Loads files and shows the menu in the middle of the screen (Dock, Open With, Choose Files…).
    func open(_ urls: [URL]) {
        load(urls)
        guard !files.isEmpty else { return }
        QuickPanel.shared.showCentered()
    }

    func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: Running

    /// Runs an action on the menu's files, or on `urls` if files were dropped onto the action.
    func perform(_ action: Action, on urls: [URL] = []) {
        guard !isRunning else { return }
        if !urls.isEmpty { load(urls) }
        guard !files.isEmpty else { return }

        self.action = action
        items = files.map { var item = $0; item.status = .ready; return item }
        let queue = items.map { ($0.id, $0.url, $0.kind) }
        isRunning = true

        task = Task {
            for (id, url, kind) in queue {
                if Task.isCancelled { break }
                setStatus(id, .working(nil))
                do {
                    let outcome = try await Converter.run(url, kind: kind, action: action) { value in
                        Task { @MainActor in self.setProgress(id, value) }
                    }
                    switch outcome {
                    case .output(let output): setStatus(id, .done(output, Converter.size(of: output)))
                    case .skipped(let reason): setStatus(id, .skipped(reason))
                    }
                } catch {
                    setStatus(id, Task.isCancelled ? .skipped("Stopped") : .failed(error.localizedDescription))
                }
            }
            for index in items.indices where !items[index].status.isFinished {
                items[index].status = .skipped("Stopped")
            }
            isRunning = false
            task = nil
            if failures.isEmpty { QuickPanel.shared.hide(after: 2.4) }
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Back to the action list for the same files.
    func reset() {
        guard !isRunning else { return }
        items = []
        action = nil
    }

    private func setStatus(_ id: FileItem.ID, _ status: FileItem.Status) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
    }

    private func setProgress(_ id: FileItem.ID, _ value: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .working = items[index].status else { return }
        items[index].status = .working(min(max(value, 0), 1))
    }
}
