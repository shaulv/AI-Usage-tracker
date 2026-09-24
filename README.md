# ChatGPT Usage Tracker

A menu-bar-only macOS app that shows how much of your ChatGPT plan's metered
usage you have consumed, read from ChatGPT's own usage endpoint.

---

## Read this first: the state you are inheriting

**This code compiles and passes its test suite.** `swift build` and `swift test` both succeed with just the Swift toolchain; the menu-bar app (`Sources/App`, AppKit) is built via `xcodegen` + Xcode.
The core framework is Foundation-only, read-only, and injects transport so the suite never touches the network.
See the Verification section for what ran on this Mac.

Your first job, in order:

1. `swift build` and fix whatever the compiler finds. Expect small syntax
   errors, not design problems.
2. `swift test`. 70 tests pass. They cover the core framework only.
3. Run the `curl` probe below against the real account. Until that returns
   `HTTP 200` with a `used_percent`, nothing else is worth doing.
4. `xcodegen generate`, open the project, run the app, and look at the panel.
5. Re-measure the three threshold colors on the actual rendered panel. They were
   computed against flat hex backgrounds, and a `MenuBarExtra` window is not
   flat. See "Design conventions".

Not a git repository yet. `git init` and commit before you change anything, so
the unverified baseline is recoverable.

Then run `bash tools/check-readme-claims.sh`. It re-verifies every countable
claim in this file against the tree and exits non-zero on drift. Run it after
any change to `Sources/` or `Tests/`, and update this file when it complains.

---

## What it does

Shows usage percentages in the menu bar — the session window alone (`6%`) or
session + weekly together (`S6% W47%`), pickable from the right-click menu.
Click the status item for a floating, draggable, resizable panel with every
limit on both accounts; stretch it edge-to-edge for a one-line strip that stays
on top in any space. Right-click the status item for settings: show/hide panel,
start at login, ChatGPT on/off, Claude on/off, header format, quit.

Polls adaptively: every 60 seconds while the numbers sit still, and every 10
seconds for a minute once any percentage starts moving. Reads two local
credential sources and two HTTPS endpoints (ChatGPT's usage endpoint, claude.ai's
web usage endpoint). Writes nothing back to any credential source, sends
nothing, tracks nothing.

---

## How it works

Five steps, and the code for each:

| Step | What happens | Where |
|---|---|---|
| 1 | Codex CLI, the Codex IDE extension, and the ChatGPT desktop app share one cached sign-in at `~/.codex/auth.json`. That file holds an access token that identifies you to OpenAI. | not ours |
| 2 | The app reads that file, pulls out `tokens.access_token` and `tokens.account_id`, and decodes the token's `exp` claim to know when it dies. | `CodexCredentials.swift` |
| 3 | It sends one GET to `https://chatgpt.com/backend-api/wham/usage` with the token. That endpoint only reports usage. It does not run a model and consumes no quota. | `ChatGPTUsageProvider.swift` |
| 4 | The response lists metered windows: a percentage used, a window length, and a reset time. Each becomes one `UsageLimit`, named by how long its window is. | `ChatGPTUsageResponse.swift` |
| 5 | `UsageStore` holds the rows, remembers which one you picked, and drives the adaptive timer (60s idle, 10s during a movement burst). The menu bar shows the header format the user chose. | `UsageStore.swift`, `Sources/App`, `Sources/UI` |

Claude rides the same five steps with its own sources: Claude Desktop's
session cookies (read from its Chromium cookie store, decrypted with the
Keychain's `Claude Safe Storage` key) instead of `auth.json`, and
`GET claude.ai/api/organizations/{org}/usage` instead of the wham endpoint.
`ClaudeUsageProvider` mirrors `ChatGPTUsageProvider` line for line: same
`UsageProvider` protocol, same injected transport, same never-stale rule,
read-only, never refreshing anything.

If any step fails, the previously shown numbers are discarded and replaced with
`--%` plus a reason. The app never keeps displaying a stale percentage.

---

## Prerequisite

Sign in to Codex once, **with ChatGPT, not with an API key**:

```bash
brew install --cask codex     # or install the ChatGPT desktop app
codex login
codex login status            # must say "Logged in using ChatGPT"
```

An API-key sign-in has no plan windows to report, and the app says so
specifically rather than showing an empty panel.

If `~/.codex/config.toml` sets `cli_auth_credentials_store = "keyring"` (or
`auto` on a Mac where the keychain is available), there is no `auth.json` to
read and the app will report "Not signed in to Codex". Either set it to
`"file"` and sign in again, or add keychain support. See "Open work", item 4.

---

## Verify the data source before running anything

```bash
A=~/.codex/auth.json
ACCESS=$(jq -r '.tokens.access_token // empty' "$A")
ACCT=$(jq -r '.tokens.account_id // empty' "$A")
curl -sS -o /tmp/u.json -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer $ACCESS" \
  -H "ChatGPT-Account-Id: $ACCT" \
  -H "originator: codex_cli_rs" \
  -H "Accept: application/json" \
  "https://chatgpt.com/backend-api/wham/usage"
jq '{plan_type, rate_limit, additional:[.additional_rate_limits[]?|{limit_name,primary:.rate_limit.primary_window}]}' /tmp/u.json
```

Read the result:

| Result | Meaning | Do this |
|---|---|---|
| `HTTP 200` with a `used_percent` | The whole design holds. | Build. |
| `HTTP 401`, body `{"detail":"Unauthorized"}` | Expired token or missing header. | Run `codex` once so it refreshes `auth.json`, retry. |
| `auth.json` missing | No Codex sign-in on this Mac, or keyring storage. | Sign in, or see the prerequisite note above. |
| `HTTP 200`, every rate-limit field `null` | This account tier exposes no windows. | Save the JSON to `Tests/.../Fixtures/` and add a test. There is nothing to display. |

Never paste the access token into chat, an issue, or a commit. The probe prints
only status codes and percentages.

---

## Build and run

Tests, no Xcode required:

```bash
swift test
```

The app:

```bash
brew install xcodegen
xcodegen generate
open ChatGPTUsageTracker.xcodeproj
# Product > Run
```

There is no Dock icon. The app lives in the menu bar only, which is
`INFOPLIST_KEY_LSUIElement: true` in `project.yml`.

Three targets, and the split is deliberate:

- `ChatGPTUsageCore`, a framework, Foundation only. Everything testable lives
  here.
- `ChatGPTUsageTracker`, the app. AppKit and SwiftUI only, deliberately thin.
- `ChatGPTUsageCoreTests`, the test bundle.

The core is a framework rather than source files shared between the app and the
tests because compiling the same files into two targets produces duplicate
symbols at link time, and `@testable import` requires the module name to match
the target name.

---

## Files

```
Package.swift                        lets `swift test` run the core with no Xcode
project.yml                          XcodeGen spec for the three targets
.gitignore                           also blocks auth.json, on purpose
tools/check-readme-claims.sh         fails when this file drifts from the code

Sources/ChatGPTUsageCore/
  UsageLimit.swift                   UsageLimit, UsageWindow, UsageProviderError,
                                     WindowNamer (duration to display name)
  CodexCredentials.swift             CodexCredentialsSource protocol,
                                     CodexAuthFileCredentialsSource,
                                     parseCredentials, JWT exp decode
  ChatGPTUsageResponse.swift         Decodable DTOs and toUsageLimits(now:)
  ChatGPTUsageProvider.swift         the one GET and every failure path
  UsageStore.swift                   selection, adaptive timer (60s/10s burst),
                                     the never-stale rule
  ClaudeCredentials.swift            ClaudeSessionSource protocol,
                                     ClaudeDesktopSessionSource (Keychain key +
                                     read-only SQLite cookie decryption)
  ClaudeUsageResponse.swift          Claude DTOs, ClaudeUsageMapper.limits(from:)
  ClaudeUsageProvider.swift          the claude.ai GET and every failure path
  HeaderFormatter.swift              HeaderStyle, title formatting, window lookup

Sources/App/ChatGPTUsageTrackerApp.swift   @main entry, delegates to AppDelegate
Sources/App/AppDelegate.swift              NSStatusItem, NSPanel host, right-click
                                           menu, both UsageStore instances
Sources/App/AppSettings.swift              persisted toggles + header style
Sources/UI/LimitsPanel.swift               the responsive panel: wide shows a single condensed row (chips left, refresh right); narrow stacks one limit per line. No title, no quit button
Sources/UI/ThresholdColors.swift           per-appearance threshold colors
Sources/UI/RelativeTime.swift              "in 2h 14m"
  Sources/UsageProbe/main.swift              live-state probe binary (read-only, hits network)

Tests/ChatGPTUsageCoreTests/
  TestSupport.swift                  fixture loader, StubCredentialsSource,
                                     SpyTransport, FailingTransport, TestDates
    ChatGPTUsageProviderTests.swift    17 tests
  CodexCredentialsTests.swift        15 tests
  UsageStoreTests.swift              12 tests (incl. burst cadence)
  ClaudeUsageProviderTests.swift     19 tests
  HeaderFormatterTests.swift         7 tests
  Fixtures/                          15 JSON payloads plus two HTML fixtures
```

---

## The endpoint contract

Captured live on 18/07/2026 against a real account, corroborated by a shipped
third-party app, **not re-verified against a live account by us**. Treat it as
the best available ground truth and re-check with the probe before you trust it.

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <tokens.access_token>     required
ChatGPT-Account-Id: <tokens.account_id>         optional today, sent anyway
originator: codex_cli_rs                        optional today, sent anyway
Accept: application/json
timeout 15 s
```

Response, trimmed to what the code reads:

```json
{
  "plan_type": "prolite",
  "rate_limit": {
    "primary_window":   { "used_percent": 6, "limit_window_seconds": 604800,
                          "reset_after_seconds": 589104, "reset_at": 1785024392 },
    "secondary_window": null
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": [
    { "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
      "rate_limit": { "primary_window": { "used_percent": 0,
                      "limit_window_seconds": 604800, "reset_at": 1785040089 } } }
  ]
}
```

Four facts that are easy to get wrong, each one independently recomputed:

1. **`reset_at` is epoch SECONDS.** `1785024392` is `2026-07-26T00:06:32Z`. Not
   milliseconds, not an ISO string. `1785024392 - 589104` is
   `2026-07-19T04:28:08Z`, which matches the capture time, confirming both the
   unit and that `reset_after_seconds` is seconds-from-capture.
2. **`used_percent` arrives as an integer** in the capture but is decoded as
   `Double`, so a future fractional value cannot break the app.
3. **`limit_window_seconds` is the meaning of a window.** `604800` is 7 days,
   `18000` is 5 hours.
4. **Position carries no meaning.** On the captured account `primary_window` IS
   the weekly one and there is no secondary. On Plus and Pro a 5-hour window
   exists too. Never name a window "primary" or "session" by slot.

Error responses actually observed: `401` with
`{"detail":"Unauthorized"}` when the auth header is missing, and `401` with an
`invalid_request_error` body when the token is wrong. Neither body is parsed.

---

## Why it is built this way

Each of these was a real alternative that got rejected for a specific reason.
Do not undo one without reading its reason.

**Why read `auth.json` instead of logging the user in through a WebView.**
The obvious design is a hidden `WKWebView`, let the user log in, lift the
session cookies. Rejected: it means fighting Cloudflare, re-extracting cookies
on every rotation, and owning a login flow that OpenAI changes without notice.
Reading a file that Codex already maintains costs nothing and cannot break
independently of Codex.

**Why never refresh the token.** The refresh token rotates. Consuming it
out-of-band can invalidate the session Codex CLI holds and log the user out of
`codex`, which is a far worse outcome than showing "session expired". The app
reads whatever token is current and lets Codex refresh it during normal use.

**Why poll only the usage endpoint.** Reading limits by sending a model turn
spends the quota being measured. A filed bug against the ChatGPT desktop app
measured a background suggestion run draining roughly 6% of the weekly window
per hour. `GET /backend-api/wham/usage` is the read-only path the Codex CLI's
own usage view uses.

**Why a 60 second idle floor with a 10 second movement burst.** The windows
reset on the scale of hours, so a quiet account does not need faster polling —
but the user asked to notice movement within a minute. The idle cadence is
therefore 60 seconds; when any percentage differs from the previous successful
fetch, a one-minute burst window opens and polls every 10 seconds, re-armed by
further movement and drained once values sit still. `UsageStore.refreshDelay`
computes the cadence as a pure function, and tests assert both legs plus the
failure-clears-the-baseline rule (a recovery after an outage is not movement).
A failure also exits burst: errors get the slow cadence, never the fast one.

**Why App Sandbox is off.** The app reads `~/.codex/auth.json`, which is outside
any container a sandboxed app can reach. The honest trade for a personal tool:
no App Store distribution. If that ever matters, the alternative is a
security-scoped bookmark, which the user has to grant by hand.

**Why the core is Foundation-only.** It keeps the whole data path testable with
`swift test` on any machine, including one with no Xcode. Only `Sources/App` and
`Sources/UI` need AppKit and SwiftUI.

**Why `plan_type`, `credits`, `spend_control` and `promo` are not decoded.**
Plain `Decodable` drops undeclared keys for free. Spend and credits are a
different product concern, and decoding them would be code to maintain for a
feature that does not exist.

---

## Error catalog

Every message the user can see, where it comes from, and what it means. If a
user reports one of these, the fix is on the right, not in the code.

| Message | Kind | Cause | Fix |
|---|---|---|---|
| `Not signed in to Codex` | notConnected | `auth.json` missing or no access token | `codex login` |
| `Codex is signed in with an API key - sign in with ChatGPT to see plan limits` | notConnected | `OPENAI_API_KEY` set, or `auth_mode: "apiKey"` | `codex login` with ChatGPT |
| `Codex credentials are malformed - sign in to Codex again` | notConnected | `auth.json` is not valid JSON | `codex logout && codex login` |
| `Codex session expired - run codex to refresh it` | notConnected | JWT `exp` is more than 60 s in the past | run `codex` once |
| `ChatGPT rejected the saved credentials - sign in to Codex again` | notConnected | HTTP 401 or 403 | sign in again |
| `Network error - check your connection` | fetchFailed | `URLError` from the transport | connectivity |
| `ChatGPT usage service returned HTTP <code>` | fetchFailed | any other non-2xx | server side; retry later |
| `Unexpected response from ChatGPT usage service` | fetchFailed | body did not decode, or none of `plan_type`, `rate_limit`, `code_review_rate_limit`, `additional_rate_limits` was present | **the endpoint changed.** See "When OpenAI changes something". |
| `Claude Desktop is not signed in on this Mac` | notConnected | cookie store missing/unreadable, no `sessionKey`/`lastActiveOrg`, or the Keychain key is unavailable | open Claude Desktop and sign in |
| `Claude is blocked by Cloudflare - open Claude Desktop, then Refresh` | notConnected | HTTP 403 from claude.ai that is a Cloudflare managed challenge — `cf-mitigated: challenge` header, or body contains `Just a moment` / `cf_chl_`, detected by `isCloudflareChallenge` | the session cookie is valid; Cloudflare is challenging the browser. Open Claude Desktop (already signed in) and let it answer the challenge, then Refresh. Do not re-sign-in: it cannot help. |
| `Claude session expired - open Claude to refresh it` | notConnected | cookie `expires_utc` past, or HTTP 401/403 that is NOT a Cloudflare challenge (aged-out `cf_clearance`) | open Claude Desktop once |
| `Claude usage service returned HTTP <code>` | fetchFailed | any other non-2xx from claude.ai | server side; retry later |
| `Unexpected response from Claude usage service` | fetchFailed | body did not decode, or none of `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `extra_usage`, `limits` was present | **the endpoint changed.** Same drill as the ChatGPT side. |

The panel footer always shows one of: `not fetched yet`, `updating…`,
`updated HH:mm`, or `failed, last good HH:mm`. That line exists so a silently
broken endpoint cannot hide behind a stale number. Do not remove it.

The menu bar shows `--%` whenever there is nothing honest to display.

---

## Tests

70 tests, all in the core framework, none of them touching the network or the
real home directory. Transport and credentials source are both injected.

| File | Count | Covers |
|---|---|---|
| `ChatGPTUsageProviderTests.swift` | 16 | the captured payload end to end, window naming by duration not position, 30-day and durationless windows, clamping 250 to 100 and -12 to 0, unnamed `additional_rate_limits` entries, unrecognized payload is a failure not an empty list, recognized payload with zero windows is a real empty answer, the expiry gate, 401, 503, an HTML body served as 200, transport failure, and the exact request headers |
| `CodexCredentialsTests.swift` | 14 | real-shaped `auth.json`, API-key sign-in, missing tokens, malformed JSON, missing file, load from disk, JWT expiry decode including unpadded base64url and a missing `exp`, the 60 second grace window, and every `WindowNamer` branch |
| `UsageStoreTests.swift` | 11 | success publishes, **failure discards the previous numbers**, menu bar label follows the selection, a saved selection that no longer exists falls back to the first row, empty result stays `ok` with `--%`, the 60 second floor, both legs of the burst cadence, movement opens a burst, failure clears the movement baseline, and selection persistence |
| `ClaudeUsageProviderTests.swift` | 19 | fixture mapping (session/weekly/model rows, RFC 3339 resets, null buckets = real empty, clamping, the `isCloudflareChallenge` helper tested on the header branch and both body markers), unrecognized payload and HTML-with-200 are fetch failures, exact cookie/UA request shape with no Authorization header, the local expiry gate proving zero network calls, a Cloudflare 403 that is distinguished from a session-lapse 403, the 500 path, transport failure, PBKDF2 recipe parity with the live probe, decrypt-shape refusals, and Chromium tick-to-date conversion |
| `HeaderFormatterTests.swift` | 7 | the spec's literal `S2% W47%` string, bare `2%`, missing windows render `--` never `0`, and session/weekly lookup by derived name |

**Three tests are load-bearing. If you break one, you have broken the product,
not the test.**

1. `test_expiredJWT_failsLocallyAndNeverCallsTheNetwork` asserts
   `spy.callCount == 0`. That is the only proof the expiry gate short-circuits
   before the network. (The Claude twin, `test_expiredSession_failsLocallyAndNeverCallsTheNetwork`,
   proves the same gate on the cookie path.)
2. `test_failedRefresh_discardsThePreviousLimits` asserts `limits == nil` after
   a failure. That is the never-stale rule.
3. `test_unrecognizedPayload_throwsFetchFailedNotEmptyList` keeps "the endpoint
   changed" distinguishable from "this account has no limits". Collapse those
   two and a server-side break will read as an empty account forever.

Fixtures: 15 JSON files plus two HTML fixtures, all with faked identifiers.
`Fixture.data(named:)` finds them under `swift test` via `Bundle.module`, under
Xcode via `Bundle(for: TestBundleAnchor.self)`, and as a last resort on disk
relative to `#filePath`. If you add a fixture, add it to all three assumptions
or it will load in one runner and not the other.

---

## When something breaks

The order matters. Check the cheap things first.

| Symptom | First check |
|---|---|
| Menu bar shows `--%` | Open the panel and read the message. It is one of the eight above and each has a fix. |
| Numbers look wrong | Compare against `https://chatgpt.com/codex/cloud/settings/analytics` at the same moment. That page is the human-readable version of the same data. |
| Worked yesterday, fails today | Run the `curl` probe. If it fails too, OpenAI changed something server-side and the bug is not in the Swift. |
| `Unexpected response from ChatGPT usage service` | The payload shape changed. Save the raw body to a new fixture, add a test that fails, then extend the DTOs. |
| Nothing appears in the menu bar at all | `LSUIElement` is on, so there is no Dock icon by design. Check the menu bar overflow, and check Console for a launch crash. |
| "I don't see my change" | Confirm which target you edited. The data path is in the framework, not the app target. |

---

## Verification status, plainly

What was actually checked on the machine where this was written, and how:

| Checked | How |
|---|---|
| All 14 JSON fixtures parse | `jq -e .` on each |
| Epoch-second claims in fixtures and tests | recomputed: `1785024392` is `2026-07-26T00:06:32Z`, `1785040089` is `2026-07-26T04:28:09Z`, `1785024392 - 589104` is `2026-07-19T04:28:08Z` |
| The three base64url JWT payloads in the tests | re-encoded from the literal JSON, byte for byte |
| Threshold color contrast | WCAG relative luminance against `#FFFFFF` and `#1C1C1E`; all six at or above 4.5:1 |
| No placeholder or elided code | grep for `TODO`, `FIXME`, `implement here`, `rest of code`, `similar to above`, `for brevity` returns nothing |
| Brace balance in all 22 Swift files | counted with strings and comments stripped; 0 imbalanced |
| `project.yml` is valid | parsed as YAML; three targets, one scheme |
| No writes to the auth file | grep for `write(to:`, `removeItem`, `FileHandle` across `Sources/` returns nothing |
| Exactly one network site | `URLSession` appears once, in `ChatGPTUsageProvider.urlSessionTransport` |

What was not checked anywhere, and needs a Mac:

| Not checked | Needs |
|---|---|
| That the Swift compiles | `swift build` (verified: passes) |
| That the tests pass | `swift test` (verified: 70/70) and `xcodebuild test` |
| That the endpoint responds for a real account | `curl` / `tools/probe-chatgpt-payload.py` for ChatGPT (200 live); `tools/probe-claude-cookies.py` and `swift run usage-probe` for Claude — `/api/organizations/{org}/usage` returns 200 live (this account, free plan, empty/null buckets), while the bare `claude.ai/` root returns 403 |
| That the panel renders and the menu bar updates | running the app |
| Threshold colors on a real vibrancy-backed panel | a screenshot, then measure on that surface |
| Behavior when the token expires mid-session | corrupt `auth.json` and watch |
| Launch at login registering and unregistering | a signed build |

A naive brace count will report `CodexCredentialsTests.swift` as unbalanced. It
is not: the JWT literal `eyJleHAiOjE2MDAwMDAwMDB9` ends in the byte `}`, which
is `}` in base64url. Strip strings before counting braces in any file carrying
encoded payloads.

---

## Design conventions to keep

These were applied throughout and should not drift.

- **Spacing is on a 4 px grid.** The stacked (narrow) panel uses 10 pt padding
  and 6/8 pt gaps; the strip mode tightens further. Every gap is a multiple
  of 2, most of 4.
- **One control, one home.** The rows in the panel ARE the selection control.
  There is deliberately no separate picker that duplicates the choice. Do not
  add one.
- **Fixed element order in every row:** color dot, name, percentage, reset time.
  The percentage is the heaviest element because it is what gets scanned.
- **Two type families at most**, both system. Percentages use
  `.monospacedDigit()` so the label does not jitter as digits change.
- **Colors carry meaning.** Green under 70%, amber 70 to 89, red 90 and above,
  with light and dark variants because no single hex passes 4.5:1 on both
  surfaces. Ratios: light `#17653A` 7.10, `#8A5300` 6.33, `#B02418` 6.75; dark
  `#4ADE80` 9.76, `#F0B429` 9.13, `#FF6B5E` 6.09. Those are against flat
  backgrounds. Re-measure on the real panel before calling them done.
- **No layout shift between states.** Failed, empty, and populated states
  occupy the same slot; only the text changes.
- **Hover stays inside the frame**, and every interactive element has a keyboard
  equivalent. Row selection is a `Button`, not a click gesture.
- **Status appears in one place**, the panel footer. Do not add a second
  indicator elsewhere.
- **No emoji as functional icons.** The refresh control is `arrow.clockwise`.
- **The unknown state is explicit.** `--%`, never a guess and never a carried
  forward value.

---

## Known limits

- **Only the Codex and ChatGPT Work surface is readable this way.** Chat-side
  quotas (uploads, deep research, images, voice) have no credential-safe source,
  so this app cannot show them. That is a property of what OpenAI exposes, not a
  missing feature.
- **Everyday text chat has been unmetered on every plan since 06/08/2026**, so
  there is no "messages left" number to display anywhere. Anyone asking for one
  is asking for something that no longer exists.
- **Single account only.** It reads whatever `~/.codex/auth.json` holds, which
  is the one active Codex sign-in. `CODEX_HOME` is honored, so a second account
  is possible by pointing that env var elsewhere, but there is no switching UI.
- **Claude's Cloudflare gate.** `claude.ai/` itself often returns 403 with the
  "Just a moment" managed challenge, but the authenticated
  `/api/organizations/{org}/usage` call returns 200 from the saved Desktop
  cookies (verified live). When it does challenge, the panel says "Claude is
  blocked by Cloudflare" instead of "session expired" — a valid session being
  challenged is a different fix than a stale one.
- **No token refresh**, by design. See "Why it is built this way".
- **Personal tool.** Unsigned by default (`CODE_SIGN_IDENTITY: "-"`), sandbox
  off, not App Store eligible.

---

## Open work, ranked

1. **QA the app on a real screen.** The shell (status item, floating panel,
   right-click menu, header formats) compiles and the app launches, but no
   human has judged the responsive strip at real widths yet. Check the three
   states, both layouts, row alignment, and the `S100% W100%` label width.
2. **Re-measure the threshold colors on the real panel** and replace the hex
   values if they fail on a vibrancy surface.
3. **Live Claude QA with real windows.** HTTP 200 verified via both the cookie
   probe and `swift run usage-probe`, and the empty-bucket path is proven (free
   plan shows "no usage limits available"). Confirm rows appear at non-zero usage.
4. **Keychain credential support for Codex.** If `cli_auth_credentials_store` is
   `keyring` there is no `auth.json` file to read. Either document the
   workaround or read the keychain item, which needs a first-use permission
   prompt. (Claude already reads its Keychain key.)
5. **The always-on-top floating panel.** Deliberately out of scope for this
   version. If you add it: `.nonactivatingPanel`, `level = .floating`,
   `hidesOnDeactivate = false`, off by default, and verify it does not cover a
   video call.
6. **A second provider (Claude).** `UsageProvider` is the seam and it already
   has two implementations counting the test stub, so it is a real seam. Claude
   Code stores its credentials in the keychain and has its own usage endpoint.
7. **Multi-account switching.** Needs a credential registry, not just a picker.

---

## When OpenAI changes something

This will happen. The design assumes it.

- The URL lives in one place: `ChatGPTUsageProvider.usageURL`.
- The header set lives in one place: `ChatGPTUsageProvider.makeRequest`.
- The payload shape lives in one place: `ChatGPTUsageResponse`.
- Window naming lives in one place: `WindowNamer`.

A breaking change should be a one-file edit. The procedure:

1. Run the `curl` probe and save the raw response body.
2. Drop it in `Tests/ChatGPTUsageCoreTests/Fixtures/` with faked identifiers.
3. Write a test that asserts the new shape. Watch it fail.
4. Extend the DTOs. Never delete a field mapping without checking whether a
   plan tier still sends it.
5. Keep the "unrecognized payload" guard. It is what turns a silent break into
   a visible error.
6. New named entries in `additional_rate_limits` need no code change at all.
   They are surfaced verbatim by design, so a new model appears in the panel on
   its own.

---

## History

This began as a plan that assumed the only data source was an intermittent
"You have N messages left" toast in the ChatGPT web UI, and designed a hidden
`WKWebView` plus Safari cookie extraction around it. That premise was checked
and found to be wrong on three counts: the endpoint above exists, text chat has
been unmetered since August 2026, and `chatgpt.com/codex/cloud/settings/analytics`
is a real web meter. The WebView design was dropped entirely.

A shipped MIT-licensed app, `sebastian-suarez/ai-usage`, already does what this
app does, signed and notarized, installable with
`brew install --cask sebastian-suarez/tap/ai-usage`. If the goal is simply to
see the number, install that instead. This codebase exists for the cases where
you want to own it: a different UI, a second provider, or learning how the
endpoint works.

Full reasoning, sources, and the acceptance contract are in `PLAN-v2.md`.
