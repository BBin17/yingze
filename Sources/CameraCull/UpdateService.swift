import CoreServices
import CryptoKit
import Foundation

struct AvailableUpdate: Sendable {
    struct Package: Sendable {
        let filename: String
        let url: URL
        let size: Int64
        let sha256: String
    }

    let version: String
    let notes: String
    let releaseURL: URL
    let package: Package?
}

enum AppUpdateError: LocalizedError {
    case invalidVersion
    case invalidResponse
    case githubStatus(Int)
    case invalidDownload
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidVersion: "无法识别当前版本或 GitHub 发布的版本号。"
        case .invalidResponse: "GitHub 返回的版本信息无法读取。"
        case .githubStatus(404): "GitHub 暂无可用的正式发布版本。"
        case .githubStatus(429): "GitHub 暂时限制了请求次数，请稍后重试。"
        case .githubStatus(let code): "GitHub 返回 HTTP \(code)，请稍后重试。"
        case .invalidDownload: "无法从 GitHub 下载此安装包。"
        case .verificationFailed: "安装包大小或 SHA-256 校验失败，请重新下载。"
        }
    }
}

struct AppUpdateService: Sendable {
    private static let apiURL = URL(string: "https://api.github.com/repos/BBin17/yingze/releases/latest")!
    static let releasesURL = URL(string: "https://github.com/BBin17/yingze/releases")!

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    func check(currentVersion: String) async throws -> AvailableUpdate? {
        var request = URLRequest(url: Self.apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Yingze-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request, delegate: RedirectPolicy(download: false))
        guard let http = response as? HTTPURLResponse, http.url == Self.apiURL else {
            throw AppUpdateError.invalidResponse
        }
        if http.statusCode == 403, http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            throw AppUpdateError.githubStatus(429)
        }
        guard http.statusCode == 200 else { throw AppUpdateError.githubStatus(http.statusCode) }
        return try Self.availableUpdate(from: data, currentVersion: currentVersion)
    }

    func download(_ package: AvailableUpdate.Package, releaseURL: URL) async throws -> URL {
        var request = URLRequest(url: package.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Yingze-Updater", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request, delegate: RedirectPolicy(download: true))
        let manager = FileManager.default
        defer { try? manager.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, url == package.url || Self.isReleaseAssetHost(url) else {
            throw AppUpdateError.invalidDownload
        }
        try Self.verify(temporary, package: package)

        let folder = manager.temporaryDirectory.appendingPathComponent("YingzeUpdate-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(package.filename)
        do {
            try manager.moveItem(at: temporary, to: file)
            try (file as NSURL).setResourceValue([
                kLSQuarantineAgentNameKey as String: "影择",
                kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload,
                kLSQuarantineOriginURLKey as String: releaseURL,
                kLSQuarantineDataURLKey as String: package.url
            ], forKey: .quarantinePropertiesKey)
            return file
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    static func availableUpdate(from data: Data, currentVersion: String) throws -> AvailableUpdate? {
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw AppUpdateError.invalidResponse
        }
        guard !release.draft, !release.prerelease else { return nil }
        guard let installed = versionComponents(currentVersion), let latest = versionComponents(release.tagName) else {
            throw AppUpdateError.invalidVersion
        }
        guard installed.lexicographicallyPrecedes(latest) else { return nil }
        let tag = release.tagName
        let packages = release.assets.compactMap { package(from: $0, tag: tag) }
        let page = releasesURL.appendingPathComponent("tag").appendingPathComponent(tag)
        return AvailableUpdate(
            version: tag,
            notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            releaseURL: page,
            package: packages.count == 1 ? packages.first : nil
        )
    }

    static func verify(_ file: URL, package: AvailableUpdate.Package) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == package.size else { throw AppUpdateError.verificationFailed }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try autoreleasepool(invoking: { try handle.read(upToCount: 1024 * 1024) }), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == package.sha256 else { throw AppUpdateError.verificationFailed }
    }

    static func isNewer(_ version: String, than current: String) -> Bool {
        guard let latest = versionComponents(version), let installed = versionComponents(current) else { return false }
        return installed.lexicographicallyPrecedes(latest)
    }

    static func versionComponents(_ version: String) -> [Int]? {
        let digits = version.first == "v" || version.first == "V" ? version.dropFirst() : version[...]
        let fields = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count),
              fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { return nil }
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == fields.count else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    private static func package(from asset: Release.Asset, tag: String) -> AvailableUpdate.Package? {
        let name = asset.name
        guard name.lowercased().hasSuffix("arm64.dmg"),
              !name.contains("/"), !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              asset.state == "uploaded", asset.size > 0,
              let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:")
        else { return nil }
        let expected = String(digest.dropFirst("sha256:".count))
        guard expected.utf8.count == 64,
              expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let url = asset.browserDownloadURL,
              url == releasesURL.appendingPathComponent("download").appendingPathComponent(tag).appendingPathComponent(name)
        else { return nil }
        return .init(filename: name, url: url, size: asset.size, sha256: expected)
    }

    private static func isReleaseAssetHost(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil &&
            ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        let download: Bool

        init(download: Bool) { self.download = download }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard download, let url = request.url, AppUpdateService.isReleaseAssetHost(url) else { return nil }
            return request
        }
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let state: String
            let size: Int64
            let digest: String?
            let browserDownloadURL: URL?

            enum CodingKeys: String, CodingKey {
                case name, state, size, digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case body, draft, prerelease, assets
            case tagName = "tag_name"
        }
    }
}
