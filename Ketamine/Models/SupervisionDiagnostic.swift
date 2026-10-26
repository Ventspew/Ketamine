import Darwin
import Foundation
import ObjectiveC

/// Diagnostics + experimental CloudConfigurationDetails supervision toggle.
///
/// Diagnostics first isolate the failing filesystem operation (open / temp create /
/// rename / Cocoa rewrite) with errno + path. Enable stays locked unless a
/// content-preserving identical rewrite of the existing plist actually succeeds.
/// Success for Enable still requires ManagedConfiguration `isSupervised == true`.
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

        var dirWriteAllowed: Bool = false
        var dirWriteError: String?

        var cloudConfigExists: Bool = false
        var cloudConfigReadable: Bool = false
        var cloudConfigError: String?
        var cloudConfigFileInfo: String?

        /// Per-operation lines: op, path, token, errno/cocoa, result.
        var fsOperationLog: [String] = []
        /// First failing op that blocks overwriting the existing plist.
        var failingOperation: String?
        /// Explicit verdict for UI (restriction vs implementation).
        var restrictionVerdict: String?

        /// True only if identical-byte rewrite of the live plist succeeded.
        var cloudConfigWriteAllowed: Bool = false
        var cloudConfigWriteError: String?
        var cloudConfigWriteMethod: String?

        var isSupervisedPlistClaim: Bool?
        var organizationName: String?
        var cloudConfigKeys: [String] = []

        var mcProbeAttempted: Bool = false
        var mcProbeSupported: Bool = false
        var mcIsSupervised: Bool?
        var mcProbeError: String?

        var lastActionNote: String?

        var writeGatePassed: Bool {
            badQueryAvailable && configProfilesDirReachable && dirWriteAllowed && cloudConfigWriteAllowed
        }

        var summaryLine: String {
            if !badQueryAvailable { return "BadQuery unavailable." }
            if !configProfilesDirReachable {
                return "configurationprofiles unreachable (\(configProfilesDirError ?? "?"))"
            }
            if let verdict = restrictionVerdict, !cloudConfigWriteAllowed {
                return verdict
            }
            let write = writeGatePassed
                ? "write OK via \(cloudConfigWriteMethod ?? "?")"
                : "write blocked"
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

    /// Strategies used only when Enable/Restore must actually write (not for FS matrix).
    private enum WriteStrategy: String, CaseIterable {
        case inplaceFile = "inplace+file-token"
        case inplaceParent = "inplace+parent-token"
        case inplaceDir = "inplace+dir-token"
        case posixTrunc = "posix-O_WRONLY|O_TRUNC"
    }

    @Published private(set) var isBusy = false
    @Published private(set) var last = Result()
    @Published var lastError: String?
    @Published private(set) var lastAction: ActionOutcome?
    @Published private(set) var hasLocalBackup = false
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

        // 2) Directory create probe (sibling of SystemGroup root — not the plist)
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

        // 3) Read cloud config (no write)
        var originalBytes: Data?
        if result.configProfilesDirReachable {
            do {
                let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
                defer { handle.release() }
                let url = URL(fileURLWithPath: Self.cloudConfigurationPath)
                let exists = FileManager.default.fileExists(atPath: url.path)
                result.cloudConfigExists = exists
                if exists {
                    let data = try Data(contentsOf: url)
                    originalBytes = data
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

        // 4) Non-mutating FS operation matrix + content-preserving identical rewrite check
        if result.cloudConfigReadable, let originalBytes {
            let probe = investigateCloudConfigWrite(originalBytes: originalBytes)
            result.fsOperationLog = probe.log
            result.failingOperation = probe.failingOperation
            result.restrictionVerdict = probe.verdict
            result.cloudConfigWriteAllowed = probe.writeProven
            result.cloudConfigWriteMethod = probe.writeMethod
            result.cloudConfigWriteError = probe.writeError
            if probe.writeProven {
                lastSuccessfulWriteMethod = probe.writeMethod
            }
            result.cloudConfigFileInfo = Self.fileInfo(at: Self.cloudConfigurationPath)
        }

        // 5) MC probe
        let mc = Self.probeManagedConfigurationIsSupervised()
        result.mcProbeAttempted = true
        result.mcProbeSupported = mc.supported
        result.mcIsSupervised = mc.value
        result.mcProbeError = mc.error

        last = result
        refreshBackupFlag()
    }

    // MARK: - Enable / Restore (experimental — only when write proven)

    func enableSupervision(organization: String = "Ketamine Experimental") async -> ActionOutcome {
        guard !isBusy else {
            let o = ActionOutcome.failed("Busy.")
            lastAction = o
            return o
        }
        guard enableGatePassed else {
            let detail = last.restrictionVerdict
                ?? last.failingOperation
                ?? last.cloudConfigWriteError
                ?? last.summaryLine
            let o = ActionOutcome.failed("Write gate not passed — \(detail)")
            lastAction = o
            return o
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let url = URL(fileURLWithPath: Self.cloudConfigurationPath)
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
        guard last.cloudConfigWriteAllowed || lastSuccessfulWriteMethod != nil else {
            let o = ActionOutcome.failed(
                "Cannot restore — CloudConfiguration write not proven. " +
                (last.restrictionVerdict ?? last.failingOperation ?? "")
            )
            lastAction = o
            return o
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

    // MARK: - FS investigation (does not change supervision keys)

    private struct InvestigateOutcome {
        var log: [String]
        var failingOperation: String?
        var verdict: String?
        var writeProven: Bool
        var writeMethod: String?
        var writeError: String?
    }

    /// Isolates open vs temp-create vs rename vs Cocoa rewrite. Does not unlink or
    /// replace CloudConfigurationDetails. Identical-byte rewrite is content-preserving.
    private func investigateCloudConfigWrite(originalBytes: Data) -> InvestigateOutcome {
        var log: [String] = []
        let path = Self.cloudConfigurationPath
        let parent = Self.cloudConfigurationParentDir
        let url = URL(fileURLWithPath: path)

        func line(_ s: String) { log.append(s) }

        // Hold SystemGroup token for the whole matrix (same as production writes).
        let dirToken: BadQueryHandle?
        do {
            dirToken = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
        } catch {
            return InvestigateOutcome(
                log: ["consume(dir) failed: \(describe(error))"],
                failingOperation: "bad_query consume SystemGroup dir",
                verdict: "SYSTEM RESTRICTION or BadQuery failure: cannot hold configurationprofiles token.",
                writeProven: false,
                writeMethod: nil,
                writeError: describe(error)
            )
        }
        defer { dirToken?.release() }

        // --- access(2) ---
        line(posixAccess(path: path, mode: R_OK, label: "access(R_OK)", pathLabel: path))
        line(posixAccess(path: path, mode: W_OK, label: "access(W_OK)", pathLabel: path))
        line(posixAccess(path: parent, mode: W_OK, label: "access(W_OK)", pathLabel: parent))

        // --- open existing plist: read / write-no-trunc / write+trunc (trunc immediately restored) ---
        let openRO = posixOpen(path: path, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW, label: "open(O_RDONLY)")
        line(openRO.line)
        if let fd = openRO.fd { close(fd) }

        let openWO = posixOpen(path: path, flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW, label: "open(O_WRONLY) no trunc")
        line(openWO.line)
        if let fd = openWO.fd { close(fd) }

        // open(O_WRONLY|O_TRUNC) intentionally not probed — would zero the live plist.

        // --- sibling temp create in parent (does not touch target) ---
        let tempName = ".km_fsprobe_\(UUID().uuidString).tmp"
        let tempPath = (parent as NSString).appendingPathComponent(tempName)
        let openTemp = posixOpen(
            path: tempPath,
            flags: O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            label: "open(O_CREAT|O_EXCL) sibling temp",
            mode: 0o644
        )
        line(openTemp.line)
        var tempCreated = false
        if let fd = openTemp.fd {
            tempCreated = true
            _ = posixWriteAll(fd: fd, data: Data([0x4B, 0x4D]))
            close(fd)
        }

        // rename temp → temp2 (parent dir rename capability)
        if tempCreated {
            let temp2 = tempPath + ".2"
            errno = 0
            if rename(tempPath, temp2) == 0 {
                line("op=rename(temp→temp2) path=\(tempPath) → \(temp2) result=OK")
                // rename temp2 onto target would replace CloudConfiguration — DO NOT.
                // Instead: rename exchange probe using renamex_np if available is still risky.
                // Just rename back and unlink.
                _ = rename(temp2, tempPath)
            } else {
                let e = errno
                line("op=rename(temp→temp2) path=\(tempPath) errno=\(e) (\(String(cString: strerror(e))))")
            }
            errno = 0
            if unlink(tempPath) == 0 {
                line("op=unlink(sibling temp) path=\(tempPath) result=OK")
            } else {
                let e = errno
                line("op=unlink(sibling temp) path=\(tempPath) errno=\(e) (\(String(cString: strerror(e))))")
                try? FileManager.default.removeItem(atPath: tempPath)
                try? FileManager.default.removeItem(atPath: tempPath + ".2")
            }
        }

        // Attempt rename of a NEW sibling onto the target is intentionally skipped
        // (would replace CloudConfigurationDetails). Log that we skipped it.
        line("op=rename(temp→CloudConfigurationDetails.plist) path=\(path) result=SKIPPED (would replace live config)")

        // --- Cocoa Data.write identical bytes (maps to user's NSCocoaErrorDomain 513) ---
        // Content-preserving: same bytes. Does not change IsSupervised / supervision keys.
        var cocoaInplace: String?
        do {
            try originalBytes.write(to: url, options: [])
            let readback = try Data(contentsOf: url)
            if readback == originalBytes {
                cocoaInplace = "OK"
                line("op=Data.write(options:[]) identical path=\(path) token=dir result=OK")
            } else {
                cocoaInplace = "readback mismatch"
                line("op=Data.write(options:[]) identical path=\(path) token=dir result=readback mismatch")
                // try restore
                try? originalBytes.write(to: url, options: [])
            }
        } catch {
            cocoaInplace = describe(error)
            line("op=Data.write(options:[]) identical path=\(path) token=dir result=FAIL \(describe(error))")
        }

        // Cocoa atomic (temp + replace) — Foundation may create NS*.tmp then replace.
        // If atomic succeeds it still writes identical content. If it fails, unwrap errno.
        do {
            try originalBytes.write(to: url, options: .atomic)
            let readback = try Data(contentsOf: url)
            if readback == originalBytes {
                line("op=Data.write(options:.atomic) identical path=\(path) token=dir result=OK")
            } else {
                line("op=Data.write(options:.atomic) identical path=\(path) token=dir result=readback mismatch")
                try? originalBytes.write(to: url, options: [])
            }
        } catch {
            line("op=Data.write(options:.atomic) identical path=\(path) token=dir result=FAIL \(describe(error))")
        }

        // File-scoped token + open(O_WRONLY)
        do {
            let fileToken = try BadQuery.consume(path: path, create: true)
            defer { fileToken.release() }
            let underFile = posixOpen(
                path: path,
                flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                label: "open(O_WRONLY) under file-token"
            )
            line(underFile.line)
            if let fd = underFile.fd { close(fd) }

            do {
                try originalBytes.write(to: url, options: [])
                line("op=Data.write(options:[]) identical path=\(path) token=file result=OK")
            } catch {
                line("op=Data.write(options:[]) identical path=\(path) token=file result=FAIL \(describe(error))")
            }
        } catch {
            line("op=consume(file-token) path=\(path) result=FAIL \(describe(error))")
        }

        // Parent-scoped token
        do {
            let parentToken = try BadQuery.consume(path: parent, create: true)
            defer { parentToken.release() }
            let underParent = posixOpen(
                path: path,
                flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                label: "open(O_WRONLY) under parent-token"
            )
            line(underParent.line)
            if let fd = underParent.fd { close(fd) }
        } catch {
            line("op=consume(parent-token) path=\(parent) result=FAIL \(describe(error))")
        }

        // --- Verdict ---
        let openDenied = openWO.fd == nil
        let openErrno = openWO.errnoValue

        var failing: String?
        var verdict: String?
        var writeProven = false
        var writeMethod: String?
        var writeError: String?

        // Unlock only when Cocoa identical rewrite succeeded (supervision keys unchanged).
        if cocoaInplace == "OK" {
            writeProven = true
            writeMethod = "inplace+dir-token"
        }

        if !writeProven {
            if openDenied, let e = openErrno, e == EACCES || e == EPERM {
                failing = "open(O_WRONLY) path=\(path) errno=\(e) (\(String(cString: strerror(e))))"
                verdict =
                    "SYSTEM RESTRICTION: existing CloudConfigurationDetails.plist cannot be opened for write " +
                    "(errno \(e) \(String(cString: strerror(e)))). " +
                    "Sibling/temp create in the parent may still work; that is not sufficient to overwrite this file. " +
                    "NSCocoaErrorDomain 513 is the Foundation mapping of this denial. Enable remains locked."
            } else if openDenied {
                let e = openErrno ?? -1
                failing = "open(O_WRONLY) path=\(path) errno=\(e)"
                verdict =
                    "Write blocked at open(O_WRONLY) for \(path) (errno \(e) \(String(cString: strerror(e)))). Enable remains locked."
            } else if !openDenied, let cocoaInplace, cocoaInplace != "OK" {
                failing = "Data.write(options:[]) path=\(path) — \(cocoaInplace)"
                verdict =
                    "open(O_WRONLY) succeeded but Cocoa Data.write failed (\(cocoaInplace)). " +
                    "Likely Foundation replace/O_TRUNC path denial — write not proven. Enable remains locked."
            } else {
                failing = "CloudConfiguration write not proven"
                verdict = "CloudConfiguration write not proven after FS matrix. Enable remains locked."
            }
            writeError = log.filter {
                $0.contains("FAIL") || $0.contains("DENY") || $0.contains("errno=")
            }.suffix(8).joined(separator: " || ")
        }

        // Final safety: ensure bytes unchanged
        if let now = try? Data(contentsOf: url), now != originalBytes {
            line("op=post-investigation-byte-check result=CHANGED — attempting restore")
            try? Self.posixOverwrite(path: path, data: originalBytes)
            try? originalBytes.write(to: url, options: [])
            verdict = (verdict ?? "") + " WARNING: investigation altered bytes; restore attempted."
            writeProven = false
        } else {
            line("op=post-investigation-byte-check result=unchanged")
        }

        return InvestigateOutcome(
            log: log,
            failingOperation: failing,
            verdict: verdict,
            writeProven: writeProven,
            writeMethod: writeMethod,
            writeError: writeError
        )
    }

    private struct OpenResult {
        var line: String
        var fd: Int32?
        var errnoValue: Int32?
    }

    private func posixAccess(path: String, mode: Int32, label: String, pathLabel: String) -> String {
        errno = 0
        let ok = access(path, mode) == 0
        if ok {
            return "op=\(label) path=\(pathLabel) result=OK"
        }
        let e = errno
        return "op=\(label) path=\(pathLabel) result=DENY errno=\(e) (\(String(cString: strerror(e))))"
    }

    private func posixOpen(path: String, flags: Int32, label: String, mode: mode_t = 0) -> OpenResult {
        errno = 0
        let fd: Int32
        if (flags & O_CREAT) != 0 {
            fd = open(path, flags, mode)
        } else {
            fd = open(path, flags)
        }
        if fd >= 0 {
            return OpenResult(
                line: "op=\(label) path=\(path) result=OK fd=\(fd)",
                fd: fd,
                errnoValue: nil
            )
        }
        let e = errno
        return OpenResult(
            line: "op=\(label) path=\(path) result=FAIL errno=\(e) (\(String(cString: strerror(e))))",
            fd: nil,
            errnoValue: e
        )
    }

    private func posixWriteAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var written = 0
            let total = raw.count
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            while written < total {
                let n = Darwin.write(fd, base.advanced(by: written), total - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += n
            }
            return true
        }
    }

    // MARK: - Write helpers (Enable / Restore only)

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
        }
    }

    private func readCloudConfigurationData() throws -> Data {
        let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
        defer { handle.release() }
        return try Data(contentsOf: URL(fileURLWithPath: Self.cloudConfigurationPath))
    }

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
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "open(O_WRONLY|O_TRUNC) path=\(path) failed: \(String(cString: strerror(e))) (errno \(e))"
                ]
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
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "write() path=\(path) failed: \(String(cString: strerror(e))) (errno \(e))"
                        ]
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
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "fsync path=\(path) failed: \(String(cString: strerror(e))) (errno \(e))"
                ]
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
        var parts: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 5 {
            var chunk = "\(ns.domain) (\(ns.code)): \(ns.localizedDescription)"
            if let path = ns.userInfo[NSFilePathErrorKey] as? String {
                chunk += " path=\(path)"
            } else if let url = ns.userInfo[NSURLErrorKey] as? URL {
                chunk += " url=\(url.path)"
            }
            if ns.domain == NSPOSIXErrorDomain {
                chunk += " strerror=\(String(cString: strerror(Int32(ns.code))))"
            }
            parts.append(chunk)
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " ← ")
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
