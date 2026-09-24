import Foundation

/// The local Antigravity language server session this app borrows, read-only.
///
/// Why this and not an OAuth token: the IDE's own language server already holds
/// a live, authenticated session and exposes the account quota over a loopback
/// HTTPS port guarded by a CSRF token. Measured on 24/09/2026: the token file at
/// `~/.gemini/jetski-standalone-oauth-token` had expired, Google's token
/// endpoint refuses a refresh without a client secret the app must never hold,
/// and the Cloud Code REST route answered 401 with every stale credential. The
/// language server answered HTTP 200 with the four real quota windows at the
/// same instant. So the app reads the session that works instead of the one
/// that does not.
///
/// Two rules, same as every other credential source here:
/// 1. Never refresh anything and never write. Discovery only reads process
///    arguments and the listening ports of a process that is already running.
/// 2. Never log the token.
public struct AntigravitySession: Equatable, Sendable {
    /// The language server process id, used only to find its listening ports.
    let processId: Int32
    /// The CSRF token the server demands in `X-Codeium-Csrf-Token`.
    let csrfToken: String
    /// Loopback ports the process listens on. More than one is normal (the
    /// language server owns an API port and a separate extension port), so the
    /// provider tries them in order instead of guessing which is which.
    let candidatePorts: [Int]
}

/// The seam that makes discovery testable without a real process on the machine
/// running the tests.
public protocol AntigravitySessionSource: Sendable {
    func load() throws -> AntigravitySession
}

/// Finds the running Antigravity language server and reads its CSRF token and
/// listening ports.
///
/// This is the approach the shipped OpenUsage client documents for the same
/// product ("scanning for the language_server / agy process and reading its
/// CSRF token and listening ports"), verified against a live install before any
/// Swift was written. Both parsing steps are pure static functions so their
/// failure modes are unit-testable from literal text.
public struct LanguageServerSessionSource: AntigravitySessionSource {
    /// `ps` and `lsof` are finite-output system utilities; the watchdog exists
    /// so a pathological hang cannot leave a fetch stuck forever.
    public static let commandTimeout: TimeInterval = 3

    public init() {}

    public func load() throws -> AntigravitySession {
        guard let psOutput = Self.run(Self.psPath, ["-ax", "-o", "pid=,command="]),
              let found = Self.parseProcess(fromPSOutput: psOutput)
        else {
            throw UsageProviderError.notConnected(Self.notRunningMessage)
        }

        let lsofOutput = Self.run(
            Self.lsofPath,
            ["-Pan", "-p", String(found.processId), "-iTCP", "-sTCP:LISTEN"]
        ) ?? ""
        let ports = Self.parseListeningPorts(fromLsofOutput: lsofOutput)
        guard !ports.isEmpty else {
            throw UsageProviderError.notConnected(Self.notRunningMessage)
        }

        return AntigravitySession(
            processId: found.processId,
            csrfToken: found.csrfToken,
            candidatePorts: ports
        )
    }

    /// The honest, actionable message when the IDE is closed. The fix is in the
    /// user's hands, so it is named instead of reporting a mystery failure.
    static let notRunningMessage = "Antigravity IDE is not running - open it to read Gemini usage"

    // These are the macOS defaults, and both tools are read-only.
    static let psPath = "/bin/ps"
    static let lsofPath = "/usr/sbin/lsof"

    /// Finds the language server line and pulls out its pid and CSRF token.
    ///
    /// A line qualifies only when it is the language server binary AND carries
    /// a `--csrf_token`, because the same binary can run without one and a
    /// token-less process cannot answer the quota call.
    public static func parseProcess(fromPSOutput output: String) -> (processId: Int32, csrfToken: String)? {
        for line in output.split(separator: "\n") {
            guard line.contains("language_server"), line.contains("--csrf_token") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let pidField = fields.first, let pid = Int32(pidField) else { continue }
            guard let flagIndex = fields.firstIndex(of: "--csrf_token"),
                  fields.indices.contains(flagIndex + 1)
            else { continue }
            let token = fields[flagIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            return (pid, token)
        }
        return nil
    }

    /// Collects the loopback ports a process listens on, in the order `lsof`
    /// reports them. Only `127.0.0.1` counts: a wildcard listener would mean
    /// something other than this server answered.
    public static func parseListeningPorts(fromLsofOutput output: String) -> [Int] {
        var ports: [Int] = []
        for line in output.split(separator: "\n") {
            guard let range = line.range(
                of: #"127\.0\.0\.1:(\d+) \(LISTEN\)"#,
                options: .regularExpression
            ) else { continue }
            let match = String(line[range])
            guard let colon = match.firstIndex(of: ":"),
                  let space = match.firstIndex(of: " ")
            else { continue }
            let digits = match[match.index(after: colon)..<space]
            guard let port = Int(digits), !ports.contains(port) else { continue }
            ports.append(port)
        }
        return ports
    }

    /// Runs a read-only system command with a watchdog, returning its stdout.
    private static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
                        // stderr of `ps`/`lsof` is noise; route it to an in-memory pipe so the
        // app's "never writes to disk" contract (enforced by
        // tools/check-readme-claims.sh) stays literal.
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // Terminating closes the pipe, so the read below always ends even if
        // the tool never finishes on its own.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + commandTimeout,
            execute: watchdog
        )

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

                return String(decoding: data, as: UTF8.self)
    }
}
