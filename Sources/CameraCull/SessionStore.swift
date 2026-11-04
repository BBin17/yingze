import AppKit
import Foundation
import SwiftUI

private struct ProjectIndex: Codable {
    var currentProjectID: UUID?
    var projects: [ProjectSummary]
}

enum ProjectRefreshMerger {
    static func merge(scanned: [PhotoGroup], previous: [PhotoGroup]) -> [PhotoGroup] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return scanned.map { scannedGroup in
            guard let saved = previousByID[scannedGroup.id] else { return scannedGroup }
            var merged = scannedGroup
            merged.rating = saved.rating
            merged.colorLabel = saved.colorLabel
            merged.pickState = saved.pickState
            merged.operationState = saved.operationState
            merged.errorMessage = saved.errorMessage
            merged.analysis = saved.analysis?.modelVersion == PhotoAnalysis.currentModelVersion
                ? saved.analysis
                : nil
            return merged
        }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    private var storageRecoveryBlocked = false
    @Published private(set) var session: CullSession = .empty
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var currentProjectID: UUID?
    @Published var showsProjectHome = true
    @Published var browserMode: BrowserMode = .grid {
        didSet { preheatFullSizeImagesIfNeeded() }
    }
    @Published var gridThumbnailSize: Double = {
        let saved = UserDefaults.standard.double(forKey: "Yingze.GridThumbnailSize")
        return saved > 0 ? min(300, max(130, saved)) : 176
    }() {
        didSet {
            UserDefaults.standard.set(gridThumbnailSize, forKey: "Yingze.GridThumbnailSize")
        }
    }
    @Published var fillsGridThumbnails: Bool = {
        UserDefaults.standard.bool(forKey: "Yingze.FillsGridThumbnails")
    }() {
        didSet {
            UserDefaults.standard.set(fillsGridThumbnails, forKey: "Yingze.FillsGridThumbnails")
        }
    }
    @Published private(set) var multiSelectedIDs: Set<String> = []
    @Published var surveyLimit: Int = {
        let saved = UserDefaults.standard.integer(forKey: "Yingze.SurveyLimit")
        return [4, 9].contains(saved) ? saved : 4
    }() {
        didSet {
            guard [4, 9].contains(surveyLimit) else { surveyLimit = 4; return }
            UserDefaults.standard.set(surveyLimit, forKey: "Yingze.SurveyLimit")
        }
    }
    @Published var advancesAfterDecision: Bool = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "Yingze.AdvancesAfterDecision") as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(advancesAfterDecision, forKey: "Yingze.AdvancesAfterDecision")
        }
    }
    @Published var photoCollection: PhotoCollection = .available {
        didSet { ensureVisibleSelection() }
    }
    @Published var showingShortcutHelp = false
#if AI_CULL
    @Published var showingAutoCullSetup = false
    @Published var showingAutoCullReview = false
    @Published var autoCullSettings: AutoCullSettings = {
        guard let data = UserDefaults.standard.data(forKey: "Yingze.AutoCullSettings"),
              let value = try? JSONDecoder().decode(AutoCullSettings.self, from: data)
        else { return AutoCullSettings() }
        return value
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(autoCullSettings) {
                UserDefaults.standard.set(data, forKey: "Yingze.AutoCullSettings")
            }
        }
    }
    @Published private(set) var isAutoCulling = false
    @Published private(set) var autoCullProgress = 0.0
    @Published private(set) var autoCullProgressMessage = ""
    @Published private(set) var autoCullPreferenceProfile: AutoCullPreferenceProfile = {
        guard let data = UserDefaults.standard.data(forKey: "Yingze.AutoCullPreferenceProfile"),
              let value = try? JSONDecoder().decode(AutoCullPreferenceProfile.self, from: data)
        else { return AutoCullPreferenceProfile() }
        return value
    }()
#endif
    @Published var previewMode: PreviewMode = {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "Yingze.PreviewMode"), let mode = PreviewMode(rawValue: saved) {
            return mode
        }
        let oldQuality = defaults.string(forKey: "Yingze.PreviewQuality")
        let oldSource = defaults.string(forKey: "Yingze.PreviewSource")
        if oldQuality == "maximum" { return .original }
        if oldQuality == "fine" || oldSource == "raw" { return .highQuality }
        if oldQuality == "fast" { return .fast }
        return .standard
    }() {
        didSet {
            UserDefaults.standard.set(previewMode.rawValue, forKey: "Yingze.PreviewMode")
            preheatFullSizeImagesIfNeeded()
        }
    }
    @Published var isIndexing = false
    @Published var isArchiving = false
    @Published var progressMessage = ""
    @Published var presentedError: String?
    @Published var archiveReport: ArchiveReport?
    @Published var undoNotice: String?
    @Published private(set) var ratingFilters: Set<Int> = []
    @Published private(set) var colorFilters: Set<ColorLabel> = []

    private var undoStack: [[(id: String, previous: PhotoGroup)]] = []
    private var saveTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
#if AI_CULL
    private var autoCullTask: Task<Void, Never>?
#endif
    private var undoNoticeTask: Task<Void, Never>?
    private var metadataLoadingIDs: Set<String> = []
    private var selectionAnchorID: String?
    private let storageDirectoryOverride: URL?

    var groups: [PhotoGroup] { session.groups }
    var collectionGroups: [PhotoGroup] { session.groups.filter(photoCollection.includes) }
    var displayedGroups: [PhotoGroup] {
        collectionGroups.filter { $0.matches(ratings: ratingFilters, colors: colorFilters) }
    }
    var hasActiveFilters: Bool { !ratingFilters.isEmpty || !colorFilters.isEmpty }
    var activeFilterCount: Int { ratingFilters.count + colorFilters.count }
    var pickedGroups: [PhotoGroup] { session.groups.filter(\.pickState.isPicked) }
    var undecidedGroups: [PhotoGroup] { session.groups.filter { $0.pickState == .undecided } }
    var availableGroups: [PhotoGroup] { session.groups.filter { !$0.pickState.isRejected } }
    var filteredAvailableGroups: [PhotoGroup] {
        displayedGroups.filter { !$0.pickState.isRejected }
    }
    var multiSelectedAvailableGroups: [PhotoGroup] {
        availableGroups.filter { multiSelectedIDs.contains($0.id) }
    }
    var multiSelectedAvailableCount: Int { multiSelectedAvailableGroups.count }
#if AI_CULL
    var analyzedGroups: [PhotoGroup] { session.groups.filter { $0.analysis != nil } }
    var autoRecommendedGroups: [PhotoGroup] { session.groups.filter(\.isAutoRecommended) }
    var autoCullScenes: [AutoCullScene] {
        let analyzed = session.groups.filter { $0.analysis != nil }
        let grouped = Dictionary(grouping: analyzed, by: { $0.analysis?.sceneID ?? "" })
        return grouped
            .map { AutoCullScene(id: $0.key, groups: $0.value) }
            .sorted { lhs, rhs in
                let left = lhs.groups.compactMap(\.captureDate).min()
                let right = rhs.groups.compactMap(\.captureDate).min()
                switch (left, right) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.id < rhs.id
                }
            }
    }
#endif
    var selectedGroup: PhotoGroup? {
        guard let id = session.selectedGroupID else { return nil }
        return session.groups.first { $0.id == id }
    }
    var counts: CullCounts {
        CullCounts(
            picked: session.groups.lazy.filter(\.pickState.isPicked).count,
            undecided: session.groups.lazy.filter { $0.pickState == .undecided }.count,
            reject: session.groups.lazy.filter { $0.pickState.isRejected }.count
        )
    }
    var estimatedAvailableBytes: Int64 {
        session.groups.lazy.filter { !$0.pickState.isRejected }.flatMap(\.allExistingURLs).reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    init(storageDirectory: URL? = nil) {
        storageDirectoryOverride = storageDirectory
        loadSavedSession()
    }

    func existingProjectID(for url: URL) -> UUID? {
        projects.first(where: { sameLocation($0.sourceURL, url) })?.id
    }

    func openSource(_ url: URL, projectName: String) {
        if let existing = projects.first(where: { sameLocation($0.sourceURL, url) }) {
            continueProject(existing.id)
            return
        }
        let cleanedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty, !cleanedName.contains("/") else {
            presentedError = "项目名称不能为空，也不能包含斜杠。"
            return
        }
        if currentProjectID != nil { saveNow() }
        scanTask?.cancel()
#if AI_CULL
        autoCullTask?.cancel()
#endif
        ratingFilters = []
        colorFilters = []
        session = CullSession.empty
        multiSelectedIDs.removeAll()
        selectionAnchorID = nil
        session.sourceURL = url
        session.projectName = cleanedName
        currentProjectID = UUID()
        photoCollection = .available
        showsProjectHome = false
        isIndexing = true
        progressMessage = "正在扫描…"
        saveNow()

        scanTask = Task {
            do {
                var accumulated: [PhotoGroup] = []
                let result = try await PhotoIndexer().scan(directory: url) { batch in
                    await MainActor.run {
                        accumulated.append(contentsOf: batch)
                        self.session.groups = accumulated
                        if self.session.selectedGroupID == nil { self.session.selectedGroupID = accumulated.first?.id }
                        self.progressMessage = "已发现 \(accumulated.count) 组照片"
                    }
                }
                session.groups = result
                session.selectedGroupID = result.first?.id
                isIndexing = false
                progressMessage = "共 \(result.count) 组照片"
                scheduleSave()
            } catch is CancellationError {
                isIndexing = false
            } catch {
                isIndexing = false
                presentedError = error.localizedDescription
            }
        }
    }

    func refreshProject() {
        guard let source = session.sourceURL, !isIndexing else { return }
        scanTask?.cancel()
        let previousGroups = session.groups
        let previousFocusedID = session.selectedGroupID
        let previousSelectedIDs = multiSelectedIDs
        isIndexing = true
        progressMessage = "正在刷新项目…"

        scanTask = Task {
            do {
                let result = try await PhotoIndexer().scan(directory: source) { batch in
                    await MainActor.run {
                        if let last = batch.last {
                            self.progressMessage = "正在刷新…\(last.baseName)"
                        }
                    }
                }
                session.groups = ProjectRefreshMerger.merge(scanned: result, previous: previousGroups)
                let validIDs = Set(session.groups.map(\.id))
                multiSelectedIDs = previousSelectedIDs.intersection(validIDs)
                session.selectedGroupID = previousFocusedID.flatMap { validIDs.contains($0) ? $0 : nil }
                ensureVisibleSelection()
                isIndexing = false
                progressMessage = "刷新完成，共 \(result.count) 组照片"
                scheduleSave()
            } catch is CancellationError {
                isIndexing = false
            } catch {
                isIndexing = false
                progressMessage = "刷新未完成"
                presentedError = error.localizedDescription
            }
        }
    }

    func focus(_ id: String) {
        session.selectedGroupID = id
        preheatFullSizeImagesIfNeeded()
        loadMetadataIfNeeded(for: id)
        scheduleSave()
    }

    func selectPhotos(_ id: String, toggling: Bool = false, extendingRange: Bool = false) {
        session.selectedGroupID = id
        let visible = displayedGroups
        if extendingRange,
           let anchorID = selectionAnchorID,
           let anchor = visible.firstIndex(where: { $0.id == anchorID }),
           let target = visible.firstIndex(where: { $0.id == id }) {
            let rangeIDs = Set(visible[min(anchor, target)...max(anchor, target)].map(\.id))
            if toggling { multiSelectedIDs.formUnion(rangeIDs) }
            else { multiSelectedIDs = rangeIDs }
        } else if toggling {
            if multiSelectedIDs.contains(id) { multiSelectedIDs.remove(id) }
            else { multiSelectedIDs.insert(id) }
            selectionAnchorID = id
        } else {
            multiSelectedIDs = [id]
            selectionAnchorID = id
        }
        preheatFullSizeImagesIfNeeded()
        loadMetadataIfNeeded(for: id)
        scheduleSave()
    }

    func selectAllDisplayed() {
        multiSelectedIDs = Set(displayedGroups.map(\.id))
        selectionAnchorID = displayedGroups.first?.id
        if let first = displayedGroups.first { session.selectedGroupID = first.id }
    }

    func clearSelection() {
        multiSelectedIDs.removeAll()
        selectionAnchorID = nil
    }

#if AI_CULL
    func startAutoCull(settings: AutoCullSettings) {
        guard !session.groups.isEmpty, !isAutoCulling else { return }
        autoCullSettings = settings
        autoCullTask?.cancel()
        let input = session.groups
        let preferenceProfile = autoCullPreferenceProfile
        isAutoCulling = true
        autoCullProgress = 0
        autoCullProgressMessage = "正在准备本地分析…"
        showingAutoCullSetup = false

        autoCullTask = Task {
            do {
                let analyzed = try await Task.detached(priority: .userInitiated) {
                    try AutoCullEngine().analyze(
                        groups: input,
                        settings: settings,
                        preferenceProfile: preferenceProfile
                    ) { completed, total, name in
                        Task { @MainActor [weak self] in
                            self?.autoCullProgress = total > 0 ? Double(completed) / Double(total) : 0
                            self?.autoCullProgressMessage = "正在分析 \(name) · \(completed)/\(total)"
                        }
                    }
                }.value
                guard !Task.isCancelled else { return }
                let analysisByID = Dictionary(uniqueKeysWithValues: analyzed.compactMap { group in
                    group.analysis.map { (group.id, $0) }
                })
                for index in session.groups.indices {
                    session.groups[index].analysis = analysisByID[session.groups[index].id]
                }
                isAutoCulling = false
                autoCullProgress = 1
                autoCullProgressMessage = "自动分析完成：\(autoCullScenes.count) 个场景，推荐 \(autoRecommendedGroups.count) 张"
                showingAutoCullReview = true
                scheduleSave()
            } catch is CancellationError {
                isAutoCulling = false
                autoCullProgressMessage = "已取消自动分析"
            } catch {
                isAutoCulling = false
                autoCullProgressMessage = "自动分析未完成"
                presentedError = error.localizedDescription
            }
        }
    }

    func cancelAutoCull() {
        autoCullTask?.cancel()
        autoCullTask = nil
        isAutoCulling = false
        autoCullProgressMessage = "已取消自动分析"
    }

    func acceptAutoRecommendations(sceneID: String? = nil) {
        let ids = Set(session.groups.compactMap { group -> String? in
            guard group.analysis?.recommendation == .recommended,
                  group.pickState == .undecided,
                  sceneID == nil || group.analysis?.sceneID == sceneID
            else { return nil }
            return group.id
        })
        guard !ids.isEmpty else { return }
        mutate(ids: ids) { $0.pickState = .keep }
        showUndoNotice("已接受 \(ids.count) 张自动推荐，其他照片仍保持未决定")
    }

    func setPickStateForReview(_ state: PickState, groupID: String) {
        guard let group = session.groups.first(where: { $0.id == groupID }),
              group.pickState != state
        else { return }
        learnFromAutoCullDecision(groupID: groupID, state: state)
        mutate(ids: [groupID]) { $0.pickState = state }
        session.selectedGroupID = groupID
        showUndoNotice("已将 \(group.baseName) 标记为\(state.title)")
    }

    func compareAutoCullScene(_ sceneID: String) {
        guard let scene = autoCullScenes.first(where: { $0.id == sceneID }) else { return }
        let ranked = scene.groups.sorted {
            ($0.analysis?.overallScore ?? 0) > ($1.analysis?.overallScore ?? 0)
        }
        let visible = Array(ranked.prefix(9))
        guard let first = visible.first else { return }
        multiSelectedIDs = Set(visible.map(\.id))
        selectionAnchorID = first.id
        session.selectedGroupID = first.id
        surveyLimit = visible.count > 4 ? 9 : 4
        browserMode = visible.count == 2 ? .compare : (visible.count > 2 ? .survey : .single)
        showingAutoCullReview = false
        preheatFullSizeImagesIfNeeded()
    }

    func clearAutoCullAnalysis() {
        let ids = Set(session.groups.compactMap { $0.analysis == nil ? nil : $0.id })
        guard !ids.isEmpty else { return }
        for index in session.groups.indices {
            session.groups[index].analysis = nil
        }
        autoCullProgress = 0
        autoCullProgressMessage = ""
        showingAutoCullReview = false
        scheduleSave()
    }

    func resetAutoCullPreferences() {
        autoCullPreferenceProfile = AutoCullPreferenceProfile()
        UserDefaults.standard.removeObject(forKey: "Yingze.AutoCullPreferenceProfile")
    }
#endif

    func setPickState(_ state: PickState) {
        guard let selected = selectedGroup else { return }
        let previousState = selected.pickState
        let previousGroups = displayedGroups
        let previousIndex = previousGroups.firstIndex { $0.id == session.selectedGroupID } ?? 0
        let affectedCount = mutationTargetIDs.count
#if AI_CULL
        if affectedCount == 1 {
            learnFromAutoCullDecision(groupID: selected.id, state: state)
        }
#endif
        mutateTargets { $0.pickState = state }
        if advancesAfterDecision, browserMode != .grid, affectedCount == 1 {
            focusNextAfterDecision(previousGroups: previousGroups, previousIndex: previousIndex)
        } else {
            ensureVisibleSelection(preferredIndex: previousIndex)
        }
        if previousState != state {
            let subject = affectedCount > 1 ? "\(affectedCount) 张照片" : selected.baseName
            showUndoNotice("已将 \(subject) 标记为\(state.title)")
        }
    }
    func setRating(_ rating: Int) {
        let previousIndex = displayedGroups.firstIndex { $0.id == session.selectedGroupID } ?? 0
        mutateTargets { $0.rating = min(5, max(0, rating)) }
        ensureVisibleSelection(preferredIndex: previousIndex)
    }
    func setColor(_ color: ColorLabel) {
        let previousIndex = displayedGroups.firstIndex { $0.id == session.selectedGroupID } ?? 0
        mutateTargets { $0.colorLabel = color }
        ensureVisibleSelection(preferredIndex: previousIndex)
    }

    func previewURL(for group: PhotoGroup) -> URL? { group.previewURL(for: previewMode) }

    func toggleRatingFilter(_ rating: Int) {
        var next = ratingFilters
        if next.contains(rating) { next.remove(rating) } else { next.insert(rating) }
        ratingFilters = next
        ensureVisibleSelection()
    }

    func toggleColorFilter(_ color: ColorLabel) {
        var next = colorFilters
        if next.contains(color) { next.remove(color) } else { next.insert(color) }
        colorFilters = next
        ensureVisibleSelection()
    }

    func clearFilters() {
        ratingFilters.removeAll()
        colorFilters.removeAll()
        ensureVisibleSelection()
    }

    func countForRating(_ rating: Int) -> Int {
        collectionGroups.lazy.filter { $0.rating == rating }.count
    }

    func countForColor(_ color: ColorLabel) -> Int {
        collectionGroups.lazy.filter { $0.colorLabel == color }.count
    }

    func undo() {
        guard let entries = undoStack.popLast(), let focused = entries.first else { return }
        for entry in entries {
            guard let index = session.groups.firstIndex(where: { $0.id == entry.id }) else { continue }
            session.groups[index] = entry.previous
        }
        session.selectedGroupID = focused.id
        ensureVisibleSelection()
        dismissUndoNotice()
        scheduleSave()
    }

    func showProjectHome() {
#if AI_CULL
        autoCullTask?.cancel()
        isAutoCulling = false
#endif
        if currentProjectID != nil { saveNow() }
        showsProjectHome = true
        browserMode = .grid
    }

    func continueProject(_ id: UUID) {
#if AI_CULL
        autoCullTask?.cancel()
        isAutoCulling = false
#endif
        guard let project = projects.first(where: { $0.id == id }) else {
            presentedError = "找不到这个项目记录。"
            return
        }
        guard FileManager.default.fileExists(atPath: project.sourceURL.path) else {
            presentedError = "项目的来源文件夹已经不可用：\(project.sourceURL.path)"
            return
        }
        if currentProjectID != id, currentProjectID != nil { saveNow() }
        do {
            session = try readSession(id: id)
            discardOutdatedAnalysis()
            currentProjectID = id
            try writeSession(session, id: id)
            try saveProjectIndex()
        } catch {
            presentedError = "项目读取失败：\(error.localizedDescription)"
            return
        }
        ratingFilters = []
        colorFilters = []
        multiSelectedIDs.removeAll()
        selectionAnchorID = nil
        undoStack.removeAll()
        photoCollection = .available
        browserMode = .grid
        showsProjectHome = false
        ensureVisibleSelection()
        if let id = session.selectedGroupID { loadMetadataIfNeeded(for: id) }
    }

    func renameProject(_ id: UUID, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("/") else {
            presentedError = "项目名称不能为空，也不能包含斜杠。"
            return
        }
        if id == currentProjectID {
            session.projectName = cleaned
            scheduleSave()
            return
        }
        do {
            var saved = try readSession(id: id)
            saved.projectName = cleaned
            saved.updatedAt = .now
            try writeSession(saved, id: id)
            upsertProjectSummary(id: id, session: saved)
            try saveProjectIndex()
        } catch {
            presentedError = "项目重命名失败：\(error.localizedDescription)"
        }
    }

    func removeProject(_ id: UUID) {
        guard !storageRecoveryBlocked else {
            presentedError = "项目记录读取失败，已暂停修改以保护原记录。"
            return
        }
        saveTask?.cancel()
        if currentProjectID != id, currentProjectID != nil { saveNow() }
        do {
            let file = try projectSessionURL(id: id)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            let backup = backupURL(for: file)
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            projects.removeAll { $0.id == id }
            if currentProjectID == id {
                currentProjectID = nil
                session = .empty
                multiSelectedIDs.removeAll()
                selectionAnchorID = nil
            }
            try saveProjectIndex()
        } catch {
            presentedError = "移除项目记录失败：\(error.localizedDescription)"
        }
    }

    func projectName(for id: UUID) -> String {
        projects.first(where: { $0.id == id })?.projectName ?? ""
    }

    func dismissUndoNotice() {
        undoNoticeTask?.cancel()
        undoNotice = nil
    }

    func moveSelection(by offset: Int) {
        let visible = displayedGroups
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == session.selectedGroupID } ?? 0
        let next = min(visible.count - 1, max(0, current + offset))
        session.selectedGroupID = visible[next].id
        preheatFullSizeImagesIfNeeded()
        loadMetadataIfNeeded(for: visible[next].id)
        scheduleSave()
    }

    func setDestination(_ url: URL) {
        session.destinationURL = url
        scheduleSave()
    }

    func setProjectName(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("/") else {
            presentedError = "项目名称不能为空，也不能包含斜杠。"
            return
        }
        session.projectName = cleaned
        scheduleSave()
    }

    func comparisonGroups(limit: Int) -> [PhotoGroup] {
        let visible = displayedGroups
        let explicitlySelected = visible.filter { multiSelectedIDs.contains($0.id) }
        if explicitlySelected.count >= 2 { return Array(explicitlySelected.prefix(limit)) }
        guard let currentIndex = visible.firstIndex(where: { $0.id == session.selectedGroupID }) else { return [] }
        let count = min(limit, visible.count)
        let start = min(currentIndex, max(0, visible.count - count))
        return Array(visible[start..<(start + count)])
    }

    func groupsForArchive(scope: ArchiveScope) -> [PhotoGroup] {
        switch scope {
        case .picks: pickedGroups
        case .allAvailable: availableGroups
        case .filtered: filteredAvailableGroups
        case .selected: multiSelectedAvailableGroups
        }
    }

    func estimatedBytes(for scope: ArchiveScope) -> Int64 {
        groupsForArchive(scope: scope).flatMap(\.allExistingURLs).reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func archive(scope: ArchiveScope, folderName: String) async {
        guard let source = session.sourceURL, let destination = session.destinationURL else {
            presentedError = "请选择来源和导出文件夹。"
            return
        }
        let cleanName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanName.contains("/") else {
            presentedError = "请输入不包含斜杠的导出文件夹名称。"
            return
        }

        isArchiving = true
        progressMessage = "正在预检…"
        do {
            let service = ArchiveService()
            let report = try await service.execute(
                source: source,
                destinationRoot: destination,
                projectName: cleanName,
                groups: groupsForArchive(scope: scope)
            ) { message in
                Task { @MainActor in self.progressMessage = message }
            }
            for outcome in report.outcomes {
                guard let index = session.groups.firstIndex(where: { $0.id == outcome.groupID }) else { continue }
                session.groups[index].operationState = outcome.succeeded ? .archived : .failed
                session.groups[index].errorMessage = outcome.error
            }
            archiveReport = report
            progressMessage = "导出完成"
            scheduleSave()
        } catch {
            presentedError = error.localizedDescription
            progressMessage = "导出未完成"
        }
        isArchiving = false
    }

    func revealProject(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openSelectedWithDefaultApp() {
        guard let url = selectedGroup?.rawURL ?? selectedGroup?.jpegURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var mutationTargetIDs: Set<String> {
        guard let focusedID = session.selectedGroupID else { return [] }
        if browserMode == .grid, multiSelectedIDs.contains(focusedID), multiSelectedIDs.count > 1 {
            return multiSelectedIDs
        }
        return [focusedID]
    }

    private func mutateTargets(_ change: (inout PhotoGroup) -> Void) {
        mutate(ids: mutationTargetIDs, change)
    }

    private func mutate(ids targetIDs: Set<String>, _ change: (inout PhotoGroup) -> Void) {
        guard !targetIDs.isEmpty else { return }
        let snapshot = session.groups
            .filter { targetIDs.contains($0.id) }
            .map { (id: $0.id, previous: $0) }
        undoStack.append(snapshot)
        if undoStack.count > 100 { undoStack.removeFirst() }
        for index in session.groups.indices where targetIDs.contains(session.groups[index].id) {
            change(&session.groups[index])
        }
        scheduleSave()
    }

#if AI_CULL
    private func learnFromAutoCullDecision(groupID: String, state: PickState) {
        guard let group = session.groups.first(where: { $0.id == groupID }),
              let analysis = group.analysis,
              let scene = autoCullScenes.first(where: { $0.id == analysis.sceneID })
        else { return }

        let comparison: PhotoGroup?
        let chosen: PhotoGroup?
        if state == .keep, analysis.recommendation != .recommended {
            chosen = group
            comparison = scene.groups
                .filter(\.isAutoRecommended)
                .max { ($0.analysis?.overallScore ?? 0) < ($1.analysis?.overallScore ?? 0) }
        } else if state == .reject, analysis.recommendation == .recommended {
            comparison = group
            chosen = scene.groups
                .filter { $0.id != group.id }
                .max { ($0.analysis?.overallScore ?? 0) < ($1.analysis?.overallScore ?? 0) }
        } else {
            return
        }
        guard let chosenAnalysis = chosen?.analysis,
              let baselineAnalysis = comparison?.analysis
        else { return }
        autoCullPreferenceProfile.learn(chosen: chosenAnalysis, over: baselineAnalysis)
        if let data = try? JSONEncoder().encode(autoCullPreferenceProfile) {
            UserDefaults.standard.set(data, forKey: "Yingze.AutoCullPreferenceProfile")
        }
    }
#endif

    private func focusNextAfterDecision(previousGroups: [PhotoGroup], previousIndex: Int) {
        let visible = displayedGroups
        if !visible.isEmpty {
            let previousID = previousGroups.indices.contains(previousIndex) ? previousGroups[previousIndex].id : nil
            if let previousID, let same = visible.firstIndex(where: { $0.id == previousID }) {
                let next = min(visible.count - 1, same + 1)
                focus(visible[next].id)
            } else {
                focus(visible[min(previousIndex, visible.count - 1)].id)
            }
        } else {
            session.selectedGroupID = nil
        }
    }

    private func preheatFullSizeImagesIfNeeded() {
        let visible = displayedGroups
        guard browserMode != .grid,
              let current = visible.firstIndex(where: { $0.id == session.selectedGroupID })
        else { return }
        let neighborIndices = previewMode == .original ? [current] : [current, current + 1, current - 1]
        let indices = neighborIndices.filter { visible.indices.contains($0) }
        let urls = indices.compactMap { previewURL(for: visible[$0]) }
        Task(priority: .utility) {
            for url in urls {
                if Task.isCancelled { return }
                _ = await ImageCache.shared.image(for: url, maxPixelSize: previewMode.previewPixelSize)
            }
        }
    }

    private func loadMetadataIfNeeded(for id: String) {
        guard !metadataLoadingIDs.contains(id),
              let group = session.groups.first(where: { $0.id == id }),
              !group.hasCaptureMetadata
        else { return }
        metadataLoadingIDs.insert(id)
        Task {
            let enriched = await Task.detached(priority: .utility) {
                PhotoMetadataReader.enrich(group)
            }.value
            metadataLoadingIDs.remove(id)
            guard enriched.hasCaptureMetadata,
                  let index = session.groups.firstIndex(where: { $0.id == id })
            else { return }
            session.groups[index] = enriched
            scheduleSave()
        }
    }

    private func ensureVisibleSelection(preferredIndex: Int = 0) {
        let visible = displayedGroups
        guard !visible.isEmpty else {
            session.selectedGroupID = nil
            return
        }
        if let selectedID = session.selectedGroupID, visible.contains(where: { $0.id == selectedID }) { return }
        session.selectedGroupID = visible[min(max(0, preferredIndex), visible.count - 1)].id
        multiSelectedIDs = multiSelectedIDs.intersection(Set(session.groups.map(\.id)))
        preheatFullSizeImagesIfNeeded()
    }

    private func showUndoNotice(_ message: String) {
        undoNoticeTask?.cancel()
        undoNotice = message
        undoNoticeTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            undoNotice = nil
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        guard let id = currentProjectID, session.sourceURL != nil else { return }
        session.updatedAt = .now
        do {
            try writeSession(session, id: id)
            upsertProjectSummary(id: id, session: session)
            try saveProjectIndex()
        } catch {
            presentedError = "会话保存失败：\(error.localizedDescription)"
        }
    }

    private func loadSavedSession() {
        do {
            let indexURL = try projectIndexURL()
            if FileManager.default.fileExists(atPath: indexURL.path) || FileManager.default.fileExists(atPath: backupURL(for: indexURL).path) {
                let index: ProjectIndex = try readProtected(ProjectIndex.self, from: indexURL, notify: true)
                projects = index.projects.sorted { $0.updatedAt > $1.updatedAt }
                currentProjectID = index.currentProjectID
                if let id = currentProjectID, projects.contains(where: { $0.id == id }) {
                    session = try readSession(id: id)
                } else if let first = projects.first {
                    currentProjectID = first.id
                    session = try readSession(id: first.id)
                }
                discardOutdatedAnalysis()
                refreshProjectSummariesFromSessions()
                return
            }
            try migrateLegacySessionIfNeeded()
        } catch {
            storageRecoveryBlocked = true
            session = .empty
            currentProjectID = nil
            presentedError = "项目记录读取失败，已暂停写入以保护原记录。请保留 Application Support/CameraCull 文件夹并检查或恢复记录。\n\(error.localizedDescription)"
        }
    }

    private func migrateLegacySessionIfNeeded() throws {
        let legacyURL = try supportDirectory().appendingPathComponent("CurrentSession.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        let data = try Data(contentsOf: legacyURL)
        let legacy = try JSONDecoder.sessionDecoder.decode(CullSession.self, from: data)
        guard legacy.sourceURL != nil else { return }
        let id = UUID()
        session = legacy
        discardOutdatedAnalysis()
        currentProjectID = id
        try writeSession(session, id: id)
        upsertProjectSummary(id: id, session: session)
        try saveProjectIndex()
    }

    private func refreshProjectSummariesFromSessions() {
        var changed = false
        for index in projects.indices {
            guard let saved = try? readSession(id: projects[index].id, notify: false) else { continue }
            let refreshed = ProjectSummary(id: projects[index].id, session: saved)
            if projects[index] != refreshed {
                projects[index] = refreshed
                changed = true
            }
        }
        if changed {
            projects.sort { $0.updatedAt > $1.updatedAt }
            try? saveProjectIndex()
        }
    }

    private func discardOutdatedAnalysis() {
        for index in session.groups.indices
        where session.groups[index].analysis?.modelVersion != PhotoAnalysis.currentModelVersion {
            session.groups[index].analysis = nil
        }
    }

    private func upsertProjectSummary(id: UUID, session: CullSession) {
        guard session.sourceURL != nil else { return }
        let summary = ProjectSummary(id: id, session: session)
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index] = summary
        } else {
            projects.append(summary)
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    private func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("backup")
    }

    private func readProtected<T: Decodable>(_ type: T.Type, from url: URL, notify: Bool) throws -> T {
        do {
            return try JSONDecoder.sessionDecoder.decode(type, from: Data(contentsOf: url))
        } catch {
            let originalError = error
            do {
                let value = try JSONDecoder.sessionDecoder.decode(type, from: Data(contentsOf: backupURL(for: url)))
                if notify {
                    presentedError = "项目记录无法正常读取，已从上一次备份恢复。备份可能不包含最近的修改；原记录仍保留，建议检查选片结果。"
                }
                return value
            } catch {
                throw originalError
            }
        }
    }

    private func writeProtected<T: Codable>(_ value: T, to url: URL) throws {
        guard !storageRecoveryBlocked else {
            throw NSError(domain: "CameraCull.ProjectStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "项目记录读取失败，已暂停写入以保护原记录。"])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.sessionEncoder.encode(value)
        let backup = backupURL(for: url)
        if FileManager.default.fileExists(atPath: url.path) {
            let oldData = try Data(contentsOf: url)
            if (try? JSONDecoder.sessionDecoder.decode(T.self, from: oldData)) != nil {
                try oldData.write(to: backup, options: .atomic)
            } else {
                // Preserve a damaged original separately and never replace a valid backup with it.
                let damaged = url.appendingPathExtension("damaged-\(UUID().uuidString)")
                try oldData.write(to: damaged, options: .atomic)
            }
        } else if !FileManager.default.fileExists(atPath: backup.path) {
            try data.write(to: backup, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }

    private func readSession(id: UUID, notify: Bool = true) throws -> CullSession {
        try readProtected(CullSession.self, from: projectSessionURL(id: id), notify: notify)
    }

    private func writeSession(_ value: CullSession, id: UUID) throws {
        try writeProtected(value, to: projectSessionURL(id: id))
    }

    private func saveProjectIndex() throws {
        let index = ProjectIndex(currentProjectID: currentProjectID, projects: projects)
        try writeProtected(index, to: projectIndexURL())
    }

    private func supportDirectory() throws -> URL {
        if let storageDirectoryOverride { return storageDirectoryOverride }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("CameraCull", isDirectory: true)
    }

    private func projectIndexURL() throws -> URL {
        try supportDirectory().appendingPathComponent("Projects.json")
    }

    private func projectSessionURL(id: UUID) throws -> URL {
        try supportDirectory()
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    private func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path.caseInsensitiveCompare(rhs.standardizedFileURL.path) == .orderedSame
    }

}

private extension JSONEncoder {
    static var sessionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var sessionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
