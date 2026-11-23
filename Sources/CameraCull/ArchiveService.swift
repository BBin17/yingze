import CryptoKit
import Foundation

struct ArchiveRequest: Codable, Sendable {
    let source: URL
    let destinationRoot: URL
    let projectName: String
    let groups: [PhotoGroup]
    var preservesSubdirectories = false

    var projectURL: URL { destinationRoot.appendingPathComponent(projectName, isDirectory: true) }
    var stagingURL: URL { destinationRoot.appendingPathComponent(".\(projectName).影择导出中", isDirectory: true) }

    static func isValidFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

struct ArchiveFileFailure: Sendable {
    let path: String
    let reason: String
}

struct ArchiveOutcome: Sendable, Identifiable {
    var id: String { groupID }
    let groupID: String
    let failures: [ArchiveFileFailure]
    var succeeded: Bool { failures.isEmpty }
    var error: String? { failures.first.map { "\($0.path)：\($0.reason)" } }
}

struct ArchiveReport: Sendable, Identifiable {
    let id = UUID()
    let request: ArchiveRequest
    let outcomes: [ArchiveOutcome]
    let logURL: URL?
    let isComplete: Bool
    let issue: String?

    var location: URL { isComplete ? request.projectURL : request.stagingURL }
    var totalCount: Int { request.groups.lazy.filter { !$0.pickState.isRejected }.count }
    var succeededCount: Int { outcomes.lazy.filter(\.succeeded).count }
    var failedCount: Int { outcomes.count - succeededCount }
}

enum ArchiveError: LocalizedError {
    case invalidFolderName
    case noAvailablePhotos
    case targetExists(URL)
    case conflicts([String])
    case pairingConflicts([String])
    case invalidSourceGroup(String)
    case insufficientSpace(required: Int64, available: Int64)
    case destinationNotWritable(URL)
    case verificationFailed
    case resumeConflict(URL)

    var canRetry: Bool {
        switch self {
        case .insufficientSpace, .destinationNotWritable, .verificationFailed: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidFolderName: "请输入有效的导出文件夹名称。"
        case .noAvailablePhotos: "当前范围没有可导出的照片。"
        case .targetExists(let url): "导出文件夹已存在：\(url.path)"
        case .conflicts(let names): "目标存在同名文件或目录：\(names.prefix(8).joined(separator: "、"))"
        case .pairingConflicts(let names): "以下照片组存在重复配对，解决冲突后才能导出：\(names.prefix(8).joined(separator: "、"))"
        case .invalidSourceGroup(let name): "照片组的文件不在同一个来源子目录：\(name)"
        case .insufficientSpace(let required, let available): "目标空间不足，需要 \(required) 字节，可用 \(available) 字节。"
        case .destinationNotWritable(let url): "目标目录不可写：\(url.path)\n请检查目标磁盘或 NAS 是否已连接。"
        case .verificationFailed: "文件 SHA-256 校验失败。"
        case .resumeConflict(let url): "这个暂存目录属于不同的导出范围或目录布局：\(url.path)。请使用原来的导出设置，或为新导出使用其他名称。"
        }
    }
}

actor ArchiveService {
    private struct PlannedGroup {
        let photo: PhotoGroup
        let subdirectories: [String]
        let imageURLs: [URL]

        var xmpName: String { "\(photo.baseName).xmp" }
        var names: [String] { imageURLs.map(\.lastPathComponent) + [xmpName] }
        var relativePaths: [String] { names.map { relativePath(for: $0) } }

        func relativePath(for name: String) -> String {
            (subdirectories + [name]).joined(separator: "/")
        }
    }

    private struct ExportManifest: Codable {
        var version = 2
        let sourcePath: String
        let projectName: String
        let plannedGroupIDs: [String]
        // Optional fields allow resuming a flat export started by version 1.
        let preservesSubdirectories: Bool?
        let plannedPaths: [[String]]?
        var completedGroupIDs: Set<String>
    }

    private static let logName = "影择-导出日志.txt"
    private static let manifestName = ".影择-导出状态.json"
    private static let scratchName = ".影择-复制暂存"
    private let fileManager = FileManager.default
    private let xmpWriter = XMPWriter()
    private let interruptionAfterCompletedGroups: Int?

    init(interruptionAfterCompletedGroups: Int? = nil) {
        self.interruptionAfterCompletedGroups = interruptionAfterCompletedGroups
    }

    func execute(_ request: ArchiveRequest, progress: @escaping @Sendable (String) -> Void) async throws -> ArchiveReport {
        try Task.checkCancellation()
        guard ArchiveRequest.isValidFolderName(request.projectName) else { throw ArchiveError.invalidFolderName }
        let available = request.groups.filter { !$0.pickState.isRejected }
        guard !available.isEmpty else { throw ArchiveError.noAvailablePhotos }
        guard fileManager.isWritableFile(atPath: request.destinationRoot.path) else {
            throw ArchiveError.destinationNotWritable(request.destinationRoot)
        }
        guard !fileManager.fileExists(atPath: request.projectURL.path) else { throw ArchiveError.targetExists(request.projectURL) }
        let plan = try planExport(available, from: request.source, preservingSubdirectories: request.preservesSubdirectories)
        let staging = request.stagingURL
        var manifest = try prepareManifest(for: request, plan: plan)
        let previouslyCompleted = plan.filter { manifest.completedGroupIDs.contains($0.photo.id) }
        manifest.completedGroupIDs.removeAll()
        for (index, group) in previouslyCompleted.enumerated() {
            try Task.checkCancellation()
            progress("正在校验暂存文件 \(index + 1)/\(previouslyCompleted.count)：\(group.relativePath(for: group.photo.baseName))")
            if (try? completedGroupMatches(group, in: staging)) == true {
                manifest.completedGroupIDs.insert(group.photo.id)
            }
        }
        try checkCapacity(at: request.destinationRoot, remaining: plan.filter { !manifest.completedGroupIDs.contains($0.photo.id) })
        try removeScratch(in: staging)

        var outcomes: [ArchiveOutcome] = []
        var issue: String?
        var log = [
            "影择 导出日志",
            "来源：\(request.source.path)",
            "目标：\(request.projectURL.path)",
            "开始：\(ISO8601DateFormatter().string(from: .now))",
            ""
        ]
        for (index, group) in plan.enumerated() {
            try Task.checkCancellation()
            progress("正在处理 \(index + 1)/\(plan.count)：\(group.relativePath(for: group.photo.baseName))")
            var failures: [ArchiveFileFailure] = []
            if manifest.completedGroupIDs.contains(group.photo.id) {
                log.append("[已验证，继续] \(group.relativePath(for: group.photo.baseName))")
            } else {
                failures = try copyGroup(group, in: staging)
                if failures.isEmpty {
                    manifest.completedGroupIDs.insert(group.photo.id)
                    do {
                        try writeManifest(manifest, in: staging)
                        log.append("[成功] \(group.relativePath(for: group.photo.baseName))")
                    } catch {
                        failures = [ArchiveFileFailure(path: Self.manifestName, reason: error.localizedDescription)]
                        manifest.completedGroupIDs.remove(group.photo.id)
                    }
                    if let interruptionAfterCompletedGroups,
                       manifest.completedGroupIDs.count >= interruptionAfterCompletedGroups {
                        throw CancellationError()
                    }
                }
            }
            outcomes.append(ArchiveOutcome(groupID: group.photo.id, failures: failures))
            log += failures.map { "[失败] \($0.path)：\($0.reason)" }
            if !failures.isEmpty, !fileManager.isWritableFile(atPath: staging.path) {
                issue = ArchiveError.destinationNotWritable(staging).localizedDescription
                break
            }
        }

        try Task.checkCancellation()
        log.append("结束：\(ISO8601DateFormatter().string(from: .now))")
        if let issue { log.append(issue) }
        let stagedLog = staging.appendingPathComponent(Self.logName)
        var logURL: URL?
        var isComplete = false
        do {
            try log.joined(separator: "\n").write(to: stagedLog, atomically: true, encoding: .utf8)
            logURL = stagedLog
            if issue == nil, outcomes.allSatisfy(\.succeeded) {
                try removeScratch(in: staging)
                try fileManager.moveItem(at: staging, to: request.projectURL)
                try? fileManager.removeItem(at: manifestURL(in: request.projectURL))
                logURL = request.projectURL.appendingPathComponent(Self.logName)
                isComplete = true
            }
        } catch {
            issue = issue ?? "无法写入导出日志或完成目标文件夹：\(error.localizedDescription)"
        }
        return ArchiveReport(request: request, outcomes: outcomes, logURL: logURL, isComplete: isComplete, issue: issue)
    }

    private func planExport(_ groups: [PhotoGroup], from source: URL, preservingSubdirectories: Bool) throws -> [PlannedGroup] {
        let sourcePath = source.standardizedFileURL.pathComponents
        let pairingConflicts = groups.filter(\.hasPairingConflict).map(\.baseName)
        if !pairingConflicts.isEmpty { throw ArchiveError.pairingConflicts(pairingConflicts) }

        var files = Set([Self.logName, Self.manifestName, Self.scratchName].map { $0.lowercased() })
        var directories: [String: String] = [:]
        var duplicates: [String] = []
        let plan = try groups.map { group in
            let images = [group.jpegURL, group.heicURL, group.rawURL].compactMap { $0 }
            guard let first = images.first, ArchiveRequest.isValidFolderName(group.baseName) else {
                throw ArchiveError.invalidSourceGroup(group.baseName)
            }
            let parent = first.standardizedFileURL.deletingLastPathComponent()
            guard parent.pathComponents.starts(with: sourcePath),
                  group.allExistingURLs.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent() == parent })
            else { throw ArchiveError.invalidSourceGroup(group.baseName) }
            let subdirectories = preservingSubdirectories ? Array(parent.pathComponents.dropFirst(sourcePath.count)) : []
            let planned = PlannedGroup(photo: group, subdirectories: subdirectories, imageURLs: images)
            for depth in subdirectories.indices {
                let path = subdirectories[...depth].joined(separator: "/")
                let key = path.lowercased()
                if files.contains(key) || directories[key].map({ $0 != path }) == true { duplicates.append(path) }
                directories[key] = path
            }
            for path in planned.relativePaths {
                let key = path.lowercased()
                if directories[key] != nil || !files.insert(key).inserted { duplicates.append(path) }
            }
            return planned
        }
        if !duplicates.isEmpty { throw ArchiveError.conflicts(duplicates) }
        return plan
    }

    private func prepareManifest(for request: ArchiveRequest, plan: [PlannedGroup]) throws -> ExportManifest {
        let staging = request.stagingURL
        var expected = ExportManifest(
            sourcePath: request.source.standardizedFileURL.path,
            projectName: request.projectName,
            plannedGroupIDs: plan.map { $0.photo.id },
            preservesSubdirectories: request.preservesSubdirectories,
            plannedPaths: plan.map(\.relativePaths),
            completedGroupIDs: []
        )
        if fileManager.fileExists(atPath: staging.path) {
            let values = try staging.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ArchiveError.resumeConflict(staging) }
            let data: Data
            do {
                data = try Data(contentsOf: manifestURL(in: staging))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile && fileManager.isWritableFile(atPath: staging.path) {
                throw ArchiveError.resumeConflict(staging)
            }
            guard let existing = try? JSONDecoder().decode(ExportManifest.self, from: data),
                  existing.sourcePath == expected.sourcePath,
                  existing.projectName == expected.projectName,
                  existing.plannedGroupIDs == expected.plannedGroupIDs,
                  (existing.version == 1 && !request.preservesSubdirectories) ||
                    (existing.version == expected.version &&
                     existing.preservesSubdirectories == expected.preservesSubdirectories &&
                     existing.plannedPaths == expected.plannedPaths)
            else { throw ArchiveError.resumeConflict(staging) }
            if existing.version == 1 {
                try removeLegacyScratch(in: staging)
            }
            expected.completedGroupIDs = existing.completedGroupIDs
            return expected
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try writeManifest(expected, in: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return expected
    }

    private func checkCapacity(at destination: URL, remaining: [PlannedGroup]) throws {
        let required = remaining.lazy.flatMap { $0.photo.allExistingURLs }.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let values = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available > 0, required > available {
            throw ArchiveError.insufficientSpace(required: required, available: available)
        }
    }

    private func manifestURL(in staging: URL) -> URL {
        staging.appendingPathComponent(Self.manifestName)
    }

    private func writeManifest(_ manifest: ExportManifest, in staging: URL) throws {
        try JSONEncoder().encode(manifest).write(to: manifestURL(in: staging), options: .atomic)
    }

    private func removeScratch(in staging: URL) throws {
        let scratch = staging.appendingPathComponent(Self.scratchName, isDirectory: true)
        if fileManager.fileExists(atPath: scratch.path) { try fileManager.removeItem(at: scratch) }
    }

    private func removeLegacyScratch(in staging: URL) throws {
        let prefix = ".cull-stage-"
        for item in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            let name = item.lastPathComponent
            if name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil {
                try fileManager.removeItem(at: item)
            }
        }
    }

    private func destination(for group: PlannedGroup, in staging: URL, create: Bool) throws -> URL {
        var directory = staging
        for component in group.subdirectories {
            directory.appendPathComponent(component, isDirectory: true)
            if create, !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ArchiveError.conflicts([directory.path])
            }
        }
        return directory
    }

    private func completedGroupMatches(_ group: PlannedGroup, in staging: URL) throws -> Bool {
        let output = try destination(for: group, in: staging, create: false)
        for source in group.imageURLs {
            let file = output.appendingPathComponent(source.lastPathComponent)
            guard fileManager.fileExists(atPath: file.path), try filesMatch(source, file) else { return false }
        }
        let expected = try xmpWriter.data(existingURL: group.photo.xmpURL, rating: group.photo.rating, label: group.photo.colorLabel)
        return try Data(contentsOf: output.appendingPathComponent(group.xmpName)) == expected
    }

    private func copyGroup(_ group: PlannedGroup, in staging: URL) throws -> [ArchiveFileFailure] {
        let scratch = staging.appendingPathComponent(Self.scratchName, isDirectory: true)
        let output: URL
        do {
            output = try destination(for: group, in: staging, create: true)
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: false)
        } catch {
            return group.relativePaths.map { ArchiveFileFailure(path: $0, reason: error.localizedDescription) }
        }
        defer { try? fileManager.removeItem(at: scratch) }

        var failures: [ArchiveFileFailure] = []
        for source in group.imageURLs {
            try Task.checkCancellation()
            let name = source.lastPathComponent
            let temporary = scratch.appendingPathComponent(name)
            do {
                try fileManager.copyItem(at: source, to: temporary)
                guard try filesMatch(source, temporary) else { throw ArchiveError.verificationFailed }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(ArchiveFileFailure(path: group.relativePath(for: name), reason: error.localizedDescription))
            }
        }

        do {
            let xmp = try xmpWriter.data(existingURL: group.photo.xmpURL, rating: group.photo.rating, label: group.photo.colorLabel)
            try xmp.write(to: scratch.appendingPathComponent(group.xmpName), options: .atomic)
        } catch {
            failures.append(ArchiveFileFailure(path: group.relativePath(for: group.xmpName), reason: error.localizedDescription))
        }
        guard failures.isEmpty else { return failures }

        var finalized: [URL] = []
        for name in group.names {
            let target = output.appendingPathComponent(name)
            do {
                if fileManager.fileExists(atPath: target.path) {
                    let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw ArchiveError.conflicts([group.relativePath(for: name)])
                    }
                    try fileManager.removeItem(at: target)
                }
                try fileManager.moveItem(at: scratch.appendingPathComponent(name), to: target)
                finalized.append(target)
            } catch {
                for url in finalized { try? fileManager.removeItem(at: url) }
                return [ArchiveFileFailure(path: group.relativePath(for: name), reason: error.localizedDescription)]
            }
        }
        return []
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
        return try Self.digestChunks {
            try Task.checkCancellation()
            return try handle.read(upToCount: 4 * 1024 * 1024)
        }
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
