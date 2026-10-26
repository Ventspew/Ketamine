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
    @State private var showResearchLog = false
    @State private var showFsLog = false
    @State private var busyMessage = "Working…"
    @State private var didAutoRun = false

    private var a: OnDeviceSupervisionManager.CapabilityAssessment {
        onDevice.report.assessment
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if diagnostic.last.ranAt != nil {
                        supervisionSummary
                        capabilityGrid
                        enrollmentOptions
                        actions
                        researchLog
                        fsLog
                    } else {
                        placeholder
                    }
                    reRunButton
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
                "This erases the iPhone. Back up first. After Prepare → Supervise " +
                "(and optional MDM), return here and Verify. Separate confirmation is required " +
                "before you erase on the Mac."
            )
        }
        .alert("Enable On-Device Supervision?", isPresented: $showEnableConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Enable", role: .destructive) {
                Task { await runEnable() }
            }
        } message: {
            Text(
                "Only if a supported in-app activator exists. Success requires MC isSupervised=true. " +
                "Does not forge CloudConfiguration."
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
            Text("Capability assessment for genuine supervision. MC isSupervised is authoritative.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("EXPERIMENTAL")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Theme.caution)
        }
    }

    private var placeholder: some View {
        Text("Assessing supervision capabilities…")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass()
    }

    private var supervisionSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("On-Device Supervision")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Current status")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(onDevice.report.supervisionStatusLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            a.currentSupervision == .available ? Theme.affirmative : .primary
                        )
                }
                if !a.missingPrerequisite.isEmpty {
                    labeledBlock("Missing prerequisite", a.missingPrerequisite)
                }
                if !a.macFreeWorkflowNote.isEmpty {
                    labeledBlock("Mac-free workflow", a.macFreeWorkflowNote)
                }
                if !a.closestSupportedWorkflow.isEmpty {
                    labeledBlock("Closest supported alternative", a.closestSupportedWorkflow)
                }
                Text(onDevice.report.activationResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass()
        }
    }

    private var capabilityGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Capability assessment")
            VStack(spacing: 0) {
                capRow("Filesystem access", a.filesystemAccess)
                Divider().padding(.leading, 16)
                capRow("Configuration integrity", a.configurationIntegrity)
                Divider().padding(.leading, 16)
                capRow("ManagedConfiguration", a.managedConfiguration)
                Divider().padding(.leading, 16)
                capRow("Supervision (MC)", a.currentSupervision)
                Divider().padding(.leading, 16)
                capRow("MDM enrollment", a.mdmEnrollment)
                Divider().padding(.leading, 16)
                capRow("ADE / ABM eligibility", a.adeEligibility)
                Divider().padding(.leading, 16)
                capRow("On-device activation (KetaMine)", a.onDeviceActivation)
                Divider().padding(.leading, 16)
                capRow("Mac-free + no erase", a.macFreeNoErase)
                Divider().padding(.leading, 16)
                capRow("DelayOTA prerequisites", a.delayOTAPrerequisites)
            }
            .padding(.horizontal, 16)
            .liquidGlass()
        }
    }

    private var enrollmentOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Enrollment options")
            VStack(alignment: .leading, spacing: 8) {
                optionLine("ADE / Apple Business Manager", "Supervised at Setup — usually requires erase to re-run Setup")
                optionLine("Apple Configurator (Mac)", "Supervise = erase (documented)")
                optionLine("MDM profile / account-driven (iPhone)", "Enrollment without supervision")
                optionLine("KetaMine BadQuery plist write", "Not used — does not authorize MC supervision")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass()
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if onDevice.report.canEnable {
                Button { showEnableConfirm = true } label: {
                    actionRow("Enable Supervision", "Supported activator verified", "lock.open", locked: false)
                }
                .buttonStyle(.plain)
            } else {
                actionRow(
                    "Enable Supervision",
                    "Locked — \(shortMissing)",
                    "lock.fill",
                    locked: true
                )
            }

            Button { showConfiguratorConfirm = true } label: {
                actionRow(
                    "Apple Configurator (Mac)",
                    "REQUIRES_ERASE — documented Supervise path",
                    "laptopcomputer.and.iphone",
                    locked: false
                )
            }
            .buttonStyle(.plain)

            Button {
                Task { await refreshAll(busy: "Verifying supervision") }
            } label: {
                actionRow(
                    "Verify Supervision",
                    "Re-read MC isSupervised (+ full assessment)",
                    "checkmark.shield",
                    locked: false
                )
            }
            .buttonStyle(.plain)
            .disabled(diagnostic.isBusy || onDevice.isBusy)

            Text(
                "After Configurator/ADE: Verify → force-quit KetaMine → reopen → Verify. " +
                "Then reboot and Verify again. DelayOTA stays separate from supervision."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var shortMissing: String {
        let s = a.missingPrerequisite
        if s.isEmpty { return "no supported activator" }
        if s.count <= 56 { return s }
        return String(s.prefix(53)) + "…"
    }

    private var researchLog: some View {
        disclosure(title: "Technical research log", isOpen: $showResearchLog) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(a.conclusionLines, id: \.self) { line in
                    Text("• \(line)")
                        .font(.caption2)
                        .textSelection(.enabled)
                }
                Text(onDevice.report.log.joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var fsLog: some View {
        disclosure(title: "Filesystem diagnostic log", isOpen: $showFsLog) {
            VStack(alignment: .leading, spacing: 6) {
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
        }
    }

    private var reRunButton: some View {
        ActionButton(
            title: "Re-run assessment",
            systemImage: "stethoscope",
            isBusy: diagnostic.isBusy || onDevice.isBusy
        ) {
            Task { await refreshAll() }
        }
    }

    // MARK: - Helpers

    private func refreshAll(busy: String = "Running assessment") async {
        busyMessage = busy
        await diagnostic.run()
        await onDevice.evaluate(using: diagnostic.last)
    }

    private func runEnable() async {
        busyMessage = "Activation"
        let outcome = await onDevice.enableSupervisionConfirmed()
        await refreshAll(busy: "Verifying")
        actionAlertTitle = outcome.isSuccess ? "SUPERVISED (MC)" : "Result"
        actionAlertBody = outcome.message
        showActionAlert = true
    }

    private func labeledBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(body).font(.caption).textSelection(.enabled)
        }
    }

    private func optionLine(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func capRow(_ title: String, _ state: OnDeviceSupervisionManager.CapState) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(state.rawValue)
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(capColor(state))
        }
        .padding(.vertical, 12)
    }

    private func capColor(_ state: OnDeviceSupervisionManager.CapState) -> Color {
        switch state {
        case .available: return Theme.affirmative
        case .unavailable: return .secondary
        case .requiresExternalSetup, .requiresErase: return Theme.caution
        case .unknown: return .secondary
        }
    }

    private func actionRow(_ title: String, _ detail: String, _ symbol: String, locked: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(locked ? .secondary : Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .liquidGlass()
        .opacity(locked ? 0.72 : 1)
    }

    private func disclosure<Content: View>(
        title: String,
        isOpen: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation { isOpen.wrappedValue.toggle() }
            } label: {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: isOpen.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if isOpen.wrappedValue {
                content()
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlass()
            }
        }
    }
}
