import Foundation

private final class StubProtocol: URLProtocol {
    static var status = 200
    static var payload = Data()
    static var failure: URLError?
    static var webPage = "https://github.com/Clawborn/remote-go/releases/tag/v1.5.30"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url == GitHubUpdates.latestPage {
            precondition(request.httpMethod == "HEAD")
            let response = HTTPURLResponse(url: URL(string: Self.webPage)!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        precondition(request.url == GitHubUpdates.endpoint)
        precondition(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct UpdatesTests {
    static func payload(tag: String = "v1.5.30", page: String? = nil,
                        draft: Bool = false, prerelease: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "html_url": page ?? "https://github.com/Clawborn/remote-go/releases/tag/\(tag)",
            "body": "Release notes", "draft": draft, "prerelease": prerelease
        ])
    }

    static func expectError(_ expected: UpdateCheckError, session: URLSession) async {
        do {
            _ = try await GitHubUpdates.latest(using: session)
            preconditionFailure("Expected \(expected)")
        } catch let error as UpdateCheckError {
            precondition(error == expected)
        } catch { preconditionFailure("Unexpected error: \(error)") }
    }

    static func main() async throws {
        precondition(ReleaseVersion("v1.5.29") == ReleaseVersion("1.5.29"))
        precondition(ReleaseVersion("1.5.9")! < ReleaseVersion("1.5.10")!)
        precondition(ReleaseVersion("1.9.99")! < ReleaseVersion("1.10.0")!)
        precondition(ReleaseVersion("1.99.99")! < ReleaseVersion("2.0.0")!)
        for invalid in ["", "v", "1.5", "1.5.29.1", "1.5.-1", "1.5.2-beta", "1.5.２", " 1.5.29",
                        "1.5.999999999999999999999999999999999999"] {
            precondition(ReleaseVersion(invalid) == nil)
        }
        let now = Date(timeIntervalSince1970: 1_000_000)
        precondition(UpdateCheckSchedule.isDue(lastCheck: nil, now: now))
        precondition(!UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(-86_399), now: now))
        precondition(UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        precondition(UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(100), now: now))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        StubProtocol.payload = payload()
        let newer = try await GitHubUpdates.latest(using: session)
        let newerVersion = try newer.validated().version
        precondition(newerVersion > ReleaseVersion("1.5.29")!)
        precondition(newer.body == "Release notes")
        precondition(newer.isNewer(than: "1.5.29"))
        precondition(!newer.isNewer(than: "invalid"))
        let stored = try JSONEncoder().encode(newer)
        let restored = try JSONDecoder().decode(GitHubRelease.self, from: stored)
        precondition(restored.isNewer(than: "1.5.29"))
        precondition(!restored.isNewer(than: "1.5.30"))
        precondition(!restored.isNewer(than: "1.5.31"))
        StubProtocol.payload = payload(tag: "v1.5.29")
        let equal = try await GitHubUpdates.latest(using: session)
        let equalVersion = try equal.validated().version
        precondition(equalVersion == ReleaseVersion("1.5.29")!)
        StubProtocol.payload = payload(tag: "v1.5.28")
        let older = try await GitHubUpdates.latest(using: session)
        let olderVersion = try older.validated().version
        precondition(olderVersion < ReleaseVersion("1.5.29")!)
        for status in [404, 403, 429, 500] {
            StubProtocol.status = status
            await expectError(status == 404 ? .noRelease : status == 500 ? .server : .rateLimited, session: session)
        }
        StubProtocol.status = 200
        for invalid in [payload(draft: true), payload(prerelease: true), payload(tag: "v1.5.30-beta"),
                        payload(page: "http://github.com/Clawborn/remote-go/releases/tag/v1.5.30"),
                        payload(page: "https://github.com.evil.test/Clawborn/remote-go/releases/tag/v1.5.30"),
                        payload(page: "https://github.com/another/repo/releases/tag/v1.5.30"),
                        payload(page: "https://github.com/Clawborn/remote-go/releases/tag/v1.5.31"),
                        Data("{broken".utf8), Data(repeating: 32, count: 2_000_001)] {
            StubProtocol.payload = invalid
            await expectError(.invalidRelease, session: session)
        }
        StubProtocol.failure = URLError(.timedOut)
        do {
            _ = try await GitHubUpdates.latest(using: session)
            preconditionFailure("Expected timeout")
        } catch let error as URLError { precondition(error.code == .timedOut) }
        StubProtocol.failure = nil
        StubProtocol.status = 403
        let fallback = try await GitHubUpdates.check(using: session)
        precondition(fallback.isNewer(than: "1.5.29"))
        precondition(fallback.body == nil)
        StubProtocol.webPage = "https://evil.test/releases/tag/v1.5.30"
        do {
            _ = try await GitHubUpdates.check(using: session)
            preconditionFailure("Untrusted fallback URL accepted")
        } catch let error as UpdateCheckError { precondition(error == .invalidRelease) }
        print("Update checks passed: versions, daily schedule, HTTP errors, timeouts and release URL validation")

        if CommandLine.arguments.contains("--live") {
            let release = try await GitHubUpdates.check()
            let verified = try release.validated()
            print("Live GitHub release: \(verified.version.display) · \(verified.page.absoluteString)")
        }
    }
}
