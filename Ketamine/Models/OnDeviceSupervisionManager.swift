import Foundation
import ObjectiveC

/// Experimental research into on-device supervision activation without Configurator.
///
/// Genuine supervision (ManagedConfiguration `isSupervised == true`) is issued by
/// Apple during ADE/Setup or Apple Configurator Prepare — not by rewriting
/// CloudConfigurationDetails via sandbox escape.
///
/// This manager:
/// - Reuses BadQuery filesystem diagnostics (read / writable-fd proof only)
/// - Probes ManagedConfiguration / related private classes for activation entry points
/// - Refuses exploit mutation of protected supervision records
/// - Enables activation only if a supported, non-exploit mechanism is detected
@MainActor
final class OnDeviceSupervisionManager: ObservableObject {

    static let shared = OnDeviceSupervisionManager()

    enum ActivationMechanism: String, Equatable {
        case none = "none"
        /// Device already supervised — nothing to activate.
        case alreadySupervised = "already-supervised"
        /// Documented Apple path (Mac + erase). Not on-device.
        case appleConfigurator = "apple-configurator"
        /// ADE/ABM identity applied at Setup Assistant — not recoverable mid-lifecycle here.
        case adeSetupAssistant = "ade-setup-assistant"
    }

    enum ActivationOutcome: Equatable {
        case success(String)
        case refused(String)
        case failed(String)
        case notApplicable(String)
    }

    struct Report: Equatable {
        var ranAt: Date?
        var filesystemAccess: String = "—"
        var writableFdProven: Bool = false
        var configurationIntegrityOK: Bool = false
        var plistIsSupervisedClaim: Bool? = nil
        var mcIsSupervised: Bool? = nil
        var mcSupported: Bool = false
        var mcError: String?

        var eligibility: String = "Unknown"
        var availableMechanism: ActivationMechanism = .none
        var missingRequirement: String?
        var activationResult: String = "Not attempted"
        var delayOTAReadiness: String = "Not ready"

        var probedClasses: [String] = []
        var probedSelectors: [String] = []
        var log: [String] = []

        var canEnable: Bool {
            // Only if we have a real on-device mechanism — currently never for unsigned apps.
            // alreadySupervised does not need Enable.
            false
        }

        var summary: String {
            "mechanism=\(availableMechanism.rawValue); MC=\(mcIsSupervised.map { $0 ? "true" : "false" } ?? "?"); " +
            (missingRequirement ?? eligibility)
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

        r.filesystemAccess = diagnostic.filesystemAccessStatus
        r.writableFdProven = diagnostic.writableFdProven
        r.configurationIntegrityOK = diagnostic.configurationIntegrityOK
        r.plistIsSupervisedClaim = diagnostic.isSupervisedPlistClaim
        r.mcIsSupervised = diagnostic.mcIsSupervised
        r.mcSupported = diagnostic.mcProbeSupported
        r.mcError = diagnostic.mcProbeError

        line("fs=\(r.filesystemAccess) writableFd=\(r.writableFdProven) integrity=\(r.configurationIntegrityOK)")
        line("plist IsSupervised claim=\(r.plistIsSupervisedClaim.map(String.init(describing:)) ?? "nil")")
        line("MC isSupervised=\(r.mcIsSupervised.map(String.init(describing:)) ?? "nil")")

        // Architecture notes (research, not activation)
        line("arch: CloudConfigurationDetails IsSupervised is a claim file; MC isSupervised is authoritative")
        line("arch: ADE cloud config is applied by Setup/manageddaemons with Apple-signed identity — not by 3rd-party apps")
        line("arch: BadQuery writable fd proves FS access only; writing IsSupervised≠MC supervision (forbidden here)")

        let probe = Self.probeActivationSurfaces()
        r.probedClasses = probe.classes
        r.probedSelectors = probe.selectors
        log.append(contentsOf: probe.log)

        if diagnostic.mcIsSupervised == true {
            r.availableMechanism = .alreadySupervised
            r.eligibility = "Device already supervised (MC)"
            r.missingRequirement = nil
            r.delayOTAReadiness =
                "Supervision OK — DelayOTA still needs MDM deferral profile + Apple still signing target"
            r.activationResult = "Already supervised"
            line("verdict: already supervised")
        } else {
            // No supported on-device activation for an unsigned third-party app.
            r.availableMechanism = .none
            r.eligibility = "Not eligible for on-device activation from KetaMine"
            r.missingRequirement =
                "Missing Apple-signed supervision identity / Configurator or ADE enrollment. " +
                "MCProfileConnection exposes isSupervised for query only; no public or privately " +
                "callable unsupervised→supervised transition was found for this process. " +
                "Filesystem write access to CloudConfigurationDetails is insufficient and must not " +
                "be used to forge supervision."
            r.delayOTAReadiness = "Not ready (device not supervised per MC)"
            r.activationResult = "Disabled — no supported mechanism"
            line("verdict: no on-device mechanism; missing=\(r.missingRequirement!)")

            // Document Configurator / ADE as external mechanisms (not activatable here)
            if probe.hasQueryOnlySupervisionAPI {
                line("note: supervision query API present; activation API absent for this sandbox/signing")
            }
            line("external: apple-configurator (erase) and ade-setup-assistant remain the supported paths")
            _ = ActivationMechanism.appleConfigurator
            _ = ActivationMechanism.adeSetupAssistant
        }

        r.log = log
        report = r
        lastOutcome = nil
    }

    /// Explicit activation attempt. Refuses exploit-based plist mutation.
    func enableSupervisionConfirmed() async -> ActivationOutcome {
        guard !isBusy else {
            let o = ActivationOutcome.failed("Busy.")
            lastOutcome = o
            return o
        }

        // Refresh MC first
        let mc = SupervisionDiagnostic.probeManagedConfigurationIsSupervised()
        if mc.supported, mc.value == true {
            let o = ActivationOutcome.notApplicable(
                "Already supervised (ManagedConfiguration isSupervised=true). No activation needed."
            )
            lastOutcome = o
            report.activationResult = o.message
            report.mcIsSupervised = true
            return o
        }

        if !report.canEnable {
            let detail = report.missingRequirement
                ?? "No supported on-device activation mechanism."
            let o = ActivationOutcome.refused(
                "Enable refused: \(detail) " +
                "KetaMine will not mutate CloudConfigurationDetails.IsSupervised via BadQuery " +
                "because that does not produce ManagedConfiguration-recognized supervision."
            )
            lastOutcome = o
            report.activationResult = o.message
            return o
        }

        // Placeholder for a future supported path — currently unreachable while canEnable == false.
        let o = ActivationOutcome.failed(
            "Internal error: canEnable true but no activator implemented."
        )
        lastOutcome = o
        report.activationResult = o.message
        return o
    }

    // MARK: - Private API surface probe (detection only)

    private struct ProbeResult {
        var classes: [String]
        var selectors: [String]
        var log: [String]
        var hasQueryOnlySupervisionAPI: Bool
    }

    /// Looks for classes/selectors related to supervision / cloud config / DEP.
    /// Does not invoke mutating methods.
    private static func probeActivationSurfaces() -> ProbeResult {
        var classes: [String] = []
        var selectors: [String] = []
        var log: [String] = []
        var hasQuery = false

        let classNames = [
            "MCProfileConnection",
            "MCInstaller",
            "MCCloudConfiguration",
            "MCDeviceUploadSubmission",
            "DEPClient",
            "MDMClient",
            "RMStore",
            "ManagedConfigurationHelper"
        ]

        for name in classNames {
            guard let cls = NSClassFromString(name) as? NSObject.Type else {
                log.append("class \(name): absent")
                continue
            }
            classes.append(name)
            log.append("class \(name): present")

            if name == "MCProfileConnection" {
                let sharedSel = NSSelectorFromString("sharedConnection")
                guard cls.responds(to: sharedSel),
                      let unmanaged = cls.perform(sharedSel),
                      let connection = unmanaged.takeUnretainedValue() as? NSObject else {
                    log.append("MCProfileConnection.sharedConnection: unavailable")
                    continue
                }

                let querySelectors = [
                    "isSupervised",
                    "isSupervisedDevice",
                    "cloudConfigurationDetails",
                    "hasCloudConfiguration",
                    "isProvisionallyEnrolled",
                    "isEnrolledInDEP",
                    "organizationName"
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
                    if ok {
                        selectors.append(selName)
                        if selName == "isSupervised" || selName == "isSupervisedDevice" {
                            hasQuery = true
                        }
                    }
                }
                for selName in mutateSelectors {
                    let sel = NSSelectorFromString(selName)
                    let ok = connection.responds(to: sel)
                    log.append("selector \(selName) (mutate): \(ok ? "responds — not invoked" : "missing")")
                    if ok { selectors.append("mutate:\(selName)") }
                }
            }
        }

        return ProbeResult(
            classes: classes,
            selectors: selectors,
            log: log,
            hasQueryOnlySupervisionAPI: hasQuery
        )
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
