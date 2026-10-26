import SwiftUI
import UIKit

struct DeviceManagementView: View {
    @ObservedObject private var diagnostic = SupervisionDiagnostic.shared
    @ObservedObject private var onDevice = OnDeviceSupervisionManager.shared
    @State private var showConfiguratorConfirm = false
    @State private var showEnableConfirm = false
    @State private var showActionAlert = false
    @State private var actionAlertTitle = ""
    @State private var actionAlertBody = ""
    @State private var showDiagnostics = false
    @State private var showOnDeviceLog = false
    @State private var busyMessage = "Working…"
    @State private var didAutoRun = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if diagnostic.last.ranAt != nil {
                        statusCard
                        onDeviceSection
                        configuratorFallback
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
            if diagnostic.isBusy || onDevice.isBusy {
                ProgressOverlay(message: busyMessage)
            }
        }
        .navigationTitle("Device Management")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didAutoRun else { return }
            didAutoRun = true
            await refreshAll()
        }
        .alert("Supervise with Apple Configurator?", isPresented: $showConfiguratorConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Open Apple guide", role: .destructive) {
                UIApplication.shared.open(SupervisionDiagnostic.configuratorHelpURL)
            }
        } message: {
            Text(
                "Supported Apple path: Configurator on a Mac erases and supervises the device. " +
                "Back up first. Then return here and Verify Supervision."
            )
        }
        .alert("Experimental: Enable On-Device Supervision?", isPresented: $showEnableConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Enable", role: .destructive) {
                Task { await runEnable() }
            }
        } message: {
            Text(
                "Only runs if a verified supported activation mechanism exists. " +
                "Success requires ManagedConfiguration isSupervised=true. " +
                "Does not forge CloudConfiguration via BadQuery."
            )
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
                "Research into on-device supervision plus Configurator fallback. " +
                "MC isSupervised is the only success signal."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text("EXPERIMENTAL")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Theme.caution)
        }
    }

    private var placeholder: some View {
        Text("Running diagnostics…")
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
                statusRow("Supervision (MC)", diagnostic.last.supervisionStatus,
                          detail: diagnostic.last.mcProbeError,
                          emphasize: diagnostic.last.mcIsSupervised == true)
                Divider().padding(.leading, 16)
                statusRow("DelayOTA readiness", diagnostic.last.delayOTAStatus)
            }
            .padding(.horizontal, 16)
            .liquidGlass()
        }
    }

    private var onDeviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("On-Device Supervision")
            VStack(spacing: 0) {
                statusRow("Filesystem access", onDevice.report.filesystemAccess)
                Divider().padding(.leading, 16)
                statusRow("Supervision eligibility", onDevice.report.eligibility)
                Divider().padding(.leading, 16)
                statusRow(
                    "Activation mechanism",
                    onDevice.report.availableMechanism.rawValue,
                    detail: onDevice.report.missingRequirement
                )
                Divider().padding(.leading, 16)
                statusRow(
                    "ManagedConfiguration",
                    onDevice.report.mcIsSupervised.map { $0 ? "supervised" : "not supervised" } ?? "—"
                )
                Divider().padding(.leading, 16)
                statusRow("Activation result", shortActivationResult)
                Divider().padding(.leading, 16)
                statusRow("DelayOTA readiness", onDevice.report.delayOTAReadiness)
            }
            .padding(.horizontal, 16)
            .liquidGlass()

            if onDevice.report.canEnable {
                Button { showEnableConfirm = true } label: {
                    actionRow(
                        title: "Enable Supervision",
                        detail: "Supported on-device mechanism verified",
                        symbol: "lock.open",
                        locked: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(diagnostic.isBusy || onDevice.isBusy)
            } else {
                actionRow(
                    title: "Enable Supervision",
                    detail: enableLockedDetail,
                    symbol: "lock.fill",
                    locked: true
                )
            }

            Button {
                withAnimation { showOnDeviceLog.toggle() }
            } label: {
                HStack {
                    Text("On-device research log")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: showOnDeviceLog ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showOnDeviceLog {
                Text(onDevice.report.log.joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlass()
            }

            Text(
                "After any future successful activation: force-quit and reopen KetaMine to confirm MC " +
                "still reports supervised; then reboot and Verify again. DelayOTA is separate."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var enableLockedDetail: String {
        if let missing = onDevice.report.missingRequirement, !missing.isEmpty {
            // Keep button subtitle short; full text is in Activation mechanism detail.
            return "Locked — no supported on-device mechanism"
        }
        return "Locked"
    }

    private var shortActivationResult: String {
        let raw = onDevice.report.activationResult
        if raw.count <= 48 { return raw }
        return String(raw.prefix(45)) + "…"
    }

    private var configuratorFallback: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Supported fallback")
            Text(
                "Apple Configurator on a Mac remains the supported way to supervise without ADE. " +
                "It erases the device."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button { showConfiguratorConfirm = true } label: {
                actionRow(
                    title: "Apple Configurator guide",
                    detail: "Erase + Supervise on Mac, then Verify here",
                    symbol: "laptopcomputer.and.iphone",
                    locked: false
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var verifyButton: some View {
        Button {
            Task { await refreshAll(busy: "Verifying supervision") }
        } label: {
            actionRow(
                title: "Verify Supervision",
                detail: "Re-read ManagedConfiguration isSupervised",
                symbol: "checkmark.shield",
                locked: false
            )
        }
        .buttonStyle(.plain)
        .disabled(diagnostic.isBusy || onDevice.isBusy)
    }

    private var diagnosticsDisclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation { showDiagnostics.toggle() }
            } label: {
                HStack {
                    Text("Filesystem diagnostic log")
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
            isBusy: diagnostic.isBusy || onDevice.isBusy
        ) {
            Task { await refreshAll() }
        }
    }

    // MARK: - Actions

    private func refreshAll(busy: String = "Running diagnostics") async {
        busyMessage = busy
        await diagnostic.run()
        await onDevice.evaluate(using: diagnostic.last)
    }

    private func runEnable() async {
        busyMessage = "Attempting activation"
        let outcome = await onDevice.enableSupervisionConfirmed()
        await diagnostic.run()
        await onDevice.evaluate(using: diagnostic.last)
        actionAlertTitle = outcome.isSuccess ? "Supervision active (MC)" : "Activation result"
        actionAlertBody = outcome.message
        showActionAlert = true
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
                Spacer(minLength: 12)
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

    private func actionRow(title: String, detail: String, symbol: String, locked: Bool) -> some View {
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
