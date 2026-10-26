import SwiftUI
import UIKit

struct DeviceManagementView: View {
    @ObservedObject private var diagnostic = SupervisionDiagnostic.shared
    @State private var showConfiguratorConfirm = false
    @State private var showDiagnostics = false
    @State private var busyMessage = "Working…"
    @State private var didAutoRun = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if diagnostic.last.ranAt != nil {
                        statusCard
                        supervisionWorkflow
                        verifyButton
                        diagnosticsDisclosure
                    } else {
                        placeholder
                    }
                    runButton
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
        .task {
            guard !didAutoRun else { return }
            didAutoRun = true
            busyMessage = "Running diagnostics"
            await diagnostic.run()
        }
        .alert("Supervise with Apple Configurator?", isPresented: $showConfiguratorConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Open Apple guide", role: .destructive) {
                UIApplication.shared.open(SupervisionDiagnostic.configuratorHelpURL)
            }
        } message: {
            Text(
                "Genuine supervision requires Apple Configurator on a Mac and erases this iPhone. " +
                "Back up first. After Prepare → Supervise (and optional MDM), return here and tap " +
                "Verify Supervision. KetaMine does not rewrite system plists to fake supervision."
            )
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Device Management")
                .font(.largeTitle.weight(.semibold))
            Text(
                "Checks filesystem access and ManagedConfiguration supervision. " +
                "Apple-recognized supervision needs Configurator or ADE — not a plist edit."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var placeholder: some View {
        Text("Running read-only diagnostics…")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Status")
            VStack(spacing: 0) {
                statusRow("Filesystem access", diagnostic.last.filesystemAccessStatus)
                Divider().padding(.leading, 16)
                statusRow("Configuration integrity", diagnostic.last.integrityStatus,
                          detail: diagnostic.last.configurationIntegrityDetail)
                Divider().padding(.leading, 16)
                statusRow("Supervision eligibility", diagnostic.last.supervisionEligibilityStatus)
                Divider().padding(.leading, 16)
                statusRow("Supervision (MC)", diagnostic.last.supervisionStatus,
                          detail: diagnostic.last.mcProbeError,
                          emphasize: diagnostic.last.mcIsSupervised == true)
                Divider().padding(.leading, 16)
                statusRow("DelayOTA readiness", diagnostic.last.delayOTAStatus)
            }
            .padding(.horizontal, 16)
            .liquidGlass()

            if let verdict = diagnostic.last.restrictionVerdict {
                Text(verdict)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var supervisionWorkflow: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Enable Supervision")
            VStack(alignment: .leading, spacing: 10) {
                Text("Apple Configurator (supported)")
                    .font(.body.weight(.semibold))
                Text(
                    "1. Back up this iPhone.\n" +
                    "2. On a Mac: Apple Configurator → select device → Prepare → Supervise.\n" +
                    "3. This erases the device. Restore from backup afterward if needed.\n" +
                    "4. Enroll Mareades MDM (or other) if you need DelayOTA deferral.\n" +
                    "5. Return here → Verify Supervision (MC must show Supervised)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button { showConfiguratorConfirm = true } label: {
                    HStack {
                        Image(systemName: "laptopcomputer.and.iphone")
                        Text("Continue with Apple Configurator")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(18)
                    .liquidGlass()
                }
                .buttonStyle(.plain)
                .disabled(diagnostic.isBusy)
            }
        }
    }

    private var verifyButton: some View {
        Button {
            busyMessage = "Verifying supervision"
            Task { await diagnostic.verifySupervisionStatus() }
        } label: {
            HStack {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Verify Supervision").font(.body.weight(.semibold))
                    Text("Re-read ManagedConfiguration isSupervised")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .liquidGlass()
        }
        .buttonStyle(.plain)
        .disabled(diagnostic.isBusy)
    }

    private var diagnosticsDisclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation { showDiagnostics.toggle() }
            } label: {
                HStack {
                    Text("Diagnostic log")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showDiagnostics ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showDiagnostics {
                VStack(alignment: .leading, spacing: 8) {
                    if let sha = diagnostic.last.cloudConfigSHA256 {
                        Text("SHA-256: \(sha)")
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                    if let sha2 = diagnostic.last.cloudConfigSHA256Recheck {
                        Text("SHA-256 recheck: \(sha2)")
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                    Text(diagnostic.last.fsOperationLog.joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlass()
            }
        }
    }

    private var runButton: some View {
        ActionButton(
            title: "Re-run diagnostics",
            systemImage: "stethoscope",
            isBusy: diagnostic.isBusy
        ) {
            busyMessage = "Running diagnostics"
            Task { await diagnostic.run() }
        }
    }

    // MARK: - Rows

    private func statusRow(
        _ title: String,
        _ value: String,
        detail: String? = nil,
        emphasize: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(emphasize ? Theme.affirmative : .primary)
                    .multilineTextAlignment(.trailing)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 12)
    }
}
