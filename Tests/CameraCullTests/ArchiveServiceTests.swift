import Foundation
import Testing
@testable import CameraCull

@Suite("导出事务")
struct ArchiveServiceTests {
    @Test("复制全部可用照片并保持来源文件夹不变")
    func copiesAvailableGroupsWritesXMPAndLeavesSourceUntouched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let kept = try makeGroup(name: "KEEP", in: source, state: .undecided, rating: 3, color: .yellow)
        let rejected = try makeGroup(name: "REJECT", in: source, state: .reject)

        let report = try await ArchiveService().execute(ArchiveRequest(
            source: source, destinationRoot: destination, projectName: "Trip",
            groups: [kept, rejected]
        ), progress: { _ in })

        let project = destination.appendingPathComponent("Trip")
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("KEEP.JPG").path))
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("KEEP.HEIC").path))
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("KEEP.ARW").path))
        let xmp = try String(contentsOf: project.appendingPathComponent("KEEP.xmp"), encoding: .utf8)
        #expect(xmp.contains("xmp:Rating=\"3\""))
        #expect(xmp.contains("xmp:Label=\"Yellow\""))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("KEEP.JPG").path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("KEEP.HEIC").path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("KEEP.ARW").path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("REJECT.JPG").path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("REJECT.HEIC").path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("REJECT.ARW").path))
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("_Rejected").path))
        #expect(report.succeededCount == 1)
    }

    @Test("筛选或手动导出只复制范围且不移动废片")
    func scopedArchiveNeverMovesRejectedFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let selected = try makeGroup(name: "SELECTED", in: source, state: .undecided)
        let rejected = try makeGroup(name: "REJECT", in: source, state: .reject)

        let report = try await ArchiveService().execute(ArchiveRequest(
            source: source, destinationRoot: destination, projectName: "Selection",
            groups: [selected, rejected]
        ), progress: { _ in })

        let project = destination.appendingPathComponent("Selection")
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("SELECTED.JPG").path))
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("REJECT.JPG").path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("SELECTED.JPG").path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("REJECT.JPG").path))
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("_Rejected").path))
        #expect(report.succeededCount == 1)
    }

    @Test("项目目录冲突时复制前停止")
    func existingProjectStopsBeforeCopying() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("Trip"), withIntermediateDirectories: true)
        let kept = try makeGroup(name: "KEEP", in: source, state: .undecided)

        await #expect(throws: ArchiveError.self) {
            _ = try await ArchiveService().execute(ArchiveRequest(
                source: source, destinationRoot: destination, projectName: "Trip",
                groups: [kept]
            ), progress: { _ in })
        }
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("KEEP.JPG").path))
    }

    @Test("配对冲突会在复制前停止")
    func pairingConflictStopsBeforeCopying() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var group = try makeGroup(name: "CONFLICT", in: source, state: .undecided)
        group.pairingConflicts = ["RAW：CONFLICT.ARW、CONFLICT.SRF"]

        await #expect(throws: ArchiveError.self) {
            _ = try await ArchiveService().execute(ArchiveRequest(
                source: source, destinationRoot: destination, projectName: "Conflict",
                groups: [group]
            ), progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Conflict").path))
    }

    @Test("导出中断后从暂存状态继续并原子完成项目")
    func resumesInterruptedExport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let first = try makeGroup(name: "FIRST", in: source, state: .undecided)
        let second = try makeGroup(name: "SECOND", in: source, state: .undecided)
        let final = destination.appendingPathComponent("Recoverable")
        let staging = destination.appendingPathComponent(".Recoverable.影择导出中")

        await #expect(throws: CancellationError.self) {
            _ = try await ArchiveService(interruptionAfterCompletedGroups: 1).execute(ArchiveRequest(
                source: source, destinationRoot: destination, projectName: "Recoverable",
                groups: [first, second]
            ), progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("FIRST.JPG").path))

        let report = try await ArchiveService().execute(ArchiveRequest(
            source: source, destinationRoot: destination, projectName: "Recoverable",
            groups: [first, second]
        ), progress: { _ in })
        #expect(report.succeededCount == 2)
        #expect(FileManager.default.fileExists(atPath: final.appendingPathComponent("FIRST.JPG").path))
        #expect(FileManager.default.fileExists(atPath: final.appendingPathComponent("SECOND.JPG").path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("保留子目录时可以导出跨目录同名照片及 XMP")
    func exportsSameNamesIntoTheirSourceSubdirectories() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try directory("source/day 1/card A", under: root)
        let second = try directory("source/day 2", under: root)
        let destination = try directory("destination", under: root)
        var a = try makeGroup(name: "IMG", in: first, state: .keep, rating: 4, color: .blue)
        a.id = "day1/img"
        var b = try makeGroup(name: "IMG", in: second, state: .keep, rating: 2, color: .red)
        b.id = "day2/img"
        try Data("different photo".utf8).write(to: try #require(b.jpegURL))
        var request = ArchiveRequest(
            source: root.appendingPathComponent("source"), destinationRoot: destination,
            projectName: "Trip", groups: [a, b]
        )

        await #expect(throws: ArchiveError.self) {
            _ = try await ArchiveService().execute(request) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: request.stagingURL.path))

        request.preservesSubdirectories = true
        let report = try await ArchiveService().execute(request) { _ in }
        #expect(report.isComplete)
        let outputA = request.projectURL.appendingPathComponent("day 1/card A")
        let outputB = request.projectURL.appendingPathComponent("day 2")
        #expect(try Data(contentsOf: outputA.appendingPathComponent("IMG.JPG")) == Data("jpeg-IMG".utf8))
        #expect(try Data(contentsOf: outputB.appendingPathComponent("IMG.JPG")) == Data("different photo".utf8))
        #expect(XMPReader().metadata(at: outputA.appendingPathComponent("IMG.xmp"))?.rating == 4)
        #expect(XMPReader().metadata(at: outputB.appendingPathComponent("IMG.xmp"))?.colorLabel == .red)
        #expect(!FileManager.default.fileExists(atPath: request.projectURL.appendingPathComponent("IMG.JPG").path))
    }

    @Test("失败报告逐个列出文件和原因，重试复用已校验的子目录文件")
    func reportsIndividualFailuresAndResumesNestedExport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory("source", under: root)
        let firstFolder = try directory("first", under: source)
        let secondFolder = try directory("second", under: source)
        let destination = try directory("destination", under: root)
        let first = try makeGroup(name: "A", in: firstFolder, state: .keep)
        var second = try makeGroup(name: "B", in: secondFolder, state: .keep)
        let missingJPEG = try #require(second.jpegURL)
        let missingRAW = try #require(second.rawURL)
        let xmp = secondFolder.appendingPathComponent("B.xmp")
        second.xmpURL = xmp
        try FileManager.default.removeItem(at: missingJPEG)
        try FileManager.default.removeItem(at: missingRAW)
        try Data("broken XML".utf8).write(to: xmp)
        let request = ArchiveRequest(
            source: source, destinationRoot: destination, projectName: "Trip",
            groups: [first, second], preservesSubdirectories: true
        )

        let firstReport = try await ArchiveService().execute(request) { _ in }
        #expect(!firstReport.isComplete)
        #expect(firstReport.succeededCount == 1)
        #expect(firstReport.failedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: request.projectURL.path))
        let failures = try #require(firstReport.outcomes.first { !$0.succeeded }).failures
        #expect(failures.map(\.path) == ["second/B.JPG", "second/B.ARW", "second/B.xmp"])
        #expect(failures.allSatisfy { !$0.reason.isEmpty })
        #expect(failures.last?.reason.contains("现有 XMP 无法解析") == true)
        let failureLog = try String(contentsOf: try #require(firstReport.logURL), encoding: .utf8)
        #expect(failureLog.contains("[失败] second/B.ARW"))
        #expect(!FileManager.default.fileExists(atPath: request.stagingURL.appendingPathComponent("second/B.HEIC").path))

        var changedLayout = request
        changedLayout.preservesSubdirectories = false
        await #expect(throws: ArchiveError.self) {
            _ = try await ArchiveService().execute(changedLayout) { _ in }
        }
        try Data("restored jpg".utf8).write(to: missingJPEG)
        try Data("restored raw".utf8).write(to: missingRAW)
        let originalXMP = try XMPWriter().data(existingURL: nil, rating: 1, label: .none)
        try originalXMP.write(to: xmp)

        let result = try await ArchiveService().execute(request) { _ in }
        #expect(result.isComplete)
        #expect(result.succeededCount == 2)
        #expect(try Data(contentsOf: xmp) == originalXMP)
        #expect(try Data(contentsOf: request.projectURL.appendingPathComponent("second/B.ARW")) == Data("restored raw".utf8))
        let finalLog = try String(contentsOf: try #require(result.logURL), encoding: .utf8)
        #expect(finalLog.contains("[已验证，继续] first/A"))
        #expect(!FileManager.default.fileExists(atPath: request.stagingURL.path))
    }

    @Test("模拟 NAS 在复制途中断开，保留失败明细，连接恢复后继续")
    func resumesAfterDestinationDisappearsDuringCopy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory("source", under: root)
        let destination = try directory("destination", under: root)
        let disconnected = root.appendingPathComponent("disconnected")
        let groups = try ["A", "B", "C"].map { try makeGroup(name: $0, in: source, state: .keep) }
        let request = ArchiveRequest(source: source, destinationRoot: destination, projectName: "Trip", groups: groups)
        let interrupted = try await ArchiveService().execute(request) { progress in
            guard progress.contains("2/3：") else { return }
            do {
                try FileManager.default.moveItem(at: destination, to: disconnected)
            } catch {
                Issue.record("无法模拟目标磁盘断开：\(error)")
            }
        }
        #expect(!interrupted.isComplete)
        #expect(interrupted.succeededCount == 1)
        #expect(interrupted.failedCount == 1)
        #expect(interrupted.outcomes.last?.failures.map(\.path) == ["B.JPG", "B.HEIC", "B.ARW", "B.xmp"])
        #expect(interrupted.outcomes.count == 2)
        #expect(interrupted.issue?.contains("NAS") == true)
        #expect(interrupted.logURL == nil)

        await #expect(throws: ArchiveError.self) {
            _ = try await ArchiveService().execute(request) { _ in }
        }
        try FileManager.default.moveItem(at: disconnected, to: destination)
        let resumed = try await ArchiveService().execute(request) { _ in }
        #expect(resumed.isComplete)
        #expect(resumed.succeededCount == 3)
        let log = try String(contentsOf: try #require(resumed.logURL), encoding: .utf8)
        #expect(log.contains("[已验证，继续] A"))
    }

    @Test("继续导出可读取旧版本的平铺暂存记录")
    func resumesVersionOneExportManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory("source", under: root)
        let destination = try directory("destination", under: root)
        let group = try makeGroup(name: "A", in: source, state: .keep)
        let request = ArchiveRequest(source: source, destinationRoot: destination, projectName: "Trip", groups: [group])
        await #expect(throws: CancellationError.self) {
            _ = try await ArchiveService(interruptionAfterCompletedGroups: 1).execute(request) { _ in }
        }
        let manifest = request.stagingURL.appendingPathComponent(".影择-导出状态.json")
        let oldRecord: [String: Any] = [
            "version": 1, "sourcePath": source.standardizedFileURL.path, "projectName": "Trip",
            "plannedGroupIDs": [group.id], "completedGroupIDs": [group.id]
        ]
        try JSONSerialization.data(withJSONObject: oldRecord).write(to: manifest)
        let oldScratch = ".cull-stage-\(UUID().uuidString)"
        let unfinished = try directory(oldScratch, under: request.stagingURL)
        try Data("partial".utf8).write(to: unfinished.appendingPathComponent("A.JPG"))

        let result = try await ArchiveService().execute(request) { _ in }
        #expect(result.isComplete)
        #expect(!FileManager.default.fileExists(atPath: request.projectURL.appendingPathComponent(oldScratch).path))
        let log = try String(contentsOf: try #require(result.logURL), encoding: .utf8)
        #expect(log.contains("[已验证，继续] A"))
    }

    @Test("重新打开影择后，继续导出使用原来的范围与目录设置")
    @MainActor
    func resumesOriginalRequestAfterReopeningSession() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory("source", under: root)
        let folder = try directory("cards/one", under: source)
        let destination = try directory("destination", under: root)
        let storage = try directory("storage", under: root)
        let group = try makeGroup(name: "A", in: folder, state: .keep, rating: 4)
        let legacy = CullSession(
            sourceURL: source, destinationURL: destination, projectName: "Trip", groups: [group],
            selectedGroupID: group.id, updatedAt: .now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: storage.appendingPathComponent("CurrentSession.json"))
        let store = SessionStore(storageDirectory: storage)
        let image = try #require(group.jpegURL)
        try FileManager.default.removeItem(at: image)

        await store.archive(scope: .picks, folderName: "Trip", preservesSubdirectories: true)
        #expect(store.archiveReport?.isComplete == false)
        #expect(store.archiveReport?.outcomes.first?.failures.first?.path == "cards/one/A.JPG")
        let previous = try #require(store.archiveReport)
        let disconnected = root.appendingPathComponent("disconnected")
        try FileManager.default.moveItem(at: destination, to: disconnected)
        await store.resumeArchive(previousReport: previous)
        #expect(store.archiveReport?.outcomes.first?.failures.first?.path == "cards/one/A.JPG")
        #expect(store.archiveReport?.issue?.contains("NAS") == true)
        try FileManager.default.moveItem(at: disconnected, to: destination)

        await store.archive(scope: .picks, folderName: "Trip", preservesSubdirectories: false)
        #expect(store.archiveReport?.issue?.contains("目录布局") == true)
        #expect(store.session.pendingArchive?.preservesSubdirectories == true)
        store.setRating(1)
        store.setPickState(.reject)
        store.showProjectHome()

        let reopened = SessionStore(storageDirectory: storage)
        let original = try #require(reopened.session.pendingArchive)
        #expect(original.preservesSubdirectories)
        #expect(original.groups.first?.rating == 4)
        #expect(reopened.groups.first?.pickState == .reject)
        try Data("restored".utf8).write(to: image)
        await reopened.resumeArchive()
        #expect(reopened.archiveReport?.isComplete == true)
        #expect(reopened.session.pendingArchive == nil)
        #expect(SessionStore(storageDirectory: storage).session.pendingArchive == nil)
        #expect(XMPReader().metadata(at: original.projectURL.appendingPathComponent("cards/one/A.xmp"))?.rating == 4)
    }

    @Test("校验读取出错时不能当成文件结束")
    func digestPropagatesReadFailures() throws {
        enum SimulatedReadError: Error { case failed }
        var reads = 0
        #expect(throws: SimulatedReadError.self) {
            _ = try ArchiveService.digestChunks {
                reads += 1
                if reads == 1 { return Data("partial".utf8) }
                throw SimulatedReadError.failed
            }
        }
    }

    private func makeGroup(name: String, in directory: URL, state: PickState, rating: Int = 0, color: ColorLabel = .none) throws -> PhotoGroup {
        let jpg = directory.appendingPathComponent("\(name).JPG")
        let heic = directory.appendingPathComponent("\(name).HEIC")
        let raw = directory.appendingPathComponent("\(name).ARW")
        try Data("jpeg-\(name)".utf8).write(to: jpg)
        try Data("heic-\(name)".utf8).write(to: heic)
        try Data("raw-\(name)".utf8).write(to: raw)
        return PhotoGroup(id: name.lowercased(), baseName: name, jpegURL: jpg, heicURL: heic, rawURL: raw, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil, rating: rating, colorLabel: color, pickState: state)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCullArchive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func directory(_ name: String, under root: URL) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
