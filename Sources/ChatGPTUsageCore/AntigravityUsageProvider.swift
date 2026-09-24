import Foundation

/// Fetches the account's quota windows from the running Antigravity language
/// server, authenticated with the CSRF token that server already demands from
/// its own IDE extension.
///
/// Same contract shape as the ChatGPT and Claude providers: one read-only
/// endpoint, no quota spent, no session consumed, nothing written anywhere. The
/// only local reads are the process arguments and listening ports of a server
/// that is already running, so an IDE that is closed costs nothing and reports
/// the fix honestly.
///
/// Why loopback and not the public Cloud Code API: measured on 24/09/2026, every
/// OAuth route answered 401 with the credentials this Mac holds (the IDE's token
/// file was expired and a refresh needs a client secret the app must never
/// store), while this endpoint answered 200 with the four real windows in the
/// same minute.
public final class AntigravityUsageProvider: UsageProvider {
    public let id = "antigravity"
    public let displayName = "Gemini"

    public static let timeout: TimeInterval = 15
    /// The language server's gRPC-style method, called over its loopback HTTPS
    /// port. This is the one endpoint that reports both pools AND both windows;
    /// the older per-model method only knows the 5-hour window.
    static let quotaPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    /// The header name the server enforces; a wrong name is answered 401
    /// `missing CSRF token`, which is how the name was confirmed.
    static let csrfHeader = "X-Codeium-Csrf-Token"

    private let sessionSource: any AntigravitySessionSource
    /// Same seam as ChatGPT and Claude: tests inject spies, production gets the
    /// one URLSession call site below.
    private let transport: ChatGPTUsageProvider.Transport
    private let now: () -> Date

    public init(
        sessionSource: any AntigravitySessionSource = LanguageServerSessionSource(),
        transport: @escaping ChatGPTUsageProvider.Transport = AntigravityUsageProvider.localServerTransport,
        now: @escaping () -> Date = { Date() }
    ) {
        self.sessionSource = sessionSource
        self.transport = transport
        self.now = now
    }

    public func fetchLimits() async throws -> [UsageLimit] {
        // Discovery runs off the main actor on purpose: it spawns two short
        // system commands, and the panel must never wait on a process listing.
        let source = sessionSource
        let session = try await Task.detached(priority: .userInitiated) {
            try source.load()
        }.value

        var lastFailure: UsageProviderError?
        for port in session.candidatePorts {
            let request = Self.makeRequest(session: session, port: port)
            do {
                let (data, response) = try await transport(request)
                switch response.statusCode {
                case 200...299:
                    return try AntigravityUsageMapper.limits(from: data)
                case 401, 403:
                    // The IDE rotated its session since discovery: restarting
                    // the IDE is the fix, so say that rather than retrying a
                    // token that is provably refused.
                    throw UsageProviderError.notConnected(
                        "Antigravity rejected the local session - restart Antigravity IDE"
                    )
                default:
                    lastFailure = .fetchFailed(
                        "Antigravity usage service returned HTTP \(response.statusCode)"
                    )
                }
            } catch let error as UsageProviderError {
                if case .notConnected = error { throw error }
                lastFailure = error
            } catch {
                // A port that is not the API port is the normal case here, so
                // remember it and try the next one.
                lastFailure = .fetchFailed("Could not reach the Antigravity language server")
            }
        }

        throw lastFailure ?? .fetchFailed("Could not reach the Antigravity language server")
    }

    public static func quotaURL(port: Int) -> URL {
        URL(string: "https://127.0.0.1:\(port)\(quotaPath)")!
    }

    public static func makeRequest(session: AntigravitySession, port: Int) -> URLRequest {
        var request = URLRequest(url: quotaURL(port: port), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(session.csrfToken, forHTTPHeaderField: csrfHeader)
        // The server requires a metadata block identifying the caller, the same
        // block its own IDE extension sends.
        let body = #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#
        request.httpBody = Data(body.utf8)
        return request
    }

    /// Loopback only. The language server presents a self-signed certificate,
    /// so default evaluation would refuse a request to the machine itself. This
    /// delegate accepts the server's own trust object for 127.0.0.1, localhost
    /// and ::1 and nothing else; every other request keeps the default
    /// evaluation, and no other provider uses this transport.
    public static let localServerTransport: ChatGPTUsageProvider.Transport = { request in
        let session = URLSession(
            configuration: .ephemeral,
            delegate: localTrustDelegate,
            delegateQueue: nil
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }

    private static let localTrustDelegate = LocalLoopbackTrustDelegate()
}

/// Accepts the local server's self-signed certificate for loopback hosts only.
private final class LocalLoopbackTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard Self.loopbackHosts.contains(challenge.protectionSpace.host),
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
