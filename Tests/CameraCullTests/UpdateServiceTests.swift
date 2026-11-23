import CryptoKit
import Foundation
import Testing
@testable import CameraCull

@Suite("软件更新")
struct UpdateServiceTests {
    @Test("按数字比较版本并选择已校验信息齐全的 Apple Silicon 安装包")
    func comparesVersionsAndSelectsDownloadedDMG() throws {
        let json = try release(assets: [
            asset(name: "Yingze-x86_64.dmg"),
            asset(name: "Yingze-0.24.10-arm64.dmg")
        ])
        let update = try #require(try AppUpdateService.availableUpdate(from: json, currentVersion: "0.24.9"))
        #expect(update.version == "v0.24.10")
        #expect(update.notes == "更新说明")
        #expect(update.releaseURL.path == "/BBin17/yingze/releases/tag/v0.24.10")
        #expect(update.package?.filename == "Yingze-0.24.10-arm64.dmg")
        #expect(update.package?.size == 4)
        #expect(try AppUpdateService.availableUpdate(from: json, currentVersion: "0.24.10") == nil)
        #expect(try AppUpdateService.availableUpdate(from: json, currentVersion: "0.25") == nil)
    }

    @Test("跳过草稿和预发布")
    func ignoresDraftsAndPrereleases() throws {
        let draft = try release(draft: true)
        let prerelease = try release(tag: "v0.25.0-beta.1", prerelease: true)
        #expect(try AppUpdateService.availableUpdate(from: draft, currentVersion: "0.24.9") == nil)
        #expect(try AppUpdateService.availableUpdate(from: prerelease, currentVersion: "0.24.9") == nil)
    }

    @Test("正式版标签格式无效时提示错误")
    func rejectsInvalidReleaseTags() throws {
        for tag in ["v0.25.0-beta.1", "v0.25..1", "update-20261123"] {
            let data = try release(tag: tag)
            #expect(throws: AppUpdateError.self) {
                _ = try AppUpdateService.availableUpdate(from: data, currentVersion: "0.24.9")
            }
        }
    }

    @Test("无校验值、附件不完整或候选包冲突时保留发布页入口")
    func fallsBackToReleasePageWhenAnAssetCannotBeVerified() throws {
        let name = "Yingze-arm64.dmg"
        let cases = [
            [asset(name: name, digest: nil)],
            [asset(name: name, digest: "sha256:abc")],
            [asset(name: name, state: "new")],
            [asset(name: name), asset(name: "Yingze-alternate-arm64.dmg")]
        ]
        for assets in cases {
            let update = try #require(try AppUpdateService.availableUpdate(from: release(assets: assets), currentVersion: "0.24.9"))
            #expect(update.package == nil)
            #expect(update.releaseURL.host == "github.com")
        }
    }

    @Test("不采用其他仓库、其他站点或不同版本的下载地址")
    func restrictsDownloadToMatchingGitHubRelease() throws {
        let name = "Yingze-arm64.dmg"
        for url in [
            "https://github.com/another/yingze/releases/download/v0.24.10/\(name)",
            "https://example.org/\(name)",
            "https://github.com/BBin17/yingze/releases/download/v0.24.9/\(name)",
            "http://github.com/BBin17/yingze/releases/download/v0.24.10/\(name)"
        ] {
            let data = try release(assets: [asset(name: name, url: url)])
            let update = try #require(try AppUpdateService.availableUpdate(from: data, currentVersion: "0.24.9"))
            #expect(update.package == nil)
        }
    }

    @Test("仅接受大小与 SHA-256 都匹配的安装包")
    func refusesTruncatedAndModifiedDownloads() throws {
        let data = Data("disk".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let json = try release(assets: [asset(name: "Yingze-arm64.dmg", digest: "sha256:\(hash)")])
        let update = try #require(try AppUpdateService.availableUpdate(from: json, currentVersion: "0.24.9"))
        let package = try #require(update.package)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }

        try data.write(to: file)
        try AppUpdateService.verify(file, package: package)
        for altered in ["dusk", "dis"] {
            try Data(altered.utf8).write(to: file)
            #expect(throws: AppUpdateError.self) {
                try AppUpdateService.verify(file, package: package)
            }
        }
    }

    private func release(
        tag: String = "v0.24.10", draft: Bool = false, prerelease: Bool = false, assets: [[String: Any]] = []
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "body": "更新说明",
            "assets": assets
        ])
    }

    private func asset(
        name: String, state: String = "uploaded", digest: String? = "sha256:" + String(repeating: "a", count: 64), url: String? = nil
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "name": name,
            "state": state,
            "size": 4,
            "browser_download_url": url ?? "https://github.com/BBin17/yingze/releases/download/v0.24.10/\(name)"
        ]
        if let digest { fields["digest"] = digest }
        return fields
    }
}
