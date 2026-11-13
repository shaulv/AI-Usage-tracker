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

    public typealias LocalFallback = @Sendable (Date) -> [UsageLimit]?

    private let sessionSource: any ClaudeSessionSource
    /// Same seam as ChatGPT: tests inject spies, production gets the one
    /// URLSession call site that already exists in `ChatGPTUsageProvider`.
    private let transport: ChatGPTUsageProvider.Transport
    private let now: () -> Date
    private let localFallback: LocalFallback

    public init(
        sessionSource: any ClaudeSessionSource = ClaudeDesktopSessionSource(),
        transport: @escaping ChatGPTUsageProvider.Transport = ChatGPTUsageProvider.urlSessionTransport,
        now: @escaping () -> Date = { Date() },
        localFallback: LocalFallback? = nil
    ) {
        self.sessionSource = sessionSource
        self.transport = transport
        self.now = now
        if let localFallback {
            self.localFallback = localFallback
        } else if sessionSource is ClaudeDesktopSessionSource {
            self.localFallback = { date in
                ClaudeLocalUsageFallback.loadLimits(now: date)
            }
        } else {
            self.localFallback = { _ in nil }
        }
    }

    public func fetchLimits() async throws -> [UsageLimit] {
        do {
            return try await fetchLiveLimits()
        } catch let error as UsageProviderError {
            if case .notConnected = error,
               let fallbackLimits = localFallback(now()),
               !fallbackLimits.isEmpty {
                return fallbackLimits
            }
            throw error
        }
    }

    private func fetchLiveLimits() async throws -> [UsageLimit] {
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

    public static let oauthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func usageURL(organizationId: String) -> URL {
        URL(string: "https://claude.ai/api/organizations/\(organizationId)/usage")!
    }

    public static func makeRequest(session: ClaudeSession) -> URLRequest {
        if let accessToken = session.accessToken, !accessToken.isEmpty {
            var request = URLRequest(url: oauthUsageURL, timeoutInterval: timeout)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            return request
        }

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

/// Read-only fallback that inspects Claude Desktop's unencrypted local usage
/// and rate-limit state in `~/Library/Application Support/Claude` when live
/// credentials cannot be read (for example, when macOS Keychain is locked and
/// Electron `safeStorage` cannot decrypt or persist OAuth tokens).
public enum ClaudeLocalUsageFallback {
    public static var defaultApplicationSupportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    public static func loadLimits(
        applicationSupportURL: URL = defaultApplicationSupportURL,
        now: Date = Date()
    ) -> [UsageLimit]? {
        var limits: [UsageLimit] = []

        func clampFraction(_ percent: Double) -> Double {
            min(max(percent, 0), 100) / 100
        }

        // 1. Active rate-limit reset persisted in claude_desktop_config.json
        //    (`preferences["epitaxyPrefs"]["autoResumeRateLimit.<accountUuid>"]["<sessionId>"]["resetsAt"]`)
        //    or in `claude-code-sessions/*/*/*.json`.
        let desktopConfigURL = applicationSupportURL.appendingPathComponent("claude_desktop_config.json")
        let sessionsRootURL = applicationSupportURL.appendingPathComponent("claude-code-sessions", isDirectory: true)
        if let activeReset = loadActiveRateLimitReset(from: desktopConfigURL, now: now) {
            limits.append(UsageLimit(
                name: WindowNamer.name(forWindowSeconds: 18_000, fallback: "Session"),
                usedFraction: 1.0,
                resetsAt: activeReset
            ))
        } else if let sessionErrorLimit = loadRecentFiveHourSessionLimitError(in: sessionsRootURL, now: now) {
            limits.append(sessionErrorLimit)
        }

        // 2. Cached `/api/organizations/{org}/usage` responses in Claude Desktop's
        //    Chromium SimpleCache (`Cache/Cache_Data/*_0`), which carry the full
        //    `five_hour`, `seven_day` (`Weekly`), and `limits` (`Weekly (Fable)`, etc.)
        //    payloads with exact RFC 3339 `resets_at` timestamps.
        let cacheDataURL = applicationSupportURL.appendingPathComponent("Cache/Cache_Data", isDirectory: true)
        for cachedLimit in loadCachedUsageEndpointLimits(from: cacheDataURL, now: now) {
            if !limits.contains(where: { $0.name == cachedLimit.name }) {
                limits.append(cachedLimit)
            }
        }

        // 3. Plan usage history samples persisted by Claude Desktop's tray usage
        //    poller in `plan-usage-history.json`.
        let historyURL = applicationSupportURL.appendingPathComponent("plan-usage-history.json")
        for historyLimit in loadHistoryLimits(from: historyURL, now: now, clampFraction: clampFraction) {
            if !limits.contains(where: { $0.name == historyLimit.name }) {
                limits.append(historyLimit)
            }
        }

        let uniqued = UsageLimit.uniqued(limits)
        return uniqued.isEmpty ? nil : uniqued
    }

    private static func loadActiveRateLimitReset(from configURL: URL, now: Date) -> Date? {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let preferences = root["preferences"] as? [String: Any]
        else {
            return nil
        }

        var candidateMaps: [[String: Any]] = [preferences]
        if let epitaxyPrefs = preferences["epitaxyPrefs"] as? [String: Any] {
            candidateMaps.append(epitaxyPrefs)
        }

        var latestReset: Date?
        for map in candidateMaps {
            for (key, value) in map where key.hasPrefix("autoResumeRateLimit.") {
                guard let sessions = value as? [String: Any] else { continue }
                for (_, sessionValue) in sessions {
                    guard let entry = sessionValue as? [String: Any],
                          let rawReset = numericDouble(entry["resetsAt"])
                    else {
                        continue
                    }
                    let seconds = rawReset > 1_000_000_000_000 ? rawReset / 1000.0 : rawReset
                    let resetDate = Date(timeIntervalSince1970: seconds)
                    guard resetDate > now else { continue }
                    if let current = latestReset {
                        if resetDate > current {
                            latestReset = resetDate
                        }
                    } else {
                        latestReset = resetDate
                    }
                }
            }
        }
        return latestReset
    }

    private static func loadRecentFiveHourSessionLimitError(in sessionsRoot: URL, now: Date) -> UsageLimit? {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let errorText = obj["error"] as? String,
                  errorText.localizedCaseInsensitiveContains("5-hour limit"),
                  let rawErrorAt = numericDouble(obj["errorAt"])
            else {
                continue
            }
            let errorSeconds = rawErrorAt > 1_000_000_000_000 ? rawErrorAt / 1000.0 : rawErrorAt
            let age = now.timeIntervalSince1970 - errorSeconds
            if age >= 0 && age < 18_000 {
                return UsageLimit(
                    name: WindowNamer.name(forWindowSeconds: 18_000, fallback: "Session"),
                    usedFraction: 1.0,
                    resetsAt: nil
                )
            }
        }
        return nil
    }

    private static func loadHistoryLimits(
        from historyURL: URL,
        now: Date,
        clampFraction: (Double) -> Double
    ) -> [UsageLimit] {
        guard let data = try? Data(contentsOf: historyURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]]
        else {
            return []
        }

        var result: [UsageLimit] = []
        let nowSeconds = now.timeIntervalSince1970

        for sample in samples.reversed() {
            guard let rawTime = numericDouble(sample["t"]) else { continue }
            let sampleSeconds = rawTime > 1_000_000_000_000 ? rawTime / 1000.0 : rawTime
            let age = max(0, nowSeconds - sampleSeconds)

            let buckets: [String: Any]
            if let u = sample["u"] as? [String: Any] {
                buckets = u
            } else {
                buckets = sample
            }

            if age < 18_000, let fh = numericDouble(buckets["fh"]) {
                result.append(UsageLimit(
                    name: WindowNamer.name(forWindowSeconds: 18_000, fallback: "Session"),
                    usedFraction: clampFraction(fh),
                    resetsAt: nil
                ))
            }
            if age < 604_800 {
                if let sd = numericDouble(buckets["sd"]) {
                    result.append(UsageLimit(
                        name: WindowNamer.name(forWindowSeconds: 604_800, fallback: "Weekly"),
                        usedFraction: clampFraction(sd),
                        resetsAt: nil
                    ))
                }
                if let so = numericDouble(buckets["so"]) {
                    result.append(UsageLimit(
                        name: "Weekly (Opus)",
                        usedFraction: clampFraction(so),
                        resetsAt: nil
                    ))
                }
                if let sn = numericDouble(buckets["sn"]) {
                    result.append(UsageLimit(
                        name: "Weekly (Sonnet)",
                        usedFraction: clampFraction(sn),
                        resetsAt: nil
                    ))
                }
                if let xu = numericDouble(buckets["xu"]) {
                    result.append(UsageLimit(
                        name: "Extra usage",
                        usedFraction: clampFraction(xu),
                        resetsAt: nil
                    ))
                }
            }

            if !result.isEmpty {
                break
            }
        }

        return result
    }

    private static func loadCachedUsageEndpointLimits(from cacheDataURL: URL, now: Date) -> [UsageLimit] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDataURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let markerOrg = Data("claude.ai/api/organizations/".utf8)
        let markerUsage = Data("/usage".utf8)

        var candidates: [(url: URL, mtime: Date, raw: Data)] = []
        for fileURL in urls where fileURL.lastPathComponent.hasSuffix("_0") {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 64, size < 512_000,
                  let raw = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
            else {
                continue
            }
            let header = raw.prefix(320)
            guard let orgRange = header.range(of: markerOrg),
                  let usageRange = header.range(of: markerUsage, in: orgRange.upperBound..<header.endIndex)
            else {
                continue
            }
            // Exclude `/usage/activity` and similar sub-routes.
            if usageRange.upperBound < header.endIndex {
                let nextByte = header[usageRange.upperBound]
                if nextByte == UInt8(ascii: "/") {
                    continue
                }
            }
            let mtime = values.contentModificationDate ?? .distantPast
            candidates.append((url: fileURL, mtime: mtime, raw: raw))
        }

        candidates.sort { $0.mtime > $1.mtime }

        for candidate in candidates {
            guard let jsonData = extractUsageJSONFromCacheEntry(candidate.raw),
                  let parsed = try? ClaudeUsageMapper.limits(from: jsonData)
            else {
                continue
            }
            let active = parsed.filter { limit in
                guard let reset = limit.resetsAt else { return true }
                return reset > now
            }
            if !active.isEmpty {
                return active
            }
        }

        return []
    }

    private static func extractUsageJSONFromCacheEntry(_ raw: Data) -> Data? {
        // 1. Zstandard frame (`0x28 0xB5 0x2F 0xFD`) inside SimpleCache entry.
        let zstdMagic = Data([0x28, 0xB5, 0x2F, 0xFD])
        var searchStart = raw.startIndex
        while let magicRange = raw.range(of: zstdMagic, in: searchStart..<raw.endIndex) {
            let slice = raw.subdata(in: magicRange.lowerBound..<raw.endIndex)
            if let decompressed = decompressZstdFrame(slice),
               decompressed.first == UInt8(ascii: "{") {
                return decompressed
            }
            searchStart = magicRange.lowerBound + 1
        }

        // 2. Uncompressed JSON payload inside SimpleCache entry.
        for marker in [Data("{\"five_hour\"".utf8), Data("{\"limits\"".utf8)] {
            if let range = raw.range(of: marker),
               let jsonSlice = extractBalancedJSONObject(from: raw, startingAt: range.lowerBound) {
                return jsonSlice
            }
        }

        return nil
    }

    private static func extractBalancedJSONObject(from data: Data, startingAt start: Int) -> Data? {
        var depth = 0
        var inString = false
        var escaped = false

        for index in start..<data.endIndex {
            let byte = data[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }

            if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    return data.subdata(in: start..<(index + 1))
                }
            }
        }

        return nil
    }

    private static func decompressZstdFrame(_ data: Data) -> Data? {
        let candidates = [
            "/opt/homebrew/lib/libzstd.dylib",
            "/opt/homebrew/lib/libzstd.1.dylib",
            "/usr/local/lib/libzstd.dylib",
            "libzstd.dylib",
        ]
        var handle: UnsafeMutableRawPointer?
        for path in candidates {
            if let opened = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
                handle = opened
                break
            }
        }
        guard let handle else { return nil }
        defer { dlclose(handle) }

        typealias FindCompressedSizeFn = @convention(c) (UnsafeRawPointer, Int) -> Int
        typealias DecompressFn = @convention(c) (UnsafeMutableRawPointer, Int, UnsafeRawPointer, Int) -> Int
        typealias IsErrorFn = @convention(c) (Int) -> UInt32

        guard let findSym = dlsym(handle, "ZSTD_findFrameCompressedSize"),
              let decompSym = dlsym(handle, "ZSTD_decompress"),
              let isErrSym = dlsym(handle, "ZSTD_isError")
        else {
            return nil
        }

        let findCompressedSize = unsafeBitCast(findSym, to: FindCompressedSizeFn.self)
        let decompress = unsafeBitCast(decompSym, to: DecompressFn.self)
        let isError = unsafeBitCast(isErrSym, to: IsErrorFn.self)

        let capacity = 65_536
        var output = Data(count: capacity)
        let decompressedSize = data.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress, rawBuffer.count >= 4 else { return -1 }
            let compressedSize = findCompressedSize(baseAddress, rawBuffer.count)
            guard isError(compressedSize) == 0, compressedSize > 0, compressedSize <= rawBuffer.count else {
                return -1
            }
            return output.withUnsafeMutableBytes { outBuffer -> Int in
                guard let outBase = outBuffer.baseAddress else { return -1 }
                return decompress(outBase, capacity, baseAddress, compressedSize)
            }
        }
        guard decompressedSize > 0, isError(decompressedSize) == 0, decompressedSize <= capacity else {
            return nil
        }
        output.count = decompressedSize
        return output
    }

    private static func numericDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
