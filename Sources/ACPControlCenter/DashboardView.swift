import AppKit
import SwiftUI

/// The read-only menu bar dashboard: CLI status, account usage/freshness,
/// observed model/source, and current wrapper configuration. No controls in
/// this slice write to any Kiro/Xcode file.
struct DashboardView: View {
    @Bindable var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if let snapshot = viewModel.snapshot {
                cliSection(snapshot.cli)
                Divider()
                usageSection(snapshot.accountUsage)
                Divider()
                modelSection(snapshot.observedModel)
                Divider()
                wrapperSection(snapshot.wrapper)
                Divider()
                Text("Refreshed \(snapshot.refreshedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Loading\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 340)
        .task {
            await viewModel.performInitialRefreshIfNeeded()
        }
    }

    private var header: some View {
        Text("ACP Control Center")
            .font(.headline)
    }

    private func cliSection(_ cli: KiroCLIInstallation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Kiro CLI").font(.subheadline).bold()
                Spacer()
                Button("Search Again") {
                    Task { await viewModel.searchAgain() }
                }
                .disabled(viewModel.isRefreshing)
                Button("Choose Executable\u{2026}") {
                    chooseExecutable()
                }
                .disabled(viewModel.isRefreshing)
            }
            .font(.caption)

            if let executableURL = cli.executableURL {
                Text(executableURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                statusDot(cli.availability == .ready)
                Text(cliStatusText(cli.availability))
                Spacer()
                Text(cli.version.map { "v\($0)" } ?? "version unknown")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func usageSection(_ result: Result<KiroAccountUsage, ReaderError>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Section header with inline Refresh button and progress indicator
            HStack {
                Text("Account usage").font(.subheadline).bold()
                Spacer()
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                }
                Button("Refresh") {
                    Task { await viewModel.refreshAccountUsage() }
                }
                .font(.caption)
                .disabled(viewModel.isRefreshing)
            }

            switch result {
            case .success(let usage):
                Text("\(usage.used as NSDecimalNumber) / \(usage.limit as NSDecimalNumber) credits")
                    .font(.body)
                HStack {
                    Text(usage.subscriptionTitle ?? "Unknown plan")
                    Spacer()
                    if let overageStatus = usage.overageStatus {
                        Text("Overage: \(overageStatus)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                usageSourceLabel(usage.source)
                liveUsageRecoveryLabel
                freshnessLabel(for: DataAvailability.classify(age: Date().timeIntervalSince(usage.observedAt)), observedAt: usage.observedAt)
            case .failure(let error):
                errorLabel(error)
                liveUsageRecoveryLabel
            }
        }
    }

    private func modelSection(_ result: Result<ModelObservation, ReaderError>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Latest Observed Model Activity").font(.subheadline).bold()
            switch result {
            case .success(let observation):
                Text(observation.modelID == "auto" ? "Auto" : observation.modelID)
                    .font(.body)
                HStack {
                    Text(sourceLabel(observation.source))
                    Spacer()
                    if let agentMode = observation.agentMode {
                        Text(agentMode)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("Observed \(observation.observedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .failure(let error):
                errorLabel(error)
            }
        }
    }

    private func wrapperSection(_ result: Result<ACPWrapperConfiguration, ReaderError>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("ACP wrapper").font(.subheadline).bold()
                Spacer()
                Button("Rescan Xcode") {
                    Task { await viewModel.rescanXcode() }
                }
                .font(.caption)
                .disabled(viewModel.isRefreshing)
            }
            switch result {
            case .success(let wrapper):
                Text(wrapper.wrapperURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Text("Model: \(wrapper.modelID ?? "unspecified")")
                    Spacer()
                    Text("Effort: \(wrapper.effort ?? "unspecified")")
                }
                .font(.caption)
                HStack {
                    statusDot(wrapper.isExecutable)
                    Text(wrapper.isExecutable ? "Executable" : "Not executable")
                    Spacer()
                    statusDot(wrapper.syntaxIsValid)
                    Text(wrapper.syntaxIsValid ? "Syntax OK" : "Syntax error")
                }
                .font(.caption)
            case .failure(let error):
                errorLabel(error)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
        }
    }

    // MARK: - Helpers

    private func statusDot(_ ok: Bool) -> some View {
        Circle()
            .fill(ok ? Color.green : Color.red)
            .frame(width: 6, height: 6)
    }

    private func cliStatusText(_ availability: KiroCLIAvailability) -> String {
        switch availability {
        case .ready:
            return "Ready"
        case .notFound:
            return "Not found"
        case .notExecutable:
            return "Not executable"
        case .launchFailed:
            return "Launch failed"
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose Kiro CLI Executable"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApplication.shared.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await viewModel.chooseExecutable(url)
            }
        }
    }

    @ViewBuilder
    private var liveUsageRecoveryLabel: some View {
        switch viewModel.liveUsageStatus {
        case .notAttempted, .ready:
            EmptyView()
        case .cliUnavailable:
            recoveryText("Live usage unavailable until Kiro CLI is found.")
        case .authenticationRequired:
            recoveryText("Kiro CLI sign-in required. Sign in, then check again.")
        case .sessionExpired:
            recoveryText("Kiro CLI session expired. Sign in again, then check again.")
        case .timedOut:
            recoveryText("Live usage timed out. Check the CLI and try again.")
        case .permissionDenied:
            recoveryText("Kiro CLI could not launch because permission was denied.")
        case .commandFailed:
            recoveryText("Kiro CLI usage command failed. Try again or choose another executable.")
        case .parseFailed:
            recoveryText("Kiro CLI returned an unsupported usage format.")
        }
    }

    private func recoveryText(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(message)
                .foregroundStyle(.orange)
            Spacer()
            Button("Check Again") {
                Task { await viewModel.refreshAccountUsage() }
            }
            .disabled(viewModel.isRefreshing)
        }
        .font(.caption2)
    }

    private func sourceLabel(_ source: ModelSource) -> String {
        switch source {
        case .kiroCLI:
            return "Kiro CLI"
        case .aiEditor:
            return "AI editor (unconfirmed)"
        case .unknown:
            return "Unknown source"
        }
    }

    private func errorLabel(_ error: ReaderError) -> some View {
        Group {
            switch error {
            case .missing:
                Text("No data available").foregroundStyle(.secondary)
            case .invalid(let reason):
                Text("Invalid: \(reason)").foregroundStyle(.orange)
            case .ioFailure(let reason):
                Text("I/O error: \(reason)").foregroundStyle(.red)
            }
        }
        .font(.caption)
    }

    private func usageSourceLabel(_ source: UsageSource) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(source == .liveCLI ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(source == .liveCLI ? "Live from Kiro CLI" : "Local log (fallback)")
        }
        .font(.caption2)
        .foregroundStyle(source == .liveCLI ? Color.primary : Color.orange)
    }

    @ViewBuilder
    private func freshnessLabel(for availability: DataAvailability, observedAt: Date) -> some View {
        switch availability {
        case .available:
            Text("Updated \(observedAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .aging:
            Text("Aging \u{2014} updated \(observedAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .stale:
            Text("Stale \u{2014} updated \(observedAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.red)
        case .missing:
            Text("No observation available")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .invalid(let reason):
            Text("Invalid: \(reason)")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}
