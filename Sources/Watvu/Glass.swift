import SwiftUI
import AppKit

// Glass styles. The app uses *clear* glass everywhere: its own
// controls via these helpers, and the system toolbar via ClearGlassEnforcer.

extension View {
    /// Untinted clear glass button.
    func glassButton() -> some View {
        buttonStyle(.glass(.clear)).tint(nil)
    }

    /// Primary action: clear glass tinted with the accent.
    func glassDestructiveButton() -> some View {
        self.glassButton().tint(.red)
    }

    func glassProminentButton() -> some View {
        buttonStyle(.glass(.clear.tint(Theme.accent))).foregroundStyle(.white)
    }

    /// Clear glass behind a custom shape.
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        glassEffect(Glass.clear.tint(tint).interactive(interactive), in: shape)
    }
}

/// SwiftUI can't choose the style of the glass AppKit draws for toolbar
/// items, but they are public `NSGlassEffectView`s. This sets the ones in
/// the title bar to `.clear`, re-applying after the window updates because
/// toolbar items are rebuilt when the page changes.
@MainActor
final class ClearGlassEnforcer {
    private weak var window: NSWindow?
    private var observer: NSObjectProtocol?
    private var pending = false

    init(window: NSWindow) {
        self.window = window
        apply()
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleApply() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// didUpdate fires for every input event (~120/s while scrolling), so
    /// run one pass after each burst.
    private func scheduleApply() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pending = false
            self?.apply()
        }
    }

    /// Title bar only: glass elsewhere is managed by SwiftUI, and changing
    /// it would fight SwiftUI and flicker.
    private func apply() {
        guard let root = window?.contentView?.superview else { return }
        for view in root.subviews where String(describing: type(of: view)).contains("Titlebar") {
            Self.makeClear(view)
        }
    }

    private static func makeClear(_ view: NSView) {
        if let glass = view as? NSGlassEffectView, glass.style != .clear {
            glass.style = .clear
        }
        view.subviews.forEach(makeClear)
    }
}
