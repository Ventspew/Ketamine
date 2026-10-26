import Foundation
import ObjectiveC

/// Deep research + capability assessment for genuine on-device supervision.
///
/// Apple's documented supervision paths (deployment guide):
/// - Automated Device Enrollment (ADE/ABM): supervised at Setup Assistant — typically
///   requires the device to go through setup (erase if already configured).
/// - Apple Configurator for Mac Prepare → Supervise: **erases** the device.
/// - Profile-based / account-driven Device Enrollment on iPhone: MDM **without**
///   supervision (iOS). Account-driven User Enrollment: never supervised.
///
/// There is **no** documented Mac-free, erase-free transition from unsupervised →
/// supervised for an already-configured iPhone. Writable CloudConfigurationDetails
/// via BadQuery is filesystem access only and must not forge IsSupervised.
@MainActor
final class OnDeviceSupervisionManager: ObservableObject {

    static let shared = OnDeviceSupervisionManager()

    // MARK: - Explicit capability states

    enum CapState: String, Equatable {
        case available = "AVAILABLE"
        case unavailable = "UNAVAILABLE"
        case requiresExternalSetup = "REQUIRES_EXTERNAL_SETUP"
        case requiresErase = "REQUIRES_ERASE"
        case unknown = "UNKNOWN"
    }

    enum ActivationMechanism: String, Equatable {
        case none = "none"
        case alreadySupervised = "already-supervised"
        case appleConfiguratorMac = "apple-configurator-mac"
        case adeSetupAssistant = "ade-abm-setup-assistant"
        case mdmEnrollmentUnsupervised = "mdm-enrollment-not-supervised"
    }

    enum ActivationOutcome: Equatable {
        case success(String)
        case refused(String)
        case failed(String)
        case notApplicable(String)
    }

    /// Structured assessment shown in UI and research log.
    struct CapabilityAssessment: Equatable {
        var filesystemAccess: CapState = .unknown
        var configurationIntegrity: CapState = .unknown
        var managedConfiguration: CapState = .unknown
        var currentSupervision: CapState = .unknown
        var mdmEnrollment: CapState = .unknown
        var adeEligibility: CapState = .unknown
        var onDeviceActivation: CapState = .unknown
        var macFreeNoErase: CapState = .unknown
        var delayOTAPrerequisites: CapState = .unknown

        var mcIsSupervised: Bool?
        var mdmEnrolledHint: Bool?
        var plistIsSupervisedClaim: Bool?
        var writableFdProven: Bool = false

        var availableMechanisms: [ActivationMechanism] = []
        var missingPrerequisite: String = ""
        var closestSupportedWorkflow: String = ""
        var macFreeWorkflowNote: String = ""
        var conclusionLines: [String] = []
    }

    struct Report: Equatable {
        var ranAt: Date?
        var assessment = CapabilityAssessment()
        var activationResult: String = "Not attempted"
        var probedClasses: [String] = []
        var probedSelectors: [String] = []
        var log: [String] = []

        /// Enable only if a documented activator is executable in-process (never true today).
        var canEnable: Bool { false }

        var supervisionStatusLabel: String {
            switch assessment.currentSupervision {
            case .available: return "SUPERVISED (MC)"
            case .unavailable: return "Not supervised (MC)"
            case .unknown: return "UNKNOWN"
            default: return assessment.currentSupervision.rawValue
            }
        }
    }

    @Published private(set) var isBusy = false
    @Published private(set) var report = Report()
    @Published private(set) var lastOutcome: ActivationOutcome?

    private init() {}

    // MARK: - Evaluate

    func evaluate(using diagnostic: SupervisionDiagnostic.Result) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        var r = Report()
        r.ranAt = Date()
        var log: [String] = []
        func line(_ s: String) { log.append(s) }

        var a = CapabilityAssessment()
        a.writableFdProven = diagnostic.writableFdProven
        a.plistIsSupervisedClaim = diagnostic.isSupervisedPlistClaim
        a.mcIsSupervised = diagnostic.mcIsSupervised

        // --- Filesystem ---
        if !diagnostic.badQueryAvailable {
            a.filesystemAccess = .unavailable
        } else if diagnostic.writableFdProven {
            a.filesystemAccess = .available
        } else if diagnostic.configProfilesDirReachable {
            a.filesystemAccess = .unavailable
        } else {
            a.filesystemAccess = .unknown
        }
        line("cap.filesystemAccess=\(a.filesystemAccess.rawValue) writableFd=\(diagnostic.writableFdProven)")

        // --- Integrity ---
        if diagnostic.configurationIntegrityOK {
            a.configurationIntegrity = .available
        } else if diagnostic.cloudConfigReadable {
            a.configurationIntegrity = .unknown
        } else {
            a.configurationIntegrity = .unavailable
        }
        line("cap.configurationIntegrity=\(a.configurationIntegrity.rawValue)")

        // --- ManagedConfiguration framework ---
        if diagnostic.mcProbeSupported {
            a.managedConfiguration = .available
        } else {
            a.managedConfiguration = .unavailable
        }
        line("cap.managedConfiguration=\(a.managedConfiguration.rawValue)")

        // --- Current supervision (MC only) ---
        if let supervised = diagnostic.mcIsSupervised {
            a.currentSupervision = supervised ? .available : .unavailable
        } else {
            a.currentSupervision = .unknown
        }
        line("cap.currentSupervision=\(a.currentSupervision.rawValue) mc=\(diagnostic.mcIsSupervised.map(String.init(describing:)) ?? "nil")")
        line("note: plist IsSupervised claim=\(diagnostic.isSupervisedPlistClaim.map(String.init(describing:)) ?? "nil") is NOT authoritative")

        // --- Probe private surfaces + MDM/DEP query getters ---
        let probe = Self.probeActivationSurfaces()
        r.probedClasses = probe.classes
        r.probedSelectors = probe.selectors
        log.append(contentsOf: probe.log)
        a.mdmEnrolledHint = probe.mdmEnrolled
        if let enrolled = probe.mdmEnrolled {
            a.mdmEnrollment = enrolled ? .available : .unavailable
        } else {
            a.mdmEnrollment = .unknown
        }
        line("cap.mdmEnrollment=\(a.mdmEnrollment.rawValue) hint=\(probe.mdmEnrolled.map(String.init(describing:)) ?? "nil")")

        if let dep = probe.depEnrolled {
            a.adeEligibility = dep ? .requiresExternalSetup : .unavailable
            line("cap.adeEligibility=\(a.adeEligibility.rawValue) isEnrolledInDEP=\(dep)")
        } else {
            // Cannot verify ABM assignment from this app without Apple/MDM server APIs.
            a.adeEligibility = .unknown
            line("cap.adeEligibility=UNKNOWN (DEP/ABM assignment not verifiable in-process)")
        }

        // --- Architecture research log ---
        line("arch: Reporter = MCProfileConnection.isSupervised; Activators = ADE Setup / Configurator Prepare")
        line("arch: ADE (iOS 13+) auto-supervises at enrollment; needs ABM + Setup Assistant")
        line("arch: Configurator for Mac Supervise erases device (Apple deployment guide)")
        line("arch: Profile-based Device Enrollment on iPhone = MDM without supervision")
        line("arch: Account-driven Device Enrollment on iPhone = not supervised; User Enrollment = not supervised")
        line("arch: Apple Configurator for iPhone configures other devices — does not supervise this iPhone in place")
        line("arch: No documented unsupervised→supervised path that preserves data without erase/re-setup")
        line("arch: BadQuery writable fd ≠ supervision authorization; forging IsSupervised forbidden")

        // --- On-device activation by KetaMine ---
        if diagnostic.mcIsSupervised == true {
            a.onDeviceActivation = .available
            a.macFreeNoErase = .available
            a.availableMechanisms = [.alreadySupervised]
            a.missingPrerequisite = ""
            a.closestSupportedWorkflow = "None required — already supervised."
            a.macFreeWorkflowNote = "Already supervised; no Mac or erase needed."
            a.conclusionLines = [
                "Can become supervised without Mac? N/A (already supervised).",
                "Without erase? N/A (already supervised).",
                "Can KetaMine perform the transition? N/A.",
                "Verified status: SUPERVISED (MC)."
            ]
            r.activationResult = "Already supervised"
        } else {
            a.onDeviceActivation = .unavailable
            a.macFreeNoErase = .unavailable
            a.availableMechanisms = [
                .appleConfiguratorMac,
                .adeSetupAssistant,
                .mdmEnrollmentUnsupervised
            ]
            a.missingPrerequisite =
                "Apple-signed supervision identity applied at ADE Setup Assistant or " +
                "Configurator Prepare. This process has query-only MC APIs; no authorized " +
                "unsupervised→supervised activator. MDM enrollment alone does not supervise iPhone."
            a.closestSupportedWorkflow =
                "Backup → Apple Configurator for Mac → Prepare → Supervise (erases) → " +
                "optional MDM → restore backup if needed → Verify in KetaMine. " +
                "Or: assign device in Apple Business Manager → erase → Setup Assistant ADE."
            a.macFreeWorkflowNote =
                "Mac-free ADE still requires the device in ABM and typically an erase to re-run Setup. " +
                "No Mac-free, erase-free supervision transition exists for this already-configured iPhone."
            a.conclusionLines = [
                "Can this iPhone become genuinely supervised without a Mac? Only via ADE/ABM + Setup (usually after erase) — not via KetaMine.",
                "Without erasing? No supported Apple path for unsupervised→supervised while keeping the current install.",
                "Can KetaMine perform the transition? No.",
                "Blocking prerequisite: \(a.missingPrerequisite)",
                "Closest alternative: \(a.closestSupportedWorkflow)",
                "Verified current status: Not supervised (MC isSupervised=false)."
            ]
            r.activationResult = "Disabled — no supported on-device mechanism"
            line("verdict: onDeviceActivation=UNAVAILABLE macFreeNoErase=UNAVAILABLE")
        }

        // --- DelayOTA (separate) ---
        if diagnostic.mcIsSupervised == true {
            // Supervision necessary but not sufficient.
            a.delayOTAPrerequisites = .requiresExternalSetup
            line("cap.delayOTAPrerequisites=REQUIRES_EXTERNAL_SETUP (need MDM deferral profile + signed target)")
        } else {
            a.delayOTAPrerequisites = .unavailable
            line("cap.delayOTAPrerequisites=UNAVAILABLE (supervision required first)")
        }

        a.assessmentCompleteNote(&log)
        r.assessment = a
        r.log = log
        report = r
        lastOutcome = nil
    }

    func enableSupervisionConfirmed() async -> ActivationOutcome {
        guard !isBusy else {
            let o = ActivationOutcome.failed("Busy.")
            lastOutcome = o
            return o
        }

        let mc = SupervisionDiagnostic.probeManagedConfigurationIsSupervised()
        if mc.supported, mc.value == true {
            let o = ActivationOutcome.notApplicable(
                "Already supervised (ManagedConfiguration isSupervised=true)."
            )
            lastOutcome = o
            report.activationResult = o.message
            report.assessment.mcIsSupervised = true
            report.assessment.currentSupervision = .available
            return o
        }

        let o = ActivationOutcome.refused(
            "Enable refused: \(report.assessment.missingPrerequisite) " +
            "KetaMine will not forge CloudConfigurationDetails.IsSupervised via BadQuery."
        )
        lastOutcome = o
        report.activationResult = o.message
        return o
    }

    // MARK: - Probes

    private struct ProbeResult {
        var classes: [String]
        var selectors: [String]
        var log: [String]
        var mdmEnrolled: Bool?
        var depEnrolled: Bool?
    }

    /// Detection + safe boolean getters only. Never invokes mutate selectors.
    private static func probeActivationSurfaces() -> ProbeResult {
        var classes: [String] = []
        var selectors: [String] = []
        var log: [String] = []
        var mdmEnrolled: Bool?
        var depEnrolled: Bool?

        let classNames = [
            "MCProfileConnection",
            "MCInstaller",
            "MCCloudConfiguration",
            "DEPClient",
            "MDMClient",
            "RMStore"
        ]

        for name in classNames {
            guard let cls = NSClassFromString(name) as? NSObject.Type else {
                log.append("class \(name): absent")
                continue
            }
            classes.append(name)
            log.append("class \(name): present")
        }

        guard let connectionClass = NSClassFromString("MCProfileConnection") as? NSObject.Type else {
            return ProbeResult(classes: classes, selectors: selectors, log: log, mdmEnrolled: nil, depEnrolled: nil)
        }
        let sharedSel = NSSelectorFromString("sharedConnection")
        guard connectionClass.responds(to: sharedSel),
              let unmanaged = connectionClass.perform(sharedSel),
              let connection = unmanaged.takeUnretainedValue() as? NSObject else {
            log.append("MCProfileConnection.sharedConnection: unavailable")
            return ProbeResult(classes: classes, selectors: selectors, log: log, mdmEnrolled: nil, depEnrolled: nil)
        }

        let querySelectors = [
            "isSupervised",
            "cloudConfigurationDetails",
            "hasCloudConfiguration",
            "isProvisionallyEnrolled",
            "isEnrolledInDEP",
            "isMDMProfileInstalled",
            "isEnrolledViaMDM",
            "hasMDMProfileInstalled",
            "organizationName",
            "deviceSupervisionIdentityCertificate"
        ]
        let mutateSelectors = [
            "superviseDevice",
            "setSupervised:",
            "applyCloudConfiguration:",
            "installCloudConfiguration:",
            "migrateCloudConfiguration:",
            "acceptCloudConfiguration:"
        ]

        for selName in querySelectors {
            let sel = NSSelectorFromString(selName)
            let ok = connection.responds(to: sel)
            log.append("selector \(selName): \(ok ? "responds" : "missing")")
            if ok { selectors.append(selName) }
        }
        for selName in mutateSelectors {
            let sel = NSSelectorFromString(selName)
            let ok = connection.responds(to: sel)
            log.append("selector \(selName) (mutate): \(ok ? "responds — NOT invoked" : "missing")")
            if ok { selectors.append("mutate:\(selName)") }
        }

        // Safe bool getters where present
        mdmEnrolled = boolGetter(connection, names: [
            "isMDMProfileInstalled", "isEnrolledViaMDM", "hasMDMProfileInstalled"
        ], log: &log)
        depEnrolled = boolGetter(connection, names: ["isEnrolledInDEP"], log: &log)

        if let detailsSel = optionalPerformDict(connection, "cloudConfigurationDetails") {
            log.append("cloudConfigurationDetails keys=\(detailsSel.keys.sorted().joined(separator: ","))")
            if let claim = detailsSel["IsSupervised"] as? Bool {
                log.append("cloudConfigurationDetails.IsSupervised claim=\(claim) (non-authoritative)")
            }
        }

        return ProbeResult(
            classes: classes,
            selectors: selectors,
            log: log,
            mdmEnrolled: mdmEnrolled,
            depEnrolled: depEnrolled
        )
    }

    private static func boolGetter(_ object: NSObject, names: [String], log: inout [String]) -> Bool? {
        for name in names {
            let sel = NSSelectorFromString(name)
            guard object.responds(to: sel),
                  let method = class_getInstanceMethod(type(of: object), sel) else { continue }
            typealias BoolFn = @convention(c) (AnyObject, Selector) -> Bool
            let fn = unsafeBitCast(method_getImplementation(method), to: BoolFn.self)
            let value = fn(object, sel)
            log.append("call \(name) → \(value)")
            return value
        }
        return nil
    }

    private static func optionalPerformDict(_ object: NSObject, _ selName: String) -> [String: Any]? {
        let sel = NSSelectorFromString(selName)
        guard object.responds(to: sel),
              let unmanaged = object.perform(sel) else { return nil }
        return unmanaged.takeUnretainedValue() as? [String: Any]
    }
}

private extension OnDeviceSupervisionManager.CapabilityAssessment {
    mutating func assessmentCompleteNote(_ log: inout [String]) {
        log.append("assessment.complete filesystem=\(filesystemAccess.rawValue) integrity=\(configurationIntegrity.rawValue) mc=\(managedConfiguration.rawValue) supervision=\(currentSupervision.rawValue) mdm=\(mdmEnrollment.rawValue) ade=\(adeEligibility.rawValue) onDevice=\(onDeviceActivation.rawValue) macFreeNoErase=\(macFreeNoErase.rawValue) delayOTA=\(delayOTAPrerequisites.rawValue)")
    }
}

extension OnDeviceSupervisionManager.ActivationOutcome {
    var message: String {
        switch self {
        case .success(let s), .refused(let s), .failed(let s), .notApplicable(let s):
            return s
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
