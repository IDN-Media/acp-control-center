import AppKit
import SwiftUI

/// State-aware ACP wrapper section in the dashboard. Replaces the previous
/// unconditional "Manage…" button with lifecycle-driven actions per Work
/// Package A. Future work packages will add migration and edit-in-place.
struct ACPWrapperManagerView: View {
    @Bindable var viewModel: DashboardViewModel
    @State private var modelID: String
    @State private var effortValue: String
    @State private var isConfirmingInstall = false
    @State private var isConfirmingEdit = false
    @State private var restoreTarget: URL?
    @State private var isCustomModel = false

    init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
        // For Work Package A first-time setup, default to unspecified. Only use
        // the configured wrapper's own model (from the reader) — but since
        // first-time setup means no existing wrapper, this will always be empty.
        _modelID = State(initialValue: "")
        _effortValue = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sheetTitle).font(.title2).bold()

            switch viewModel.lifecycleContext.state {
            case .noProvider, .configuredPathMissing:
                setupFlow
            case .managedWrapperInactive:
                xcodeOnboardingFlow
            case .managedWrapperActive:
                managedActiveStatus
            case .managedWrapperInvalid:
                managedInvalidNotice
            case .unmanagedWrapperActive:
                unmanagedActiveNotice
            case .unmanagedWrapperInvalid:
                unmanagedInvalidNotice
            }

            operationStatus

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 480)
        .confirmationDialog(
            "Install this managed wrapper?",
            isPresented: $isConfirmingInstall,
            titleVisibility: .visible
        ) {
            Button("Install Wrapper") {
                Task { await viewModel.installWrapperPreview() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The previewed script will be syntax-checked, installed atomically with permission 0700, "
                    + "read back, and rolled back automatically if verification fails."
            )
        }
    }

    private var sheetTitle: String {
        switch viewModel.lifecycleContext.state {
        case .noProvider:
            return "Set Up ACP Wrapper"
        case .configuredPathMissing:
            return "Create Managed Replacement"
        case .managedWrapperInactive:
            return "Finish Xcode Setup"
        case .managedWrapperActive:
            return "ACP Wrapper Status"
        case .managedWrapperInvalid:
            return "ACP Wrapper Problem"
        case .unmanagedWrapperActive:
            return "ACP Wrapper (Read-Only)"
        case .unmanagedWrapperInvalid:
            return "ACP Wrapper (Read-Only)"
        }
    }

    // MARK: - First-time setup flow

    private var setupFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.lifecycleContext.state == .configuredPathMissing {
                Label(
                    "Xcode references a wrapper that does not exist. "
                        + "You can create a managed replacement, but you will still need to update the path in Xcode Settings.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            } else {
                Text(
                    "ACP Control Center writes only its private wrapper directory. "
                        + "After installation, you add the wrapper path through Xcode Settings."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if viewModel.snapshot?.cli.availability != .ready {
                Label(
                    "A ready Kiro CLI is required before creating a wrapper.",
                    systemImage: "xmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.red)
            } else {
                setupForm
            }
        }
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                TextField("Model ID (optional)", text: $modelID)
                Picker("Effort", selection: $effortValue) {
                    Text("Unspecified").tag("")
                    ForEach(ACPWrapperEffort.allCases, id: \.rawValue) { effort in
                        Text(effort.rawValue).tag(effort.rawValue)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Preview Wrapper") {
                    Task {
                        await viewModel.prepareWrapperPreview(
                            modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                            effort: ACPWrapperEffort(rawValue: effortValue)
                        )
                    }
                }
                .disabled(viewModel.isRefreshing)

                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text(viewModel.managedWrapperURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let preview = viewModel.wrapperPreview {
                GroupBox("Install preview") {
                    ScrollView {
                        Text(preview.renderedContent)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 130, maxHeight: 190)
                }
                HStack {
                    Button("Discard Preview") { viewModel.clearWrapperPreview() }
                    Spacer()
                    Button("Install Wrapper") { isConfirmingInstall = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isRefreshing)
                }
            }
        }
    }

    // MARK: - Xcode onboarding (managedWrapperInactive)

    private var xcodeOnboardingFlow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "The managed wrapper is installed. Configure Xcode to use it:",
                systemImage: "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 6) {
                Text("Xcode Settings \u{2192} Agentic Coding \u{2192} Add Provider:")
                    .font(.subheadline).bold()
                Text("\u{2022} Executable: paste the managed wrapper path below")
                    .font(.caption)
                Text("\u{2022} Interpreter: /bin/zsh")
                    .font(.caption)
                Text("\u{2022} Arguments and environment: leave empty")
                    .font(.caption)
            }

            HStack {
                Button("Copy Wrapper Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.managedWrapperURL.path, forType: .string)
                }
                if viewModel.managedWrapperExists {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([viewModel.managedWrapperURL])
                    }
                }
                Spacer()
                Button("Rescan Xcode") {
                    Task { await viewModel.rescanXcode() }
                }
                .disabled(viewModel.isRefreshing)
            }

            Text(viewModel.managedWrapperURL.path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)

            if let configuredPath = viewModel.lifecycleContext.configuredPath {
                Divider()
                Text("Xcode currently points to:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(configuredPath.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()
            editFormSection
            backupHistorySection
        }
    }

    // MARK: - Active managed wrapper

    private var managedActiveStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Xcode is using the managed wrapper.", systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.green)

            if let config = viewModel.lifecycleContext.activeConfiguration {
                HStack {
                    Text("Model: \(config.modelID ?? "unspecified")")
                    Spacer()
                    Text("Effort: \(config.effort ?? "unspecified")")
                }
                .font(.caption)
            }

            Divider()
            editFormSection
            backupHistorySection
        }
        .confirmationDialog(
            "Install this edit?",
            isPresented: $isConfirmingEdit,
            titleVisibility: .visible
        ) {
            Button("Install Edit") {
                Task { await viewModel.installEditPreview() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The current wrapper will be backed up, then replaced atomically. "
                    + "If verification fails, the previous version is restored automatically."
            )
        }
    }

    /// The model/effort edit form with preview and install actions. Shared by
    /// the active and inactive managed states.
    private var editFormSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit Wrapper")
                .font(.subheadline).bold()

            Text(
                .init(
                    "Change the model or effort used by the managed wrapper. "
                        + "The CLI executable stays as configured; Xcode keeps pointing "
                        + "at the same managed path, so no Xcode update is needed. "
                        + "[View available models](https://kiro.dev/docs/cli/models/)."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Form {
                Picker("Model", selection: $modelID) {
                    Text("Auto (default)").tag("")
                    ForEach(observedModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                    Text("Custom\u{2026}").tag("__custom__")
                }
                .onChange(of: modelID) { _, newValue in
                    if newValue == "__custom__" {
                        modelID = ""
                        isCustomModel = true
                    } else if !newValue.isEmpty {
                        isCustomModel = false
                    }
                }

                if isCustomModel {
                    TextField("Model ID (e.g. claude-opus-4.6)", text: $modelID)
                }

                Picker("Effort", selection: $effortValue) {
                    Text("Unspecified").tag("")
                    ForEach(ACPWrapperEffort.allCases, id: \.rawValue) { effort in
                        Text(effort.rawValue).tag(effort.rawValue)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Preview Edit") {
                    Task {
                        await viewModel.prepareEditPreview(
                            modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                            effort: ACPWrapperEffort(rawValue: effortValue)
                        )
                    }
                }
                .disabled(viewModel.isRefreshing)

                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Discard Preview") { viewModel.clearWrapperPreview() }
                    .font(.caption)
                    .disabled(viewModel.wrapperPreview == nil)
            }

            if let preview = viewModel.wrapperPreview {
                GroupBox("Edit preview") {
                    ScrollView {
                        Text(preview.renderedContent)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 100, maxHeight: 180)
                }

                HStack {
                    Spacer()
                    Button("Install Edit") { isConfirmingEdit = true }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                        .disabled(viewModel.isRefreshing)
                }
            }
        }
    }

    /// Model IDs observed in Kiro logs plus the implicit auto default.
    private var observedModels: [String] {
        viewModel.observedModelIDs()
    }

    // MARK: - Managed wrapper backup history & rollback

    private var backupHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("History & Rollback")
                .font(.subheadline).bold()

            Text(
                "Every install, edit, and migration backs up the previous wrapper "
                    + "version. Restore any of them at any time."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            let backups = viewModel.backupHistory
            if backups.isEmpty {
                Text("No backups yet. Backups are created when you install, edit, or migrate a wrapper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(backups, id: \.path) { backupURL in
                    HStack {
                        Text(backupURL.deletingPathExtension().lastPathComponent)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Restore") { restoreTarget = backupURL }
                            .font(.caption)
                            .disabled(viewModel.isRefreshing)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .confirmationDialog(
            "Restore this version?",
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore") {
                if let target = restoreTarget {
                    Task { await viewModel.restoreBackup(target) }
                }
                restoreTarget = nil
            }
            Button("Cancel", role: .cancel) { restoreTarget = nil }
        } message: {
            Text(
                "The current wrapper will be backed up first, then replaced with "
                    + "this backup. If verification fails, the current version is restored automatically."
            )
        }
    }

    // MARK: - Managed wrapper invalid

    private var managedInvalidNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "The managed wrapper location contains an invalid or unrecognized entry. "
                    + "ACP Control Center will not overwrite it. A future update may provide repair options.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.orange)

            if let reason = viewModel.lifecycleContext.invalidReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Unmanaged active (read-only)

    private var unmanagedActiveNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Xcode is using a wrapper that was not created by this app. "
                    + "ACP Control Center will not modify it.",
                systemImage: "lock.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if let config = viewModel.lifecycleContext.activeConfiguration {
                HStack {
                    Text("Path: \(config.wrapperURL.path)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption.monospaced())
                HStack {
                    Text("Model: \(config.modelID ?? "unspecified")")
                    Spacer()
                    Text("Effort: \(config.effort ?? "unspecified")")
                }
                .font(.caption)
            }

            Divider()

            Text("Migrate to Managed")
                .font(.subheadline).bold()

            Text(
                "Create an identical managed copy of this wrapper inside the "
                    + "app's private directory. Your original file is left untouched; "
                    + "you will then update the path in Xcode Settings to use the managed copy."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if viewModel.wrapperPreview == nil {
                Button("Preview Managed Copy\u{2026}") {
                    Task { await viewModel.prepareMigrationPreview() }
                }
                .font(.caption)
                .disabled(viewModel.isRefreshing)
            } else {
                migrationPreviewFlow
            }
        }
    }

    private var migrationPreviewFlow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preview = viewModel.wrapperPreview {
                GroupBox("Managed copy preview") {
                    ScrollView {
                        Text(preview.renderedContent)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 100, maxHeight: 180)
                }

                HStack {
                    Button("Discard Preview") { viewModel.clearWrapperPreview() }
                        .font(.caption)
                    Spacer()
                    Button("Install Managed Copy") { isConfirmingInstall = true }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                        .disabled(viewModel.isRefreshing)
                }
            }
        }
        .confirmationDialog(
            "Install the managed copy?",
            isPresented: $isConfirmingInstall,
            titleVisibility: .visible
        ) {
            Button("Install Managed Copy") {
                Task { await viewModel.installMigrationPreview() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The identical copy will be installed with 0700 permissions, syntax-checked, "
                    + "and verified. Your original unmanaged wrapper is not modified."
            )
        }
    }

    // MARK: - Unmanaged invalid (read-only)

    private var unmanagedInvalidNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Xcode references a wrapper that is invalid. "
                    + "ACP Control Center cannot modify it because it was not created by this app.",
                systemImage: "xmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.orange)

            if let reason = viewModel.lifecycleContext.invalidReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let configuredPath = viewModel.lifecycleContext.configuredPath {
                Text(configuredPath.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if viewModel.lifecycleContext.managedWrapperAvailable {
                Label(
                    "A managed wrapper is available. Update the path in Xcode Settings to use it.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - Operation status

    @ViewBuilder
    private var operationStatus: some View {
        switch viewModel.wrapperManagerStatus {
        case .idle:
            EmptyView()
        case .previewReady:
            Label(
                "Preview ready. Review the complete script before installing.",
                systemImage: "doc.text.magnifyingglass"
            )
            .foregroundStyle(.blue)
        case .installed(let modelID, let effort):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Wrapper installed and verified.",
                    systemImage: "checkmark.shield"
                )
                .foregroundStyle(.green)
                HStack(spacing: 12) {
                    Text("Model: \(modelID ?? "auto")")
                    Text("Effort: \(effort ?? "unspecified")")
                    Text("Path: \(viewModel.managedWrapperURL.path)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                if viewModel.lifecycleContext.state != .managedWrapperActive {
                    Text("Add its path through Xcode Settings, then use Rescan Xcode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
