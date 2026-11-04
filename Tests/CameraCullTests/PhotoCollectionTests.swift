import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CameraCull

@Suite("软件内照片分类")
struct PhotoCollectionTests {
    @Test("原始像素缩放按屏幕像素密度计算")
    func focusZoomUsesBackingScale() {
        let scale = FocusZoom.scale(
            pixelWidth: 6_000,
            pixelHeight: 4_000,
            viewportWidth: 1_000,
            viewportHeight: 800,
            backingScale: 2
        )
        #expect(abs(scale - 3) < 0.001)
        #expect(FocusZoom.scale(
            pixelWidth: nil,
            pixelHeight: nil,
            viewportWidth: 1_000,
            viewportHeight: 800,
            backingScale: 2
        ) == 1)
    }

    @Test("刷新项目保留原有选片状态并接纳新照片")
    func refreshMergePreservesSessionState() {
        var saved = group(.reject)
        saved.id = "existing"
        saved.rating = 5
        saved.colorLabel = .blue
        saved.operationState = .archived

        var rescanned = group(.undecided)
        rescanned.id = "existing"
        rescanned.rating = 2
        rescanned.colorLabel = .red
        var newGroup = group(.undecided)
        newGroup.id = "new"
        newGroup.rating = 3
        newGroup.colorLabel = .green

        let merged = ProjectRefreshMerger.merge(scanned: [rescanned, newGroup], previous: [saved])
        #expect(merged.count == 2)
        #expect(merged[0].pickState == .reject)
        #expect(merged[0].rating == 5)
        #expect(merged[0].colorLabel == .blue)
        #expect(merged[0].operationState == .archived)
        #expect(merged[1].rating == 3)
        #expect(merged[1].colorLabel == .green)
    }

    @Test("选片显示全部未淘汰照片，废片单独显示")
    func filtersByPickState() {
        let undecided = group(.undecided)
        let picked = group(.keep)
        let rejected = group(.reject)

        #expect(PhotoCollection.available.includes(undecided))
        #expect(PhotoCollection.available.includes(picked))
        #expect(!PhotoCollection.available.includes(rejected))
        #expect(PhotoCollection.rejected.includes(rejected))
        #expect(!PhotoCollection.rejected.includes(undecided))
        #expect(!PhotoCollection.rejected.includes(picked))
    }

    @Test("颜色标签使用中文显示名称")
    func colorLabelsUseChineseTitles() {
        #expect(ColorLabel.none.title == "无颜色")
        #expect(ColorLabel.red.title == "红色")
        #expect(ColorLabel.yellow.title == "黄色")
        #expect(ColorLabel.green.title == "绿色")
        #expect(ColorLabel.blue.title == "蓝色")
        #expect(ColorLabel.purple.title == "紫色")
    }

    @Test("预览模式在速度与 RAW 质量之间自动选源")
    func previewModeSelectsRenderedOrRawSource() {
        let jpg = URL(fileURLWithPath: "/tmp/TEST.JPG")
        let heic = URL(fileURLWithPath: "/tmp/TEST.HEIC")
        let raw = URL(fileURLWithPath: "/tmp/TEST.ARW")
        let paired = PhotoGroup(id: "paired", baseName: "TEST", jpegURL: jpg, heicURL: heic, rawURL: raw, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil)
        let rawOnly = PhotoGroup(id: "raw", baseName: "RAW_ONLY", jpegURL: nil, rawURL: raw, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil)

        #expect(paired.previewURL(for: .fast) == jpg)
        #expect(paired.previewURL(for: .standard) == jpg)
        #expect(paired.previewURL(for: .highQuality) == raw)
        #expect(paired.previewURL(for: .original) == raw)
        #expect(paired.previewFormat(for: .highQuality) == "ARW")
        #expect(rawOnly.previewURL(for: .fast) == raw)
    }

    @Test("筛选同类取或且跨类别取且")
    func bridgeStyleFilterMatching() {
        var redThree = group(.undecided)
        redThree.rating = 3
        redThree.colorLabel = .red
        var blueFive = group(.undecided)
        blueFive.rating = 5
        blueFive.colorLabel = .blue

        #expect(redThree.matches(ratings: [3, 5], colors: []))
        #expect(blueFive.matches(ratings: [3, 5], colors: []))
        #expect(redThree.matches(ratings: [3, 5], colors: [.red]))
        #expect(!blueFive.matches(ratings: [3, 5], colors: [.red]))
        #expect(redThree.matches(ratings: [], colors: []))
    }

    @Test("标准模式读取 JPG/HEIC 原图，高质量和原图模式优先 RAW")
    func previewModesUseExpectedSourcesAndResolution() {
        #expect(PreviewMode.fast.previewPixelSize == 2_048)
        #expect(PreviewMode.standard.previewPixelSize == 0)
        #expect(PreviewMode.highQuality.previewPixelSize == 6_144)
        #expect(PreviewMode.original.thumbnailPixelSize == 2_048)
        #expect(PreviewMode.original.previewPixelSize == 0)
        #expect(PreviewMode.highQuality.prefersRaw)
        #expect(PreviewMode.original.prefersRaw)
        #expect(!PreviewMode.standard.prefersRaw)
    }

    @Test("原图解码应用相机 EXIF 方向")
    @MainActor
    func originalPreviewAppliesEXIFOrientation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("portrait.jpg")

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: 80,
            height: 40,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let sourceImage = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, sourceImage, [kCGImagePropertyOrientation: 8] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let decoded = try #require(await ImageCache.shared.image(for: url, maxPixelSize: 0))
        #expect(decoded.size.width == 40)
        #expect(decoded.size.height == 80)
    }

    private func group(_ state: PickState) -> PhotoGroup {
        PhotoGroup(id: UUID().uuidString, baseName: "TEST", jpegURL: nil, rawURL: nil, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil, pickState: state)
    }
}

@Suite("多项目会话")
struct ProjectSessionTests {
    @Test("项目摘要保存前三张可用照片作为堆叠封面")
    func projectSummaryBuildsCoverStack() {
        let source = URL(fileURLWithPath: "/tmp/source")
        let first = URL(fileURLWithPath: "/tmp/FIRST.JPG")
        let second = URL(fileURLWithPath: "/tmp/SECOND.ARW")
        let rejected = URL(fileURLWithPath: "/tmp/REJECTED.JPG")
        let third = URL(fileURLWithPath: "/tmp/THIRD.HEIC")
        let fourth = URL(fileURLWithPath: "/tmp/FOURTH.JPG")
        let fifth = URL(fileURLWithPath: "/tmp/FIFTH.ARW")
        let session = CullSession(
            sourceURL: source,
            destinationURL: nil,
            projectName: "封面测试",
            groups: [
                PhotoGroup(id: "1", baseName: "FIRST", jpegURL: first, rawURL: nil, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil),
                PhotoGroup(id: "2", baseName: "SECOND", jpegURL: nil, rawURL: second, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil),
                PhotoGroup(id: "3", baseName: "REJECTED", jpegURL: rejected, rawURL: nil, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil, pickState: .reject),
                PhotoGroup(id: "4", baseName: "THIRD", jpegURL: nil, heicURL: third, rawURL: nil, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil),
                PhotoGroup(id: "5", baseName: "FOURTH", jpegURL: fourth, rawURL: nil, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil),
                PhotoGroup(id: "6", baseName: "FIFTH", jpegURL: nil, rawURL: fifth, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil)
            ],
            selectedGroupID: "1",
            updatedAt: .now
        )

        let summary = ProjectSummary(id: UUID(), session: session)
        #expect(summary.coverURLs == [first, third, fifth])
    }

    @Test("旧会话迁移后可新增切换重命名和移除项目")
    @MainActor
    func migratesLegacySessionAndManagesMultipleProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCullProjects-\(UUID().uuidString)", isDirectory: true)
        let firstSource = root.appendingPathComponent("first", isDirectory: true)
        let secondSource = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstJPG = firstSource.appendingPathComponent("FIRST.JPG")
        let secondJPG = secondSource.appendingPathComponent("SECOND.JPG")
        try Data("first".utf8).write(to: firstJPG)
        try Data("second".utf8).write(to: secondJPG)
        var firstGroup = PhotoGroup(
            id: "first", baseName: "FIRST", jpegURL: firstJPG, rawURL: nil, xmpURL: nil,
            captureDate: nil, pixelWidth: 1, pixelHeight: 1
        )
        firstGroup.analysis = PhotoAnalysis(
            modelVersion: 1,
            sceneID: "legacy-scene",
            sharpnessScore: 0.9,
            exposureScore: 0.9,
            faceCount: 0,
            overallScore: 0.9,
            recommendation: .recommended,
            reasons: ["旧模型结果"],
            analyzedAt: .now
        )
        let legacy = CullSession(
            sourceURL: firstSource,
            destinationURL: nil,
            projectName: "旧项目",
            groups: [firstGroup],
            selectedGroupID: firstGroup.id,
            updatedAt: .now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: root.appendingPathComponent("CurrentSession.json"), options: .atomic)

        let store = SessionStore(storageDirectory: root)
        #expect(store.projects.count == 1)
        #expect(store.session.projectName == "旧项目")
        #expect(store.session.groups.first?.analysis == nil)

        store.openSource(secondSource, projectName: "第二次拍摄")
        for _ in 0..<200 where store.isIndexing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isIndexing)
        #expect(store.projects.count == 2)
        #expect(store.session.projectName == "第二次拍摄")
        #expect(store.existingProjectID(for: secondSource) != nil)

        let firstProject = try #require(store.projects.first(where: { $0.sourceURL == firstSource }))
        let secondProject = try #require(store.projects.first(where: { $0.sourceURL == secondSource }))
        store.renameProject(firstProject.id, to: "第一次拍摄")
        store.continueProject(firstProject.id)
        #expect(store.session.projectName == "第一次拍摄")
        #expect(store.session.sourceURL == firstSource)
        #expect(store.session.groups.first?.analysis == nil)

        let restored = SessionStore(storageDirectory: root)
        #expect(restored.projects.count == 2)
        #expect(restored.session.projectName == "第一次拍摄")
        #expect(restored.session.groups.first?.analysis == nil)
        restored.removeProject(secondProject.id)
        #expect(restored.projects.count == 1)
        #expect(FileManager.default.fileExists(atPath: secondJPG.path))
    }

    @Test("项目会话损坏时从备份恢复并提示")
    @MainActor
    func restoresDamagedSessionFromBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCullRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let group = PhotoGroup(id: "one", baseName: "ONE", jpegURL: nil, rawURL: nil, xmpURL: nil, captureDate: nil, pixelWidth: nil, pixelHeight: nil, rating: 4, pickState: .keep)
        let legacy = CullSession(sourceURL: source, destinationURL: nil, projectName: "恢复测试", groups: [group], selectedGroupID: "one", updatedAt: .now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: root.appendingPathComponent("CurrentSession.json"))
        let initial = SessionStore(storageDirectory: root)
        let id = try #require(initial.currentProjectID)
        let record = root.appendingPathComponent("Projects/\(id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: record.appendingPathExtension("backup").path))
        try Data("invalid json".utf8).write(to: record)

        let restored = SessionStore(storageDirectory: root)
        #expect(restored.session.projectName == "恢复测试")
        #expect(restored.session.groups.first?.rating == 4)
        #expect(restored.presentedError?.contains("备份恢复") == true)
        #expect(try Data(contentsOf: record) == Data("invalid json".utf8))
    }

    @Test("项目索引丢失时从备份恢复")
    @MainActor
    func restoresMissingIndexFromBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCullMissingIndex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = CullSession(sourceURL: root, destinationURL: nil, projectName: "索引恢复", groups: [], selectedGroupID: nil, updatedAt: .now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: root.appendingPathComponent("CurrentSession.json"))
        let initial = SessionStore(storageDirectory: root)
        #expect(initial.projects.count == 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Projects.json"))
        let restored = SessionStore(storageDirectory: root)
        #expect(restored.projects.count == 1)
        #expect(restored.session.projectName == "索引恢复")
        #expect(restored.presentedError?.contains("备份恢复") == true)
    }

    @Test("项目索引和备份均损坏时提示并阻止覆盖")
    @MainActor
    func blocksWritesWhenIndexCannotBeRecovered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCullBrokenIndex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("Projects.json")
        let broken = Data("broken index".utf8)
        try broken.write(to: index)
        try Data("broken backup".utf8).write(to: index.appendingPathExtension("backup"))
        let store = SessionStore(storageDirectory: root)
        #expect(store.presentedError?.contains("暂停写入") == true)
        store.removeProject(UUID())
        #expect(try Data(contentsOf: index) == broken)
    }

    @Test("位于末尾的当前照片仍能组成完整比较组")
    @MainActor
    func comparisonAtEndIncludesPreviousPhotos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCullCompare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let groups = (1...4).map { index in
            PhotoGroup(
                id: "\(index)",
                baseName: "IMG_\(index)",
                jpegURL: URL(fileURLWithPath: "/tmp/IMG_\(index).JPG"),
                rawURL: nil,
                xmpURL: nil,
                captureDate: nil,
                pixelWidth: 1,
                pixelHeight: 1
            )
        }
        let legacy = CullSession(
            sourceURL: root,
            destinationURL: nil,
            projectName: "比较测试",
            groups: groups,
            selectedGroupID: "4",
            updatedAt: .now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: root.appendingPathComponent("CurrentSession.json"), options: .atomic)

        let store = SessionStore(storageDirectory: root)
        #expect(store.comparisonGroups(limit: 2).map(\.id) == ["3", "4"])
        #expect(store.comparisonGroups(limit: 4).map(\.id) == ["1", "2", "3", "4"])
    }
}
