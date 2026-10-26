import CryptoKit
import Darwin
import Foundation
import ObjectiveC

/// Device-management diagnostics and Apple-recognized supervision status.
///
/// Genuine supervision is established via Apple Configurator (device erase) or
/// ADE/ABM — not by rewriting CloudConfigurationDetails.plist.
///
/// Diagnostics are read-only against the live cloud-config plist (no writes).
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

    static let configuratorHelpURL = URL(string: "https://support.apple.com/apple-configurator")!

    // MARK: - Result

    struct Result: Equatable {
        var ranAt: Date?
        var badQueryAvailable: Bool = false
        var osMajor: Int = 0

        var configProfilesDirReachable: Bool = false
        var configProfilesDirError: String?

        var dirCreateAllowed: Bool = false
        var dirCreateError: String?

        var cloudConfigExists: Bool = false
        var cloudConfigReadable: Bool = false
        var cloudConfigError: String?
        var cloudConfigFileInfo: String?

        /// SHA-256 (hex) of live CloudConfigurationDetails bytes (token-held read).
        var cloudConfigSHA256: String?
        /// Second independent read hash (integrity / stability).
        var cloudConfigSHA256Recheck: String?
        var configurationIntegrityOK: Bool = false
        var configurationIntegrityDetail: String?

        /// Layer 1: file-token open(O_WRONLY) + write-mode + inode match (no write performed).
        var writableFdProven: Bool = false
        var writableFdDetail: String?

        /// Dir-token open fails with EPERM on this device class — recorded for logs.
        var dirTokenOpenDenied: Bool = false
        var dirTokenOpenDetail: String?

        var fsOperationLog: [String] = []
        var restrictionVerdict: String?

        var isSupervisedPlistClaim: Bool?
        var organizationName: String?
        var cloudConfigKeys: [String] = []

        var mcProbeAttempted: Bool = false
        var mcProbeSupported: Bool = false
        var mcIsSupervised: Bool?
        var mcProbeError: String?

        /// Concise UI statuses
        var filesystemAccessStatus: String {
            if !badQueryAvailable { return "Unavailable" }
            if !configProfilesDirReachable { return "Blocked" }
            if writableFdProven { return "Writable fd OK" }
            if dirCreateAllowed { return "Dir only" }
            return "Limited"
        }

        var integrityStatus: String {
            if !cloudConfigReadable { return "Unread" }
            return configurationIntegrityOK ? "OK" : "Failed"
        }

        var supervisionEligibilityStatus: String {
            // On-device BadQuery cannot create ADE/Configurator supervision.
            if mcIsSupervised == true { return "Already supervised" }
            return "Requires Apple Configurator (erase)"
        }

        var supervisionStatus: String {
            if let v = mcIsSupervised { return v ? "Supervised (MC)" : "Not supervised" }
            if mcProbeAttempted { return mcProbeSupported ? "Unknown" : "MC unavailable" }
            return "Not checked"
        }

        var delayOTAStatus: String {
            if mcIsSupervised != true { return "Not ready (need supervision)" }
            return "Unknown — needs MDM deferral + Apple signing"
        }

        var summaryLine: String {
            "FS \(filesystemAccessStatus); integrity \(integrityStatus); MC \(supervisionStatus)"
        }
    }

    @Published private(set) var isBusy = false
    @Published private(set) var last = Result()
    @Published var lastError: String?

    private init() {}

    // MARK: - Diagnostics (read-only on live cloud-config)

    func run() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        var result = Result()
        result.ranAt = Date()
        result.osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        result.badQueryAvailable = BadQuery.isAvailable
        var log: [String] = []
        func line(_ s: String) { log.append(s) }

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

        // 2) Sibling create under SystemGroup root (does not touch cloud-config)
        if result.configProfilesDirReachable {
            do {
                let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
                defer { handle.release() }
                let probe = URL(fileURLWithPath: Self.configurationProfilesDir, isDirectory: true)
                    .appendingPathComponent(".km_write_probe")
                try? FileManager.default.removeItem(at: probe)
                try Data([0x4B, 0x4D]).write(to: probe, options: .withoutOverwriting)
                try FileManager.default.removeItem(at: probe)
                result.dirCreateAllowed = true
                line("op=dir-create-probe result=OK")
            } catch {
                result.dirCreateAllowed = false
                result.dirCreateError = describe(error)
                line("op=dir-create-probe result=FAIL \(describe(error))")
            }
        }

        let path = Self.cloudConfigurationPath
        let url = URL(fileURLWithPath: path)

        // 3) Read cloud config + SHA-256 (token held) — no writes
        if result.configProfilesDirReachable {
            do {
                let handle = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
                defer { handle.release() }
                let exists = FileManager.default.fileExists(atPath: path)
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
                    result.cloudConfigFileInfo = Self.fileInfo(at: path)
                    let hash1 = Self.sha256Hex(data)
                    result.cloudConfigSHA256 = hash1
                    line("op=sha256-read#1 token=dir bytes=\(data.count) sha256=\(hash1)")
                } else {
                    result.cloudConfigError = "CloudConfigurationDetails.plist not present."
                }
            } catch {
                result.cloudConfigReadable = false
                if result.cloudConfigError == nil {
                    result.cloudConfigError = describe(error)
                }
                line("op=cloud-config-read result=FAIL \(describe(error))")
            }
        }

        // 4) Integrity: second read under file-token; compare SHA-256 (never write)
        if result.cloudConfigReadable, let hash1 = result.cloudConfigSHA256 {
            do {
                let fileToken = try BadQuery.consume(path: path, create: true)
                defer { fileToken.release() }
                let data2 = try Data(contentsOf: url)
                let hash2 = Self.sha256Hex(data2)
                result.cloudConfigSHA256Recheck = hash2
                line("op=sha256-read#2 token=file bytes=\(data2.count) sha256=\(hash2)")
                if hash1 == hash2 {
                    result.configurationIntegrityOK = true
                    result.configurationIntegrityDetail =
                        "Two token-held reads match (SHA-256 \(hash1.prefix(16))…, \(data2.count) bytes)."
                    line("op=integrity result=OK")
                } else {
                    result.configurationIntegrityOK = false
                    result.configurationIntegrityDetail =
                        "Hash mismatch between reads: \(hash1) vs \(hash2). Not treated as write proof."
                    line("op=integrity result=MISMATCH")
                }
            } catch {
                // Prior false INTEGRITY FAIL: tokenless / failed re-read must not imply corruption.
                result.configurationIntegrityOK = false
                result.configurationIntegrityDetail =
                    "Recheck read failed (\(describe(error))). First hash \(hash1.prefix(16))… retained — " +
                    "this is NOT proof the file was corrupted."
                line("op=integrity result=RECHECK_FAIL \(describe(error))")
            }
        }

        // 5) Writable-fd probe (open only — no write/fsync to live plist)
        if result.cloudConfigReadable {
            // Dir-token open (expected EPERM)
            do {
                let dirToken = try BadQuery.consume(path: Self.configurationProfilesDir, create: true)
                defer { dirToken.release() }
                let openDir = Self.posixOpen(path: path, flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                if let fd = openDir.fd {
                    line("op=open(O_WRONLY)+dir-token result=OK fd=\(fd) (unexpected)")
                    line(Self.inspectFd(fd, expectedPath: path))
                    close(fd)
                    result.dirTokenOpenDenied = false
                } else {
                    result.dirTokenOpenDenied = true
                    result.dirTokenOpenDetail =
                        "errno=\(openDir.errnoValue ?? -1) (\(String(cString: strerror(openDir.errnoValue ?? 0))))"
                    line("op=open(O_WRONLY)+dir-token result=FAIL \(result.dirTokenOpenDetail!)")
                }
            } catch {
                line("op=consume(dir-token) FAIL \(describe(error))")
            }

            // File-token open + identity
            do {
                let fileToken = try BadQuery.consume(path: path, create: true)
                defer { fileToken.release() }
                let open1 = Self.posixOpen(path: path, flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                line(
                    open1.fd.map { "op=open(O_WRONLY)+file-token #1 result=OK fd=\($0)" }
                        ?? "op=open(O_WRONLY)+file-token #1 result=FAIL errno=\(open1.errnoValue ?? -1)"
                )
                if let fd = open1.fd {
                    let insp = Self.inspectFd(fd, expectedPath: path)
                    line(insp)
                    let identity =
                        insp.contains("inode-match=yes") && insp.contains("write-mode=yes")
                    close(fd)

                    let open2 = Self.posixOpen(path: path, flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                    line(
                        open2.fd.map { "op=open(O_WRONLY)+file-token #2 result=OK fd=\($0)" }
                            ?? "op=open(O_WRONLY)+file-token #2 result=FAIL errno=\(open2.errnoValue ?? -1)"
                    )
                    if let fd2 = open2.fd { close(fd2) }

                    result.writableFdProven = identity && open2.fd != nil
                    result.writableFdDetail = identity
                        ? "file-token writable fd; inode+path match; reproducible open (no write performed this run)"
                        : "file-token open OK but identity/write-mode incomplete: \(insp)"
                } else {
                    result.writableFdProven = false
                    result.writableFdDetail =
                        "file-token open failed errno=\(open1.errnoValue ?? -1)"
                }
            } catch {
                result.writableFdProven = false
                result.writableFdDetail = "consume(file-token) failed: \(describe(error))"
                line("op=consume(file-token) FAIL \(describe(error))")
            }

            // Parent-token open (confirm scope)
            do {
                let parentToken = try BadQuery.consume(path: Self.cloudConfigurationParentDir, create: true)
                defer { parentToken.release() }
                let openP = Self.posixOpen(path: path, flags: O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                if let fd = openP.fd {
                    line("op=open(O_WRONLY)+parent-token result=OK fd=\(fd)")
                    line(Self.inspectFd(fd, expectedPath: path))
                    close(fd)
                } else {
                    line("op=open(O_WRONLY)+parent-token result=FAIL errno=\(openP.errnoValue ?? -1)")
                }
            } catch {
                line("op=consume(parent-token) FAIL \(describe(error))")
            }
        }

        line("op=live-plist-write result=SKIPPED (read-only diagnostics; no CloudConfiguration mutation)")

        // 6) MC — only authoritative on-device supervision signal we use
        let mc = Self.probeManagedConfigurationIsSupervised()
        result.mcProbeAttempted = true
        result.mcProbeSupported = mc.supported
        result.mcIsSupervised = mc.value
        result.mcProbeError = mc.error
        line(
            "op=MC.isSupervised supported=\(mc.supported) value=\(mc.value.map(String.init(describing:)) ?? "nil") " +
            (mc.error ?? "")
        )

        // Verdict — layers, no fake write-proven from integrity
        if result.mcIsSupervised == true {
            result.restrictionVerdict =
                "Device already reports supervised via ManagedConfiguration. " +
                "DelayOTA still needs an MDM deferral profile and a still-signed target build."
        } else if result.writableFdProven {
            result.restrictionVerdict =
                "Filesystem: writable fd to CloudConfigurationDetails is available via file-token " +
                "(dir-token open remains EPERM). " +
                "Integrity: \(result.configurationIntegrityOK ? "OK" : result.configurationIntegrityDetail ?? "see log"). " +
                "Genuine Apple supervision is NOT established by rewriting IsSupervised in this plist — " +
                "use Apple Configurator (erases device) or ADE/ABM. " +
                "KetaMine will only report success when MC isSupervised becomes true."
        } else {
            result.restrictionVerdict =
                "Writable fd not proven. Genuine supervision still requires Apple Configurator or ADE. " +
                (result.configurationIntegrityDetail ?? "")
        }

        result.fsOperationLog = log
        last = result
    }

    /// Re-check ManagedConfiguration only (after Configurator / MDM).
    func verifySupervisionStatus() async {
        await run()
    }

    // MARK: - POSIX / hash helpers

    private struct OpenResult {
        var fd: Int32?
        var errnoValue: Int32?
    }

    private static func posixOpen(path: String, flags: Int32, mode: mode_t = 0) -> OpenResult {
        errno = 0
        let fd: Int32
        if (flags & O_CREAT) != 0 {
            fd = open(path, flags, mode)
        } else {
            fd = open(path, flags)
        }
        if fd >= 0 { return OpenResult(fd: fd, errnoValue: nil) }
        return OpenResult(fd: nil, errnoValue: errno)
    }

    private static func inspectFd(_ fd: Int32, expectedPath: String) -> String {
        var parts: [String] = ["op=fd-inspect fd=\(fd)"]
        let flags = fcntl(fd, F_GETFL)
        if flags == -1 {
            parts.append("F_GETFL errno=\(errno)")
        } else {
            let acc = flags & O_ACCMODE
            let writable = acc == O_WRONLY || acc == O_RDWR
            parts.append("F_GETFL=\(flags)")
            parts.append("write-mode=\(writable ? "yes" : "no")")
        }
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(fd, F_GETPATH, &pathBuf) == 0 {
            let got = String(cString: pathBuf)
            let match =
                got == expectedPath
                || got == "/private\(expectedPath)"
                || expectedPath == "/private\(got)"
            parts.append("F_GETPATH=\(got)")
            parts.append("path-match=\(match ? "yes" : "no")")
        } else {
            parts.append("F_GETPATH errno=\(errno)")
        }
        var stFd = stat()
        var stPath = stat()
        if fstat(fd, &stFd) == 0, lstat(expectedPath, &stPath) == 0 {
            let match = stFd.st_ino == stPath.st_ino && stFd.st_dev == stPath.st_dev
            parts.append("inode-match=\(match ? "yes" : "no")")
            parts.append("fd-ino=\(stFd.st_ino) path-ino=\(stPath.st_ino)")
        } else {
            parts.append("fstat/lstat failed")
        }
        return parts.joined(separator: " ")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileInfo(at path: String) -> String {
        var st = stat()
        guard lstat(path, &st) == 0 else { return "lstat errno=\(errno)" }
        var parts: [String] = [
            String(format: "mode=%o", st.st_mode & 0o7777),
            "uid=\(st.st_uid) gid=\(st.st_gid)",
            "size=\(st.st_size)",
            String(format: "flags=0x%x", st.st_flags)
        ]
        parts.append("access(R)=\(access(path, R_OK) == 0) access(W)=\(access(path, W_OK) == 0)")
        return parts.joined(separator: " ")
    }

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
        guard connection.responds(to: supervisedSel),
              let method = class_getInstanceMethod(type(of: connection), supervisedSel) else {
            return (false, nil, "isSupervised selector missing.")
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
