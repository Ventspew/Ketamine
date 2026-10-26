import Darwin
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
    static let cloudConfigurationParentDir =
        configurationProfilesDir + "/Library/ConfigurationProfiles"
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
        var cloudConfigFileInfo: String?

        /// True when at least one write strategy can replace the plist bytes.
        var cloudConfigWriteAllowed: Bool = false
        var cloudConfigWriteError: String?
        var cloudConfigWriteMethod: String?
        var cloudConfigWriteAttempts: [String] = []

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
            let write: String
            if writeGatePassed {
                write = "write OK via \(cloudConfigWriteMethod ?? "?")"
            } else {
                write = "write blocked"
            }
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

    private enum WriteStrategy: String, CaseIterable {
        case inplaceDir = "inplace+dir-token"
        case inplaceParent = "inplace+parent-token"
        case inplaceFile = "inplace+file-token"
        case posixTrunc = "posix-O_WRONLY|O_TRUNC"
        case replaceItem = "temp+replaceItem"
        case deleteRecreate = "unlink+recreate"
    }

    @Published private(set) var isBusy = false
    @Published private(set) var last = Result()
    @Published var lastError: String?
    @Published private(set) var lastAction: ActionOutcome?
    @Published private(set) var hasLocalBackup = false
    /// Last strategy that successfully wrote CloudConfigurationDetails.
    @Published private(set) var lastSuccessfulWriteMethod: String?

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

        // 2) Non-destructive directory write probe
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

        // 3) Read cloud config + multi-strategy identical-bytes write probe
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
                    result.cloudConfigFileInfo = Self.fileInfo(at: url.path)
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

        if result.cloudConfigReadable {
            let probe = await probeCloudConfigWrite()
            result.cloudConfigWriteAllowed = probe.ok
            result.cloudConfigWriteMethod = probe.method
            result.cloudConfigWriteError = probe.error
            result.cloudConfigWriteAttempts = probe.attempts
            if probe.ok {
                lastSuccessfulWriteMethod = probe.method
            }
            // Refresh file info after probe (esp. delete+recreate)
            result.cloudConfigFileInfo = Self.fileInfo(at: Self.cloudConfigurationPath)
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
            let detail = last.cloudConfigWriteError ?? last.summaryLine
            let o = ActionOutcome.failed("Write gate not passed — \(detail)")
            lastAction = o
            return o
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let url = URL(fileURLWithPath: Self.cloudConfigurationPath)
            // Ensure we can read under a live token
            let original: Data
            do {
                let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
                defer { handle.release() }
                original = try Data(contentsOf: url)
            }

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

            let newData = try PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0
            )

            let writeResult = try writeCloudConfiguration(newData, prefer: lastSuccessfulWriteMethod)
            lastSuccessfulWriteMethod = writeResult.method

            guard let readback = try? readCloudConfigurationData(),
                  let verify = try? PropertyListSerialization.propertyList(
                    from: readback, options: [], format: nil
                  ) as? [String: Any],
                  Self.boolValue(verify["IsSupervised"]) == true
            else {
                _ = try? writeCloudConfiguration(original, prefer: lastSuccessfulWriteMethod)
                let o = ActionOutcome.failed(
                    "Write verify failed after \(writeResult.method) — attempted restore of original bytes."
                )
                lastAction = o
                await runUnlocked()
                return o
            }

            try? await Task.sleep(nanoseconds: 400_000_000)
            let mc = Self.probeManagedConfigurationIsSupervised()
            await runUnlocked()

            if mc.supported, mc.value == true {
                let o = ActionOutcome.success(
                    "ManagedConfiguration reports supervised (write via \(writeResult.method)). " +
                    "DelayOTA still needs an MDM deferral profile + Apple still offering the target build."
                )
                lastAction = o
                return o
            }

            let o = ActionOutcome.incomplete(
                "Plist IsSupervised=true via \(writeResult.method), but ManagedConfiguration still reports unsupervised" +
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
            let original = try Data(contentsOf: backupURL)
            let writeResult = try writeCloudConfiguration(original, prefer: lastSuccessfulWriteMethod)
            lastSuccessfulWriteMethod = writeResult.method
            guard let readback = try? readCloudConfigurationData(), readback == original else {
                let o = ActionOutcome.failed(
                    "Restore write verification failed after \(writeResult.method)."
                )
                lastAction = o
                return o
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await runUnlocked()
            let o = ActionOutcome.success(
                "Restored CloudConfigurationDetails.plist from app backup via \(writeResult.method)."
            )
            lastAction = o
            return o
        } catch {
            let o = ActionOutcome.failed(describe(error))
            lastAction = o
            return o
        }
    }

    // MARK: - Write strategies

    private struct ProbeOutcome {
        var ok: Bool
        var method: String?
        var error: String?
        var attempts: [String]
    }

    /// Non-destructive: rewrite identical bytes using each strategy until one works.
    private func probeCloudConfigWrite() async -> ProbeOutcome {
        guard let original = try? readCloudConfigurationData() else {
            return ProbeOutcome(ok: false, method: nil, error: "Could not read plist for write probe.", attempts: [])
        }

        var attempts: [String] = []
        for strategy in WriteStrategy.allCases {
            do {
                try applyWrite(original, strategy: strategy)
                let readback = try readCloudConfigurationData()
                if readback == original {
                    attempts.append("\(strategy.rawValue): OK")
                    return ProbeOutcome(
                        ok: true,
                        method: strategy.rawValue,
                        error: nil,
                        attempts: attempts
                    )
                }
                attempts.append("\(strategy.rawValue): wrote but readback differed (\(readback.count) vs \(original.count) bytes)")
                ensureCloudConfigurationRestored(original)
            } catch {
                attempts.append("\(strategy.rawValue): \(describe(error))")
                ensureCloudConfigurationRestored(original)
            }
        }

        return ProbeOutcome(
            ok: false,
            method: nil,
            error: attempts.joined(separator: " | "),
            attempts: attempts
        )
    }

    private struct WriteApplyResult {
        var method: String
    }

    private func writeCloudConfiguration(_ data: Data, prefer: String?) throws -> WriteApplyResult {
        var order = WriteStrategy.allCases
        if let prefer, let preferred = WriteStrategy(rawValue: prefer) {
            order.removeAll { $0 == preferred }
            order.insert(preferred, at: 0)
        }

        var errors: [String] = []
        for strategy in order {
            do {
                try applyWrite(data, strategy: strategy)
                let readback = try readCloudConfigurationData()
                if readback == data {
                    return WriteApplyResult(method: strategy.rawValue)
                }
                errors.append("\(strategy.rawValue): readback mismatch")
            } catch {
                errors.append("\(strategy.rawValue): \(describe(error))")
            }
        }
        throw NSError(
            domain: "SupervisionDiagnostic",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "All write strategies failed — \(errors.joined(separator: " | "))"]
        )
    }

    private func applyWrite(_ data: Data, strategy: WriteStrategy) throws {
        let path = Self.cloudConfigurationPath
        let url = URL(fileURLWithPath: path)
        let parent = URL(fileURLWithPath: Self.cloudConfigurationParentDir, isDirectory: true)

        switch strategy {
        case .inplaceDir:
            let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
            defer { handle.release() }
            try data.write(to: url, options: [])

        case .inplaceParent:
            let handle = try BadQuery.consume(path: Self.cloudConfigurationParentDir, create: true)
            defer { handle.release() }
            try data.write(to: url, options: [])

        case .inplaceFile:
            let handle = try BadQuery.consume(path: path, create: true)
            defer { handle.release() }
            try data.write(to: url, options: [])

        case .posixTrunc:
            let handle = try BadQuery.consume(path: path, create: true)
            defer { handle.release() }
            try Self.posixOverwrite(path: path, data: data)

        case .replaceItem:
            let dirHandle = try BadQuery.consume(path: Self.cloudConfigurationParentDir, create: true)
            defer { dirHandle.release() }
            let temp = parent.appendingPathComponent(".km_cloudconfig_\(UUID().uuidString).tmp")
            try data.write(to: temp, options: .withoutOverwriting)
            do {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                // Fallback: remove destination then move
                let fileHandle = try BadQuery.consume(path: path, create: true)
                defer { fileHandle.release() }
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: temp, to: url)
            }
            try? FileManager.default.removeItem(at: temp)

        case .deleteRecreate:
            let dirHandle = try BadQuery.consume(path: Self.cloudConfigurationParentDir, create: true)
            defer { dirHandle.release() }
            // Prefer unlink of existing; if it fails, surface that errno.
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    // Also try POSIX unlink under file token
                    let fileHandle = try BadQuery.consume(path: path, create: true)
                    defer { fileHandle.release() }
                    if unlink(path) != 0 {
                        let e = errno
                        throw NSError(
                            domain: NSPOSIXErrorDomain,
                            code: Int(e),
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "unlink failed: \(String(cString: strerror(e))) (errno \(e)); removeItem: \(describe(error))"
                            ]
                        )
                    }
                }
            }
            try data.write(to: url, options: .withoutOverwriting)
        }
    }

    private func readCloudConfigurationData() throws -> Data {
        let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
        defer { handle.release() }
        return try Data(contentsOf: URL(fileURLWithPath: Self.cloudConfigurationPath))
    }

    /// Best-effort put original bytes back after a failed strategy (esp. unlink+recreate).
    private func ensureCloudConfigurationRestored(_ original: Data) {
        if let current = try? readCloudConfigurationData(), current == original { return }
        for strategy in WriteStrategy.allCases {
            if (try? applyWrite(original, strategy: strategy)) != nil,
               let current = try? readCloudConfigurationData(),
               current == original {
                return
            }
        }
    }

    /// Re-run diagnostics while already holding `isBusy` (caller owns the flag).
    private func runUnlocked() async {
        isBusy = false
        await run()
    }

    private static func posixOverwrite(path: String, data: Data) throws {
        let fd = open(path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            let e = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(e),
                userInfo: [NSLocalizedDescriptionKey: "open(O_WRONLY|O_TRUNC) failed: \(String(cString: strerror(e))) (errno \(e))"]
            )
        }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var written = 0
            let total = raw.count
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            while written < total {
                let n = Darwin.write(fd, base!.advanced(by: written), total - written)
                if n < 0 {
                    let e = errno
                    if e == EINTR { continue }
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(e),
                        userInfo: [NSLocalizedDescriptionKey: "write() failed: \(String(cString: strerror(e))) (errno \(e))"]
                    )
                }
                written += n
            }
        }
        if fsync(fd) != 0 {
            let e = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(e),
                userInfo: [NSLocalizedDescriptionKey: "fsync failed: \(String(cString: strerror(e))) (errno \(e))"]
            )
        }
    }

    private static func fileInfo(at path: String) -> String {
        var st = stat()
        let statOK = lstat(path, &st) == 0
        var parts: [String] = []
        if statOK {
            parts.append(String(format: "mode=%o", st.st_mode & 0o7777))
            parts.append("uid=\(st.st_uid) gid=\(st.st_gid)")
            parts.append("size=\(st.st_size)")
            // Flag bits from sys/stat.h (avoid depending on all symbols being visible).
            let ufImmutable: UInt32 = 0x00000002
            let sfImmutable: UInt32 = 0x00020000
            let ufAppend: UInt32 = 0x00000004
            let sfAppend: UInt32 = 0x00040000
            let ufNounlink: UInt32 = 0x00000010
            let sfNounlink: UInt32 = 0x00100000
            if (st.st_flags & ufImmutable) != 0 { parts.append("UF_IMMUTABLE") }
            if (st.st_flags & sfImmutable) != 0 { parts.append("SF_IMMUTABLE") }
            if (st.st_flags & ufAppend) != 0 { parts.append("UF_APPEND") }
            if (st.st_flags & sfAppend) != 0 { parts.append("SF_APPEND") }
            if (st.st_flags & ufNounlink) != 0 { parts.append("UF_NOUNLINK") }
            if (st.st_flags & sfNounlink) != 0 { parts.append("SF_NOUNLINK") }
            parts.append(String(format: "flags=0x%x", st.st_flags))
        } else {
            parts.append("lstat errno=\(errno)")
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            if let perm = attrs[.posixPermissions] as? NSNumber {
                parts.append("NSPerm=\(String(perm.uint16Value, radix: 8))")
            }
            if let immutable = attrs[.immutable] as? Bool, immutable {
                parts.append("NSImmutable=true")
            }
            if let owner = attrs[.ownerAccountName] as? String {
                parts.append("owner=\(owner)")
            }
        }
        // access(2) hints
        let r = access(path, R_OK) == 0
        let w = access(path, W_OK) == 0
        parts.append("access(R)=\(r) access(W)=\(w)")
        return parts.joined(separator: " ")
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
        var s = "\(ns.domain) (\(ns.code)): \(ns.localizedDescription)"
        if ns.domain == NSPOSIXErrorDomain || ns.domain == NSCocoaErrorDomain {
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                s += " | underlying \(underlying.domain) (\(underlying.code)): \(underlying.localizedDescription)"
            }
        }
        return s
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
