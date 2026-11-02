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

        let report = try await ArchiveService().execute(
            source: source, destinationRoot: destination, projectName: "Trip",
            groups: [kept, rejected], progress: { _ in }
        )

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

        let report = try await ArchiveService().execute(
            source: source, destinationRoot: destination, projectName: "Selection",
            groups: [selected, rejected], progress: { _ in }
        )

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
            _ = try await ArchiveService().execute(
                source: source, destinationRoot: destination, projectName: "Trip",
                groups: [kept], progress: { _ in }
            )
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
            _ = try await ArchiveService().execute(
                source: source, destinationRoot: destination, projectName: "Conflict",
                groups: [group], progress: { _ in }
            )
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
            _ = try await ArchiveService(interruptionAfterCompletedGroups: 1).execute(
                source: source, destinationRoot: destination, projectName: "Recoverable",
                groups: [first, second], progress: { _ in }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("FIRST.JPG").path))

        let report = try await ArchiveService().execute(
            source: source, destinationRoot: destination, projectName: "Recoverable",
            groups: [first, second], progress: { _ in }
        )
        #expect(report.succeededCount == 2)
        #expect(FileManager.default.fileExists(atPath: final.appendingPathComponent("FIRST.JPG").path))
        #expect(FileManager.default.fileExists(atPath: final.appendingPathComponent("SECOND.JPG").path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
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
}
