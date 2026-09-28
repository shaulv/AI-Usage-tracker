import XCTest
@testable import ChatGPTUsageCore

/// Grok credentials: secrets-file parsing, v10 decrypt shape, and JWT expiry.
/// No test touches the real secrets file or the Keychain.
final class GrokCredentialsTests: XCTestCase {

    func test_decryptToken_rejectsWrongShapes() {
        let key = Data(repeating: 0x01, count: 16)
        XCTAssertNil(GrokBotCredentialsSource.decryptToken(Data(), key: key))
        XCTAssertNil(GrokBotCredentialsSource.decryptToken(Data("v10".utf8), key: key))
        XCTAssertNil(GrokBotCredentialsSource.decryptToken(Data("v11".utf8) + Data(repeating: 0, count: 16), key: key))
        XCTAssertNil(GrokBotCredentialsSource.decryptToken(Data("v10".utf8) + Data(repeating: 0, count: 16), key: Data()))
    }

    func test_parseCredentials_rejectsGarbageFile() {
        XCTAssertThrowsError(try GrokBotCredentialsSource.parseCredentials(Data("{oops".utf8), keychainPassword: "pw"))
        XCTAssertThrowsError(try GrokBotCredentialsSource.parseCredentials(Data("{}".utf8), keychainPassword: "pw"))
    }

    func test_parseCredentials_rejectsMissingToken() throws {
        let accounts = "{\"active\":\"slot\",\"accounts\":{}}"
        let file = "{\"cursor-machine-id\":\"mid\",\"cursor-accounts\":" + quoted(accounts) + "}"
        do {
            _ = try GrokBotCredentialsSource.parseCredentials(Data(file.utf8), keychainPassword: "pw")
            XCTFail("expected notConnected")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .notConnected("Grok Bot is not signed in - open Grok Bot and sign in"))
        }
    }

    func test_parseCredentials_rejectsUndecryptableBlob() throws {
        let blob = Data("v10".utf8) + Data(repeating: 0x00, count: 32)
        let accounts = "{\"active\":\"slot\",\"accounts\":{\"slot\":{\"cursor-access-token\":\"" + blob.base64EncodedString() + "\"}}}"
        let file = "{\"cursor-machine-id\":\"mid\",\"cursor-accounts\":" + quoted(accounts) + "}"
        do {
            _ = try GrokBotCredentialsSource.parseCredentials(Data(file.utf8), keychainPassword: "pw")
            XCTFail("expected notConnected")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .notConnected("Grok Bot rejected the saved session - reopen Grok Bot to refresh it"))
        }
    }

    func test_expiry_nilForGarbage() {
        XCTAssertNil(GrokBotCredentialsSource.expiry(fromJWT: ""))
        XCTAssertNil(GrokBotCredentialsSource.expiry(fromJWT: "not-a-jwt"))
    }

    func test_expiry_decodesExpClaim() {
        // exp 1795475364 = 2026-10-26T...Z (the live Grok Bot session shape).
        let payload = "eyJzdWIiOiJ4IiwiZXhwIjoxNzk1NDc1MzY0fQ"
        let token = "eyJhbGciOiJIUzI1NiJ9." + payload + ".sig"
        let date = GrokBotCredentialsSource.expiry(fromJWT: token)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_795_475_364, accuracy: 1)
    }

    func test_isExpired_respectsGraceWindow() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let fresh = GrokCredentials(accessToken: "t", machineId: "m", email: nil, expiresAt: now.addingTimeInterval(3600))
        XCTAssertFalse(fresh.isExpired(now: now))
        let stale = GrokCredentials(accessToken: "t", machineId: "m", email: nil, expiresAt: now.addingTimeInterval(-3600))
        XCTAssertTrue(stale.isExpired(now: now))
        let unknown = GrokCredentials(accessToken: "t", machineId: "m", email: nil, expiresAt: nil)
        XCTAssertFalse(unknown.isExpired(now: now))
    }

    private func quoted(_ raw: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [raw])
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }
}
