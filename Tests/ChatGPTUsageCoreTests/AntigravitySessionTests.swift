import Foundation
import XCTest
@testable import ChatGPTUsageCore

/// Process and port discovery, tested against the literal text the real tools
/// emit. Both parsers are pure so the failure modes are assertable with no
/// process on the machine running the tests.
final class AntigravitySessionTests: XCTestCase {

    // The real line shape, with a forced token and a shortened path.
    private let realPSLine = " 1357 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --enable_lsp --csrf_token FORCED-CSRF --extension_server_port 49472 --cloud_code_endpoint https://cloudcode-pa.googleapis.com"

    func test_parseProcess_readsPidAndCSRFToken() throws {
        let found = try XCTUnwrap(LanguageServerSessionSource.parseProcess(fromPSOutput: realPSLine))
        XCTAssertEqual(found.processId, 1357)
        XCTAssertEqual(found.csrfToken, "FORCED-CSRF")
    }

    func test_parseProcess_skipsLanguageServerLinesWithoutAToken() {
        let line = " 1454 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --enable_lsp"
        XCTAssertNil(LanguageServerSessionSource.parseProcess(fromPSOutput: line))
    }

    func test_parseProcess_ignoresUnrelatedProcesses() {
        let output = """
        1 /sbin/launchd
        999 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --csrf_token NOT-A-SERVER
        """
        XCTAssertNil(LanguageServerSessionSource.parseProcess(fromPSOutput: output))
    }

    // The IDE's backend: `agy --hub`, token in `--flag=value` form.
    func test_parseProcess_readsAgyHubWithEqualsStyleToken() throws {
        let line = " 3935 /Users/me/.gemini/bin/agy --hub --hub-port=50194 --app_data_dir=antigravity --csrf_token=FORCED-AGY --add-dir=/Users/me/My Drive/PAUL"
        let found = try XCTUnwrap(LanguageServerSessionSource.parseProcess(fromPSOutput: line))
        XCTAssertEqual(found.processId, 3935)
        XCTAssertEqual(found.csrfToken, "FORCED-AGY")
    }

    func test_parseProcess_ignoresAgyWithoutHubFlag() {
        let line = " 3936 /Users/me/.gemini/bin/agy chat --csrf_token=NOPE"
        XCTAssertNil(LanguageServerSessionSource.parseProcess(fromPSOutput: line))
    }

    func test_parseProcess_emptyOutput_isNil() {
        XCTAssertNil(LanguageServerSessionSource.parseProcess(fromPSOutput: ""))
    }

    func test_parseListeningPorts_readsOnlyLoopbackListeners() {
        let output = """
        language_ 1357 user 7u IPv4 0x11 0t0 TCP 127.0.0.1:49433 (LISTEN)
        language_ 1357 user 8u IPv4 0x22 0t0 TCP 127.0.0.1:49434 (LISTEN)
        language_ 1357 user 9u IPv4 0x33 0t0 TCP 127.0.0.1:49433 (ESTABLISHED)
        language_ 1357 user 10u IPv4 0x44 0t0 TCP *:8080 (LISTEN)
        language_ 1357 user 11u IPv6 0x55 0t0 TCP [::1]:9999 (LISTEN)
        """
        XCTAssertEqual(LanguageServerSessionSource.parseListeningPorts(fromLsofOutput: output), [49433, 49434])
    }

    func test_parseListeningPorts_emptyOutput_isEmpty() {
        XCTAssertEqual(LanguageServerSessionSource.parseListeningPorts(fromLsofOutput: ""), [])
    }
}
