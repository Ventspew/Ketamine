import SwiftUI
import UIKit

struct DeviceManagementView: View {
    @ObservedObject private var diagnostic = SupervisionDiagnostic.shared
    @State private var showGateAlert = false

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
                ProgressOverlay(message: "Running diagnostics")
            }
        }
        .navigationTitle("Device Management")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Not enabled yet", isPresented: $showGateAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "Enable / Restore stay locked until configurationprofiles access is confirmed " +
                "and ManagedConfiguration recognition is independently verified. " +
                "A plist IsSupervised flag alone is not treated as success."
            )
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Supervision diagnostics")
                .font(.largeTitle.weight(.semibold))
            Text(
                "Read-only checks for BadQuery access to the configurationprofiles SystemGroup " +
                "and CloudConfigurationDetails.plist. Nothing is written."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var runButton: some View {
        ActionButton(
            title: diagnostic.last.ranAt == nil ? "Run diagnostics" : "Re-run diagnostics",
            systemImage: "stethoscope",
            isBusy: diagnostic.isBusy
        ) {
            Task { await diagnostic.run() }
        }
    }

    private var placeholder: some View {
        Text("Tap Run diagnostics to probe BadQuery and CloudConfiguration on this device.")
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
                row("CloudConfiguration exists", bool: diagnostic.last.cloudConfigExists)
                Divider().padding(.leading, 16)
                row(
                    "CloudConfiguration readable",
                    bool: diagnostic.last.cloudConfigReadable,
                    detail: diagnostic.last.cloudConfigError
                )
                Divider().padding(.leading, 16)
                row(
                    "IsSupervised (plist claim)",
                    text: plistClaimText,
                    detail: "Not proof of DelayOTA / ManagedConfiguration enforcement"
                )
                Divider().padding(.leading, 16)
                row(
                    "OrganizationName",
                    text: diagnostic.last.organizationName ?? "—"
                )
                Divider().padding(.leading, 16)
                row(
                    "MC isSupervised (independent)",
                    text: mcText,
                    detail: diagnostic.last.mcProbeError
                )
                Divider().padding(.leading, 16)
                row(
                    "Independently verified",
                    bool: diagnostic.last.systemRecognizedIndependentlyVerified,
                    detail: diagnostic.last.systemRecognizedIndependentlyVerified
                        ? nil
                        : "Use Mareades MDM → Info → IsSupervised as a second channel"
                )
            }
            .padding(.horizontal, 16)
            .liquidGlass()

            if !diagnostic.last.cloudConfigKeys.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cloud config keys (\(diagnostic.last.cloudConfigKeys.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(diagnostic.last.cloudConfigKeys.joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .liquidGlass()
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Supervision actions")
            Text("Writes stay locked until access + independent MC recognition are validated.")
                .font(.caption)
                .foregroundStyle(.secondary)

            lockedAction(
                title: "Enable Supervision",
                detail: "Would write CloudConfigurationDetails IsSupervised — disabled"
            )
            lockedAction(
                title: "Verify Supervision Status",
                detail: "Re-runs diagnostics + MC probe (safe). Tap Run diagnostics above."
            )
            lockedAction(
                title: "Restore Original Configuration",
                detail: "Would restore backed-up cloud config — disabled until Enable exists"
            )
        }
    }

    private var delayOTANote: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("DelayOTA")
            Text(
                "Deferred software updates need ManagedConfiguration-recognized supervision " +
                "plus an MDM restriction profile (e.g. Mareades forceDelayedSoftwareUpdates). " +
                "This screen does not install updates or extend IPSW signing. " +
                "iOS 27.0.1 is only available if Apple still serves that build to the device."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

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
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color(for: affirmative, text: text))
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    private func color(for affirmative: Bool?, text: String) -> Color {
        if let affirmative {
            return affirmative ? Theme.affirmative : .secondary
        }
        if text == "true" || text == "yes" { return Theme.affirmative }
        return .primary
    }

    private func lockedAction(title: String, detail: String) -> some View {
        Button { showGateAlert = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .liquidGlass()
            .opacity(0.72)
        }
        .buttonStyle(.plain)
    }
}
