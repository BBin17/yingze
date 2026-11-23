import Foundation
import Testing
@testable import CameraCull

@Suite("安装并重启")
struct UpdateInstallerTests {
    @Test("启动程序时，正式路径已经是新版，旧版仍可回退")
    @MainActor
    func installsBeforeLaunchingNewApp() async throws {
        let update = try fixture()
        defer { try? FileManager.default.removeItem(at: update.target.deletingLastPathComponent()) }

        try await AppUpdateInstaller.replaceAndRelaunch(update) { launched in
            #expect(launched == update.target)
            let installed = try version(at: launched)
            let backup = try version(at: update.stagedApp)
            #expect(installed == "new")
            #expect(backup == "old")
        }
        #expect(try version(at: update.target) == "new")
    }

    @Test("新版启动失败时正式路径恢复旧版")
    @MainActor
    func rollsBackWhenRelaunchFails() async throws {
        let update = try fixture()
        defer { try? FileManager.default.removeItem(at: update.target.deletingLastPathComponent()) }

        await #expect(throws: UpdateInstallError.self) {
            try await AppUpdateInstaller.replaceAndRelaunch(update) { _ in
                throw UpdateInstallError.launchFailed
            }
        }
        #expect(try version(at: update.target) == "old")
        #expect(try version(at: update.stagedApp) == "new")
    }

    @Test("无法确认新版已启动时保留旧版备份")
    @MainActor
    func keepsBackupWhenLaunchIsUnconfirmed() async throws {
        let update = try fixture()
        defer { try? FileManager.default.removeItem(at: update.target.deletingLastPathComponent()) }

        await #expect(throws: UpdateInstallError.self) {
            try await AppUpdateInstaller.replaceAndRelaunch(update) { _ in
                throw UpdateInstallError.launchUnconfirmed(update.stagedApp)
            }
        }
        #expect(try version(at: update.target) == "new")
        #expect(try version(at: update.stagedApp) == "old")
    }

    @Test("核对正在运行的签名时允许路径变化，并拒绝其他程序")
    func matchesRunningCodeAtDifferentPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = URL(fileURLWithPath: "/bin/sleep")
        let copy = root.appendingPathComponent(executable.lastPathComponent)
        try FileManager.default.copyItem(at: executable, to: copy)
        let expected = try AppCodeIdentity(at: copy)
        let other = try AppCodeIdentity(at: URL(fileURLWithPath: "/bin/ls"))

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(expected.matches(processID: process.processIdentifier))
        #expect(!other.matches(processID: process.processIdentifier))
    }

    @Test("更新重启前立即写入尚未自动保存的评分")
    @MainActor
    func savesPendingProjectChangesBeforeRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let photo = PhotoGroup(
            id: "photo", baseName: "PHOTO", jpegURL: source.appendingPathComponent("PHOTO.JPG"),
            rawURL: nil, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil
        )
        let legacy = CullSession(
            sourceURL: source, destinationURL: nil, projectName: "Restart",
            groups: [photo], selectedGroupID: photo.id, updatedAt: .now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: root.appendingPathComponent("CurrentSession.json"))
        let store = SessionStore(storageDirectory: root)
        store.setRating(5)

        try store.saveForUpdateRestart()
        let reopened = SessionStore(storageDirectory: root)
        #expect(reopened.selectedGroup?.rating == 5)
    }

    @Test("正在扫描时不会进入更新退出流程")
    @MainActor
    func busyProjectRefusesToRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = SessionStore(storageDirectory: root.appendingPathComponent("storage", isDirectory: true))
        store.openSource(source, projectName: "正在扫描")
        #expect(!store.canRestartForUpdate)
        #expect(throws: UpdateInstallError.self) { try store.saveForUpdateRestart() }
        store.showProjectHome()
        // Changing projects cancels the scan, so no delayed save can recreate the test fixture.
        store.removeProject(try #require(store.currentProjectID))
    }

    private func fixture() throws -> AppUpdateInstaller.PreparedUpdate {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let update = AppUpdateInstaller.PreparedUpdate(
            target: root.appendingPathComponent("影择.app", isDirectory: true),
            directory: root.appendingPathComponent("staging", isDirectory: true),
            version: "v0.25.2"
        )
        for (url, version) in [(update.target, "old"), (update.stagedApp, "new")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(version.utf8).write(to: url.appendingPathComponent("version"))
        }
        return update
    }

    private func version(at app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8)
    }
}
