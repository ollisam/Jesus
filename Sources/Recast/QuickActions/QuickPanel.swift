import AppKit
import SwiftUI

/// The transparent, non-activating panel that hosts the radial menu, centered on the cursor.
@MainActor
final class QuickPanel {
    static let shared = QuickPanel()

    private lazy var panel: FloatingPanel = makePanel()
    private lazy var host = FirstMouseHostingView(rootView: AnyView(EmptyView()))
    private var generation = 0  // invalidates pending hides when the menu is shown again

    var isVisible: Bool { panel.isVisible }
    var center: CGPoint { CGPoint(x: panel.frame.midX, y: panel.frame.midY) }

    /// Builds the panel and loads the sound up front so the first Shift press opens instantly.
    func prepare() {
        _ = panel
        Feedback.prepare()
    }

    /// Shows the menu around the file being dragged, so any action is one short move away.
    func show(around point: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let half = Radial.size / 2
        let center = NSPoint(x: min(max(point.x, visible.minX + half), visible.maxX - half),
                             y: min(max(point.y, visible.minY + half), visible.maxY - half))
        present(at: center)
    }

    func showCentered() {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        present(at: NSPoint(x: visible.midX, y: visible.midY))
    }

    func hide(after delay: TimeInterval = 0) {
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard current == generation, isVisible else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    if current == self.generation {
                        self.panel.orderOut(nil)
                        // Drop the view so its cursor tracking stops while hidden.
                        self.host.rootView = AnyView(EmptyView())
                    }
                }
            }
        }
    }

    /// Clicking elsewhere closes the menu, unless it's busy.
    func dismissIfIdle() {
        guard isVisible, !AppModel.shared.isRunning, !containsMouse else { return }
        hide()
    }

    /// The drag ended without a drop on the menu.
    func dismissIfAbandoned() {
        guard isVisible, AppModel.shared.isChoosing, !containsMouse else { return }
        hide()
    }

    private var containsMouse: Bool {
        let mouse = NSEvent.mouseLocation
        return hypot(mouse.x - panel.frame.midX, mouse.y - panel.frame.midY) <= Radial.reach(for: AppModel.shared.actions.count)
    }

    private func present(at center: NSPoint) {
        generation += 1
        // A fresh view each time so the ring animates open again.
        host.rootView = AnyView(RadialMenu().environmentObject(AppModel.shared).id(generation))
        panel.setFrame(NSRect(x: center.x - Radial.size / 2, y: center.y - Radial.size / 2,
                              width: Radial.size, height: Radial.size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()  // for Esc
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Radial.size, height: Radial.size),
                                  styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                  backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // each circle draws its own
        panel.acceptsMouseMovedEvents = true
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Escape closes the menu.
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated {
            if !AppModel.shared.isRunning { QuickPanel.shared.hide() }
        }
    }
}

/// Lets the first click on the (inactive) panel hit a button instead of just focusing it.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
