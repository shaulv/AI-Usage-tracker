import Foundation
import SQLite3

/// The only Cursor credential this app ever touches, and it only ever READS it.
///
/// Same two rules as the Codex path, stricter here because the store is a live
/// SQLite database Cursor holds open while it runs:
///
/// 1. Never refresh the token. The refresh token rotates, and consuming it
///    out-of-band can invalidate the IDE session. Cursor refreshes its own
///    store during normal use; this app just reads whatever is current.
/// 2. Never log a token, and never write to the database. Read-only, provably.
public struct CursorCredentials: Equatable {
    let accessToken: String
    let email: String?
    let planTier: String?
    /// From the JWT `exp` claim, epoch seconds. Nil when the token does not
    /// decode, which is treated as "expiry unknown", never as "expired".
    let expiresAt: Date?

    /// True when the token is provably past its expiry, with a 60 second grace
    /// window so clock skew between this Mac and Cursor does not lock the user
    /// out of their own dashboard.
    func isExpired(now: Date, grace: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(grace) < now
    }
}

/// The seam that makes every Cursor credential error testable without a real
/// database on disk. Implementations: the desktop database reader below and
/// test stubs.
public protocol CursorCredentialsSource {
    func load() throws -> CursorCredentials
}

/// Reads Cursor IDE's own credential store:
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`,
/// table `ItemTable`, keys `cursorAuth/accessToken`, `cursorAuth/cachedEmail`,
/// and `cursorAuth/stripeMembershipType`.
///
/// Why a temp copy first: Cursor holds the database open with a WAL lock while
/// it runs, so a direct query can return empty or SQLITE_LOCKED. Copying to a
/// unique file under /tmp with FileManager gives a stable snapshot, read through
/// an in-process read-only SQLite handle (same recipe as the Claude cookie
/// reader), and the temp file is deleted before returning. The live file is
/// never written to.
public struct CursorDesktopCredentialsSource: CursorCredentialsSource {
    let databaseURL: URL?

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
    }

    public func load() throws -> CursorCredentials {
        let sourceURL = databaseURL ?? Self.defaultDatabaseURL()
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw UsageProviderError.notConnected("Cursor is not signed in - open Cursor IDE and sign in")
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: "cursor-state-\(UUID().uuidString).vscdb")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
            for sidecar in ["-wal", "-shm", "-journal"] {
                let live = URL(fileURLWithPath: sourceURL.path + sidecar)
                if FileManager.default.fileExists(atPath: live.path) {
                    try? FileManager.default.copyItem(
                        at: live,
                        to: URL(fileURLWithPath: tempURL.path + sidecar)
                    )
                }
            }
        } catch {
            throw UsageProviderError.notConnected("Cursor is not signed in - open Cursor IDE and sign in")
        }
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempURL.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempURL.path + "-journal"))
        }
        let values: [String: String]
        do {
            values = try Self.readKeys(
                ["cursorAuth/accessToken", "cursorAuth/cachedEmail", "cursorAuth/stripeMembershipType"],
                from: tempURL
            )
        } catch {
            throw UsageProviderError.notConnected("Cursor is not signed in - open Cursor IDE and sign in")
        }
        let accessToken = (values["cursorAuth/accessToken"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw UsageProviderError.notConnected("Cursor is not signed in - open Cursor IDE and sign in")
        }
        return CursorCredentials(
            accessToken: accessToken,
            email: values["cursorAuth/cachedEmail"],
            planTier: values["cursorAuth/stripeMembershipType"],
            expiresAt: Self.expiry(fromJWT: accessToken)
        )
    }

    /// Best-effort decode of the JWT `exp` claim. Every failure path returns
    /// nil and the caller proceeds to the network, where the server's 401 is
    /// the real authority. A base64 quirk here must never lock a user out.
    public static func expiry(fromJWT token: String) -> Date? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let payload = Data(base64Encoded: base64) else { return nil }
        guard let claims = try? JSONDecoder().decode(JWTExpiry.self, from: payload) else { return nil }
        guard let exp = claims.exp, exp > 0 else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library")
            .appending(path: "Application Support")
            .appending(path: "Cursor")
            .appending(path: "User")
            .appending(path: "globalStorage")
            .appending(path: "state.vscdb")
    }

    /// Opens the snapshot copy strictly read-only in SQLite's `immutable=1`
    /// mode, which skips all locking and WAL recovery on the frozen /tmp
    /// copy. No subprocess, no shell — same recipe as the Claude cookie reader.
    static func readKeys(_ keys: [String], from databaseURL: URL) throws -> [String: String] {
        var db: OpaquePointer?
        // Immutable mode: the snapshot is a frozen copy, so SQLite skips all
        // locking and WAL recovery instead of trying to join the live WAL.
        let uri = "file:" + databaseURL.path + "?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            throw CursorDatabaseError.unreadable
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT key, value FROM ItemTable;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CursorDatabaseError.unreadable
        }
        defer { sqlite3_finalize(statement) }
        var values: [String: String] = [:]
        let wanted = Set(keys)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(statement, 0),
                  let valueC = sqlite3_column_text(statement, 1)
            else { continue }
            let key = String(cString: keyC)
            guard wanted.contains(key) else { continue }
            values[key] = String(cString: valueC)
        }
        return values
    }

    private struct JWTExpiry: Decodable {
        let exp: Double?
    }

    enum CursorDatabaseError: Error {
        case unreadable
    }
}
