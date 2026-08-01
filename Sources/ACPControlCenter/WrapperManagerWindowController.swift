import AppKit
import SwiftUI

/// Presents the ACP wrapper manager in its own standalone window instead of a
/// sheet attached to the MenuBarExtra panel.
///
/// The MenuBarExtra window is a non-activating NSPanel that hides when the
/// user interacts with anything outside it. A sheet presented from that panel
/// inherits the behavior and dismisses as soon as the user clicks a text field
/// or moves the pointer away — the wrapper form becomes unusable. Hosting the
/// manager in a real, standalone NSWindow (titled, not a panel) keeps it alive
/// and interactive regardless of what happens to the menu bar panel.
final class WrapperManagerWindowController: NSWindowController {
    private let viewModel: DashboardViewModel

    init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ACP Wrapper"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        let managerView = ACPWrapperManagerView(viewModel: viewModel)
        window.contentViewController = NSHostingController(rootView: managerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the window and brings it to the front.
    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
