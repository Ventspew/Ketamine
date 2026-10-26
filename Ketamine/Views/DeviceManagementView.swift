import SwiftUI
import UIKit

struct DeviceManagementView: View {
    @ObservedObject private var diagnostic = SupervisionDiagnostic.shared
    @State private var showEnableConfirm = false
    @State private var showRestoreConfirm = false
    @State private var showActionAlert = false
    @State private var actionAlertTitle = ""
    @State private var actionAlertBody = ""
    @State private var busyMessage = "Working…"

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    runButton
                    if diagnostic.last.ranAt != nil {
                        summaryCard
                        results
                        actions
                        delayOTANote
                    } else {
                        placeholder
                    }
                }
                .padding(Theme.pagePadding)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            if diagnostic.isBusy {
                ProgressOverlay(message: busyMessage)
            }
        }
        .navigationTitle("Device Management")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Experimental: Enable Supervision?", isPresented: $showEnableConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Enable", role: .destructive) {
                Task { await runEnable() }
            }
        } message: {
            Text(
                "This writes IsSupervised and a few CloudConfigurationDetails keys only. " +
                "A local backup is kept for Restore. Success requires ManagedConfiguration " +
                "to report supervised — not just the plist. This may have no effect on DelayOTA."
            )
        }
        .alert("Restore original CloudConfiguration?", isPresented: $showRestoreConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) {
                Task { await runRestore() }
            }
        } message: {
            Text("Replaces CloudConfigurationDetails.plist with the copy saved before Enable.")
        }
        .alert(actionAlertTitle, isPresented: $showActionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionAlertBody)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Device Management")
                .font(.largeTitle.weight(.semibold))
            Text(
                "Diagnostics for configurationprofiles access, write capability, and " +
                "experimental CloudConfiguration supervision. Labelled experimental."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text("EXPERIMENTAL")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Theme.caution)
        }
    }

    private var runButton: some View {
        ActionButton(
            title: diagnostic.last.ranAt == nil ? "Run diagnostics" : "Re-run diagnostics",
            systemImage: "stethoscope",
            isBusy: diagnostic.isBusy
        ) {
            busyMessage = "Running diagnostics"
            Task { await diagnostic.run() }
        }
    }

    private var placeholder: some View {
        Text("Run diagnostics first (includes non-destructive write probes).")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass()
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary").font(.subheadline.weight(.semibold))
            Text(diagnostic.last.summaryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let outcome = diagnostic.lastAction {
                Text(outcome.message)
                    .font(.caption)
                    .foregroundStyle(outcome.isSuccess ? Theme.affirmative : Theme.caution)
            }
            if let when = diagnostic.last.ranAt {
                Text(when.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass()
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Probe results")
            VStack(spacing: 0) {
                row("BadQuery available", bool: diagnostic.last.badQueryAvailable)
                Divider().padding(.leading, 16)
                row("iOS major", text: "\(diagnostic.last.osMajor)")
                Divider().padding(.leading, 16)
                row(
                    "configurationprofiles dir",
                    bool: diagnostic.last.configProfilesDirReachable,
                    detail: diagnostic.last.configProfilesDirError
                )
                Divider().padding(.leading, 16)
                row(
                    "Directory write (probe file)",
                    bool: diagnostic.last.dirWriteAllowed,
                    detail: diagnostic.last.dirWriteError
                )
                Divider().padding(.leading, 16)
                row("CloudConfiguration exists", bool: diagnostic.last.cloudConfigExists)
                Divider().padding(.leading, 16)
                row(
                    "CloudConfiguration readable",
                    bool: diagnostic.last.cloudConfigReadable,
                    detail: diagnostic.last.cloudConfigError
                )
                Divider().padding(.leading, 16)
                row(
                    "CloudConfiguration write (identical rewrite)",
                    bool: diagnostic.last.cloudConfigWriteAllowed,
                    detail: diagnostic.last.cloudConfigWriteError
                )
                Divider().padding(.leading, 16)
                row(
                    "IsSupervised (plist claim)",
                    text: plistClaimText,
                    detail: "Not counted as success alone"
                )
                Divider().padding(.leading, 16)
                row("OrganizationName", text: diagnostic.last.organizationName ?? "—")
                Divider().padding(.leading, 16)
                row(
                    "MC isSupervised (independent)",
                    text: mcText,
                    detail: diagnostic.last.mcProbeError
                )
                Divider().padding(.leading, 16)
                row(
                    "Write gate (Enable eligible)",
                    bool: diagnostic.last.writeGatePassed
                )
                Divider().padding(.leading, 16)
                row("Local backup present", bool: diagnostic.hasLocalBackup)
            }
            .padding(.horizontal, 16)
            .liquidGlass()
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Experimental actions")

            if diagnostic.enableGatePassed {
                Button { showEnableConfirm = true } label: {
                    actionCard(
                        title: "Enable Supervision",
                        detail: "Write IsSupervised + minimal cloud-config keys; verify via MC",
                        symbol: "lock.open",
                        locked: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(diagnostic.isBusy)
            } else {
                actionCard(
                    title: "Enable Supervision",
                    detail: "Locked until write probes pass — re-run diagnostics",
                    symbol: "lock.fill",
                    locked: true
                )
            }

            Button {
                busyMessage = "Verifying"
                Task { await diagnostic.run() }
            } label: {
                actionCard(
                    title: "Verify Supervision Status",
                    detail: "Re-run diagnostics + ManagedConfiguration probe",
                    symbol: "checkmark.shield",
                    locked: false
                )
            }
            .buttonStyle(.plain)
            .disabled(diagnostic.isBusy)

            if diagnostic.hasLocalBackup {
                Button { showRestoreConfirm = true } label: {
                    actionCard(
                        title: "Restore Original Configuration",
                        detail: "Restore CloudConfigurationDetails from app backup",
                        symbol: "arrow.uturn.backward",
                        locked: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(diagnostic.isBusy)
            } else {
                actionCard(
                    title: "Restore Original Configuration",
                    detail: "No backup yet — created on first Enable",
                    symbol: "lock.fill",
                    locked: true
                )
            }
        }
    }

    private var delayOTANote: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("DelayOTA")
            Text(
                "Even if MC reports supervised, DelayOTA still needs your MDM deferral profile " +
                "(e.g. Mareades forceDelayedSoftwareUpdates) and Apple must still serve iOS 27.0.1. " +
                "Status after Enable: verified only for MC supervision — DelayOTA remains unknown until you test updates UI / MDM."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func runEnable() async {
        busyMessage = "Enabling supervision"
        let outcome = await diagnostic.enableSupervision()
        actionAlertTitle = outcome.isSuccess ? "Supervision active (MC)" : "Result"
        actionAlertBody = outcome.message
        showActionAlert = true
    }

    private func runRestore() async {
        busyMessage = "Restoring"
        let outcome = await diagnostic.restoreOriginalConfiguration()
        actionAlertTitle = outcome.isSuccess ? "Restored" : "Restore failed"
        actionAlertBody = outcome.message
        showActionAlert = true
    }

    // MARK: - Rows

    private var plistClaimText: String {
        guard diagnostic.last.cloudConfigReadable else { return "—" }
        guard let v = diagnostic.last.isSupervisedPlistClaim else { return "key absent" }
        return v ? "true" : "false"
    }

    private var mcText: String {
        if let v = diagnostic.last.mcIsSupervised { return v ? "true" : "false" }
        if diagnostic.last.mcProbeAttempted {
            return diagnostic.last.mcProbeSupported ? "—" : "unsupported"
        }
        return "not run"
    }

    private func row(_ title: String, bool: Bool, detail: String? = nil) -> some View {
        row(title, text: bool ? "yes" : "no", detail: detail, affirmative: bool)
    }

    private func row(_ title: String, text: String, detail: String? = nil, affirmative: Bool? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color(for: affirmative, text: text))
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    private func color(for affirmative: Bool?, text: String) -> Color {
        if let affirmative { return affirmative ? Theme.affirmative : .secondary }
        if text == "true" || text == "yes" { return Theme.affirmative }
        return .primary
    }

    private func actionCard(title: String, detail: String, symbol: String, locked: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(locked ? .secondary : Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .liquidGlass()
        .opacity(locked ? 0.72 : 1)
    }
}
