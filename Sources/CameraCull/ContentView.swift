import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    @State private var showingArchive = false
    @State private var showingRenameProject = false
    @State private var renameDraft = ""
    @State private var renameProjectID: UUID?
    @State private var projectPendingRemoval: ProjectSummary?
    @State private var pendingNewProject: NewProjectRequest?

    var body: some View {
        Group {
            if store.showsProjectHome {
                projectHome
            } else {
                workspace
            }
        }
        .background(KeyboardShortcutMonitor(store: store, settings: shortcutSettings).frame(width: 0, height: 0))
        .overlay(alignment: .top) {
            if let notice = store.undoNotice {
                UndoNoticeView(message: notice)
                    .padding(.top, store.showsProjectHome ? 18 : 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.undoNotice)
        .frame(minWidth: 940, minHeight: 620)
        .toolbar { toolbar }
        .alert("影择", isPresented: errorBinding) {
            Button("好", role: .cancel) { store.presentedError = nil }
        } message: {
            Text(store.presentedError ?? "")
        }
        .sheet(isPresented: $showingArchive) { ArchiveConfirmationView() }
        .sheet(item: $store.archiveReport) { report in ArchiveReportView(report: report) }
        .sheet(isPresented: $store.showingShortcutHelp) { ShortcutHelpView() }
        .sheet(item: $pendingNewProject) { request in
            NewProjectView(sourceURL: request.sourceURL) { projectName in
                store.openSource(request.sourceURL, projectName: projectName)
                pendingNewProject = nil
            }
        }
        .sheet(isPresented: $showingRenameProject) {
            ProjectRenameView(name: $renameDraft) {
                if let id = renameProjectID {
                    store.renameProject(id, to: renameDraft)
                }
                showingRenameProject = false
            }
        }
        .confirmationDialog(
            "移除项目记录？",
            isPresented: Binding(
                get: { projectPendingRemoval != nil },
                set: { if !$0 { projectPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: projectPendingRemoval
        ) { project in
            Button("移除“\(project.projectName)”", role: .destructive) {
                store.removeProject(project.id)
                projectPendingRemoval = nil
            }
            Button("取消", role: .cancel) { projectPendingRemoval = nil }
        } message: { _ in
            Text("只删除影择中的选片会话，不会删除或修改来源照片。")
        }
    }

    private var projectHome: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 72, height: 72)
                Text("影择").font(.title.bold())
                Text("摄影选片与导出").foregroundStyle(.secondary)
                Divider()
                Button(action: chooseSource) {
                    Label("打开照片文件夹…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .appButton(.primary, controlSize: .large)
                Spacer()
                Button { store.showingShortcutHelp = true } label: {
                    Label("快捷键帮助", systemImage: "keyboard")
                }
                .appButton(.quiet)
            }
            .padding(28)
            .frame(width: 250)
            .background(.regularMaterial)

            VStack(alignment: .leading, spacing: 22) {
                Text("项目").font(.largeTitle.bold())
                Text("继续已有项目，或者打开新的照片文件夹。")
                    .foregroundStyle(.secondary)
                if store.projects.isEmpty {
                    ContentUnavailableView("还没有项目", systemImage: "photo.stack", description: Text("打开一个包含 JPG、HEIC/HEIF 或 RAW 的文件夹开始选片。"))
                        .frame(maxWidth: 760, maxHeight: 300)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(store.projects) { project in
                                HStack(spacing: 10) {
                                    Button { store.continueProject(project.id) } label: {
                                        HStack(spacing: 16) {
                                            ProjectCoverStack(urls: project.coverURLs ?? [])
                                            VStack(alignment: .leading, spacing: 6) {
                                                HStack(spacing: 8) {
                                                    Text(project.projectName.isEmpty ? project.sourceURL.lastPathComponent : project.projectName)
                                                        .font(.title3.bold())
                                                        .lineLimit(1)
                                                        .truncationMode(.tail)
                                                    if !FileManager.default.fileExists(atPath: project.sourceURL.path) {
                                                        Label("来源不可用", systemImage: "exclamationmark.triangle.fill")
                                                            .font(.caption).foregroundStyle(.orange)
                                                            .fixedSize()
                                                    }
                                                }
                                                Text(project.sourceURL.path)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                    .foregroundStyle(.secondary)
                                                Text("\(project.groupCount) 组照片 · 精选 \(project.pickedCount ?? 0) · 未决定 \(max(0, project.availableCount - (project.pickedCount ?? 0))) · 废片 \(project.rejectCount)")
                                                    .font(.caption.monospacedDigit())
                                                    .lineLimit(1)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(project.updatedAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.tertiary)
                                                .fixedSize()
                                            Image(systemName: "chevron.right")
                                                .font(.caption.bold())
                                                .foregroundStyle(.secondary)
                                                .fixedSize()
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .layoutPriority(1)
                                    .help("继续这个项目")
                                    Button { beginProjectRename(project.id) } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .appIconButton(compact: true)
                                    .fixedSize()
                                    .help("重命名这个项目")
                                    Menu {
                                        Button("移除项目记录…", role: .destructive) {
                                            projectPendingRemoval = project
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle").frame(width: 28, height: 28)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .fixedSize()
                                    .help("更多项目操作")
                                }
                                .padding(18)
                                .frame(maxWidth: 860, minHeight: 112)
                                .background(
                                    Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color(nsColor: .separatorColor).opacity(0.45))
                                )
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            switch store.browserMode {
            case .grid: PhotoGridView()
            case .single: SinglePhotoView()
            case .compare: ComparePhotosView()
            case .survey: ComparePhotosView()
            }
            Divider()
            actionBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 18) {
            Picker("照片分类", selection: $store.photoCollection) {
                ForEach(PhotoCollection.allCases, id: \.self) { collection in
                    Text(collection.title).tag(collection)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            Label("可用 \(store.availableGroups.count)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Label("废片 \(store.counts.reject)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            if store.multiSelectedIDs.count > 1 {
                Label("临时多选 \(store.multiSelectedIDs.count)", systemImage: "square.stack.3d.up.fill")
                    .foregroundStyle(.blue)
            }
            PhotoFilterButton()
            if store.browserMode == .grid {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.grid.3x3")
                        .foregroundStyle(.secondary)
                    Slider(value: $store.gridThumbnailSize, in: 130...300, step: 10)
                        .frame(width: 110)
                        .accessibilityLabel("网格大小")
                    Image(systemName: "rectangle.grid.2x2")
                        .foregroundStyle(.secondary)
                    Button {
                        store.fillsGridThumbnails.toggle()
                    } label: {
                        Image(systemName: store.fillsGridThumbnails ? "rectangle.inset.filled" : "rectangle")
                    }
                    .appIconButton(compact: true)
                    .accessibilityLabel(store.fillsGridThumbnails ? "缩略图填满" : "完整显示照片")
                    .help(store.fillsGridThumbnails ? "当前填满缩略图；点击改为完整显示" : "当前完整显示；点击改为填满缩略图")
                }
                .help("调整网格缩略图大小")
            }
            Spacer()
            if store.isIndexing || store.isArchiving { ProgressView().controlSize(.small) }
            Text(store.progressMessage).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                Button { store.moveSelection(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .appIconButton()
                .accessibilityLabel("上一张")
                .help("上一张（\(shortcutSettings.binding(for: .previous).displayText)）")
                Button { store.moveSelection(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .appIconButton()
                .accessibilityLabel("下一张")
                .help("下一张（\(shortcutSettings.binding(for: .next).displayText)）")
            }
            .fixedSize(horizontal: true, vertical: false)
            if store.browserMode == .grid {
                Divider().frame(height: 24)
                HStack(spacing: 2) {
                    Button { store.selectAllDisplayed() } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .appIconButton()
                    .accessibilityLabel("全选结果")
                    .disabled(store.displayedGroups.isEmpty)
                    .help("临时选择当前显示的全部照片")
                    Button { store.clearSelection() } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .appIconButton()
                    .accessibilityLabel("清除选择")
                    .disabled(store.multiSelectedIDs.isEmpty)
                    .help("清除临时多选；Command 点选可多选，Shift 点选可连选")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            Divider().frame(height: 24)
            HStack(spacing: 2) {
                Button { store.setPickState(.keep) } label: {
                    Label("精选", systemImage: "checkmark.circle.fill")
                }
                .appButton(store.selectedGroup?.pickState == .keep ? .secondary : .quiet)
                .foregroundStyle(.green)
                .help("标记为精选（\(shortcutSettings.binding(for: .pick).displayText)）")
                Button { store.setPickState(.undecided) } label: {
                    Label("未决定", systemImage: "circle.dotted")
                }
                .appButton(store.selectedGroup?.pickState == .undecided ? .secondary : .quiet)
                .help("恢复为未决定（\(shortcutSettings.binding(for: .restore).displayText)）")
                Button(role: .destructive) { store.setPickState(.reject) } label: {
                    Label("淘汰", systemImage: "xmark.circle.fill")
                }
                .appButton(store.selectedGroup?.pickState == .reject ? .secondary : .quiet)
                .foregroundStyle(.red)
                .help("标记为淘汰（\(shortcutSettings.binding(for: .reject).displayText)）")
            }
            .fixedSize(horizontal: true, vertical: false)
            Divider().frame(height: 24)
            RatingPicker(rating: store.selectedGroup?.rating ?? 0, onSelect: store.setRating)
            Divider().frame(height: 24)
            ColorLabelButtons(selected: store.selectedGroup?.colorLabel ?? .none, onSelect: store.setColor)
            Spacer()
            if let selected = store.selectedGroup {
                Text(selected.baseName).font(.headline)
                PickBadge(state: selected.pickState)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .controlSize(.regular)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if !store.showsProjectHome {
                Button(action: store.showProjectHome) { Label("项目", systemImage: "rectangle.stack") }
                    .help("返回项目首页")
                Picker("显示方式", selection: $store.browserMode) {
                    ForEach(BrowserMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .help("切换网格、单张、双图或多图视图（G / E / C / N）")
                Button { if let id = store.currentProjectID { beginProjectRename(id) } } label: {
                    Label(store.session.projectName, systemImage: "pencil")
                }
                .help("重命名当前项目；导出时默认使用这个文件夹名称")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !store.showsProjectHome {
                Menu {
                    ForEach(PreviewMode.allCases) { mode in
                        Button {
                            store.previewMode = mode
                        } label: {
                            if mode == store.previewMode {
                                Label("\(mode.title) · \(mode.detail)", systemImage: "checkmark")
                            } else {
                                Label("\(mode.title) · \(mode.detail)", systemImage: mode.icon)
                            }
                        }
                    }
                } label: {
                    Label(store.previewMode.title, systemImage: store.previewMode.icon)
                }
                .help("当前为\(store.previewMode.title)预览；在速度与 RAW 画质之间切换")
                ControlGroup {
                    Button { store.refreshProject() } label: {
                        Label("刷新项目", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isIndexing || store.isArchiving)
                    .help("重新扫描来源文件夹；保留精选、废片、星级和颜色")
                    Button { store.undo() } label: {
                        Label("撤销", systemImage: "arrow.uturn.backward")
                    }
                    .help("撤销最近一次评分、颜色或去留操作（\(shortcutSettings.binding(for: .undo).displayText)）")
                }
                Button { store.openSelectedWithDefaultApp() } label: { Label("打开方式", systemImage: "arrow.up.forward.app") }
                    .disabled(store.selectedGroup == nil)
                    .help("使用 macOS 默认关联应用打开当前照片")
                Button { store.showingShortcutHelp = true } label: { Label("快捷键帮助", systemImage: "questionmark.circle") }
                    .help("查看并自定义影择的全部快捷键")
                Button { showingArchive = true } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                    .appButton(.primary)
                    .disabled(store.groups.isEmpty || store.isArchiving)
                    .help("把最终精选、未淘汰照片、筛选结果或临时多选复制到新文件夹")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.presentedError != nil }, set: { if !$0 { store.presentedError = nil } })
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "选择照片来源文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let projectID = store.existingProjectID(for: url) {
            store.continueProject(projectID)
        } else {
            pendingNewProject = NewProjectRequest(sourceURL: url)
        }
    }

    private func beginProjectRename(_ id: UUID) {
        renameProjectID = id
        renameDraft = store.projectName(for: id)
        showingRenameProject = true
    }
}

private struct NewProjectRequest: Identifiable {
    let id = UUID()
    let sourceURL: URL
}

private struct ProjectCoverStack: View {
    let urls: [URL]

    var body: some View {
        ZStack {
            if urls.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 72, height: 72)
                    .overlay {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
            } else {
                ForEach(Array(urls.prefix(3).enumerated()), id: \.element.path) { index, url in
                    ProjectCoverImage(url: url)
                        .frame(width: 66, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(.white.opacity(0.78), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .rotationEffect(rotation(for: index, count: min(3, urls.count)))
                        .offset(offset(for: index, count: min(3, urls.count)))
                }
            }
        }
        .frame(width: 82, height: 76)
        .accessibilityHidden(true)
    }

    private func rotation(for index: Int, count: Int) -> Angle {
        guard count > 1 else { return .zero }
        if count == 2 { return .degrees(index == 0 ? -5 : 4) }
        return [.degrees(-6), .degrees(5), .zero][index]
    }

    private func offset(for index: Int, count: Int) -> CGSize {
        guard count > 1 else { return .zero }
        if count == 2 { return CGSize(width: index == 0 ? -5 : 5, height: 2) }
        return [
            CGSize(width: -7, height: 3),
            CGSize(width: 7, height: 4),
            CGSize(width: 0, height: -1)
        ][index]
    }
}

private struct ProjectCoverImage: View {
    let url: URL
    @State private var image: NSImage?
    @State private var finishedLoading = false

    var body: some View {
        ZStack {
            Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if finishedLoading {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: url.path) {
            finishedLoading = false
            image = await ImageCache.shared.image(for: url, maxPixelSize: 640)
            finishedLoading = true
        }
    }
}

private struct PhotoFilterButton: View {
    @EnvironmentObject private var store: SessionStore
    @State private var showingFilters = false

    var body: some View {
        Button {
            showingFilters.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: store.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                Text(store.hasActiveFilters ? "筛选 \(store.activeFilterCount)" : "筛选")
                if store.hasActiveFilters {
                    Text("\(store.displayedGroups.count)/\(store.collectionGroups.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .appButton(.secondary)
        .tint(store.hasActiveFilters ? .accentColor : nil)
        .help("按照星级和颜色标签筛选照片")
        .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
            PhotoFilterPanel()
        }
    }
}

private struct PhotoFilterPanel: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("筛选照片").font(.headline)
                    Text("显示 \(store.displayedGroups.count) / \(store.collectionGroups.count) 张")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("清除全部") { store.clearFilters() }
                    .appButton(.quiet, controlSize: .small)
                    .disabled(!store.hasActiveFilters)
            }

            Divider()
            Text("星级").font(.caption.bold()).foregroundStyle(.secondary)
            VStack(spacing: 3) {
                ForEach(0...5, id: \.self) { rating in
                    Button { store.toggleRatingFilter(rating) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: store.ratingFilters.contains(rating) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(store.ratingFilters.contains(rating) ? Color.accentColor : .secondary)
                            if rating == 0 {
                                Label("无星级", systemImage: "star.slash")
                                    .foregroundStyle(.primary)
                            } else {
                                HStack(spacing: 2) {
                                    ForEach(1...5, id: \.self) { value in
                                        Image(systemName: value <= rating ? "star.fill" : "star")
                                            .foregroundStyle(
                                                value <= rating
                                                    ? Color.yellow
                                                    : Color.secondary.opacity(0.42)
                                            )
                                    }
                                }
                                Text("\(rating) 星").foregroundStyle(.primary)
                            }
                            Spacer()
                            Text("\(store.countForRating(rating))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(store.ratingFilters.contains(rating) ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            Text("颜色标签").font(.caption.bold()).foregroundStyle(.secondary)
            VStack(spacing: 3) {
                ForEach(ColorLabel.allCases, id: \.self) { label in
                    Button { store.toggleColorFilter(label) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: store.colorFilters.contains(label) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(store.colorFilters.contains(label) ? Color.accentColor : .secondary)
                            if label == .none {
                                Image(systemName: "circle.slash").foregroundStyle(.secondary)
                            } else {
                                Circle().fill(color(for: label)).frame(width: 13, height: 13)
                            }
                            Text(label.title).foregroundStyle(.primary)
                            Spacer()
                            Text("\(store.countForColor(label))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(store.colorFilters.contains(label) ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            Label("同一分类内满足任一条件；星级与颜色之间需同时满足。", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 350)
    }
}

private struct PhotoGridView: View {
    @EnvironmentObject private var store: SessionStore
    private var columns: [GridItem] {
        let width = CGFloat(store.gridThumbnailSize)
        return [GridItem(.adaptive(minimum: width, maximum: width * 1.15), spacing: 10)]
    }

    var body: some View {
        Group {
            if store.displayedGroups.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: store.hasActiveFilters ? "line.3.horizontal.decrease.circle" : store.photoCollection.icon,
                    description: Text(emptyDescription)
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(store.displayedGroups) { group in
                                PhotoCard(
                                    group: group,
                                    selected: store.multiSelectedIDs.contains(group.id),
                                    focused: group.id == store.session.selectedGroupID,
                                    thumbnailHeight: CGFloat(store.gridThumbnailSize) * 0.75
                                )
                                    .id(group.id)
                                    .gesture(photoClickGesture(for: group))
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: store.session.selectedGroupID) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        if store.hasActiveFilters { return "没有符合筛选条件的照片" }
        switch store.photoCollection {
        case .available: return "没有可选照片"
        case .rejected: return "废片区是空的"
        }
    }

    private var emptyDescription: String {
        if store.hasActiveFilters { return "调整星级或颜色条件，或者清除筛选。" }
        switch store.photoCollection {
        case .available: return "打开或刷新照片文件夹后，未淘汰的照片会显示在这里。"
        case .rejected: return "按 X 淘汰的照片会显示在这里，来源文件始终保持不动。"
        }
    }

    private func photoClickGesture(for group: PhotoGroup) -> some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { click in
                switch click {
                case .first:
                    store.selectPhotos(group.id)
                    store.browserMode = .single
                case .second:
                    let modifiers = NSEvent.modifierFlags
                    if modifiers.contains(.command) || modifiers.contains(.shift) {
                        store.selectPhotos(
                            group.id,
                            toggling: modifiers.contains(.command),
                            extendingRange: modifiers.contains(.shift)
                        )
                    } else {
                        store.selectPhotos(group.id)
                    }
                }
            }
    }
}

private struct PhotoCard: View {
    @EnvironmentObject private var store: SessionStore
    let group: PhotoGroup
    let selected: Bool
    let focused: Bool
    let thumbnailHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                PhotoImage(
                    url: store.previewURL(for: group),
                    maxPixelSize: store.previewMode.thumbnailPixelSize,
                    displayMode: store.fillsGridThumbnails ? .fill : .fit
                )
                    .frame(height: thumbnailHeight)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.85))
                    .clipped()
                HStack(spacing: 5) {
                    Button {
                        store.selectPhotos(group.id, toggling: true)
                    } label: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : Color.white.opacity(0.88))
                            .font(.title2.weight(.semibold))
                            .background(.black.opacity(selected ? 0.48 : 0.58), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(selected ? "从临时多选中移除" : "加入临时多选")
                    if group.hasPairingConflict {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                            .help(group.pairingConflictText)
                    }
                }
                .padding(7)
            }
            HStack {
                Text(group.baseName).lineLimit(1).font(.callout.weight(.medium))
                Spacer()
                PickBadge(state: group.pickState)
            }
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { value in
                    Image(systemName: value <= group.rating ? "star.fill" : "star")
                        .foregroundStyle(
                            value <= group.rating
                                ? Color.yellow
                                : Color.secondary.opacity(0.42)
                        )
                }
                Spacer()
                Circle().fill(color(for: group.colorLabel)).frame(width: 10, height: 10)
            }
            .font(.caption2)
        }
        .padding(7)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(cardBorderColor, lineWidth: cardBorderWidth)
        )
        .shadow(color: focused ? Color.accentColor.opacity(0.22) : .clear, radius: 3)
    }

    private var cardBackground: Color {
        if selected { return Color.accentColor.opacity(focused ? 0.18 : 0.12) }
        if focused { return Color.accentColor.opacity(0.07) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var cardBorderColor: Color {
        if focused { return .accentColor }
        if selected { return Color.accentColor.opacity(0.72) }
        return Color(nsColor: .separatorColor).opacity(0.48)
    }

    private var cardBorderWidth: CGFloat {
        if focused { return 3 }
        if selected { return 2 }
        return 1
    }
}

private struct SinglePhotoView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var scale = 1.0
    @State private var offset = CGSize.zero

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    ZStack {
                        Color.black
                        if let group = store.selectedGroup {
                            let actualScale = focusScale(for: group, viewport: geometry.size)
                            ZoomablePhoto(
                                url: store.previewURL(for: group),
                                maxPixelSize: isActualPixels(actualScale) ? 0 : store.previewMode.previewPixelSize,
                                scale: $scale,
                                offset: $offset,
                                onDoubleClick: { toggleActualPixels(actualScale) }
                            )
                            VStack {
                                HStack {
                                    Button {
                                        toggleActualPixels(actualScale)
                                    } label: {
                                        Text("\(store.previewMode.title) · \(group.previewFormat(for: store.previewMode) ?? "未知") · \(zoomText(actualScale))")
                                    }
                                    .buttonStyle(PreviewOverlayCapsuleStyle())
                                    .help(previewCapsuleHelp(actualScale))
                                    Spacer()
                                    if let summary = group.captureSummary {
                                        PreviewMetadataCapsule(text: summary)
                                            .help("当前照片的快门、光圈、感光度和焦段")
                                    }
                                }
                                Spacer()
                            }
                            .padding(12)
                        } else {
                            ContentUnavailableView("没有照片", systemImage: "photo")
                        }
                    }
                }
                Divider()
                PreviewFilmstrip()
            }
            .frame(minWidth: 520)

            if let group = store.selectedGroup {
                PreviewInspector(group: group)
                    .frame(minWidth: 250, idealWidth: 285, maxWidth: 340)
            }
        }
        .onChange(of: store.session.selectedGroupID) { _, _ in scale = 1; offset = .zero }
    }

    private func focusScale(for group: PhotoGroup, viewport: CGSize) -> Double {
        FocusZoom.scale(
            pixelWidth: group.pixelWidth,
            pixelHeight: group.pixelHeight,
            viewportWidth: viewport.width,
            viewportHeight: viewport.height,
            backingScale: Double(NSScreen.main?.backingScaleFactor ?? 2)
        )
    }

    private func isActualPixels(_ actualScale: Double) -> Bool {
        actualScale > 1.001 && abs(scale - actualScale) < 0.015
    }

    private func zoomText(_ actualScale: Double) -> String {
        if isActualPixels(actualScale) { return "100%" }
        if scale <= 1.001 { return "适合窗口" }
        return "\(Int((scale / actualScale) * 100))%"
    }

    private func previewCapsuleHelp(_ actualScale: Double) -> String {
        let current = "当前为\(store.previewMode.title)模式，读取\(store.selectedGroup?.previewFormat(for: store.previewMode) ?? "未知格式")，\(zoomText(actualScale))显示"
        let action = isActualPixels(actualScale) ? "点击恢复适合窗口" : "点击切换到原始像素 100%"
        return "\(current)；\(action)。也可以双击照片切换"
    }

    private func toggleActualPixels(_ actualScale: Double) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if isActualPixels(actualScale) {
                scale = 1
                offset = .zero
            } else {
                scale = actualScale
                offset = .zero
            }
        }
    }
}

private struct PreviewFilmstrip: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 7) {
                    ForEach(store.displayedGroups) { group in
                        VStack(spacing: 4) {
                            PhotoImage(url: store.previewURL(for: group), maxPixelSize: min(1_024, store.previewMode.thumbnailPixelSize))
                                .frame(width: 104, height: 70)
                                .background(.black)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            HStack(spacing: 4) {
                                Circle().fill(color(for: group.colorLabel)).frame(width: 7, height: 7)
                                Text(group.baseName).lineLimit(1)
                                if group.rating > 0 { Text("★\(group.rating)").foregroundStyle(.yellow) }
                            }
                            .font(.caption2)
                        }
                        .foregroundStyle(.primary)
                        .padding(6)
                        .background(
                            group.id == store.session.selectedGroupID
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    group.id == store.session.selectedGroupID
                                        ? Color.accentColor
                                        : Color(nsColor: .separatorColor).opacity(0.25),
                                    lineWidth: group.id == store.session.selectedGroupID ? 2 : 1
                                )
                        }
                        .id(group.id)
                        .onTapGesture { store.focus(group.id) }
                    }
                }
                .padding(8)
            }
            .frame(height: 112)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) { Divider() }
            .task {
                await Task.yield()
                if let id = store.session.selectedGroupID {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: store.session.selectedGroupID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

private struct PreviewInspector: View {
    @EnvironmentObject private var store: SessionStore
    let group: PhotoGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("预览").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(group.baseName).font(.title3.bold()).textSelection(.enabled)
                    Text(positionText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }

                PickStateControl(state: group.pickState, onSelect: store.setPickState)
                Toggle("作出决定后自动前进", isOn: $store.advancesAfterDecision)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                inspectorSection("星级") {
                    RatingPicker(rating: group.rating, onSelect: store.setRating)
                        .font(.title3)
                }

                inspectorSection("颜色标签") {
                    ColorLabelStrip(selected: group.colorLabel, onSelect: store.setColor)
                }

                inspectorSection("拍摄参数") {
                    if group.hasCaptureMetadata {
                        metadataLine("快门", value: group.shutterText)
                        metadataLine("光圈", value: group.apertureText)
                        metadataLine("感光度", value: group.isoText)
                        metadataLine("焦段", value: group.focalLengthText)
                        metadataLine("拍摄时间", value: captureDateText)
                        metadataLine("尺寸", value: group.displayDimensions)
                        metadataLine("相机", value: group.cameraText)
                        metadataLine("镜头", value: group.lensModel)
                    } else {
                        Label("没有可读取的 EXIF 拍摄数据", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                inspectorSection("照片组") {
                    fileLine("JPG", url: group.jpegURL)
                    fileLine("HEIC", url: group.heicURL)
                    fileLine(group.rawURL?.pathExtension.uppercased() ?? "RAW", url: group.rawURL)
                    fileLine("XMP", url: group.xmpURL)
                    if group.renderedPreviewURL == nil, group.rawURL != nil {
                        Label("RAW 单文件，可正常选片与导出", systemImage: "camera.aperture")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if group.rawURL == nil, group.renderedPreviewURL != nil {
                        Label("成片单文件，可正常选片与导出", systemImage: "photo")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if group.hasPairingConflict {
                        Label(group.pairingConflictText, systemImage: "exclamationmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }

                inspectorSection("预览模式") {
                    Picker("预览模式", selection: $store.previewMode) {
                        ForEach(PreviewMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .labelsHidden()
                    Text(store.previewMode.detail).font(.caption).foregroundStyle(.secondary)
                    if let format = group.previewFormat(for: store.previewMode) {
                        Label("当前读取 \(format)", systemImage: group.rawURL == group.previewURL(for: store.previewMode) ? "camera.aperture" : "photo")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .background(.regularMaterial)
    }

    private var positionText: String {
        let visible = store.displayedGroups
        let index = (visible.firstIndex { $0.id == group.id } ?? 0) + 1
        return "第 \(index) 张，共 \(visible.count) 张"
    }

    private var captureDateText: String? {
        group.captureDate?.formatted(date: .numeric, time: .standard)
    }

    private func metadataLine(_ title: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            Text(value ?? "—").textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func fileLine(_ kind: String, url: URL?) -> some View {
        HStack {
            Text(kind).font(.caption.bold()).frame(width: 34, alignment: .leading)
            Text(url?.lastPathComponent ?? "缺少").lineLimit(1).truncationMode(.middle)
            Spacer()
            if let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

private struct ComparePhotosView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var synchronizesZoom = true
    @State private var sharedScale = 1.0
    @State private var sharedOffset = CGSize.zero
    @State private var individualScales: [String: Double] = [:]
    @State private var individualOffsets: [String: CGSize] = [:]

    var body: some View {
        let isSurvey = store.browserMode == .survey
        let groups = store.comparisonGroups(limit: isSurvey ? store.surveyLimit : 2)
        VStack(spacing: 0) {
            compareToolbar(groups: groups, isSurvey: isSurvey)
            Divider().overlay(.white.opacity(0.12))
            if groups.count < 2 {
                ContentUnavailableView(
                    "至少需要两张照片",
                    systemImage: isSurvey ? "rectangle.grid.2x2" : "rectangle.split.2x1",
                    description: Text(isSurvey ? "临时多选多张照片，或从当前照片开始查看接下来的同组候选。" : "选择当前照片后，会自动与下一张进行双图比较。")
                )
            } else {
                GeometryReader { geometry in
                    let columnCount = isSurvey && store.surveyLimit == 9 ? 3 : 2
                    let rowCount = Int(ceil(Double(groups.count) / Double(columnCount)))
                    let tileHeight = max(120, (geometry.size.height - CGFloat(max(0, rowCount - 1)) * 5) / CGFloat(rowCount))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: columnCount), spacing: 5) {
                        ForEach(groups) { group in
                            comparisonTile(group)
                                .frame(height: tileHeight)
                        }
                    }
                }
                .padding(5)
            }
            compareZoomBar(groups: groups)
        }
        .background(Color.black.opacity(0.94))
    }

    private func compareToolbar(groups: [PhotoGroup], isSurvey: Bool) -> some View {
        HStack(spacing: 14) {
            Label(
                "\(isSurvey ? "多图选别" : "双图比较") · \(store.previewMode.title)",
                systemImage: isSurvey ? "rectangle.grid.2x2" : "rectangle.split.2x1"
            )
                .font(.headline)
            Text("\(groups.count) 张")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if isSurvey {
                Picker("选别数量", selection: $store.surveyLimit) {
                    Text("4 张").tag(4)
                    Text("9 张").tag(9)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 130)
                .help("选择同时选别 4 或 9 张照片")
            }
            Toggle("决定后前进", isOn: $store.advancesAfterDecision)
                .toggleStyle(.checkbox)
            Toggle("同步缩放", isOn: $synchronizesZoom)
                .toggleStyle(.switch)
                .help("开启后，所有照片使用相同的缩放比例和位置")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.black.opacity(0.42))
        .onChange(of: synchronizesZoom) { _, enabled in
            guard enabled, let selectedID = store.session.selectedGroupID else { return }
            sharedScale = individualScales[selectedID] ?? sharedScale
            sharedOffset = individualOffsets[selectedID] ?? sharedOffset
        }
    }

    private func comparisonTile(_ group: PhotoGroup) -> some View {
        ZStack {
            Color.black
            ZoomablePhoto(
                url: store.previewURL(for: group),
                maxPixelSize: store.previewMode.previewPixelSize,
                scale: scaleBinding(for: group.id),
                offset: offsetBinding(for: group.id)
            )
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Circle().fill(color(for: group.colorLabel)).frame(width: 9, height: 9)
                    Text(group.baseName).lineLimit(1)
                    if group.rating > 0 {
                        Text(String(repeating: "★", count: group.rating)).foregroundStyle(.yellow)
                    }
                    Spacer(minLength: 4)
                    PickBadge(state: group.pickState)
                }
                .font(.caption)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(.black.opacity(0.72))
                .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.focus(group.id) }
        .overlay(Rectangle().stroke(group.id == store.session.selectedGroupID ? Color.accentColor : .white.opacity(0.12), lineWidth: group.id == store.session.selectedGroupID ? 3 : 1))
    }

    private func compareZoomBar(groups: [PhotoGroup]) -> some View {
        let zoom = activeScaleBinding(groups: groups)
        return HStack(spacing: 12) {
            Label("鼠标滚轮缩放", systemImage: "computermouse")
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "minus.magnifyingglass")
            Slider(value: zoom, in: 1...8)
                .frame(maxWidth: 260)
            Image(systemName: "plus.magnifyingglass")
            Text("\(Int(zoom.wrappedValue * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
            Button("复位") { resetZoom() }
                .appButton(.secondary, controlSize: .small)
                .help("恢复所有照片为适合窗口大小")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.black.opacity(0.42))
    }

    private func scaleBinding(for id: String) -> Binding<Double> {
        if synchronizesZoom { return $sharedScale }
        return Binding(
            get: { individualScales[id] ?? 1 },
            set: { individualScales[id] = $0 }
        )
    }

    private func offsetBinding(for id: String) -> Binding<CGSize> {
        if synchronizesZoom { return $sharedOffset }
        return Binding(
            get: { individualOffsets[id] ?? .zero },
            set: { individualOffsets[id] = $0 }
        )
    }

    private func activeScaleBinding(groups: [PhotoGroup]) -> Binding<Double> {
        if synchronizesZoom { return $sharedScale }
        let id = store.session.selectedGroupID ?? groups.first?.id ?? ""
        return scaleBinding(for: id)
    }

    private func resetZoom() {
        sharedScale = 1
        sharedOffset = .zero
        individualScales.removeAll()
        individualOffsets.removeAll()
    }
}

private struct ZoomablePhoto: View {
    let url: URL?
    let maxPixelSize: Int
    @Binding var scale: Double
    @Binding var offset: CGSize
    var onDoubleClick: (() -> Void)? = nil
    @State private var gestureScale = 1.0
    @State private var dragStart = CGSize.zero

    var body: some View {
        PhotoImage(url: url, maxPixelSize: maxPixelSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(scale * gestureScale)
            .offset(x: offset.width, y: offset.height)
            .gesture(MagnifyGesture()
                .onChanged { gestureScale = $0.magnification }
                .onEnded { value in
                    scale = min(8, max(1, scale * value.magnification))
                    gestureScale = 1
                    resetOffsetIfNeeded()
                })
            .simultaneousGesture(DragGesture()
                .onChanged { value in offset = CGSize(width: dragStart.width + value.translation.width, height: dragStart.height + value.translation.height) }
                .onEnded { _ in dragStart = offset })
            .onTapGesture(count: 2) { onDoubleClick?() }
            .background(ScrollWheelZoomMonitor { delta in
                let factor = exp(Double(delta) * 0.025)
                scale = min(8, max(1, scale * factor))
                resetOffsetIfNeeded()
            })
            .clipped()
    }

    private func resetOffsetIfNeeded() {
        if scale <= 1.001 {
            offset = .zero
            dragStart = .zero
        } else {
            dragStart = offset
        }
    }
}

private struct ScrollWheelZoomMonitor: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScroll = onScroll
    }

    @MainActor
    final class MonitorView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { removeMonitor() }
            else { installMonitorIfNeeded() }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point), abs(event.scrollingDeltaY) > 0 else { return event }
                self.onScroll?(event.scrollingDeltaY)
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

private struct PhotoImage: View {
    let url: URL?
    let maxPixelSize: Int
    var displayMode: ContentMode = .fit
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: displayMode)
            } else {
                ZStack { Color.black; ProgressView().tint(.white) }
            }
        }
        .task(id: "\(url?.path ?? "")#\(maxPixelSize)") {
            guard let url else { return }
            image = nil
            image = await ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
        }
    }
}

#if AI_CULL
private struct AutoCullBadge: View {
    let analysis: PhotoAnalysis

    var body: some View {
        Label("\(Int((analysis.overallScore * 100).rounded()))", systemImage: analysis.recommendation.icon)
            .font(.caption2.bold().monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(badgeColor.opacity(0.92), in: Capsule())
            .help("\(analysis.recommendation.title)：\(analysis.reasons.joined(separator: "；"))")
    }

    private var badgeColor: Color {
        switch analysis.recommendation {
        case .recommended: .blue
        case .alternate: .secondary
        case .review: .orange
        }
    }
}

private struct AutoCullAnalysisSummary: View {
    let analysis: PhotoAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(analysis.recommendation.title, systemImage: analysis.recommendation.icon)
                    .font(.callout.bold())
                    .foregroundStyle(recommendationColor)
                Spacer()
                Text("\(Int((analysis.overallScore * 100).rounded())) 分")
                    .font(.caption.bold().monospacedDigit())
            }
            if let category = analysis.category {
                LabeledContent("画面类型") {
                    Label(category.title, systemImage: category.icon)
                }
                .font(.caption)
            }
            if let categoryModel = analysis.categoryModel {
                LabeledContent("语义模型") {
                    Text(categoryModel)
                }
                .font(.caption)
            }
            if let rank = analysis.sceneRank, let count = analysis.sceneCount {
                LabeledContent("组内排序") {
                    Text("\(rank) / \(count)")
                        .monospacedDigit()
                }
                .font(.caption)
            }
            metric("全图细节", value: analysis.sharpnessScore)
            if let subjectSharpness = analysis.subjectSharpnessScore {
                metric("主体清晰", value: subjectSharpness)
            }
            metric("曝光", value: analysis.exposureScore)
            if let technicalQuality = analysis.technicalQualityScore {
                metric("技术画质", value: technicalQuality)
            }
            if analysis.faceCount > 0 {
                LabeledContent("人物") {
                    Text("\(analysis.faceCount) 张人脸")
                }
                .font(.caption)
                if let quality = analysis.faceQualityScore {
                    metric("人物状态", value: quality)
                }
            }
            if let risks = analysis.technicalRisks, !risks.isEmpty {
                ForEach(risks, id: \.self) { risk in
                    Label(risk.title, systemImage: risk.blocksRecommendation ? "exclamationmark.triangle.fill" : "magnifyingglass")
                        .font(.caption.bold())
                        .foregroundStyle(risk.blocksRecommendation ? .orange : .secondary)
                }
            }
            ForEach(analysis.reasons, id: \.self) { reason in
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, value: Double) -> some View {
        HStack {
            Text(title).frame(width: 58, alignment: .leading)
            ProgressView(value: value)
            Text("\(Int((value * 100).rounded()))")
                .font(.caption2.monospacedDigit())
                .frame(width: 26, alignment: .trailing)
        }
        .font(.caption)
    }

    private var recommendationColor: Color {
        switch analysis.recommendation {
        case .recommended: .blue
        case .alternate: .secondary
        case .review: .orange
        }
    }
}

private struct AutoCullSetupView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AutoCullSettings()
    @State private var usesTargetCount = false
    @State private var targetCount = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.analyzedGroups.isEmpty ? "自动选图" : "重新自动分析")
                        .font(.title2.bold())
                    Text("先给出建议，再由你逐组复核；不会删除、移动或自动淘汰原片。")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("推荐强度") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("推荐强度", selection: $settings.strength) {
                        ForEach(AutoCullStrength.allCases) { strength in
                            Text(strength.title).tag(strength)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.strength.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            GroupBox("推荐数量") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("指定最终推荐张数", isOn: $usesTargetCount)
                    if usesTargetCount {
                        Stepper(
                            "推荐 \(targetCount) 张",
                            value: $targetCount,
                            in: 1...max(1, store.groups.count)
                        )
                    } else {
                        Text("按场景和推荐强度自动决定；未达到最低画质的场景可以不推荐。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            GroupBox("分析内容") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        TinyCLIPCategoryModel.shared.isAvailable
                            ? "TinyCLIP 8M 已随软件安装，可完全离线识别画面类型"
                            : "TinyCLIP 模型不可用，将只使用系统 Vision",
                        systemImage: TinyCLIPCategoryModel.shared.isAvailable
                            ? "checkmark.seal.fill"
                            : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        TinyCLIPCategoryModel.shared.isAvailable
                            ? Color.secondary
                            : Color.orange
                    )
                    Toggle("检测人脸状态与闭眼风险", isOn: $settings.detectsFaces)
                    HStack {
                        Text("场景时间间隔")
                        Slider(value: $settings.sceneGapSeconds, in: 3...30, step: 1)
                        Text("\(Int(settings.sceneGapSeconds)) 秒")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text("还会在本机识别人像、运动、夜景、风景等画面类型，分别分析主体清晰度、全图细节、曝光、画面相似度和整体观感。严重模糊、闭眼等技术风险会直接阻止推荐。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            if store.autoCullPreferenceProfile.feedbackCount > 0 {
                HStack {
                    Label(
                        "已根据 \(store.autoCullPreferenceProfile.feedbackCount) 次人工调整校准推荐偏好",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("重置学习") { store.resetAutoCullPreferences() }
                        .appButton(.quiet, controlSize: .small)
                }
            }

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                    .appButton(.secondary)
                Spacer()
                Button {
                    settings.targetCount = usesTargetCount ? targetCount : nil
                    store.startAutoCull(settings: settings)
                } label: {
                    Label(store.analyzedGroups.isEmpty ? "开始分析" : "重新分析", systemImage: "sparkles")
                }
                .appButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 590)
        .onAppear {
            settings = store.autoCullSettings
            usesTargetCount = settings.targetCount != nil
            targetCount = min(max(1, settings.targetCount ?? max(1, store.groups.count / 4)), max(1, store.groups.count))
        }
    }
}

private struct AutoCullReviewView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSceneID: String?
    @State private var championScene: AutoCullScene?

    private var selectedScene: AutoCullScene? {
        let scenes = store.autoCullScenes
        return scenes.first(where: { $0.id == selectedSceneID }) ?? scenes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader
            Divider()
            HStack(spacing: 0) {
                sceneSidebar
                Divider()
                sceneDetail
            }
            Divider()
            reviewFooter
        }
        .frame(minWidth: 980, minHeight: 680)
        .onAppear {
            selectedSceneID = store.autoCullScenes.first?.id
        }
        .sheet(item: $championScene) { scene in
            AutoCullChampionReviewView(scene: scene)
        }
    }

    private var reviewHeader: some View {
        HStack(spacing: 14) {
            Label("自动选图复核", systemImage: "sparkles")
                .font(.title2.bold())
            Text("\(store.autoCullScenes.count) 个场景 · 推荐 \(store.autoRecommendedGroups.count) 张")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.showingAutoCullReview = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    store.showingAutoCullSetup = true
                }
            } label: {
                Label("重新分析", systemImage: "arrow.clockwise")
            }
            .appButton(.secondary)
        }
        .padding(18)
    }

    private var sceneSidebar: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(store.autoCullScenes.enumerated()), id: \.element.id) { index, scene in
                    Button {
                        selectedSceneID = scene.id
                    } label: {
                        HStack(spacing: 10) {
                            if let cover = scene.bestGroup {
                                PhotoImage(url: store.previewURL(for: cover), maxPixelSize: 320, displayMode: .fill)
                                    .frame(width: 54, height: 42)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("场景 \(index + 1)")
                                    .font(.callout.bold())
                                Text("\(scene.groups.count) 张 · 推荐 \(scene.recommendedCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if scene.reviewCount > 0 {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(8)
                        .background(
                            selectedScene?.id == scene.id ? Color.accentColor.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .frame(width: 230)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var sceneDetail: some View {
        if let scene = selectedScene {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本组候选").font(.headline)
                        Text("分数用于排序，不会覆盖你的人工决定。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.acceptAutoRecommendations(sceneID: scene.id)
                    } label: {
                        Label("接受本组推荐", systemImage: "checkmark.circle")
                    }
                    .appButton(.secondary)
                    Button {
                        store.compareAutoCullScene(scene.id)
                    } label: {
                        Label("多图比较", systemImage: scene.groups.count == 2 ? "rectangle.split.2x1" : "rectangle.grid.2x2")
                    }
                    .appButton(.secondary)
                    Button {
                        championScene = scene
                    } label: {
                        Label("冠军对决", systemImage: "trophy")
                    }
                    .appButton(.primary)
                    .disabled(scene.groups.count < 2)
                }
                .padding(14)
                Divider()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 12)], spacing: 12) {
                        ForEach(scene.groups.sorted {
                            ($0.analysis?.overallScore ?? 0) > ($1.analysis?.overallScore ?? 0)
                        }) { group in
                            AutoCullReviewCard(group: group)
                        }
                    }
                    .padding(14)
                }
            }
        } else {
            ContentUnavailableView("还没有分析结果", systemImage: "sparkles")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var reviewFooter: some View {
        HStack {
            Label("自动推荐只会在你确认后变成“精选”，其余照片保持原状态。", systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("完成") { dismiss() }
                .appButton(.secondary)
            Button {
                store.acceptAutoRecommendations()
                dismiss()
            } label: {
                Label("接受全部推荐", systemImage: "checkmark.circle.fill")
            }
            .appButton(.primary)
        }
        .padding(14)
    }
}

private struct AutoCullChampionReviewView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let scene: AutoCullScene
    private let ranked: [PhotoGroup]
    @State private var championID: String
    @State private var challengerIndex = 1

    init(scene: AutoCullScene) {
        self.scene = scene
        let ranked = scene.groups.sorted {
            ($0.analysis?.overallScore ?? 0) > ($1.analysis?.overallScore ?? 0)
        }
        self.ranked = ranked
        _championID = State(initialValue: ranked.first?.id ?? "")
    }

    private var champion: PhotoGroup? {
        ranked.first(where: { $0.id == championID })
    }

    private var challenger: PhotoGroup? {
        guard ranked.indices.contains(challengerIndex) else { return nil }
        return ranked[challengerIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("组内冠军对决", systemImage: "trophy")
                        .font(.title2.bold())
                    Text(challenger == nil ? "本组冠军已产生" : "选择更好的一张，再与下一张继续比较")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(min(challengerIndex + 1, ranked.count)) / \(ranked.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()

            if let champion {
                if let challenger {
                    HStack(spacing: 6) {
                        candidate(champion, title: "当前冠军") {
                            advance(winnerID: champion.id)
                        }
                        candidate(challenger, title: "挑战者") {
                            advance(winnerID: challenger.id)
                        }
                    }
                    .padding(6)
                } else {
                    VStack(spacing: 14) {
                        Label("本组冠军", systemImage: "trophy.fill")
                            .font(.headline)
                            .foregroundStyle(.yellow)
                        PhotoImage(url: store.previewURL(for: champion), maxPixelSize: store.previewMode.previewPixelSize)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black)
                        Text(champion.baseName).font(.title3.bold())
                    }
                    .padding(18)
                }
            }

            Divider()
            HStack {
                Text("其余照片不会自动淘汰，仍可回到场景复核中调整。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .appButton(.secondary)
                if challenger == nil, let champion {
                    Button {
                        store.setPickStateForReview(.keep, groupID: champion.id)
                        dismiss()
                    } label: {
                        Label("确认冠军为精选", systemImage: "checkmark.circle.fill")
                    }
                    .appButton(.primary)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 980, minHeight: 680)
    }

    private func candidate(_ group: PhotoGroup, title: String, choose: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let analysis = group.analysis { AutoCullBadge(analysis: analysis) }
            }
            .padding(12)
            PhotoImage(url: store.previewURL(for: group), maxPixelSize: store.previewMode.previewPixelSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            VStack(alignment: .leading, spacing: 8) {
                Text(group.baseName).font(.headline)
                if let analysis = group.analysis {
                    Text(analysis.reasons.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button(action: choose) {
                    Label("这张更好", systemImage: "hand.thumbsup.fill")
                        .frame(maxWidth: .infinity)
                }
                .appButton(.primary, controlSize: .large)
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor).opacity(0.5)))
    }

    private func advance(winnerID: String) {
        championID = winnerID
        challengerIndex += 1
    }
}

private struct AutoCullReviewCard: View {
    @EnvironmentObject private var store: SessionStore
    let group: PhotoGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                PhotoImage(url: store.previewURL(for: group), maxPixelSize: 800)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                    .clipped()
                if let analysis = group.analysis {
                    AutoCullBadge(analysis: analysis).padding(7)
                }
            }
            HStack {
                Text(group.baseName).font(.callout.bold()).lineLimit(1)
                Spacer()
                PickBadge(state: group.pickState)
            }
            if let analysis = group.analysis {
                Text(analysis.reasons.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            PickStateControl(state: group.pickState) { state in
                store.setPickStateForReview(state, groupID: group.id)
            }
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(group.isAutoRecommended ? Color.blue.opacity(0.7) : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: group.isAutoRecommended ? 2 : 1)
        )
    }
}
#endif

private struct PickBadge: View {
    let state: PickState
    var body: some View {
        if state.isPicked {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("精选")
        } else if state.isRejected {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help("淘汰")
        }
    }
}

private struct PickStateControl: View {
    let state: PickState
    let onSelect: (PickState) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { onSelect(.keep) } label: {
                Label("精选", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(AppSelectionButtonStyle(isSelected: state == .keep, accent: .green))
            .foregroundStyle(.green)
            .help("标记为精选（P）")

            Button { onSelect(.undecided) } label: {
                Label("未决定", systemImage: "circle.dotted")
            }
            .buttonStyle(AppSelectionButtonStyle(isSelected: state == .undecided))
            .help("恢复为未决定（U）")

            Button { onSelect(.reject) } label: {
                Label("淘汰", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(AppSelectionButtonStyle(isSelected: state == .reject, accent: .red))
            .foregroundStyle(.red)
            .help("标记为淘汰（X）")
        }
        .labelStyle(.iconOnly)
    }
}

private struct RatingPicker: View {
    let rating: Int
    let onSelect: (Int) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Button { onSelect(value == rating ? 0 : value) } label: {
                    Image(systemName: value <= rating ? "star.fill" : "star")
                }
                .buttonStyle(AppSelectionButtonStyle(isSelected: value == rating, accent: .yellow))
                .foregroundStyle(
                    value <= rating
                        ? Color.yellow
                        : Color.secondary.opacity(0.52)
                )
                .help(value == rating ? "清除 \(value) 星评分" : "设为 \(value) 星")
            }
        }
    }
}

private struct ColorLabelButtons: View {
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    let selected: ColorLabel
    let onSelect: (ColorLabel) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                let action = CullKeyboardAction.action(for: label)
                Button { onSelect(label) } label: {
                    ZStack {
                        if label == .none {
                            Image(systemName: "circle.slash")
                                .foregroundStyle(.secondary)
                        } else {
                            Circle().fill(color(for: label)).frame(width: 15, height: 15)
                        }
                    }
                }
                .buttonStyle(
                    AppSelectionButtonStyle(
                        isSelected: label == selected,
                        accent: label == .none ? .secondary : color(for: label)
                    )
                )
                .help("\(label.title)（\(shortcutSettings.binding(for: action).displayText)）")
            }
        }
    }
}

private struct ColorLabelStrip: View {
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    let selected: ColorLabel
    let onSelect: (ColorLabel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                Button { onSelect(label) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: label == .none ? "circle.slash" : "circle.fill")
                            .foregroundStyle(color(for: label))
                        Text(label.title)
                        Spacer()
                        Text(shortcutSettings.binding(for: CullKeyboardAction.action(for: label)).displayText)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        if label == selected { Image(systemName: "checkmark").foregroundStyle(.primary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(label == selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ProjectRenameView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重命名项目").font(.title2.bold())
            Text("这个名称会显示在项目首页，并作为默认导出文件夹名称。")
                .foregroundStyle(.secondary)
            TextField("项目名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Button("取消", role: .cancel) { dismiss() }
                    .appButton(.secondary)
                Spacer()
                Button("保存", action: save)
                    .appButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.contains("/"))
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func save() {
        onSave()
        dismiss()
    }
}

private struct NewProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameIsFocused: Bool
    let sourceURL: URL
    let onCreate: (String) -> Void
    @State private var name: String

    init(sourceURL: URL, onCreate: @escaping (String) -> Void) {
        self.sourceURL = sourceURL
        self.onCreate = onCreate
        _name = State(initialValue: sourceURL.lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("新建项目", systemImage: "folder.badge.plus")
                .font(.title2.bold())
            Text("先为这次选片命名，确认后影择才会扫描并打开照片。")
                .foregroundStyle(.secondary)
            LabeledContent("照片文件夹") {
                Text(sourceURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            TextField("项目名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
                .onSubmit(create)
            HStack {
                Button("取消", role: .cancel) { dismiss() }
                    .appButton(.secondary)
                Spacer()
                Button("创建并打开", action: create)
                    .appButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!nameIsValid)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { nameIsFocused = true }
    }

    private var nameIsValid: Bool {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty && !cleaned.contains("/")
    }

    private func create() {
        guard nameIsValid else { return }
        onCreate(name)
        dismiss()
    }
}

private struct ArchiveConfirmationView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var scope: ArchiveScope = .picks
    @State private var exportFolderName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导出照片").font(.title2.bold())
            Picker("导出范围", selection: $scope) {
                ForEach(ArchiveScope.allCases) { option in
                    Text("\(option.title)（\(store.groupsForArchive(scope: option).count)）")
                        .tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            LabeledContent("本次复制") { Text("\(store.groupsForArchive(scope: scope).count) 组") }
            LabeledContent("预计复制") { Text(ByteCountFormatter.string(fromByteCount: store.estimatedBytes(for: scope), countStyle: .file)) }
            LabeledContent("文件夹名称") {
                TextField("导出文件夹名称", text: $exportFolderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 300)
            }
            HStack {
                Text(exportURL?.path ?? "尚未选择导出文件夹")
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button("选择或新建文件夹…", action: chooseDestination)
                    .appButton(.secondary)
            }
            Label("影择会创建上面的文件夹并复制本次照片；来源文件夹的所有内容保持不动。", systemImage: "folder.badge.plus")
                .foregroundStyle(.secondary)
            HStack {
                Button("取消", role: .cancel) { dismiss() }
                    .appButton(.secondary)
                Spacer()
                Button("开始导出") {
                    dismiss()
                    Task { await store.archive(scope: scope, folderName: exportFolderName) }
                }
                .appButton(.primary)
                .disabled(store.groupsForArchive(scope: scope).isEmpty || store.session.destinationURL == nil || !folderNameIsValid)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            if exportFolderName.isEmpty { exportFolderName = store.session.projectName }
            if !store.pickedGroups.isEmpty {
                scope = .picks
            } else if store.hasActiveFilters, !store.filteredAvailableGroups.isEmpty {
                scope = .filtered
            } else if store.multiSelectedAvailableCount > 1 {
                scope = .selected
            } else {
                scope = .allAvailable
            }
        }
    }

    private var folderNameIsValid: Bool {
        let cleaned = exportFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty && !cleaned.contains("/")
    }

    private var exportURL: URL? {
        guard let root = store.session.destinationURL, folderNameIsValid else { return nil }
        return root.appendingPathComponent(exportFolderName.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "选择或新建导出文件夹"
        panel.message = "输入文件夹名称，并选择本机或已挂载 NAS 中的保存位置。"
        panel.nameFieldLabel = "文件夹名称："
        panel.nameFieldStringValue = exportFolderName
        panel.prompt = "选择"
        panel.canCreateDirectories = true
        panel.directoryURL = store.session.destinationURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportFolderName = url.lastPathComponent
        store.setDestination(url.deletingLastPathComponent())
    }
}

private struct ArchiveReportView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let report: ArchiveReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: report.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 44)).foregroundStyle(report.failedCount == 0 ? .green : .orange)
            Text(report.failedCount == 0 ? "导出完成" : "导出完成，但有失败项").font(.title2.bold())
            Text("成功复制 \(report.succeededCount) 组，失败 \(report.failedCount) 组；来源文件夹未改动。")
            if report.failedCount > 0 {
                List(report.outcomes.filter { !$0.succeeded }) { outcome in
                    VStack(alignment: .leading) { Text(outcome.baseName).bold(); Text(outcome.error ?? "未知错误").foregroundStyle(.secondary) }
                }.frame(height: 160)
            }
            HStack {
                Button("关闭") { dismiss() }
                    .appButton(.secondary)
                Spacer()
                Button("在 Finder 中显示") { store.revealProject(report.projectURL) }
                    .appButton(.primary)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct ShortcutHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    private let actions: [CullKeyboardAction] = [
        .pick, .reject, .restore,
        .rating1, .rating2, .rating3, .rating4, .rating5, .rating0,
        .colorRed, .colorYellow, .colorGreen, .colorBlue, .colorPurple, .colorNone,
        .previous, .next, .undo
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "keyboard").font(.title)
                Text("影择快捷键").font(.title2.bold())
                Spacer()
                Button("自定义…") { openSettings() }
                    .appButton(.secondary)
                Button("完成") { dismiss() }
                    .appButton(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 10) {
                shortcutHint("G", "网格")
                shortcutHint("E", "单张")
                shortcutHint("C", "双图")
                shortcutHint("N", "多图")
                shortcutHint("Space", "网格／单张")
                shortcutHint("Esc", "返回网格")
            }
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 13) {
                    ForEach(actions) { action in
                        GridRow {
                            Text(shortcutSettings.binding(for: action).displayText)
                                .font(.system(.body, design: .monospaced).bold())
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            Text(action.title).fontWeight(.medium)
                        }
                    }
                }
            }
            .frame(maxHeight: 520)
            Divider()
            Label("按 X 后照片只进入软件废片区；导出只会复制选定照片，来源文件始终保持不动。", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 650)
    }

    private func shortcutHint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(.caption, design: .monospaced).bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct UndoNoticeView: View {
    @EnvironmentObject private var store: SessionStore
    let message: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(Color.accentColor)
            Text(message).lineLimit(1)
            Button("撤回") { store.undo() }
                .appButton(.primary, controlSize: .small)
            Button { store.dismissUndoNotice() } label: { Image(systemName: "xmark") }
                .appIconButton(compact: true)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.thickMaterial, in: Capsule())
        .shadow(radius: 12, y: 5)
    }
}

private func color(for label: ColorLabel) -> Color {
    switch label {
    case .none: .secondary
    case .red: .red
    case .yellow: .yellow
    case .green: .green
    case .blue: .blue
    case .purple: .purple
    }
}
