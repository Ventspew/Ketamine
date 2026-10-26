import Foundation
import ObjectiveC

/// Diagnostics + experimental CloudConfigurationDetails supervision toggle.
///
/// Success for Enable requires ManagedConfiguration `isSupervised == true`
/// after the write — a plist-only change is reported as incomplete.
@MainActor
final class SupervisionDiagnostic: ObservableObject {

    static let shared = SupervisionDiagnostic()

    static let configurationProfilesDir =
        "/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles"
    static let cloudConfigurationRelativePath =
        "Library/ConfigurationProfiles/CloudConfigurationDetails.plist"
    static var cloudConfigurationPath: String {
        configurationProfilesDir + "/" + cloudConfigurationRelativePath
    }

    static let organizationName = "Ketamine Experimental"

    // MARK: - Result

    struct Result: Equatable {
        var ranAt: Date?
        var badQueryAvailable: Bool = false
        var osMajor: Int = 0

        var configProfilesDirReachable: Bool = false
        var configProfilesDirError: String?

        /// Non-destructive: write+delete a probe file under the SystemGroup dir.
        var dirWriteAllowed: Bool = false
        var dirWriteError: String?

        var cloudConfigExists: Bool = false
        var cloudConfigReadable: Bool = false
        var cloudConfigError: String?

        /// Open CloudConfigurationDetails for write without changing contents
        /// (atomic rewrite of identical bytes), then verify.
        var cloudConfigWriteAllowed: Bool = false
        var cloudConfigWriteError: String?

        var isSupervisedPlistClaim: Bool?
        var organizationName: String?
        var cloudConfigKeys: [String] = []

        var mcProbeAttempted: Bool = false
        var mcProbeSupported: Bool = false
        var mcIsSupervised: Bool?
        var mcProbeError: String?

        var lastActionNote: String?

        var systemRecognizedIndependentlyVerified: Bool {
            mcProbeSupported && mcIsSupervised != nil
        }

        var writeGatePassed: Bool {
            badQueryAvailable && configProfilesDirReachable && dirWriteAllowed && cloudConfigWriteAllowed
        }

        var summaryLine: String {
            if !badQueryAvailable { return "BadQuery unavailable." }
            if !configProfilesDirReachable {
                return "configurationprofiles unreachable (\(configProfilesDirError ?? "?"))"
            }
            let write = writeGatePassed ? "write OK" : "write blocked"
            let claim = isSupervisedPlistClaim.map { $0 ? "plist=true" : "plist=false" } ?? "plist=?"
            let mc = mcIsSupervised.map { $0 ? "MC=true" : "MC=false" } ?? "MC=?"
            return "\(write); \(claim); \(mc)"
        }
    }

    enum ActionOutcome: Equatable {
        case success(String)
        case incomplete(String)
        case failed(String)
    }

    @Published private(set) var isBusy = false
    @Published private(set) var last = Result()
    @Published var lastError: String?
    @Published private(set) var lastAction: ActionOutcome?
    @Published private(set) var hasLocalBackup = false

    var accessGatePassed: Bool { last.configProfilesDirReachable && last.badQueryAvailable }
    var enableGatePassed: Bool { last.writeGatePassed && last.cloudConfigReadable }

    private var backupURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cloud_configuration_backup.plist")
    }

    private init() {
        refreshBackupFlag()
    }

    private func refreshBackupFlag() {
        hasLocalBackup = FileManager.default.fileExists(atPath: backupURL.path)
    }

    // MARK: - Diagnostics

    func run() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        var result = Result()
        result.ranAt = Date()
        result.osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        result.badQueryAvailable = BadQuery.isAvailable
        result.lastActionNote = lastAction.map { "\($0)" }

        // 1) Directory reachability
        do {
            let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
            defer { handle.release() }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: Self.configurationProfilesDir,
                isDirectory: &isDir
            )
            result.configProfilesDirReachable = exists && isDir.boolValue
            if !exists {
                result.configProfilesDirError = "Extension consumed but path missing."
            } else if !isDir.boolValue {
                result.configProfilesDirError = "Path is not a directory."
                result.configProfilesDirReachable = false
            }
        } catch {
            result.configProfilesDirReachable = false
            result.configProfilesDirError = describe(error)
        }

        // 2) Non-destructive directory write probe (EligibilityManager .bq_probe pattern)
        if result.configProfilesDirReachable {
            do {
                let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
                defer { handle.release() }
                let dir = URL(fileURLWithPath: Self.configurationProfilesDir, isDirectory: true)
                let probe = dir.appendingPathComponent(".km_write_probe")
                try? FileManager.default.removeItem(at: probe)
                try Data([0x4B, 0x4D]).write(to: probe, options: .withoutOverwriting)
                try FileManager.default.removeItem(at: probe)
                result.dirWriteAllowed = true
            } catch {
                result.dirWriteAllowed = false
                result.dirWriteError = describe(error)
            }
        }

        // 3) Read cloud config + identical-bytes write probe (no semantic change)
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
                        result.cloudConfigError = "Root is not a dictionary."
                        throw CocoaError(.propertyListReadCorrupt)
                    }
                    result.cloudConfigReadable = true
                    result.cloudConfigKeys = parsed.keys.sorted()
                    result.isSupervisedPlistClaim = Self.boolValue(parsed["IsSupervised"])
                    result.organizationName = parsed["OrganizationName"] as? String

                    // Write probe: rewrite exact bytes, verify
                    do {
                        try data.write(to: url, options: [])
                        let readback = try Data(contentsOf: url)
                        if readback == data {
                            result.cloudConfigWriteAllowed = true
                        } else {
                            result.cloudConfigWriteAllowed = false
                            result.cloudConfigWriteError = "Rewrite succeeded but readback differed."
                        }
                    } catch {
                        result.cloudConfigWriteAllowed = false
                        result.cloudConfigWriteError = describe(error)
                    }
                } else {
                    result.cloudConfigError = "CloudConfigurationDetails.plist not present."
                }
            } catch {
                result.cloudConfigReadable = false
                if result.cloudConfigError == nil {
                    result.cloudConfigError = describe(error)
                }
            }
        }

        // 4) MC probe
        let mc = Self.probeManagedConfigurationIsSupervised()
        result.mcProbeAttempted = true
        result.mcProbeSupported = mc.supported
        result.mcIsSupervised = mc.value
        result.mcProbeError = mc.error

        last = result
        refreshBackupFlag()
    }

    // MARK: - Enable / Restore (experimental)

    /// Sets IsSupervised (+ minimal Nugget-compatible keys). Success only if MC reports true.
    func enableSupervision(organization: String = "Ketamine Experimental") async -> ActionOutcome {
        guard !isBusy else {
            let o = ActionOutcome.failed("Busy.")
            lastAction = o
            return o
        }
        guard enableGatePassed else {
            let o = ActionOutcome.failed("Write gate not passed — re-run diagnostics.")
            lastAction = o
            return o
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
            defer { handle.release() }
            let url = URL(fileURLWithPath: Self.cloudConfigurationPath)
            let original = try Data(contentsOf: url)

            // Always refresh app-local backup of pristine-or-pre-op bytes
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try original.write(to: backupURL, options: .atomic)
            }
            refreshBackupFlag()

            guard var dict = try PropertyListSerialization.propertyList(
                from: original, options: [], format: nil
            ) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }

            // Minimal keys (Nugget-compatible); do not touch SkipSetup / purplebuddy.
            dict["IsSupervised"] = true
            dict["ConfigurationWasApplied"] = true
            dict["CloudConfigurationUIComplete"] = true
            dict["AllowPairing"] = true
            dict["PostSetupProfileWasInstalled"] = true
            if dict["ConfigurationSource"] == nil {
                dict["ConfigurationSource"] = 0
            }
            let org = organization.trimmingCharacters(in: .whitespacesAndNewlines)
            if !org.isEmpty {
                dict["OrganizationName"] = org
            }
            dict["IsMDMUnremovable"] = false

            let format = PropertyListSerialization.PropertyListFormat.xml
            let newData = try PropertyListSerialization.data(
                fromPropertyList: dict, format: format, options: 0
            )
            try newData.write(to: url, options: [])
            guard let readback = try? Data(contentsOf: url),
                  let verify = try? PropertyListSerialization.propertyList(
                    from: readback, options: [], format: nil
                  ) as? [String: Any],
                  Self.boolValue(verify["IsSupervised"]) == true
            else {
                try? original.write(to: url, options: [])
                let o = ActionOutcome.failed("Write verify failed — original restored.")
                lastAction = o
                await run()
                return o
            }

            // Independent check — brief settle then MC
            try? await Task.sleep(nanoseconds: 400_000_000)
            let mc = Self.probeManagedConfigurationIsSupervised()
            await run()

            if mc.supported, mc.value == true {
                let o = ActionOutcome.success(
                    "ManagedConfiguration reports supervised. DelayOTA still needs an MDM deferral profile + Apple still offering the target build."
                )
                lastAction = o
                return o
            }

            let o = ActionOutcome.incomplete(
                "Plist IsSupervised=true, but ManagedConfiguration still reports unsupervised" +
                (mc.error.map { " (\($0))" } ?? (mc.value == false ? " (MC=false)" : "")) +
                ". Not counted as success. Use Restore if desired."
            )
            lastAction = o
            return o
        } catch {
            let o = ActionOutcome.failed(describe(error))
            lastAction = o
            lastError = describe(error)
            return o
        }
    }

    func restoreOriginalConfiguration() async -> ActionOutcome {
        guard !isBusy else {
            let o = ActionOutcome.failed("Busy.")
            lastAction = o
            return o
        }
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            let o = ActionOutcome.failed("No local backup — run Enable once first, or reinstall.")
            lastAction = o
            return o
        }
        if !last.configProfilesDirReachable {
            await run()
            guard last.configProfilesDirReachable else {
                let o = ActionOutcome.failed("configurationprofiles not reachable.")
                lastAction = o
                return o
            }
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
            defer { handle.release() }
            let url = URL(fileURLWithPath: Self.cloudConfigurationPath)
            let original = try Data(contentsOf: backupURL)
            try original.write(to: url, options: [])
            guard let readback = try? Data(contentsOf: url), readback == original else {
                let o = ActionOutcome.failed("Restore write verification failed.")
                lastAction = o
                return o
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await run()
            let o = ActionOutcome.success("Restored CloudConfigurationDetails.plist from app backup.")
            lastAction = o
            return o
        } catch {
            let o = ActionOutcome.failed(describe(error))
            lastAction = o
            return o
        }
    }

    // MARK: - Helpers

    private static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return nil
    }

    static func probeManagedConfigurationIsSupervised() -> (supported: Bool, value: Bool?, error: String?) {
        guard let connectionClass = NSClassFromString("MCProfileConnection") as? NSObject.Type else {
            return (false, nil, "MCProfileConnection not found.")
        }
        let sharedSel = NSSelectorFromString("sharedConnection")
        guard connectionClass.responds(to: sharedSel),
              let unmanaged = connectionClass.perform(sharedSel),
              let connection = unmanaged.takeUnretainedValue() as? NSObject else {
            return (false, nil, "sharedConnection unavailable.")
        }
        let supervisedSel = NSSelectorFromString("isSupervised")
        guard connection.responds(to: supervisedSel) else {
            for alt in ["isSupervisedDevice", "deviceSupervised"] {
                let s = NSSelectorFromString(alt)
                if connection.responds(to: s),
                   let method = class_getInstanceMethod(type(of: connection), s) {
                    typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
                    let fn = unsafeBitCast(method_getImplementation(method), to: BoolGetter.self)
                    return (true, fn(connection, s), nil)
                }
            }
            return (false, nil, "isSupervised selector missing.")
        }
        guard let method = class_getInstanceMethod(type(of: connection), supervisedSel) else {
            return (false, nil, "Could not get Method for isSupervised.")
        }
        typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
        let fn = unsafeBitCast(method_getImplementation(method), to: BoolGetter.self)
        return (true, fn(connection, supervisedSel), nil)
    }

    private func describe(_ error: Error) -> String {
        if let bq = error as? BadQueryError {
            return bq.errorDescription ?? String(describing: bq)
        }
        let ns = error as NSError
        return "\(ns.domain) (\(ns.code)): \(ns.localizedDescription)"
    }
}

extension SupervisionDiagnostic.ActionOutcome {
    var message: String {
        switch self {
        case .success(let s), .incomplete(let s), .failed(let s): return s
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
