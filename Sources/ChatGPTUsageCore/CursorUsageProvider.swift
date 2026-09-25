import Foundation

/// Fetches the account's monthly usage pools from Cursor's own dashboard API.
///
/// This is the ONLY Cursor endpoint this app polls. It is read-only and
/// consumes no quota. The request is a Connect RPC v1 POST with an empty JSON
/// body, authenticated with the Bearer token Cursor IDE already stores
/// locally: no API key needed, nothing written back, nothing refreshed.
/// Cursor has no session or weekly windows: two monthly pools only, both
/// resetting on the billing cycle end (unused does not roll over).
public final class CursorUsageProvider: UsageProvider {
    public let id = "cursor"
    public let displayName = "Cursor"

    public static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    public static let timeout: TimeInterval = 15

    private let credentialsSource: any CursorCredentialsSource
    private let transport: ChatGPTUsageProvider.Transport
    private let now: () -> Date

    public init(
        credentialsSource: any CursorCredentialsSource = CursorDesktopCredentialsSource(),
        transport: @escaping ChatGPTUsageProvider.Transport = ChatGPTUsageProvider.urlSessionTransport,
        now: @escaping () -> Date = { Date() }
    ) {
        self.credentialsSource = credentialsSource
        self.transport = transport
        self.now = now
    }

    public func fetchLimits() async throws -> [UsageLimit] {
        // 1. Credentials, read-only from the IDE database copy. Detached on
        //    purpose: the copy plus sqlite3 spawn can block, and a blocked
        //    main thread would freeze the panel and the status item.
        let source = credentialsSource
        let credentials = try await Task.detached(priority: .userInitiated) {
            try source.load()
        }.value

        // 2. Expiry gate BEFORE any network call. An already-expired token
        //    gets a local message and costs nothing. If the JWT did not
        //    decode, we proceed: the server's 401 is the authority.
        if credentials.isExpired(now: now()) {
            throw UsageProviderError.notConnected(
                "Cursor session expired - open Cursor to refresh it"
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
                "Cursor rejected the saved credentials - sign in to Cursor again"
            )
        case 200...299:
            break
        default:
            throw UsageProviderError.fetchFailed(
                "Cursor usage service returned HTTP \(response.statusCode)"
            )
        }

        // 5. Decode. A decode failure is a fetch failure, never an empty
        //    account: an empty account still decodes with nil pools.
        let payload: CursorUsageResponse
        do {
            payload = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
        } catch {
            throw UsageProviderError.fetchFailed(
                "Unexpected response from Cursor usage service"
            )
        }

        guard payload.hasRecognizedPayload else {
            throw UsageProviderError.fetchFailed(
                "Unexpected response from Cursor usage service"
            )
        }

        // 6. Map. Both monthly rows always render (missing pool at zero with
        //    a not-included suffix), so this never returns an empty array
        //    from a recognized payload.
        return payload.toUsageLimits(now: now())
    }

    public static func makeRequest(credentials: CursorCredentials) -> URLRequest {
        var request = URLRequest(url: usageURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("CursorUsageTracker/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)
        return request
    }
}
