import AppKit
import Darwin
import Foundation
import Security

enum UpdateInstallError: LocalizedError {
    case projectBusy
    case unsupportedLocation
    case invalidBundle
    case unsupportedSystem(String)
    case toolFailed(String)
    case applicationStillRunning
    case launchFailed
    case launchUnconfirmed(URL)
    case rollbackFailed(URL)

    var errorDescription: String? {
        switch self {
        case .projectBusy: "请等当前项目扫描或导出完成后再安装。"
        case .unsupportedLocation: "无法更新当前安装位置。可以打开安装包，在「应用程序」中手动安装。"
        case .invalidBundle: "安装包中的应用身份、架构或版本与此次更新不符。"
        case .unsupportedSystem(let version): "新版需要 macOS \(version) 或更高版本。"
        case .toolFailed(let operation): "无法\(operation)。可以打开安装包手动安装。"
        case .applicationStillRunning: "影择尚未完全退出，更新未替换应用。"
        case .launchFailed: "macOS 未能启动新版影择。"
        case .launchUnconfirmed(let backup): "暂时无法确认新版已启动。旧版暂存于：\(backup.path)"
        case .rollbackFailed(let backup): "无法自动恢复旧版。旧版暂存于：\(backup.path)"
        }
    }
}

struct AppUpdateInstaller {
    static let helperArgument = "--apply-app-update"
    private static let installationPathArgument = "--update-installation-path"
    private static let stagingPrefix = ".yingze-update-"

    struct PreparedUpdate: Sendable {
        let target: URL
        let directory: URL
        let version: String

        var stagedApp: URL { directory.appendingPathComponent(target.lastPathComponent, isDirectory: true) }

        func discard() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func prepare(
        diskImage: URL, update: AvailableUpdate, installed: Bundle? = nil
    ) throws -> PreparedUpdate {
        guard let package = update.package else { throw AppUpdateError.invalidDownload }
        try AppUpdateService.verify(diskImage, package: package)
        let installed = try installed ?? installationBundle()
        let target = installed.bundleURL.resolvingSymlinksInPath()
        let parent = target.deletingLastPathComponent()
        let manager = FileManager.default
        guard target.pathExtension.lowercased() == "app", installed.executableURL != nil,
              manager.isWritableFile(atPath: parent.path),
              let current = installed.infoDictionary?["CFBundleShortVersionString"] as? String,
              AppUpdateService.isNewer(update.version, than: current)
        else { throw UpdateInstallError.unsupportedLocation }

        let directory = parent.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        let prepared = PreparedUpdate(target: target, directory: directory, version: update.version)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw UpdateInstallError.unsupportedLocation
        }

        do {
            let mount = manager.temporaryDirectory.appendingPathComponent("YingzeMount-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { _ = rmdir(mount.path) }
            try run("/usr/bin/hdiutil", ["attach", diskImage.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path], operation: "打开安装包")
            defer { try? run("/usr/bin/hdiutil", ["detach", mount.path], operation: "退出安装盘") }

            let candidate = mount.appendingPathComponent("影择.app", isDirectory: true)
            try validate(candidate: candidate, bundleID: installed.bundleIdentifier, version: update.version)
            try run("/usr/bin/ditto", [candidate.path, prepared.stagedApp.path], operation: "复制新版应用")
            // Apply the download's quarantine information to the staged app so Launch Services
            // handles any Gatekeeper confirmation exactly as it would for a downloaded app.
            if let quarantine = try (diskImage as NSURL).resourceValues(forKeys: [.quarantinePropertiesKey])[.quarantinePropertiesKey] {
                try (prepared.stagedApp as NSURL).setResourceValue(quarantine, forKey: .quarantinePropertiesKey)
            }
            try validate(candidate: prepared.stagedApp, bundleID: installed.bundleIdentifier, version: update.version)
            return prepared
        } catch {
            prepared.discard()
            throw error
        }
    }

    static func validate(candidate: URL, bundleID: String?, version: String) throws {
        let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let bundleID, let bundle = Bundle(url: candidate), bundle.bundleIdentifier == bundleID,
              let versionString = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              let expected = AppUpdateService.versionComponents(version),
              AppUpdateService.versionComponents(versionString) == expected,
              bundle.executableArchitectures?.contains(NSNumber(value: CPU_TYPE_ARM64)) == true
        else { throw UpdateInstallError.invalidBundle }

        if let required = bundle.infoDictionary?["LSMinimumSystemVersion"] as? String,
           let components = AppUpdateService.versionComponents(required),
           !ProcessInfo.processInfo.isOperatingSystemAtLeast(
               OperatingSystemVersion(majorVersion: components[0], minorVersion: components[1], patchVersion: components[2])
           ) {
            throw UpdateInstallError.unsupportedSystem(required)
        }
        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", candidate.path], operation: "验证新版应用签名")
    }

    static func startHelper(_ prepared: PreparedUpdate) throws {
        guard let executable = Bundle(url: prepared.target)?.executableURL else {
            throw UpdateInstallError.unsupportedLocation
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [helperArgument, prepared.directory.path, prepared.version, String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @MainActor
    static func runHelper(arguments: [String]) async -> Int32 {
        guard arguments.count == 5, let parentPID = pid_t(arguments[4]), parentPID > 1 else { return 1 }
        let installed = Bundle.main
        let target = installed.bundleURL.resolvingSymlinksInPath()
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true).resolvingSymlinksInPath()
        let name = directory.lastPathComponent
        guard directory.deletingLastPathComponent().path == target.deletingLastPathComponent().path,
              name.hasPrefix(stagingPrefix),
              UUID(uuidString: String(name.dropFirst(stagingPrefix.count))) != nil
        else { return 1 }

        let prepared = PreparedUpdate(target: target, directory: directory, version: arguments[3])
        var originalHasExited = false
        do {
            try await waitForExit(of: parentPID)
            originalHasExited = true
            guard let current = installed.infoDictionary?["CFBundleShortVersionString"] as? String,
                  AppUpdateService.isNewer(prepared.version, than: current)
            else { throw UpdateInstallError.invalidBundle }
            try validate(candidate: prepared.stagedApp, bundleID: installed.bundleIdentifier, version: prepared.version)
            guard !isRunning(at: target, bundleID: installed.bundleIdentifier) else {
                throw UpdateInstallError.applicationStillRunning
            }
            try await replaceAndRelaunch(prepared) { url in
                try await launch(url, backup: prepared.stagedApp)
            }
            prepared.discard()
            return 0
        } catch UpdateInstallError.launchUnconfirmed(let backup) {
            showNotice("更新状态待确认", message: UpdateInstallError.launchUnconfirmed(backup).localizedDescription)
        } catch UpdateInstallError.rollbackFailed(let backup) {
            showNotice("更新未完成", message: UpdateInstallError.rollbackFailed(backup).localizedDescription)
        } catch {
            prepared.discard()
            if originalHasExited, !isRunning(at: target, bundleID: installed.bundleIdentifier) {
                try? await launch(target, backup: target)
            }
            showNotice("更新未完成", message: "\(error.localizedDescription)\n可从 GitHub 发布页下载 DMG 手动安装。")
        }
        return 1
    }

    @MainActor
    static func replaceAndRelaunch(
        _ prepared: PreparedUpdate, launch: (URL) async throws -> Void
    ) async throws {
        try swap(prepared.target, prepared.stagedApp)
        do {
            try await launch(prepared.target)
        } catch UpdateInstallError.launchUnconfirmed(let backup) {
            throw UpdateInstallError.launchUnconfirmed(backup)
        } catch {
            do {
                try swap(prepared.target, prepared.stagedApp)
            } catch {
                throw UpdateInstallError.rollbackFailed(prepared.stagedApp)
            }
            throw error
        }
    }

    private static func swap(_ target: URL, _ staged: URL) throws {
        guard renameatx_np(AT_FDCWD, target.path, AT_FDCWD, staged.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func waitForExit(of pid: pid_t) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if kill(pid, 0) == -1, errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw UpdateInstallError.applicationStillRunning
    }

    private static func installationBundle() throws -> Bundle {
        let running = Bundle.main
        guard try running.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true else {
            return running
        }

        // Launch Services may run the app from a read-only location. Use the path
        // supplied by the updater only if it contains the same signed code.
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == installationPathArgument,
              arguments[2].hasPrefix("/"),
              let installed = Bundle(url: URL(fileURLWithPath: arguments[2], isDirectory: true)),
              installed.bundleIdentifier == running.bundleIdentifier,
              let identity = try? AppCodeIdentity(at: installed.bundleURL),
              identity.matches(processID: getpid())
        else { throw UpdateInstallError.unsupportedLocation }
        return installed
    }

    @MainActor
    private static func isRunning(at target: URL, bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let identity = try? AppCodeIdentity(at: target)
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
            guard !$0.isTerminated, $0.processIdentifier != getpid(), let url = $0.bundleURL else {
                return false
            }
            if url.resolvingSymlinksInPath().path == target.path { return true }
            return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true &&
                identity?.matches(processID: $0.processIdentifier) == true
        }
    }

    @MainActor
    private static func launch(_ url: URL, backup: URL) async throws {
        let identity = try AppCodeIdentity(at: url)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.promptsUserIfNeeded = true
        configuration.arguments = [installationPathArgument, url.path]
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)

        let deadline = ContinuousClock.now + .seconds(10)
        while !app.isTerminated && !app.isFinishedLaunching && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !app.isTerminated else { throw UpdateInstallError.launchFailed }
        // Gatekeeper can launch the new process from a different bundle URL.
        // A live process with an unconfirmed identity must not trigger a second launch.
        guard app.isFinishedLaunching, identity.matches(processID: app.processIdentifier) else {
            if app.isTerminated { throw UpdateInstallError.launchFailed }
            throw UpdateInstallError.launchUnconfirmed(backup)
        }
    }

    @MainActor
    private static func showNotice(_ title: String, message: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        app.activate()
        alert.runModal()
    }

    private static func run(_ path: String, _ arguments: [String], operation: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateInstallError.toolFailed(operation) }
    }
}

struct AppCodeIdentity {
    private let requirement: SecRequirement

    init(at url: URL) throws {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { throw UpdateInstallError.invalidBundle }

        let hex = hash.map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        let expression = "cdhash H\"\(hex)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { throw UpdateInstallError.invalidBundle }
        self.requirement = requirement
    }

    func matches(processID: pid_t) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: processID] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
