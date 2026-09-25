import SQLite3
import XCTest
@testable import ChatGPTUsageCore

/// Cursor credential store: missing database, missing key, expired token, and
/// valid token decoding. Tests that need a database build a fake one in /tmp
/// with in-process SQLite; none touch ~/Library or the real Cursor install.
final class CursorCredentialsTests: XCTestCase {

    private func makeJWT(exp: Double?) -> String {
        let payload: String
        if let exp {
            payload = "{\"sub\":\"user_abc\",\"exp\":\(Int(exp))}"
        } else {
            payload = "{\"sub\":\"user_abc\"}"
        }
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    /// Builds a minimal state.vscdb-shaped sqlite file with the given rows,
    /// using in-process SQLite (same library the production reader uses).
    private func makeDatabase(rows: [(String, String)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cursor-test-\(UUID().uuidString).vscdb")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw TestDatabaseError.cannotCreate
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT);", nil, nil, nil) == SQLITE_OK else {
            throw TestDatabaseError.cannotCreate
        }
        let sql = "INSERT INTO ItemTable(key, value) VALUES(?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TestDatabaseError.cannotCreate
        }
        defer { sqlite3_finalize(statement) }
        for (key, value) in rows {
            sqlite3_bind_text(statement, 1, key, -1, testTransient)
            sqlite3_bind_text(statement, 2, value, -1, testTransient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TestDatabaseError.cannotCreate
            }
            sqlite3_reset(statement)
        }
        return url
    }

    private enum TestDatabaseError: Error {
        case cannotCreate
    }

    private let testTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - 1. Missing database file

    func test_missingDatabase_throwsNotSignedIn() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "cursor-missing-\(UUID().uuidString).vscdb")
        let source = CursorDesktopCredentialsSource(databaseURL: missing)

        XCTAssertThrowsError(try source.load()) { error in
            XCTAssertEqual(
                error as? UsageProviderError,
                .notConnected("Cursor is not signed in - open Cursor IDE and sign in")
            )
        }
    }

    // MARK: - 2. Database without the token key

    func test_missingTokenKey_throwsNotSignedIn() throws {
        let db = try makeDatabase(rows: [("cursorAuth/cachedEmail", "dev@example.com")])
        defer { try? FileManager.default.removeItem(at: db) }
        let source = CursorDesktopCredentialsSource(databaseURL: db)

        XCTAssertThrowsError(try source.load()) { error in
            XCTAssertEqual(
                error as? UsageProviderError,
                .notConnected("Cursor is not signed in - open Cursor IDE and sign in")
            )
        }
    }

    // MARK: - 3. Valid token decodes email and tier

    func test_validToken_decodesEmailAndTier() throws {
        let token = makeJWT(exp: nil)
        let db = try makeDatabase(rows: [
            ("cursorAuth/accessToken", token),
            ("cursorAuth/cachedEmail", "dev@example.com"),
            ("cursorAuth/stripeMembershipType", "pro"),
        ])
        defer { try? FileManager.default.removeItem(at: db) }

        let credentials = try CursorDesktopCredentialsSource(databaseURL: db).load()

        XCTAssertEqual(credentials.accessToken, token)
        XCTAssertEqual(credentials.email, "dev@example.com")
        XCTAssertEqual(credentials.planTier, "pro")
        XCTAssertFalse(credentials.isExpired(now: TestDates.capture))
    }

    // MARK: - 4. Expired token reports expired

    func test_expiredToken_reportsExpired() throws {
        let past = TestDates.capture.addingTimeInterval(-3600).timeIntervalSince1970
        let token = makeJWT(exp: past)
        let db = try makeDatabase(rows: [("cursorAuth/accessToken", token)])
        defer { try? FileManager.default.removeItem(at: db) }

        let credentials = try CursorDesktopCredentialsSource(databaseURL: db).load()

        XCTAssertTrue(credentials.isExpired(now: TestDates.capture))
    }

    // MARK: - 5. Undecodable token means unknown expiry, never expired

    func test_undecodableToken_isNotExpired() {
        let credentials = CursorCredentials(
            accessToken: "not-a-jwt",
            email: nil,
            planTier: nil,
            expiresAt: CursorDesktopCredentialsSource.expiry(fromJWT: "not-a-jwt")
        )
        XCTAssertNil(credentials.expiresAt)
        XCTAssertFalse(credentials.isExpired(now: TestDates.capture))
    }

    // MARK: - 6. Malformed database file reports sign-in, not a crash

    func test_malformedDatabase_throwsNotSignedIn() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cursor-bad-\(UUID().uuidString).vscdb")
        try Data("not a database".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = CursorDesktopCredentialsSource(databaseURL: url)

        XCTAssertThrowsError(try source.load()) { error in
            XCTAssertEqual(
                error as? UsageProviderError,
                .notConnected("Cursor is not signed in - open Cursor IDE and sign in")
            )
        }
    }
}
