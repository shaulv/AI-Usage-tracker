import Foundation

/// Fetches the Grok Bot weekly usage window from the same dashboard endpoint
/// Grok Bot's own profile screen reads.
///
/// Same contract shape as the ChatGPT, Claude, Cursor, and Gemini providers:
/// one read-only endpoint, no quota spent, no session consumed, nothing
/// written anywhere. The only local reads are `sand-secrets.json` and the
/// Keychain password that decrypts it, both already held by Grok Bot.
///
/// Why this endpoint and not the Grok CLI billing proxy: measured on
/// 29/09/2026, `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
/// answered 200 but carried NO weekly percent for this account (no
/// `creditUsagePercent`, no `productUsage`), while `GetSandUsageStatus`
/// answered 200 with the real weekly window in the same minute. So the app
/// reads the session that reports instead of the one that does not.
public final class GrokUsageProvider: UsageProvider {
    public let id = "grok"
    public let displayName = "Grok"

    public static let usageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
    )!
    public static let timeout: TimeInterval = 15
    static let clientVersion = "0.61.0"

    private let credentialsSource: any GrokCredentialsSource
    private let transport: ChatGPTUsageProvider.Transport
    private let now: () -> Date

    public init(
        credentialsSource: any GrokCredentialsSource = GrokBotCredentialsSource(),
        transport: @escaping ChatGPTUsageProvider.Transport = ChatGPTUsageProvider.urlSessionTransport,
        now: @escaping () -> Date = { Date() }
    ) {
        self.credentialsSource = credentialsSource
        self.transport = transport
        self.now = now
    }

    public func fetchLimits() async throws -> [UsageLimit] {
        let source = credentialsSource
        let credentials = try await Task.detached(priority: .userInitiated) {
            try source.load()
        }.value
        if credentials.isExpired(now: now()) {
            throw UsageProviderError.notConnected(
                "Grok session expired - open Grok Bot to refresh it"
            )
        }
        let request = Self.makeRequest(credentials: credentials, now: now())
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw UsageProviderError.fetchFailed("Network error - check your connection")
        }
        switch response.statusCode {
        case 401, 403:
            throw UsageProviderError.notConnected(
                "Grok rejected the saved credentials - sign in to Grok Bot again"
            )
        case 200...299:
            break
        default:
            throw UsageProviderError.fetchFailed(
                "Grok usage service returned HTTP \(response.statusCode)"
            )
        }
        let payload: GrokUsageResponse
        do {
            payload = try JSONDecoder().decode(GrokUsageResponse.self, from: data)
        } catch {
            throw UsageProviderError.fetchFailed(
                "Unexpected response from Grok usage service"
            )
        }
        guard payload.hasRecognizedPayload else {
            throw UsageProviderError.fetchFailed(
                "Unexpected response from Grok usage service"
            )
        }
        return payload.toUsageLimits(now: now())
    }

    public static func makeRequest(
        credentials: GrokCredentials,
        now: Date = Date()
    ) -> URLRequest {
        var request = URLRequest(url: usageURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(checksum(machineId: credentials.machineId, now: now), forHTTPHeaderField: "x-cursor-checksum")
        request.setValue("sand", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue("sand-desktop", forHTTPHeaderField: "x-cursor-client-source")
        request.setValue(clientVersion, forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("prod", forHTTPHeaderField: "x-sand-box-namespace")
        request.setValue("CLIENT_OS_MACOS", forHTTPHeaderField: "x-cursor-client-os")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")
        request.setValue("ChatGPTUsageTracker/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)
        return request
    }

    /// The request checksum Grok Bot sends (`createCursorChecksum` in the
    /// shipped bundle): a 6-byte big-endian timestamp (millis/1e6) scrambled
    /// with a rolling XOR, base64url-encoded without padding, concatenated
    /// with the machine id. Pure so the format is unit-testable without a
    /// live server.
    static func checksum(machineId: String, now: Date) -> String {
        let t = UInt64((now.timeIntervalSince1970 * 1000).rounded() / 1_000_000)
        var bytes = [
            UInt8((t >> 40) & 0xFF), UInt8((t >> 32) & 0xFF),
            UInt8((t >> 24) & 0xFF), UInt8((t >> 16) & 0xFF),
            UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF),
        ]
        var key: UInt8 = 165
        for i in bytes.indices {
            bytes[i] = ((bytes[i] ^ key) &+ UInt8(i)) & 0xFF
            key = bytes[i]
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded + machineId
    }
}
