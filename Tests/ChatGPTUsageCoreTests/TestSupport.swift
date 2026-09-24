import Foundation
import XCTest
@testable import ChatGPTUsageCore

/// Loads a fixture by name from the test bundle, with a filesystem fallback so
/// the same tests run under `swift test` and under an Xcode test host.
enum Fixture {
    static func data(named name: String) throws -> Data {
        // 1. The bundle copy first. Under Xcode the fixtures are copied into
        //    the test bundle (project.yml resources phase), and under
        //    `swift test` they are a `.copy("Fixtures")` resource — both live
        //    on local disk, outside the working tree. The working tree sits in
        //    a FileProvider mount (Google Drive), and an open() there can
        //    block indefinitely when the provider's daemon is unhappy; that
        //    exact hang was observed as an xcodebuild test run stuck in
        //    `Data(contentsOf:)` while the same file read fine from a shell.
        if let bundled = bundleURL(for: name), let data = try? Data(contentsOf: bundled) {
            return data
        }

        // 2. Filesystem fallback relative to this source file, so the suite
        //    still runs when no bundle resource was copied.
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures")
            .appending(path: name)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try Data(contentsOf: fileURL)
        }
        throw FixtureError.notFound(name, fileURL.path)
    }

    /// `Bundle.module` exists only under SwiftPM (`SWIFT_PACKAGE` is defined
    /// there); the Xcode test bundle is reached via the anchor class.
    private static func bundleURL(for name: String) -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: (name as NSString).deletingPathExtension,
                                 withExtension: (name as NSString).pathExtension,
                                 subdirectory: "Fixtures")
        #else
        return Bundle(for: TestBundleAnchor.self).url(
            forResource: (name as NSString).deletingPathExtension,
            withExtension: (name as NSString).pathExtension,
            subdirectory: "Fixtures"
        )
        #endif
    }

    static func text(named name: String) throws -> String {
        String(decoding: try data(named: name), as: UTF8.self)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case notFound(String, String)
        var description: String {
            switch self {
            case .notFound(let name, let path):
                return "fixture \(name) not found (looked at \(path))"
            }
        }
    }
}

/// Exists only so `Bundle(for:)` can locate the test bundle under Xcode.
final class TestBundleAnchor {}

/// A credentials source with no filesystem behind it.
struct StubCredentialsSource: CodexCredentialsSource {
    let result: Result<CodexCredentials, Error>

    init(credentials: CodexCredentials) {
        self.result = .success(credentials)
    }

    init(error: Error) {
        self.result = .failure(error)
    }

    func load() throws -> CodexCredentials {
        try result.get()
    }
}

/// Records whether the transport was reached, and what it was asked for.
/// Test 9 in the plan asserts this was NOT called, which is the only way to
/// prove the expiry gate short-circuits before the network.
final class SpyTransport: @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var lastRequest: URLRequest?
    let data: Data
    let statusCode: Int

    init(data: Data = Data("{}".utf8), statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    var transport: ChatGPTUsageProvider.Transport {
        { request in
            self.callCount += 1
            self.lastRequest = request
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                statusCode: self.statusCode,
                httpVersion: "HTTP/2",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (self.data, response)
        }
    }
}

/// A transport that always throws, standing in for no connectivity.
enum FailingTransport {
    static let transport: ChatGPTUsageProvider.Transport = { _ in
        throw URLError(.notConnectedToInternet)
    }
}

enum TestDates {
    /// 2026-07-19T04:28:08Z. Derived as 1785024392 - 589104 from the captured
    /// payload, so the fixture and the test clock agree by construction.
    static let capture = Date(timeIntervalSince1970: 1785024392 - 589104)

    static func iso8601(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}

/// Asserts a specific error case and returns its message, so tests can check
/// the wording the user will actually read.
func assertProviderError(
    _ error: Error?,
    file: StaticString = #filePath,
    line: UInt = #line
) -> UsageProviderError? {
    guard let error else {
        XCTFail("expected a UsageProviderError, got nil", file: file, line: line)
        return nil
    }
    guard let providerError = error as? UsageProviderError else {
        XCTFail("expected a UsageProviderError, got \(error)", file: file, line: line)
        return nil
    }
    return providerError
}
