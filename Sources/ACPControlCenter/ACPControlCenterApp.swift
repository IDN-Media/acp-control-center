import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM executables do not carry an Info.plist with LSUIElement.
        // Accessory policy keeps this a true menu-bar utility without a Dock
        // icon while retaining the MenuBarExtra window.
        NSApplication.shared.setActivationPolicy(.accessory)

        // A deterministic read-only smoke-test path for CI/local validation.
        // It exercises the exact production readers against the current
        // machine, prints the sanitized diagnostic summary, then exits.
        if ProcessInfo.processInfo.arguments.contains("--diagnostic") {
            Task { @MainActor in
                let viewModel = DashboardViewModel()
                await viewModel.refresh()
                print(viewModel.diagnosticSummary())
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

@main
struct ACPControlCenterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = DashboardViewModel()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(viewModel: viewModel)
        } label: {
            Text(verbatim: "\u{1F47B} " + viewModel.menuBarStatusText)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel(viewModel.menuBarAccessibilityLabel)
                .task {
                    await viewModel.performInitialRefreshIfNeeded()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
