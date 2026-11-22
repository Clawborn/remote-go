import Foundation

struct ReleaseVersion: Comparable {
    let components: [Int]
    let display: String

    init?(_ string: String) {
        let version = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        components = numbers
        display = version
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.components == rhs.components }
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct GitHubRelease: Codable {
    let tagName: String
    let htmlURL: String
    let body: String?
    let draft: Bool
    let prerelease: Bool

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", body, draft, prerelease
    }

    func validated() throws -> (version: ReleaseVersion, page: URL) {
        guard !draft, !prerelease, let version = ReleaseVersion(tagName),
              let components = URLComponents(string: htmlURL),
              components.scheme == "https", components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path == "/Clawborn/remote-go/releases/tag/" + tagName,
              let page = components.url else { throw UpdateCheckError.invalidRelease }
        return (version, page)
    }

    func isNewer(than current: String) -> Bool {
        guard let current = ReleaseVersion(current), let remote = try? validated() else { return false }
        return remote.version > current
    }
}

enum UpdateCheckError: Error, Equatable {
    case noRelease, rateLimited, invalidRelease, server
}

enum UpdateCheckSchedule {
    static let interval: TimeInterval = 24 * 60 * 60

    static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now < lastCheck || now.timeIntervalSince(lastCheck) >= interval
    }
}

enum GitHubUpdates {
    static let releasesPage = URL(string: "https://github.com/Clawborn/remote-go/releases")!
    static let endpoint = URL(string: "https://api.github.com/repos/Clawborn/remote-go/releases/latest")!
    static let latestPage = URL(string: "https://github.com/Clawborn/remote-go/releases/latest")!

    static func check(using session: URLSession = .shared) async throws -> GitHubRelease {
        do {
            return try await latest(using: session)
        } catch let error as UpdateCheckError where error == .rateLimited || error == .server {
            // Public API quotas may be shared by many users on the same network.
            var request = URLRequest(url: latestPage, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "HEAD"
            request.setValue("Remote-Go", forHTTPHeaderField: "User-Agent")
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw UpdateCheckError.server }
            guard response.statusCode == 200 else {
                throw response.statusCode == 404 ? UpdateCheckError.noRelease : UpdateCheckError.server
            }
            guard let page = response.url else { throw UpdateCheckError.invalidRelease }
            let release = GitHubRelease(tagName: page.lastPathComponent, htmlURL: page.absoluteString,
                                        body: nil, draft: false, prerelease: false)
            _ = try release.validated()
            return release
        }
    }

    static func latest(using session: URLSession = .shared) async throws -> GitHubRelease {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Remote-Go", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UpdateCheckError.server }
        switch response.statusCode {
        case 200: break
        case 404: throw UpdateCheckError.noRelease
        case 403, 429: throw UpdateCheckError.rateLimited
        default: throw UpdateCheckError.server
        }
        guard data.count <= 2_000_000,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            throw UpdateCheckError.invalidRelease
        }
        _ = try release.validated()
        return release
    }
}
