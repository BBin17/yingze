import AppKit
import SwiftUI

@MainActor
final class AppUpdateController: ObservableObject {
    enum State {
        case idle
        case checking
        case current
        case available(AvailableUpdate, downloadError: String? = nil)
        case downloading(AvailableUpdate)
        case ready(AvailableUpdate, URL, openError: String? = nil)
        case checkFailed(String)
    }

    @Published private(set) var state: State = .idle
    let installedVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private let service = AppUpdateService()
    private var hasCheckedOnLaunch = false

    func checkOnLaunch() async -> Bool {
        guard !hasCheckedOnLaunch, case .idle = state, installedVersion != nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil
        else { return false }
        hasCheckedOnLaunch = true
        await check()
        if case .available = state { return true }
        return false
    }

    func check() async {
        switch state {
        case .checking, .downloading: return
        default: break
        }
        guard let installedVersion else {
            state = .checkFailed(AppUpdateError.invalidVersion.localizedDescription)
            return
        }
        state = .checking
        do {
            if let update = try await service.check(currentVersion: installedVersion) {
                state = .available(update)
            } else {
                state = .current
            }
        } catch {
            state = Task.isCancelled ? .idle : .checkFailed(error.localizedDescription)
        }
    }

    func download() async {
        guard case .available(let update, _) = state, let package = update.package else { return }
        state = .downloading(update)
        do {
            let file = try await service.download(package, releaseURL: update.releaseURL)
            state = .ready(update, file)
        } catch {
            state = .available(update, downloadError: error.localizedDescription)
        }
    }

    func openInstaller() {
        guard case .ready(let update, let file, _) = state else { return }
        if !FileManager.default.fileExists(atPath: file.path) {
            state = .available(update, downloadError: "安装包已被清理，请重新下载。")
        } else if !NSWorkspace.shared.open(file) {
            state = .ready(update, file, openError: "macOS 无法打开安装包。")
        }
    }
}

struct AppUpdateView: View {
    static let windowID = "software-update"

    @ObservedObject var updater: AppUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let installed = updater.installedVersion {
                Text("当前版本 \(installed)")
                    .foregroundStyle(.secondary)
            }
            switch updater.state {
            case .idle:
                checkButtons()
            case .checking:
                progress("正在检查更新…")
            case .current:
                Text("当前已是最新版本。").font(.headline)
                checkButtons()
            case .available(let update, let error):
                releaseDetails(update)
                if let error {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                } else if update.package == nil {
                    Text("请前往 GitHub 发布页下载此版本。").foregroundStyle(.secondary)
                }
                HStack {
                    releaseLink(update.releaseURL)
                    Spacer()
                    if let package = update.package {
                        Text(ByteCountFormatter.string(fromByteCount: package.size, countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button(error == nil ? "下载更新" : "重新下载") { Task { await updater.download() } }
                            .appButton(.primary)
                    }
                }
            case .downloading(let update):
                releaseDetails(update)
                progress("正在下载并校验安装包…")
            case .ready(let update, _, let error):
                Text("\(update.version) 已下载").font(.headline)
                Text("安装包已通过 SHA‑256 校验。打开安装包后，退出影择，再将新版拖到「应用程序」并选择替换。")
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error).foregroundStyle(.secondary)
                }
                HStack {
                    releaseLink(update.releaseURL)
                    Spacer()
                    Button("打开安装包") { updater.openInstaller() }
                        .appButton(.primary)
                }
            case .checkFailed(let error):
                Text("检查更新失败").font(.headline)
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                checkButtons()
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder
    private func releaseDetails(_ update: AvailableUpdate) -> some View {
        Text("发现新版本 \(update.version)").font(.headline)
        if !update.notes.isEmpty {
            ScrollView {
                Text(verbatim: update.notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
        }
    }

    private func progress(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message)
        }
    }

    private func checkButtons() -> some View {
        HStack {
            releaseLink(AppUpdateService.releasesURL)
            Spacer()
            Button("检查更新") { Task { await updater.check() } }
                .appButton(.primary)
        }
    }

    private func releaseLink(_ url: URL) -> some View {
        Link("查看 GitHub 发布页", destination: url)
            .appButton(.secondary)
    }
}
