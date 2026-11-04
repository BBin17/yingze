import CryptoKit
import Foundation

struct ArchiveOutcome: Sendable, Identifiable {
    var id: String { groupID }
    let groupID: String
    let baseName: String
    let succeeded: Bool
    let error: String?
}

struct ArchiveReport: Sendable, Identifiable {
    var id: URL { projectURL }
    let projectURL: URL
    let logURL: URL
    let outcomes: [ArchiveOutcome]

    var succeededCount: Int { outcomes.filter(\.succeeded).count }
    var failedCount: Int { outcomes.filter { !$0.succeeded }.count }
}

enum ArchiveError: LocalizedError {
    case noAvailablePhotos
    case targetExists(URL)
    case conflicts([String])
    case pairingConflicts([String])
    case insufficientSpace(required: Int64, available: Int64)
    case destinationNotWritable(URL)
    case verificationFailed(String)
    case resumeConflict(URL)
    case incomplete(URL, Int)

    var errorDescription: String? {
        switch self {
        case .noAvailablePhotos: "没有可导出的照片；当前照片都在废片区。"
        case .targetExists(let url): "导出文件夹已存在：\(url.path)"
        case .conflicts(let names): "目标存在同名文件：\(names.prefix(8).joined(separator: "、"))"
        case .pairingConflicts(let names): "以下照片组存在重复配对，解决冲突后才能导出：\(names.prefix(8).joined(separator: "、"))"
        case .insufficientSpace(let required, let available): "目标空间不足，需要 \(required) 字节，可用 \(available) 字节。"
        case .destinationNotWritable(let url): "目标目录不可写：\(url.path)"
        case .verificationFailed(let name): "文件校验失败：\(name)"
        case .resumeConflict(let url): "发现不匹配的导出恢复数据：\(url.path)。请移走这个隐藏暂存目录后重试。"
        case .incomplete(let url, let count): "有 \(count) 组照片导出失败。已保留可恢复数据：\(url.path)，修复问题后再次导出即可继续。"
        }
    }
}

actor ArchiveService {
    private struct ExportManifest: Codable {
        var version = 1
        var sourcePath: String
        var projectName: String
        var plannedGroupIDs: [String]
        var completedGroupIDs: Set<String>
    }

    private let fileManager = FileManager.default
    private let xmpWriter = XMPWriter()
    private let interruptionAfterCompletedGroups: Int?

    init(interruptionAfterCompletedGroups: Int? = nil) {
        self.interruptionAfterCompletedGroups = interruptionAfterCompletedGroups
    }

    func execute(
        source: URL,
        destinationRoot: URL,
        projectName: String,
        groups: [PhotoGroup],
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> ArchiveReport {
        let available = groups.filter { !$0.pickState.isRejected }
        guard !available.isEmpty else { throw ArchiveError.noAvailablePhotos }
        let projectURL = destinationRoot.appendingPathComponent(projectName, isDirectory: true)
        let stagingURL = destinationRoot.appendingPathComponent(".\(projectName).影择导出中", isDirectory: true)
        try preflight(projectURL: projectURL, destinationRoot: destinationRoot, available: available)
        var manifest = try prepareManifest(
            at: stagingURL,
            source: source,
            projectName: projectName,
            available: available
        )

        var outcomes: [ArchiveOutcome] = []
        var logLines = [
            "影择 导出日志",
            "导出文件夹：\(projectName)",
            "来源：\(source.path)",
            "目标：\(projectURL.path)",
            "开始：\(ISO8601DateFormatter().string(from: .now))",
            ""
        ]

        for (index, group) in available.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress("正在复制 \(index + 1)/\(available.count)：\(group.baseName)")
            if manifest.completedGroupIDs.contains(group.id),
               (try? completedGroupMatches(group, in: stagingURL)) == true {
                outcomes.append(ArchiveOutcome(groupID: group.id, baseName: group.baseName, succeeded: true, error: nil))
                logLines.append("[已验证，继续] \(group.baseName)")
                continue
            }
            do {
                try removeOutputs(for: group, from: stagingURL)
                try copyGroup(group, to: stagingURL)
                manifest.completedGroupIDs.insert(group.id)
                try writeManifest(manifest, at: stagingURL)
                outcomes.append(ArchiveOutcome(groupID: group.id, baseName: group.baseName, succeeded: true, error: nil))
                logLines.append("[成功] \(group.baseName)")
                if let interruptionAfterCompletedGroups,
                   manifest.completedGroupIDs.count >= interruptionAfterCompletedGroups {
                    throw CancellationError()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                manifest.completedGroupIDs.remove(group.id)
                try? writeManifest(manifest, at: stagingURL)
                outcomes.append(ArchiveOutcome(groupID: group.id, baseName: group.baseName, succeeded: false, error: error.localizedDescription))
                logLines.append("[失败] \(group.baseName)：\(error.localizedDescription)")
            }
        }

        logLines.append("")
        logLines.append("来源文件夹保持不变；本次操作仅复制所选照片组。")

        logLines.append("结束：\(ISO8601DateFormatter().string(from: .now))")
        let stagedLogURL = stagingURL.appendingPathComponent("影择-导出日志.txt")
        try logLines.joined(separator: "\n").write(to: stagedLogURL, atomically: true, encoding: .utf8)
        let failedCount = outcomes.lazy.filter { !$0.succeeded }.count
        guard failedCount == 0 else { throw ArchiveError.incomplete(stagingURL, failedCount) }

        try fileManager.moveItem(at: stagingURL, to: projectURL)
        try? fileManager.removeItem(at: manifestURL(in: projectURL))
        return ArchiveReport(
            projectURL: projectURL,
            logURL: projectURL.appendingPathComponent(stagedLogURL.lastPathComponent),
            outcomes: outcomes
        )
    }

    private func preflight(projectURL: URL, destinationRoot: URL, available: [PhotoGroup]) throws {
        guard fileManager.isWritableFile(atPath: destinationRoot.path) else { throw ArchiveError.destinationNotWritable(destinationRoot) }
        if fileManager.fileExists(atPath: projectURL.path) { throw ArchiveError.targetExists(projectURL) }
        let pairingConflicts = available.filter(\.hasPairingConflict).map(\.baseName)
        if !pairingConflicts.isEmpty { throw ArchiveError.pairingConflicts(pairingConflicts) }
        let required = available.flatMap(\.allExistingURLs).reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let availableCapacity = Int64((try? destinationRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0)
        if availableCapacity > 0, required > availableCapacity {
            throw ArchiveError.insufficientSpace(required: required, available: availableCapacity)
        }

        var names = Set<String>()
        var duplicates: [String] = []
        for group in available {
            let groupNames = [group.jpegURL?.lastPathComponent, group.heicURL?.lastPathComponent, group.rawURL?.lastPathComponent, "\(group.baseName).xmp"].compactMap { $0 }
            for name in groupNames {
                let key = name.lowercased()
                if !names.insert(key).inserted { duplicates.append(name) }
            }
        }
        if !duplicates.isEmpty { throw ArchiveError.conflicts(duplicates) }
    }

    private func prepareManifest(
        at stagingURL: URL,
        source: URL,
        projectName: String,
        available: [PhotoGroup]
    ) throws -> ExportManifest {
        let expected = ExportManifest(
            sourcePath: source.standardizedFileURL.path,
            projectName: projectName,
            plannedGroupIDs: available.map(\.id),
            completedGroupIDs: []
        )
        if fileManager.fileExists(atPath: stagingURL.path) {
            guard let data = try? Data(contentsOf: manifestURL(in: stagingURL)),
                  let existing = try? JSONDecoder().decode(ExportManifest.self, from: data),
                  existing.version == expected.version,
                  existing.sourcePath == expected.sourcePath,
                  existing.projectName == expected.projectName,
                  existing.plannedGroupIDs == expected.plannedGroupIDs
            else { throw ArchiveError.resumeConflict(stagingURL) }
            return existing
        }
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        try writeManifest(expected, at: stagingURL)
        return expected
    }

    private func manifestURL(in stagingURL: URL) -> URL {
        stagingURL.appendingPathComponent(".影择-导出状态.json")
    }

    private func writeManifest(_ manifest: ExportManifest, at stagingURL: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(in: stagingURL), options: .atomic)
    }

    private func completedGroupMatches(_ group: PhotoGroup, in stagingURL: URL) throws -> Bool {
        for source in [group.jpegURL, group.heicURL, group.rawURL].compactMap({ $0 }) {
            let destination = stagingURL.appendingPathComponent(source.lastPathComponent)
            guard fileManager.fileExists(atPath: destination.path),
                  try filesMatch(source, destination)
            else { return false }
        }
        let xmpURL = stagingURL.appendingPathComponent("\(group.baseName).xmp")
        guard let written = try? Data(contentsOf: xmpURL) else { return false }
        let expected = try xmpWriter.data(existingURL: group.xmpURL, rating: group.rating, label: group.colorLabel)
        return written == expected
    }

    private func removeOutputs(for group: PhotoGroup, from stagingURL: URL) throws {
        let names = [group.jpegURL, group.heicURL, group.rawURL]
            .compactMap { $0?.lastPathComponent } + ["\(group.baseName).xmp"]
        for name in names {
            let url = stagingURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
    }

    private func copyGroup(_ group: PhotoGroup, to projectURL: URL) throws {
        let staging = projectURL.appendingPathComponent(".cull-stage-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var finalized: [URL] = []
        do {
            for source in [group.jpegURL, group.heicURL, group.rawURL].compactMap({ $0 }) {
                let staged = staging.appendingPathComponent(source.lastPathComponent)
                try fileManager.copyItem(at: source, to: staged)
                guard try filesMatch(source, staged) else { throw ArchiveError.verificationFailed(source.lastPathComponent) }
            }
            let xmpName = "\(group.baseName).xmp"
            let xmpData = try xmpWriter.data(existingURL: group.xmpURL, rating: group.rating, label: group.colorLabel)
            try xmpWriter.writeAtomically(xmpData, to: staging.appendingPathComponent(xmpName))

            for staged in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                let final = projectURL.appendingPathComponent(staged.lastPathComponent)
                guard !fileManager.fileExists(atPath: final.path) else { throw ArchiveError.conflicts([final.lastPathComponent]) }
                try fileManager.moveItem(at: staged, to: final)
                finalized.append(final)
            }
            try fileManager.removeItem(at: staging)
        } catch {
            for url in finalized { try? fileManager.removeItem(at: url) }
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func filesMatch(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let leftSize = try lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let rightSize = try rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard leftSize == rightSize else { return false }
        return try digest(lhs) == digest(rhs)
    }

    private func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try Self.digestChunks { try handle.read(upToCount: 4 * 1024 * 1024) }
    }

    // Read errors must abort verification rather than be treated as end of file.
    nonisolated static func digestChunks(_ read: () throws -> Data?) throws -> SHA256.Digest {
        var hasher = SHA256()
        while let data = try autoreleasepool(invoking: read), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
    }

}
