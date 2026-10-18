import AppKit
import AVFoundation
import SwiftUI

enum Radial {
    static let size: CGFloat = 260  // the panel; everything outside the circles is click-through
    static let button: CGFloat = 50
    static let gap: CGFloat = 10

    /// As tight as the buttons allow, but never closer than the dragged file's icon needs.
    static func radius(for count: Int) -> CGFloat {
        guard count > 1 else { return 58 }
        return max(58, (button + gap) / (2 * sin(.pi / CGFloat(count))))
    }

    /// How far from the center the menu still counts as "under the mouse".
    static func reach(for count: Int) -> CGFloat { radius(for: count) + button / 2 + 10 }
}

/// Actions fanned out in a ring around the file being dragged. Compress sits at the top.
struct RadialMenu: View {
    @EnvironmentObject private var model: AppModel
    @State private var appeared = false
    /// True once the opening spring has fully settled. Until then nothing reacts: no highlight,
    /// sound, haptic, click or drop, since the buttons fly out underneath the cursor.
    @State private var landed = false
    /// The button under the cursor, measured against the buttons' final positions.
    @State private var hovered: Action?

    private let tracker = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

    var body: some View {
        let actions = model.actions
        let radius = Radial.radius(for: actions.count)

        ZStack {
            if model.isChoosing {
                GlassGroup {
                    // Catches a release in the middle so the files don't land on whatever is underneath.
                    Circle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: radius * 2 - Radial.button, height: radius * 2 - Radial.button)
                        .dropDestination(for: URL.self) { urls, _ in
                            model.load(urls)
                            return !model.isRunning
                        }

                    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                        RadialButton(action: action, isActive: landed && hovered == action)
                            .opacity(appeared ? 1 : 0)
                            .offset(appeared ? offset(index, of: actions.count, radius: radius) : .zero)
                            .allowsHitTesting(landed)
                    }
                }
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
            } else {
                // The ring's glass is gone entirely; one separate circle carries progress and the result.
                ResultBadge()
                    .transition(.scale(scale: 0.7).combined(with: .opacity)
                        .animation(.spring(response: 0.3, dampingFraction: 0.78)))
            }
        }
        .frame(width: Radial.size, height: Radial.size)
        .onAppear {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.86), completionCriteria: .removed) {
                appeared = true
            } completion: {
                landed = true
            }
        }
        .onReceive(tracker) { _ in
            guard landed, model.isChoosing else { return }
            let next = action(under: NSEvent.mouseLocation, in: actions, radius: radius)
            if next != hovered { hovered = next }
        }
        .onChange(of: hovered) { _, action in
            if action != nil { Feedback.hover() }
        }
    }

    /// Hit-tests the cursor ourselves rather than relying on hover events, which only fire once
    /// the mouse moves and so made the first highlight hit-or-miss.
    private func action(under mouse: NSPoint, in actions: [Action], radius: CGFloat) -> Action? {
        let center = QuickPanel.shared.center
        let point = CGSize(width: mouse.x - center.x, height: center.y - mouse.y)  // SwiftUI's y points down
        return actions.indices.first { index in
            let spot = offset(index, of: actions.count, radius: radius)
            return hypot(point.width - spot.width, point.height - spot.height) <= Radial.button / 2
        }.map { actions[$0] }
    }

    private func offset(_ index: Int, of count: Int, radius: CGFloat) -> CGSize {
        let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(max(count, 1))
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }
}

/// Drop or click to run. Highlighting comes from the ring, which tracks the cursor.
private struct RadialButton: View {
    @EnvironmentObject private var model: AppModel
    let action: Action
    let isActive: Bool

    var body: some View {
        Button { model.perform(action) } label: {
            if case .compress = action {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 14, weight: .semibold))
            } else {
                Text(action.label)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 5)
            }
        }
        .buttonStyle(RadialButtonStyle(isActive: isActive))
        .dropDestination(for: URL.self) { urls, _ in
            model.perform(action, on: urls)
            return true
        }
        .help(action.title)
    }
}

/// Progress, then ✓ / ! with a one-line caption. Click to show the result in Finder.
private struct ResultBadge: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            guard !model.isRunning, !model.outputs.isEmpty else { return }
            model.reveal(model.outputs)
            QuickPanel.shared.hide()
        } label: {
            ZStack {
                if model.isRunning && model.progress == 0 {
                    ProgressView().controlSize(.small)  // until the job reports real progress
                } else if model.isRunning {
                    Text("\(Int(model.progress * 100))%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.smooth(duration: 0.2), value: Int(model.progress * 100))
                } else {
                    let failed = !model.failures.isEmpty, empty = model.outputs.isEmpty
                    Image(systemName: failed ? "exclamationmark" : empty ? "minus" : "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(failed ? Color.red : empty ? .secondary : .green)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.isRunning)
        }
        .buttonStyle(RadialButtonStyle(isActive: false))
        .overlay {
            Circle()
                .trim(from: 0, to: model.isRunning ? model.progress : 0)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(1.5)
                .animation(.smooth(duration: 0.25), value: model.progress)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if !model.isRunning {
                Text(model.summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glass(Capsule())
                    .frame(width: 200)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: Radial.button + 10)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.smooth(duration: 0.2), value: model.isRunning)
        .help(model.isRunning || model.outputs.isEmpty ? "" : "Show in Finder")
    }
}

private struct RadialButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        // The glass keeps a fixed size: inside a GlassEffectContainer it redraws on its own schedule,
        // so resizing it jitters. Only its contents (drawn on top of the glass) animate.
        ZStack {
            Circle()
                .fill(Color.accentColor.gradient)
                .scaleEffect(isActive ? 1 : 0.8)
                .opacity(isActive ? 1 : 0)
            Circle()
                .fill(.black.opacity(configuration.isPressed ? 0.2 : 0))
            configuration.label
                .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .frame(width: Radial.button, height: Radial.button)
        .glass(Circle())
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.16), value: isActive)
        .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
    }
}

/// Renders the ring's glass together so every circle samples the same backdrop and looks alike.
private struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { ZStack { content } }
        } else {
            ZStack { content }
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26, a frosted blur before that.
    @ViewBuilder func glass<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(VisualEffect().clipShape(shape))
                .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The hover tick: click.wav plus a light trackpad tap, each switchable in Settings.
@MainActor
enum Feedback {
    /// A few preloaded players so quick sweeps across the ring never wait on one another.
    private static let players: [AVAudioPlayer] = {
        guard let url = Bundle.main.url(forResource: "click", withExtension: "wav") else { return [] }
        return (0..<3).compactMap { _ in
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.volume = 0.6
            player.prepareToPlay()
            return player
        }
    }()
    private static var next = 0

    static func prepare() { _ = players }

    static func hover() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Preferences.sounds), !players.isEmpty {
            let player = players[next % players.count]
            next += 1
            player.currentTime = 0
            player.play()
        }
        if defaults.bool(forKey: Preferences.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}
