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

    /// Strategies used only when Enable/Restore must actually write.
    /// Prefer file-token POSIX — dir-token open(O_WRONLY) fails with EPERM on this device.
    private enum WriteStrategy: String, CaseIterable {
        case posixFileToken = "posix-fd+file-token"
        case posixParentToken = "posix-fd+parent-token"
        case cocoaFileToken = "cocoa+file-token"
        case cocoaParentToken = "cocoa+parent-token"
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

    /// Focus: why file/parent tokens allow open(O_WRONLY) while dir-token gets EPERM,
    /// whether those fds are the real plist with write mode, and whether identical-byte
    /// persist works while the token remains held. Never changes supervision keys.
    private func investigateCloudConfigWrite(originalBytes: Data) -> InvestigateOutcome {
        var log: [String] = []
        let path = Self.cloudConfigurationPath
        let parent = Self.cloudConfigurationParentDir
        let url = URL(fileURLWithPath: path)
        let metaBefore = Self.fileInfo(at: path)

        func line(_ s: String) { log.append(s) }
        line("meta-before \(metaBefore)")

        // --- A) SystemGroup dir-token only (previous failing path) ---
        do {
            let dirToken = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
            defer { dirToken.release() }
            line("token=dir handle=\(dirToken.handle) path=\(dirToken.path) active=yes")
            line(posixAccess(path: path, mode: W_OK, label: "access(W_OK)+dir-token", pathLabel: path))
            let openDir = posixOpen(path: path, flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW, label: "open(O_WRONLY)+dir-token")
            line(openDir.line)
            if let fd = openDir.fd {
                line(inspectFd(fd, expectedPath: path))
                close(fd)
            }
            do {
                try originalBytes.write(to: url, options: [])
                line("op=Data.write([])+dir-token path=\(path) result=OK")
            } catch {
                line("op=Data.write([])+dir-token path=\(path) result=FAIL \(describe(error))")
            }
        } catch {
            line("op=consume(dir-token) result=FAIL \(describe(error))")
        }

        // --- B) File-token: open, identify fd, reproduce, identical persist via held fd ---
        var fileTokenOpenOK = false
        var fileTokenPersistOK = false
        var fileTokenFdWriteOK = false
        var fileTokenIdentityOK = false

        do {
            let fileToken = try BadQuery.consume(path: path, create: true)
            defer {
                line("token=file handle=\(fileToken.handle) release")
                fileToken.release()
            }
            line("token=file handle=\(fileToken.handle) path=\(fileToken.path) active=yes")

            // Reproducibility: two sequential opens while token held
            let open1 = posixOpen(path: path, flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW, label: "open(O_WRONLY)+file-token #1")
            line(open1.line)
            if let fd = open1.fd {
                fileTokenOpenOK = true
                let insp = inspectFd(fd, expectedPath: path)
                line(insp)
                fileTokenIdentityOK = insp.contains("inode-match=yes") && insp.contains("write-mode=yes")
                close(fd)
            }
            let open2 = posixOpen(path: path, flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW, label: "open(O_WRONLY)+file-token #2")
            line(open2.line)
            if open2.fd == nil {
                line("op=reproducibility file-token open #2 failed (not reproducible under held token)")
            }
            // Content-preserving persist on a fresh fd while token still held
            let openPersist = posixOpen(
                path: path,
                flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                label: "open(O_WRONLY)+file-token persist"
            )
            line(openPersist.line)
            if let fd = openPersist.fd {
                fileTokenOpenOK = true
                line(inspectFd(fd, expectedPath: path))
                let persist = identicalPersistViaFd(fd: fd, path: path, originalBytes: originalBytes)
                line(persist.line)
                fileTokenFdWriteOK = persist.writeSyscallOK
                fileTokenPersistOK = persist.readbackOK
                close(fd)
            }

            // Cocoa while file-token still held
            do {
                try originalBytes.write(to: url, options: [])
                let rb = try Data(contentsOf: url)
                line(
                    rb == originalBytes
                        ? "op=Data.write([])+file-token path=\(path) result=OK"
                        : "op=Data.write([])+file-token path=\(path) result=readback mismatch"
                )
                if rb == originalBytes { fileTokenPersistOK = true }
            } catch {
                line("op=Data.write([])+file-token path=\(path) result=FAIL \(describe(error))")
            }

            // Prove token must stay live: open after we will release is checked in section D
        } catch {
            line("op=consume(file-token) path=\(path) result=FAIL \(describe(error))")
        }

        // --- C) Parent-token ---
        var parentTokenOpenOK = false
        var parentTokenPersistOK = false
        do {
            let parentToken = try BadQuery.consume(path: parent, create: true)
            defer {
                line("token=parent handle=\(parentToken.handle) release")
                parentToken.release()
            }
            line("token=parent handle=\(parentToken.handle) path=\(parentToken.path) active=yes")
            let openP = posixOpen(path: path, flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW, label: "open(O_WRONLY)+parent-token")
            line(openP.line)
            if let fd = openP.fd {
                parentTokenOpenOK = true
                line(inspectFd(fd, expectedPath: path))
                let persist = identicalPersistViaFd(fd: fd, path: path, originalBytes: originalBytes)
                line(persist.line)
                if persist.readbackOK { parentTokenPersistOK = true }
                close(fd)
            }
        } catch {
            line("op=consume(parent-token) path=\(parent) result=FAIL \(describe(error))")
        }

        // --- D) After file-token released: open should fail again if scope was the cause ---
        do {
            let dirToken = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
            defer { dirToken.release() }
            let after = posixOpen(path: path, flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW, label: "open(O_WRONLY)+dir-token after file-token released")
            line(after.line)
            if let fd = after.fd { close(fd) }
        } catch {
            line("op=consume(dir-token) post-release check FAIL \(describe(error))")
        }

        // Sibling temp under parent (does not touch target) — context only
        do {
            let parentToken = try BadQuery.consume(path: parent, create: true)
            defer { parentToken.release() }
            let tempPath = (parent as NSString).appendingPathComponent(".km_fsprobe_\(UUID().uuidString).tmp")
            let openTemp = posixOpen(
                path: tempPath,
                flags: O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                label: "open(O_CREAT|O_EXCL) sibling temp +parent-token",
                mode: 0o644
            )
            line(openTemp.line)
            if let fd = openTemp.fd {
                _ = posixWriteAll(fd: fd, data: Data([0x4B, 0x4D]))
                close(fd)
                _ = unlink(tempPath)
                line("op=unlink(sibling temp) path=\(tempPath) result=OK")
            }
        } catch {
            line("op=sibling-temp+parent-token FAIL \(describe(error))")
        }

        line("op=rename(temp→CloudConfigurationDetails.plist) result=SKIPPED (would replace live config)")

        let metaAfter = Self.fileInfo(at: path)
        line("meta-after \(metaAfter)")

        // Integrity
        var bytesOK = false
        if let now = try? Data(contentsOf: url) {
            bytesOK = (now == originalBytes)
            line(bytesOK ? "op=post-investigation-byte-check result=unchanged" : "op=post-investigation-byte-check result=CHANGED")
            if !bytesOK {
                // Best-effort restore under file-token
                if let token = try? BadQuery.consume(path: path, create: true) {
                    defer { token.release() }
                    try? Self.posixOverwrite(path: path, data: originalBytes)
                }
                line("op=emergency-restore-attempted")
            }
        }

        // --- Verdict (layered; do not conflate open / persist / MC / DelayOTA) ---
        var writeProven = false
        var writeMethod: String?
        var failing: String?
        var verdict: String?

        if fileTokenPersistOK {
            writeProven = true
            writeMethod = fileTokenFdWriteOK ? "posix-fd+file-token" : "cocoa+file-token"
            verdict =
                "WRITE PERSIST PROVEN (layer 2) via \(writeMethod!): file-token yields a writable fd " +
                "to CloudConfigurationDetails.plist and identical-byte rewrite readback matches. " +
                "dir-token open alone fails with EPERM — prior NSCocoaErrorDomain 513 was likely " +
                "using the wrong token scope, not a total ban on this file. " +
                "This does NOT prove ManagedConfiguration will recognize IsSupervised (layer 3) " +
                "nor DelayOTA (layer 4). Enable unlocked for explicit confirmed test only."
        } else if parentTokenPersistOK {
            writeProven = true
            writeMethod = "posix-fd+parent-token"
            verdict =
                "WRITE PERSIST PROVEN (layer 2) via parent-token identical rewrite. " +
                "Enable unlocked for explicit confirmed test only. MC/DelayOTA still unproven."
        } else if fileTokenOpenOK || parentTokenOpenOK {
            failing =
                "open(O_WRONLY) under file/parent-token OK but identical persist failed " +
                "(fdWrite=\(fileTokenFdWriteOK) identity=\(fileTokenIdentityOK))"
            verdict =
                "LAYER 1 ONLY: writable fd obtained under file/parent-token " +
                "(identity \(fileTokenIdentityOK ? "OK" : "unverified")), but persisting identical bytes failed. " +
                "Open≠persist. Enable remains locked. See FS log for write()/fsync errno."
        } else {
            failing = "file-token and parent-token open(O_WRONLY) both failed"
            verdict =
                "SYSTEM RESTRICTION: cannot open CloudConfigurationDetails.plist for write " +
                "even with file/parent BadQuery tokens. Enable remains locked."
        }

        if !bytesOK {
            writeProven = false
            verdict = (verdict ?? "") + " INTEGRITY FAIL: bytes changed during probe — Enable locked."
        }

        let writeError = log.filter {
            $0.contains("FAIL") || $0.contains("DENY") || $0.contains("errno=") || $0.contains("persist")
        }.suffix(10).joined(separator: " || ")

        return InvestigateOutcome(
            log: log,
            failingOperation: failing,
            verdict: verdict,
            writeProven: writeProven,
            writeMethod: writeMethod,
            writeError: writeProven ? nil : writeError
        )
    }

    private struct PersistResult {
        var line: String
        var writeSyscallOK: Bool
        var readbackOK: Bool
    }

    /// Overwrite with the same bytes through an already-open O_WRONLY fd (token must stay held).
    private func identicalPersistViaFd(fd: Int32, path: String, originalBytes: Data) -> PersistResult {
        if lseek(fd, 0, SEEK_SET) < 0 {
            let e = errno
            return PersistResult(
                line: "op=identical-persist lseek path=\(path) errno=\(e) (\(String(cString: strerror(e))))",
                writeSyscallOK: false,
                readbackOK: false
            )
        }
        let wrote = posixWriteAll(fd: fd, data: originalBytes)
        if !wrote {
            let e = errno
            return PersistResult(
                line: "op=identical-persist write() path=\(path) errno=\(e) (\(String(cString: strerror(e))))",
                writeSyscallOK: false,
                readbackOK: false
            )
        }
        if fsync(fd) != 0 {
            let e = errno
            return PersistResult(
                line: "op=identical-persist fsync path=\(path) errno=\(e) (\(String(cString: strerror(e))))",
                writeSyscallOK: false,
                readbackOK: false
            )
        }
        // Read back via separate open (still expect caller to hold token)
        guard let readback = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return PersistResult(
                line: "op=identical-persist readback path=\(path) result=unreadable",
                writeSyscallOK: true,
                readbackOK: false
            )
        }
        let ok = readback == originalBytes
        return PersistResult(
            line: "op=identical-persist path=\(path) write=OK fsync=OK readback=\(ok ? "match" : "MISMATCH") bytes=\(originalBytes.count)",
            writeSyscallOK: true,
            readbackOK: ok
        )
    }

    /// fcntl flags + F_GETPATH + inode match vs path lstat.
    private func inspectFd(_ fd: Int32, expectedPath: String) -> String {
        var parts: [String] = ["op=fd-inspect fd=\(fd)"]
        let flags = fcntl(fd, F_GETFL)
        if flags == -1 {
            parts.append("F_GETFL errno=\(errno)")
        } else {
            let acc = flags & O_ACCMODE
            let writable = acc == O_WRONLY || acc == O_RDWR
            parts.append("F_GETFL=\(flags)")
            parts.append("write-mode=\(writable ? "yes" : "no")")
            let accName: String
            switch acc {
            case O_RDONLY: accName = "RDONLY"
            case O_WRONLY: accName = "WRONLY"
            case O_RDWR: accName = "RDWR"
            default: accName = "other"
            }
            parts.append("acc=\(accName)")
        }
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(fd, F_GETPATH, &pathBuf) == 0 {
            let got = String(cString: pathBuf)
            parts.append("F_GETPATH=\(got)")
            parts.append("path-match=\(got == expectedPath || got == "/private\(expectedPath)" || expectedPath == "/private\(got)" ? "yes" : "no")")
        } else {
            parts.append("F_GETPATH errno=\(errno)")
        }
        var stFd = stat()
        var stPath = stat()
        let fdOK = fstat(fd, &stFd) == 0
        let pathOK = lstat(expectedPath, &stPath) == 0
        if fdOK && pathOK {
            let match = stFd.st_ino == stPath.st_ino && stFd.st_dev == stPath.st_dev
            parts.append("inode-match=\(match ? "yes" : "no")")
            parts.append("fd-ino=\(stFd.st_ino) path-ino=\(stPath.st_ino)")
            parts.append(String(format: "fd-mode=%o size=%lld", stFd.st_mode & 0o7777, Int64(stFd.st_size)))
        } else {
            parts.append("fstat/lstat failed")
        }
        return parts.joined(separator: " ")
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
        case .posixFileToken:
            let handle = try BadQuery.consume(path: path, create: true)
            defer { handle.release() }
            try Self.posixOverwrite(path: path, data: data)
        case .posixParentToken:
            let handle = try BadQuery.consume(path: Self.cloudConfigurationParentDir, create: true)
            defer { handle.release() }
            try Self.posixOverwrite(path: path, data: data)
        case .cocoaFileToken:
            let handle = try BadQuery.consume(path: path, create: true)
            defer { handle.release() }
            try data.write(to: url, options: [])
        case .cocoaParentToken:
            let handle = try BadQuery.consume(path: Self.cloudConfigurationParentDir, create: true)
            defer { handle.release() }
            try data.write(to: url, options: [])
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
