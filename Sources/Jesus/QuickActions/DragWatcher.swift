import AppKit
import os

/// Opens the quick action menu when Shift is pressed while the mouse is held on a file,
/// whether or not the file is already being dragged, and closes it when Shift is let go.
/// Uses a global mouse-down monitor and then polls the mouse button and modifier keys, so
/// no Accessibility or Input Monitoring permission is needed. (Finder's selection is read
/// via Apple Events.)
@MainActor
final class DragWatcher {
    static let shared = DragWatcher()

    private let log = Logger(subsystem: "local.jesus.Jesus", category: "drag")
    private let pasteboard = NSPasteboard(name: .drag)
    private var monitor: Any?
    private var changeCount = 0
    private var timer: Timer?
    private var isPressed = false
    private var openedThisPress = false
    private var draggedThisPress = false
    private var shiftWasDown = false
    /// The menu is open because Shift is held; releasing Shift closes it.
    private var heldOpenByShift = false

    func start() {
        guard monitor == nil else { return }
        changeCount = pasteboard.changeCount
        // Global monitors are called on the main thread.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            MainActor.assumeIsolated { DragWatcher.shared.mouseDown() }
        }
        Self.warmUp()
        log.info("Watching for Shift during file drags (monitor installed: \(self.monitor != nil))")
    }

    private func mouseDown() {
        changeCount = pasteboard.changeCount
        isPressed = true
        openedThisPress = false
        draggedThisPress = false
        // Shift already down at the click is a Shift-click (extending a selection), not a request
        // for the menu: only a Shift press that starts while the mouse is held opens it.
        shiftWasDown = isShift(NSEvent.modifierFlags)
        QuickPanel.shared.dismissIfIdle()
        startPolling()
    }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { DragWatcher.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Runs while the mouse is held, and while the menu stays open on Shift.
    private func tick() {
        let shift = isShift(NSEvent.modifierFlags)
        defer { shiftWasDown = shift }

        if heldOpenByShift, !shift {
            heldOpenByShift = false
            if AppModel.shared.isChoosing { QuickPanel.shared.hide() }
        }

        if isPressed {
            if NSEvent.pressedMouseButtons & 1 == 0 {
                mouseUp()
            } else {
                // A drag writes to the drag pasteboard, which bumps its change count.
                if !draggedThisPress, pasteboard.changeCount != changeCount { draggedThisPress = true }
                // Every fresh Shift press opens the ring, so it can be let go and brought back mid-drag.
                if shift, !shiftWasDown, !heldOpenByShift, !AppModel.shared.isRunning { shiftPressed() }
            }
        }

        if !isPressed && !heldOpenByShift {
            timer?.invalidate()
            timer = nil
        }
    }

    private func shiftPressed() {
        openedThisPress = true
        if draggedThisPress {
            open(draggedFiles())
        } else if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            // Asking Finder takes a moment; don't hold up the main thread for it.
            Self.finderQueue.async {
                let files = Self.finderSelection()
                DispatchQueue.main.async { DragWatcher.shared.open(files) }
            }
        }
    }

    private func open(_ files: [URL]) {
        log.info("Opening for \(files.count) file(s); dragging: \(self.draggedThisPress)")
        // Shift may have been let go while Finder was answering.
        guard !files.isEmpty, isShift(NSEvent.modifierFlags) else { return }
        AppModel.shared.load(files)
        QuickPanel.shared.show(around: NSEvent.mouseLocation)
        heldOpenByShift = true
        startPolling()
    }

    private func mouseUp() {
        isPressed = false
        guard openedThisPress, draggedThisPress else { return }
        // Let a drop onto the menu land first, then close it if the drag ended elsewhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            QuickPanel.shared.dismissIfAbandoned()
        }
    }

    private func isShift(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.shift) && flags.isDisjoint(with: [.command, .control, .option])
    }

    private func draggedFiles() -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: Finder selection (holding still on a file)

    nonisolated private static let finderQueue = DispatchQueue(label: "local.jesus.finder", qos: .userInteractive)

    /// Compiled once, used only on `finderQueue`.
    nonisolated(unsafe) private static let selectionScript = NSAppleScript(source: """
        set paths to {}
        tell application "Finder" to set picked to selection as alias list
        repeat with item_ in picked
            set end of paths to POSIX path of item_
        end repeat
        return paths
        """)

    /// Compiles the script ahead of time so the first lookup is quick.
    nonisolated static func warmUp() {
        finderQueue.async { _ = selectionScript?.compileAndReturnError(nil) }
    }

    /// The click has already selected the file in Finder.
    nonisolated private static func finderSelection() -> [URL] {
        var error: NSDictionary?
        guard let result = selectionScript?.executeAndReturnError(&error), result.numberOfItems > 0 else {
            if let error {
                Logger(subsystem: "local.jesus.Jesus", category: "drag")
                    .error("Couldn't read the Finder selection: \(String(describing: error), privacy: .public)")
            }
            return []
        }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
            .map { URL(fileURLWithPath: $0) }
    }
}
