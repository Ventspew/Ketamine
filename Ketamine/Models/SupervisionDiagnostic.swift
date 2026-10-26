import Foundation
import ObjectiveC

/// Read-only probes for BadQuery reachability into the configurationprofiles
/// SystemGroup and the CloudConfigurationDetails.plist `IsSupervised` flag.
///
/// Does **not** write supervision state. A plist `IsSupervised == true` is reported
/// as a configuration claim only — ManagedConfiguration / DelayOTA recognition
/// requires an independent check (e.g. MDM DeviceInformation).
@MainActor
final class SupervisionDiagnostic: ObservableObject {

    static let shared = SupervisionDiagnostic()

    // MARK: - Paths (same SystemGroup tree EligibilityManager uses on iOS 27)

    static let configurationProfilesDir =
        "/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles"
    static let cloudConfigurationRelativePath =
        "Library/ConfigurationProfiles/CloudConfigurationDetails.plist"
    static var cloudConfigurationPath: String {
        configurationProfilesDir + "/" + cloudConfigurationRelativePath
    }

    // MARK: - Published results

    struct Result: Equatable {
        var ranAt: Date?
        var badQueryAvailable: Bool = false
        var osMajor: Int = 0

        var configProfilesDirReachable: Bool = false
        var configProfilesDirError: String?

        var cloudConfigExists: Bool = false
        var cloudConfigReadable: Bool = false
        var cloudConfigError: String?
        var isSupervisedPlistClaim: Bool?
        var organizationName: String?
        var cloudConfigKeys: [String] = []

        /// Best-effort ManagedConfiguration private API probe (read-only).
        var mcProbeAttempted: Bool = false
        var mcProbeSupported: Bool = false
        var mcIsSupervised: Bool?
        var mcProbeError: String?

        /// True only when MC probe returned a definite bool (not merely plist).
        var systemRecognizedIndependentlyVerified: Bool {
            mcProbeSupported && mcIsSupervised != nil
        }

        var summaryLine: String {
            if !badQueryAvailable { return "BadQuery symbols unavailable — diagnostics incomplete." }
            if osMajor < 27 {
                return "SystemGroup grant for this probe is documented for iOS 27+; this OS may return -3."
            }
            if !configProfilesDirReachable {
                return "configurationprofiles SystemGroup not reachable (\(configProfilesDirError ?? "unknown"))."
            }
            if cloudConfigReadable {
                let claim = isSupervisedPlistClaim.map { $0 ? "true" : "false" } ?? "missing"
                let mc: String
                if let v = mcIsSupervised {
                    mc = v ? "MC=true" : "MC=false"
                } else if mcProbeAttempted {
                    mc = "MC unverified"
                } else {
                    mc = "MC not probed"
                }
                return "Cloud config readable — IsSupervised plist=\(claim); \(mc)."
            }
            if cloudConfigExists {
                return "CloudConfigurationDetails.plist exists but could not be read (\(cloudConfigError ?? "unknown"))."
            }
            return "configurationprofiles reachable; CloudConfigurationDetails.plist not found (device may never have been cloud-configured)."
        }
    }

    @Published private(set) var isBusy = false
    @Published private(set) var last: Result = Result()
    @Published var lastError: String?

    /// When true, Enable/Restore UI may be shown — still disabled until access + policy gates pass.
    var accessGatePassed: Bool {
        last.configProfilesDirReachable && last.badQueryAvailable
    }

    private init() {}

    // MARK: - Run

    func run() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        var result = Result()
        result.ranAt = Date()
        result.osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        result.badQueryAvailable = BadQuery.isAvailable

        // 1) Directory consume (EligibilityManager pattern — directory, not leaf)
        do {
            let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
            defer { handle.release() }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: Self.configurationProfilesDir,
                isDirectory: &isDir
            )
            result.configProfilesDirReachable = exists
            if !exists {
                result.configProfilesDirError = "Extension consumed but path does not exist on disk."
            } else if !isDir.boolValue {
                result.configProfilesDirError = "Path exists but is not a directory."
                result.configProfilesDirReachable = false
            }
        } catch {
            result.configProfilesDirReachable = false
            result.configProfilesDirError = describe(error)
        }

        // 2) Read CloudConfigurationDetails.plist (still holding dir semantics)
        if result.configProfilesDirReachable {
            do {
                let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
                defer { handle.release() }
                let url = URL(fileURLWithPath: Self.cloudConfigurationPath)
                let exists = FileManager.default.fileExists(atPath: url.path)
                result.cloudConfigExists = exists
                if exists {
                    let data = try Data(contentsOf: url)
                    guard let parsed = try PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil
                    ) as? [String: Any] else {
                        result.cloudConfigError = "Plist parsed but root is not a dictionary."
                        throw CocoaError(.propertyListReadCorrupt)
                    }
                    result.cloudConfigReadable = true
                    result.cloudConfigKeys = parsed.keys.sorted()
                    if let supervised = parsed["IsSupervised"] as? Bool {
                        result.isSupervisedPlistClaim = supervised
                    } else if let num = parsed["IsSupervised"] as? NSNumber {
                        result.isSupervisedPlistClaim = num.boolValue
                    } else {
                        result.isSupervisedPlistClaim = nil
                    }
                    result.organizationName = parsed["OrganizationName"] as? String
                } else {
                    result.cloudConfigError = "File not present at expected path."
                }
            } catch {
                result.cloudConfigReadable = false
                if result.cloudConfigError == nil {
                    result.cloudConfigError = describe(error)
                }
            }
        }

        // 3) Independent MC probe (optional private API — never writes)
        let mc = Self.probeManagedConfigurationIsSupervised()
        result.mcProbeAttempted = true
        result.mcProbeSupported = mc.supported
        result.mcIsSupervised = mc.value
        result.mcProbeError = mc.error

        last = result
    }

    // MARK: - ManagedConfiguration probe

    /// Attempts `MCProfileConnection.sharedConnection.isSupervised` via ObjC runtime.
    /// If the selector is missing, reports unsupported — never fabricates a result.
    private static func probeManagedConfigurationIsSupervised() -> (supported: Bool, value: Bool?, error: String?) {
        guard let connectionClass = NSClassFromString("MCProfileConnection") as? NSObject.Type else {
            return (false, nil, "MCProfileConnection class not found (ManagedConfiguration not linked / stripped).")
        }
        let sharedSel = NSSelectorFromString("sharedConnection")
        guard connectionClass.responds(to: sharedSel) else {
            return (false, nil, "sharedConnection selector missing.")
        }
        guard let unmanaged = connectionClass.perform(sharedSel),
              let connection = unmanaged.takeUnretainedValue() as? NSObject else {
            return (false, nil, "sharedConnection returned nil.")
        }
        let supervisedSel = NSSelectorFromString("isSupervised")
        guard connection.responds(to: supervisedSel) else {
            // Some builds use isSupervisedDevice / deviceIsSupervised — try alternates
            for alt in ["isSupervisedDevice", "deviceSupervised"] {
                let s = NSSelectorFromString(alt)
                if connection.responds(to: s) {
                    let obj = connection.perform(s)?.takeUnretainedValue()
                    if let b = obj as? Bool { return (true, b, nil) }
                    if let n = obj as? NSNumber { return (true, n.boolValue, nil) }
                }
            }
            return (false, nil, "isSupervised selector missing on MCProfileConnection.")
        }
        // BOOL returns via perform are boxed as NSNumber on modern runtimes when using
        // NSInvocation; perform(_:) with BOOL is unreliable. Use methodIMP.
        typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
        guard let method = class_getInstanceMethod(type(of: connection), supervisedSel),
              let imp = method_getImplementation(method) else {
            return (false, nil, "Could not get IMP for isSupervised.")
        }
        let fn = unsafeBitCast(imp, to: BoolGetter.self)
        let value = fn(connection, supervisedSel)
        return (true, value, nil)
    }

    private func describe(_ error: Error) -> String {
        if let bq = error as? BadQueryError {
            return bq.localizedDescription ?? String(describing: bq)
        }
        let ns = error as NSError
        return "\(ns.domain) (\(ns.code)): \(ns.localizedDescription)"
    }
}
