import Foundation

/// Fetches the account's usage windows from claude.ai's web usage endpoint,
/// authenticated with the session cookies Claude Desktop already holds.
///
/// The contract was proven by a live probe: one GET to
/// `/api/organizations/{org}/usage` with the Desktop cookies and a Chrome
/// User-Agent returned HTTP 200 through URLSession, the exact transport used
/// here. Since 23/09/2026 the site answers every non-browser client with a
/// Cloudflare managed challenge (HTTP 403 plus `cf-mitigated: challenge`), with
/// and without the bundled `cf_clearance` cookie, and with plain `curl` too.
/// That is a property of the site, not of this code, so the app reports it
/// honestly instead of blaming the session. The transport seam is unchanged, so
/// a browser-based transport could be dropped in later without touching this
/// type; see the README for why that is not built.
///
/// Read-only, same rules as the ChatGPT side: one endpoint, no quota spent,
/// no session consumed, nothing written back to the cookie store.
public final class ClaudeUsageProvider: UsageProvider {
    public let id = "claude"
    public let displayName = "Claude"

    public static let timeout: TimeInterval = 15
    /// The same fingerprint family the successful probe used. Cloudflare's
    /// clearance cookie is tied to it, so this string is load-bearing.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    private let sessionSource: any ClaudeSessionSource
    /// Same seam as ChatGPT: tests inject spies, production gets the one
    /// URLSession call site that already exists in `ChatGPTUsageProvider`.
    private let transport: ChatGPTUsageProvider.Transport
    private let now: () -> Date

    public init(
        sessionSource: any ClaudeSessionSource = ClaudeDesktopSessionSource(),
        transport: @escaping ChatGPTUsageProvider.Transport = ChatGPTUsageProvider.urlSessionTransport,
        now: @escaping () -> Date = { Date() }
    ) {
        self.sessionSource = sessionSource
        self.transport = transport
        self.now = now
    }

    public func fetchLimits() async throws -> [UsageLimit] {
        // 1. Credentials, read-only from the cookie store. Detached on purpose:
        //    SecItemCopyMatching may show a one-time consent dialog and block
        //    this thread for as long as it takes to answer. A blocked main
        //    thread would freeze the panel, the status item, and the test host
        //    (observed exactly that way: the first xcodebuild test run hung
        //    behind a Keychain dialog presented under the lock screen).
        let source = sessionSource
        let session = try await Task.detached(priority: .userInitiated) {
            try source.load()
        }.value

        // 2. Expiry gate BEFORE any network call — same short-circuit rule as
        //    the Codex path, proven there by a spy that must stay untouched.
        if session.isExpired(now: now()) {
            throw UsageProviderError.notConnected(
                "Claude session expired - open Claude to refresh it"
            )
        }

        // 3. The request.
        let request = Self.makeRequest(session: session)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw UsageProviderError.fetchFailed("Network error - check your connection")
        }

        // 4. Status handling. 401/403/503 used to mean "the session or the
        //    clearance cookie aged out". Since Cloudflare began interrogating
        //    every non-browser client, the far more common cause of a 403 is a
        //    managed bot challenge, which has a different fix. So the body is
        //    read and named instead of guessed: this is the one deliberate
        //    exception to the "never parse error shapes" rule, and it only looks
        //    for the challenge marker, never at the payload shape.
        switch response.statusCode {
        case 401, 403, 503:
            if Self.isCloudflareChallenge(body: data, response: response) {
                throw UsageProviderError.notConnected(
                    "Claude is blocked by Cloudflare - open Claude Desktop, then Refresh"
                )
            }
            throw UsageProviderError.notConnected(
                "Claude session expired - open Claude to refresh it"
            )
        case 200...299:
            break
        default:
            throw UsageProviderError.fetchFailed(
                "Claude usage service returned HTTP \(response.statusCode)"
            )
        }

        // 5. Map. Empty list = real answer; HTML/unknown shape = fetch failure.
        return try ClaudeUsageMapper.limits(from: data)
    }

    public static func usageURL(organizationId: String) -> URL {
        URL(string: "https://claude.ai/api/organizations/\(organizationId)/usage")!
    }

    public static func makeRequest(session: ClaudeSession) -> URLRequest {
        var request = URLRequest(url: usageURL(organizationId: session.organizationId), timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Cookie header only — no Authorization header exists on this path.
        // The cf_clearance cookie is included exactly as the browser holds it;
        // it is what lets this fingerprint through Cloudflare.
        var cookies = [
            "sessionKey=\(session.sessionKey)",
            "lastActiveOrg=\(session.organizationId)",
        ]
        if let clearance = session.cfClearance, !clearance.isEmpty {
            cookies.append("cf_clearance=\(clearance)")
        }
        request.setValue(cookies.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        return request
    }

    /// A Cloudflare managed challenge is served as HTML with a 403 and the
    /// literal title "Just a moment...", usually with a `cf-mitigated: challenge`
    /// header and a `cf_chl_*` script. Recognizing it means the user is told the
    /// fix that actually applies (open Claude Desktop and let it answer the
    /// challenge) instead of "your session expired", which would send them
    /// chasing a sign-in that is already valid.
    ///
    /// Pure function on purpose: both branches are assertable without a live
    /// server, and the header branch is unreachable through `SpyTransport`.
    static func isCloudflareChallenge(body: Data, response: HTTPURLResponse) -> Bool {
        if response.value(forHTTPHeaderField: "cf-mitigated")?.lowercased().contains("challenge") == true {
            return true
        }
        guard let text = String(data: body.prefix(4096), encoding: .utf8) else { return false }
        return text.contains("Just a moment") || text.contains("cf_chl_")
    }
}
