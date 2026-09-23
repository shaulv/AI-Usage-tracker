import Foundation

/// Fetches the account's usage windows from ChatGPT's own usage endpoint.
///
/// This is the ONLY endpoint this app polls. It is read-only and consumes no
/// quota. Polling `/backend-api/codex/responses` or sending any model turn to
/// read limits would spend the thing being measured: a background suggestion
/// run was measured at roughly 6% of the weekly window per hour.
public protocol UsageProvider {
    var id: String { get }
    var displayName: String { get }
    func fetchLimits() async throws -> [UsageLimit]
}

public final class ChatGPTUsageProvider: UsageProvider {
    /// Injected so tests never construct a URLSession and never touch the
    /// network. The production value is the only place URLSession appears.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public let id = "chatgpt"
    public let displayName = "ChatGPT"

    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let timeout: TimeInterval = 15

    private let credentialsSource: any CodexCredentialsSource
    private let transport: Transport
    private let now: () -> Date

    public init(
        credentialsSource: any CodexCredentialsSource = CodexAuthFileCredentialsSource(),
        transport: @escaping Transport = ChatGPTUsageProvider.urlSessionTransport,
        now: @escaping () -> Date = { Date() }
    ) {
        self.credentialsSource = credentialsSource
        self.transport = transport
        self.now = now
    }

    public func fetchLimits() async throws -> [UsageLimit] {
        // 1. Credentials. Distinct messages because they have distinct fixes.
        let credentials = try credentialsSource.load()

        // 2. Expiry gate BEFORE any network call. An already-expired token gets
        //    a local message and costs nothing. If the JWT did not decode, we
        //    proceed: the server's 401 is the authority.
        if credentials.isExpired(now: now()) {
            throw UsageProviderError.notConnected(
                "Codex session expired - run codex to refresh it"
            )
        }

        // 3. The request.
        let request = Self.makeRequest(credentials: credentials)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw UsageProviderError.fetchFailed("Network error - check your connection")
        }

        // 4. Status handling. 401 and 403 are credential problems; the body of
        //    those is never parsed, because it is an error shape we do not own.
        switch response.statusCode {
        case 401, 403:
            throw UsageProviderError.notConnected(
                "ChatGPT rejected the saved credentials - sign in to Codex again"
            )
        case 200...299:
            break
        default:
            throw UsageProviderError.fetchFailed(
                "ChatGPT usage service returned HTTP \(response.statusCode)"
            )
        }

        // 5. Decode. An HTML interstitial served with a 200 must not read as an
        //    empty account, so a decode failure is a fetch failure.
        let payload: ChatGPTUsageResponse
        do {
            payload = try JSONDecoder().decode(ChatGPTUsageResponse.self, from: data)
        } catch {
            throw UsageProviderError.fetchFailed(
                "Unexpected response from ChatGPT usage service"
            )
        }

        guard payload.hasRecognizedPayload else {
            throw UsageProviderError.fetchFailed(
                "Unexpected response from ChatGPT usage service"
            )
        }

        // 6. Map. An empty array here is a real answer, not an error.
        return payload.toUsageLimits(now: now())
    }

    public static func makeRequest(credentials: CodexCredentials) -> URLRequest {
        var request = URLRequest(url: usageURL, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Both optional today (a live probe confirmed 200 with the auth header
        // and a generic User-Agent alone). Kept as cheap insurance against
        // future server-side gating, and they are the headers Codex itself
        // sends, so they cannot make this request look less like Codex.
        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("ChatGPTUsageTracker/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The only place a real network call happens.
    public static let urlSessionTransport: Transport = { request in
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}
