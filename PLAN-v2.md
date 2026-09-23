# ChatGPT Usage Tracker, macOS: plan v2

Supersedes the v1 planning document. Every factual claim below is dated and sourced. Anything I could not verify from this machine is marked **UNVERIFIED (yours to run)**.

Revision date: 23/09/2026.

---

## 0. What was wrong with v1

v1's opening premise: "OpenAI does not appear to expose a persistent '% used' meter in the UI; usage is normally only surfaced as a one-off toast ('You have 12 messages left until Thursday')." Three parts of that are false as of this date, and v1's two-branch design (5A "maybe there is an API" vs 5B "scrape a toast") was built on it.

| v1 claim | Reality as of 23/09/2026 | Source |
|---|---|---|
| No JSON API with usage data | `GET https://chatgpt.com/backend-api/wham/usage` returns the account's windows as JSON. This is the endpoint the Codex CLI's own `usage` view calls. | openai/codex `codex-api/src/rate_limits.rs` plus a live-capture contract in sebastian-suarez/ai-usage issue #5 |
| "N messages left until Thursday" toast is the data source | Everyday text chat has been **unlimited on every plan since 06/08/2026**, subject to abuse guardrails. That toast's premise no longer exists. What is metered: reasoning effort, images, uploads (80 files / 3 h), voice, deep research, and Codex / ChatGPT Work sessions. | OpenAI pricing page and limits docs; chatgptlimit.com |
| No persistent UI meter anywhere | `https://chatgpt.com/codex/cloud/settings/analytics` is a real web page with three meters: 5-hour rolling, weekly, and pay-as-you-go credits. It is not under the main Settings menu. | jdhodges.com walkthrough, Sep 2026 |
| Hidden `WKWebView` plus Safari cookie extraction is the fetch path | Explicitly rejected by the one project that shipped this: fighting Cloudflare, re-extracting on every cookie rotation, maximally fragile. | ai-usage issue #5, "Alternatives rejected" |
| A one-off poll is harmless | Polling the *model* endpoint consumes quota. A filed bug measured the ChatGPT desktop app's background suggestion run draining ~6% of the weekly window in ~1 h. Only the dedicated read-only usage endpoint is safe to poll. | openai/codex issue #37445 |
| Store the session token in Keychain yourself | Never refresh the OAuth token out-of-band. The refresh token rotates; consuming it can invalidate Codex CLI's stored session and log the user out of `codex`. | ai-usage issue #5 |

Net: v1's Phase 0 was right to insist on verifying the source before building. It guessed the answer instead of checking it, and guessed wrong. The whole 5B branch, the hidden WebView, the cookie plumbing, and the regex-over-`innerText` extractor are all dead weight. Delete them.

---

## 1. Do this first: the live probe (2 minutes, on your Mac)

This replaces v1 Phase 0. It answers the only question that matters, with real bytes.

**Not run yet. UNVERIFIED (yours to run).** This workspace is Linux with no Swift toolchain (`swift`, `swiftc`, `xcodebuild` all absent, checked) and no credentials of yours, so I could not execute it. Run it in Terminal on the Mac and paste the output back.

```bash
A=~/.codex/auth.json

# 1. Is there a credential, and what shape is it?
if [ -f "$A" ]; then
  echo "auth.json: present"
  jq -r '"auth_mode: \(.auth_mode)   has_api_key: \(.OPENAI_API_KEY != null)   last_refresh: \(.last_refresh)"' "$A"
else
  echo "auth.json: MISSING"
  echo "credential store setting:"; grep -n cli_auth_credentials_store ~/.codex/config.toml 2>/dev/null || echo "  (unset, defaults to file)"
fi

# 2. Access token expiry, decoded from the JWT. Prints nothing but a date.
python3 - <<'PY'
import base64,json,os,datetime
p=os.path.expanduser("~/.codex/auth.json")
if not os.path.exists(p): raise SystemExit("no auth.json, nothing to decode")
t=json.load(open(p)).get("tokens") or {}
at=t.get("access_token") or ""
print("account_id present:", bool(t.get("account_id")))
if at.count(".") < 2: raise SystemExit("no JWT to decode")
s=at.split(".")[1]; s+="="*(-len(s)%4)
c=json.loads(base64.urlsafe_b64decode(s))
e=c.get("exp")
print("access_token exp:", datetime.datetime.fromtimestamp(e,datetime.timezone.utc).isoformat() if e else "no exp claim")
PY

# 3. The actual call. This is read-only and consumes no quota.
ACCESS=$(jq -r '.tokens.access_token // empty' "$A")
ACCT=$(jq -r '.tokens.account_id // empty' "$A")
[ -z "$ACCESS" ] && { echo "no access_token in auth.json, stopping"; exit 1; }

curl -sS -D /tmp/h.txt -o /tmp/u.json -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer $ACCESS" \
  -H "ChatGPT-Account-Id: $ACCT" \
  -H "originator: codex_cli_rs" \
  -H "Accept: application/json" \
  "https://chatgpt.com/backend-api/wham/usage"

# 4. The numbers.
jq '{plan_type,
     rate_limit,
     additional: [.additional_rate_limits[]? | {limit_name, primary: .rate_limit.primary_window}]}' /tmp/u.json
```

Read the result:

| Result | Meaning | Next |
|---|---|---|
| `HTTP 200` and a `used_percent` you recognize | The whole project is feasible on one GET. | Go to section 4. |
| `HTTP 401`, body `{"detail":"Unauthorized"}` or an `invalid_request_error` | Token expired or wrong header set. | Run `codex` once so it refreshes `auth.json`, rerun step 3. If still 401 with a fresh token, stop and report: that is a server-side gate change. |
| `auth.json: MISSING` with `cli_auth_credentials_store = "keyring"` | Credentials live in the macOS keychain, not a file. | See section 6, prerequisite. |
| `auth.json: MISSING`, no keyring setting | Codex / ChatGPT desktop app never signed in on this Mac. | Install and sign in once, or this project has no data source. |
| `HTTP 200` but every rate-limit field is `null` | Your account tier does not expose windows. | Report the raw JSON; scope changes to "nothing to track". |

Never paste the `access_token` into chat, an issue, or a commit. The probe above prints only dates, booleans, and percentages.

---

## 2. The verified endpoint contract

Captured live on 18/07/2026 against a real account (identifiers faked by the capturer) and re-confirmed as the contract of a shipped app. Treat this as ground truth and re-verify with the probe before coding.

**Request**

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <tokens.access_token>
ChatGPT-Account-Id: <tokens.account_id>     (optional today)
originator: codex_cli_rs                     (optional today)
Accept: application/json
```

Verified: 200 with the `Authorization` header and a generic `User-Agent` alone. The other two headers are cheap insurance against future server-side gating. Timeout 15 s.

**Response, 200**

```json
{
  "user_id": "user-...",
  "account_id": "acct-...",
  "email": "user@example.com",
  "plan_type": "prolite",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window":   { "used_percent": 6, "limit_window_seconds": 604800, "reset_after_seconds": 589104, "reset_at": 1785024392 },
    "secondary_window": null
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": [
    {
      "limit_name": "GPT-5.3-Codex-Spark",
      "metered_feature": "codex_bengalfox",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window":   { "used_percent": 0, "limit_window_seconds": 604800, "reset_after_seconds": 604800, "reset_at": 1785040089 },
        "secondary_window": null
      }
    }
  ],
  "credits": { "has_credits": false, "unlimited": false, "balance": "0", "approx_local_messages": [0,0], "approx_cloud_messages": [0,0] },
  "spend_control": { "reached": false, "individual_limit": null },
  "rate_limit_reached_type": null,
  "promo": null,
  "rate_limit_reset_credits": { "available_count": 1, "applicable_available_count": 0 }
}
```

Facts I recomputed from that payload rather than trusting prose (run in this workspace with `jq` and `python3`):

- `reset_at` `1785024392` is epoch **seconds**: `2026-07-26T00:06:32Z`. Not milliseconds, not an ISO string.
- `reset_at` minus `reset_after_seconds` (`589104`) is `2026-07-19T04:28:08Z`, which matches the stated capture date. Confirms the units and that `reset_after_seconds` is seconds-from-capture.
- `limit_window_seconds` `604800` = 168 h = 7 d (weekly). `18000` = 5 h (the Plus/Pro session window).
- `used_percent` arrives as an integer in this capture. Decode it as `Double`, because a fractional value must not break the app.

**Errors, observed**

| Status | Body | Handling |
|---|---|---|
| 401, bad token | `{"error":{"message":"Incorrect API key provided: ...","type":"invalid_request_error"}}` | Disconnected state. Never parse the body. |
| 401, no auth header | `{"detail":"Unauthorized"}` | Disconnected state. |
| other non-2xx | varies | Fetch-failed state with the status code in the message. |

**Windows are named by duration, never by position.** On the captured account the `primary_window` *is* the weekly one and there is no secondary. On Plus/Pro a 5-hour window exists too. `primary` does not mean "5-hour".

---

## 3. Three paths. My recommendation first.

### Path A: install the app that already does exactly this. 30 seconds.

`sebastian-suarez/ai-usage` is an MIT-licensed macOS menu bar app, released 1.0.0, Developer ID signed and Apple notarized, macOS 14+. It reads `~/.codex/auth.json`, calls `chatgpt.com`'s usage endpoint, shows the % used of the limit you pick in the menu bar, and lists every limit with reset times in a panel. It also covers Claude Code. No telemetry, no server of its own.

```bash
brew install --cask sebastian-suarez/tap/ai-usage
```

That is v1's entire goal, shipped, by someone who already fought every failure mode in section 2. If the requirement is "see my ChatGPT % in the menu bar", this is the answer and building anything is wasted work.

### Path B: fork it and change the parts you dislike. 2 to 4 hours.

Justified only if you have a concrete gap: an always-on-top floating panel (v1's section 8; AI Usage is menu bar plus panel only), a different default limit, custom thresholds, Claude plus Gemini, per-workspace accounts. MIT license, Swift and SwiftUI, provider protocol already at the swap point.

### Path C: build your own. 6 to 9 hours for a careful junior dev.

Justified if this is a learning project or you want something you fully control. The build plan is section 5. What you would be re-implementing is small: one file read, one GET, one decode, one menu bar label. The interesting work is the error handling in section 5.3, which is where v1 had nothing.

There are at least four other apps in this space (SessionWatcher, TokenBar, cc-bar, tokn.watch, codex-bar) if you want a wider comparison before deciding.

---

## 4. Prerequisites and hard constraints

**Prerequisite: a Codex sign-in on this Mac.** The credential source is `~/.codex/auth.json`, written by Codex CLI, the Codex IDE extension, or the ChatGPT desktop app, which share one cached login. Sign in with **ChatGPT**, not an API key: an API-key sign-in has no plan windows to report.

- If `cli_auth_credentials_store = "keyring"` (or `auto` on a Mac where the keychain is available), there is no `auth.json` to read. Either set `cli_auth_credentials_store = "file"` in `~/.codex/config.toml` and sign in again, or read the keychain item, which needs the user's approval on first access. Decide deliberately; do not discover this at runtime.
- `CODEX_HOME` moves the whole directory. Honor the env var if it is set, else default to `~/.codex`.

**Hard constraints, each one a failure mode someone already hit:**

1. **Poll only the usage endpoint.** Never poll `/backend-api/codex/responses` or send a model turn to read limits. It spends quota: a background suggestion run was measured at ~6% of the weekly window per hour.
2. **Never refresh the token yourself.** No calls to the `auth.openai.com` token endpoint. The refresh token rotates and consuming it out-of-band can log the user out of `codex`. Read `auth.json` fresh on every fetch and let Codex refresh it during normal use.
3. **Never carry a stale number.** On any failure, discard the previously shown value and show a disconnected state with the reason. A wrong percentage held for days is worse than an honest "unknown".
4. **Never invent a window the payload did not contain.** If only `primary_window` came back, show one row.
5. **Never fall back to 0% or 100%.** Absence of data is not a value.
6. **Never log token contents**, and never write to `~/.codex/auth.json`. Read-only, and provable.
7. **ToS.** This is an unofficial read of your own account data at low frequency. Same posture as the shipped app: personal use, no redistribution of credentials, 5-minute polling floor. Your call, stated once, not re-litigated.

---

## 5. Build plan for Path C

Sizing: **deep**, because the surface is small but the error handling is the whole product.

### 5.1 Scope, in one line

A menu-bar-only macOS app that shows the % used of the limit you select, with every limit and its reset time one click away, backed by one authenticated GET.

Out of scope, deliberately: chat-message counting (unmetered since 06/08/2026, nothing to report), deep-research and upload quotas (no credential-safe source), credits and spend control (different product concern), multi-account switching, token refresh.

### 5.2 Architecture

```
                UsageStore
             selection, refresh timer,
             the never-stale rule
              /            \
   MenuBarExtra label     ChatGPTUsageProvider
   and Panel view             |
   (all limits,           CodexCredentialsSource
    reset times)          reads ~/.codex/auth.json,
                          decodes JWT exp, no network
                              |
                     GET /backend-api/wham/usage
```

Data moves one way: the store asks the provider, the provider asks the credentials source and then the network, and the result flows back up to the label and the panel.

The seam that earns its keep is `CodexCredentialsSource`: it is what lets every error path be tested without a file on disk or a network. `Transport` is the second seam, injected as a closure so tests never touch `URLSession`. Two adapters each, so both are real seams and not speculative.

### 5.3 The core, as a contract

```swift
struct UsageWindow: Equatable {
    let usedPercent: Double        // clamp to 0...100 after decode
    let windowSeconds: Double?     // drives the name
    let resetAt: Date?             // epoch SECONDS; fall back to now + resetAfterSeconds
}

struct UsageLimit: Equatable {
    let name: String               // "Session (5h)", "Weekly", "Monthly", "N-day", or server limit_name verbatim
    let usedFraction: Double       // usedPercent / 100, clamped 0...1
    let resetsAt: Date?
}

enum UsageProviderError: Error, Equatable {
    case notConnected(String)      // file missing, API-key sign-in, malformed JSON, expired JWT, 401/403
    case fetchFailed(String)       // network, other non-2xx, decode failure, unrecognized payload
}

struct CodexCredentials: Equatable {
    let accessToken: String
    let accountId: String?
    let expiresAt: Date?     // JWT exp claim in seconds; nil when undecodable
}
```

Plus two protocols, written in Swift's own syntax in the file: `CodexCredentialsSource` with one async throwing `load()` returning `CodexCredentials`, and `UsageProvider` with `id`, `displayName`, and an async throwing `fetchLimits()` returning `[UsageLimit]`.

`fetchLimits()` order, and the reason for each step:

1. `credentialsSource.load()`. File missing gives "Not signed in to Codex". API-key-only sign-in gives "Sign in with ChatGPT to see plan limits". Malformed JSON gives "Credentials are malformed, sign in again". Distinct messages, because they have distinct fixes and the user cannot debug a generic failure.
2. **Expiry gate before any network call.** Base64url-decode JWT segment 1, read `exp` (seconds). More than 60 s in the past means "Codex session expired, run codex to refresh it". If the JWT does not decode, proceed: the server's 401 is the authority, and a parse bug must not lock the user out.
3. The GET, 15 s timeout. `URLError` gives "Network error, check your connection".
4. 401 or 403 means disconnected, message "ChatGPT rejected the saved credentials". Other non-2xx means fetch-failed with the code.
5. Decode. If `rate_limit`, `code_review_rate_limit`, `additional_rate_limits`, and `plan_type` are **all** nil, that is an unrecognized payload: fetch-failed, not an empty list. An empty list is a legitimate answer ("no limits on this account") and must not be confused with a broken response.
6. Map to `[UsageLimit]`. Name by `limit_window_seconds`: under 86400 gives `Session (Nh)`; 604800 gives `Weekly`; 2592000 or 2678400 gives `Monthly`; other known durations give `N-day`; absent falls back to positional naming. Entries in `additional_rate_limits` keep their `limit_name` verbatim, and a named entry with an empty `limit_name` falls back to `metered_feature`. Nothing the server sends is silently dropped, which is what makes the app survive the next model OpenAI adds.
7. Emit in a stable order: main windows, then `code_review_rate_limit` windows, then `additional_rate_limits` in server order.

`UsageStore` discards a provider's previous limits on any thrown error. That single rule is what enforces "never stale", and it belongs in the store, not in each provider.

### 5.4 Tests, with the numbers they must assert

All against an injected transport and an injectable auth-file URL. No test touches the network or the real home directory.

| # | Input | Expected |
|---|---|---|
| 1 | The section 2 capture verbatim | 2 limits: `("Weekly", 0.06)`, `("GPT-5.3-Codex-Spark", 0.0)`, resets at `2026-07-26T00:06:32Z` and `2026-07-26T04:28:09Z` |
| 2 | Plus-shaped: primary `18000` / `45`, secondary `604800` / `72` | `[("Session (5h)", 0.45), ("Weekly", 0.72)]`, proving names do not depend on position |
| 3 | `limit_window_seconds` `259200` | `"30-day"` |
| 4 | `limit_window_seconds` absent | positional fallback, not a crash |
| 5 | `used_percent: 250` | clamped to `1.0` |
| 6 | `additional_rate_limits` entry with empty `limit_name`, `metered_feature: "codex_foo_bar"` | name `"Codex foo bar"`, row present |
| 7 | all four payload sections nil | `fetchFailed`, **not** `[]` |
| 8 | recognized payload, zero windows | `[]`, and the UI shows "No usage limits available" |
| 9 | JWT with `exp` `1600000000` (`2020-09-13T12:26:40Z`) | `notConnected`, and the transport closure was **never called** (assert this, it is the whole point of the gate) |
| 10 | undecodable JWT | proceeds to the network |
| 11 | HTTP 401 | `notConnected`, response body never parsed |
| 12 | non-200, e.g. 503 | `fetchFailed` with `"503"` in the message |
| 13 | HTML body, 200 status | `fetchFailed` (content-type or decode guard) |
| 14 | `auth.json` with `auth_mode: "apiKey"` and a non-null `OPENAI_API_KEY` | the API-key message, not the generic one |

Test 9 is the one that fails if the expiry gate is ever unwired. Keep it.

### 5.5 UI

- `MenuBarExtra` (macOS 13+, so no reason to hand-roll `NSStatusItem`). Label: the % used of the selected limit, `"--%"` when disconnected.
- Panel: every limit as a row, name, % used, reset time in relative form ("in 2 h 14 m"), a picker for which limit the menu bar shows, a Refresh item, and a "Start at login" checkbox via `SMAppService`.
- Threshold colors on the panel rows: under 70 green, 70 to 89 amber, 90 and above red. **Compute the actual contrast of those three against the panel background before shipping**; menu-bar and panel surfaces differ per appearance, and a color that passes on the panel can fail on a vibrancy-backed one. Do not assert a ratio, measure it.
- v1's always-on-top `NSPanel` is a separate opt-in feature, not part of the MVP. If you want it: `.nonactivatingPanel`, `level = .floating`, `hidesOnDeactivate = false`, off by default, and verify it does not cover a video call.
- `LSUIElement = true` in Info.plist so there is no Dock icon.

### 5.6 Project setup

macOS 14 minimum. SwiftUI lifecycle. **App Sandbox off**, because the app reads `~/.codex/auth.json` outside its container; a sandboxed app would need a security-scoped bookmark the user cannot easily grant. That is the honest trade: personal tool, no App Store.

### 5.7 File layout

```
chatgpt-usage-tracker/
  Package.swift                       so `swift test` runs the core with no Xcode
  project.yml                         XcodeGen spec: core framework, app, test bundle
  Sources/ChatGPTUsageCore/           the framework, Foundation only
    UsageLimit.swift                    UsageLimit, UsageWindow, error type, window naming
    CodexCredentials.swift              source protocol, auth.json reader, JWT exp decode
    ChatGPTUsageResponse.swift          Decodable DTOs, CodingKeys, toUsageLimits(now:)
    ChatGPTUsageProvider.swift          the one GET and every failure path
    UsageStore.swift                    selection, timer, the never-stale rule
  Sources/App/ChatGPTUsageTrackerApp.swift   MenuBarExtra scene, LSUIElement
  Sources/UI/                         LimitsPanel, ThresholdColors, RelativeTime
  Tests/ChatGPTUsageCoreTests/        37 tests covering the 14 cases plus the store
  Tests/ChatGPTUsageCoreTests/Fixtures/      captured payloads, identifiers faked
```

The core is a separate framework target rather than files compiled into both the
app and the tests. Compiling the same sources into two targets produces
duplicate symbols at link time, and `@testable import` needs the module name to
match the target name.

### 5.8 Acceptance contract

Delivery is diffed against this, not against a vibe.

1. The section 1 probe returns 200 with a real `used_percent` on your account. **Gate: do not write app code before this passes.**
2. Menu bar shows a percentage that agrees with `https://chatgpt.com/codex/cloud/settings/analytics` read at the same moment, within rounding.
3. Panel lists every window in the payload, named by duration, including anything in `additional_rate_limits`.
4. Kill the network: the previous numbers disappear and a reason appears. No stale value survives a failed fetch.
5. Corrupt or expire the token: the message says to sign in again, and no request is made when the JWT is already expired.
6. `git diff` shows zero writes to `~/.codex/auth.json`, and no log line contains a token.
7. `xcodebuild test` passes with all 14 cases.
8. No Dock icon; quits from the menu.

### 5.9 Effort

| Step | Time |
|---|---|
| Probe and confirm the contract on your account | 2 min |
| Project setup, sandbox off, menu bar shell with a hardcoded % | 1 h |
| Credentials source plus JWT expiry gate, with tests 9 to 14 | 1.5 h |
| Provider, DTOs, window naming, tests 1 to 8 | 2.5 h |
| Panel, selection persistence, refresh, start at login | 2 h |
| Contrast measurement, packaging, sign or run unsigned | 1 h |
| **Total** | **8 h** |

---

## 6. Open questions, with my recommended answer attached

| # | Question | My recommendation |
|---|---|---|
| 1 | Which plan are you on: Plus, Pro 5x, Pro 20x, Business? | Answer it in the probe output; `plan_type` comes back in the response and the app reads it, so it does not block anything. It only predicts which windows you will see. |
| 2 | Is Codex CLI, the IDE extension, or the ChatGPT desktop app signed in on this Mac with ChatGPT? | Must be yes. If no, `brew install --cask codex` or install the desktop app, sign in once, done. This is the one true blocker. |
| 3 | Do you want the always-on-top floating panel? | No, not in v1 of your own build. Ship the menu bar plus panel, add the floating panel only if you actually miss it after a week. |
| 4 | Claude in the same item? | Only via Path A or B. Adding a second provider to a from-scratch build doubles the work for a feature an existing app already has. |
| 5 | Distribute to anyone? | No. Personal, unsigned or self-signed. Distribution means notarization, a paid developer account, and a support burden for an endpoint OpenAI can change any Tuesday. |

---

## 7. Fragility budget

OpenAI can rename this endpoint, gate it behind a new header, or move plan windows elsewhere. Plan for it:

- One file owns the URL, the header set, and the DTOs. A break is a one-file fix.
- Ship a visible "last updated 14:32, status: ok / failed (reason)" line in the panel, so silent breakage is impossible. This is v1's section 9 point 2 and it survives into v2 unchanged, because it was right.
- Re-run the section 1 probe when the app starts misbehaving, before touching Swift. It tells you in 10 seconds whether the break is server-side or yours.

---

## 8. Lessons carried forward

- v1 asked "does the data source exist?" and then answered it from memory. The answer was checkable in one `curl`. Check before planning, or the plan is decoration.
- A premise that is merely *plausible* is the most expensive kind of wrong, because every downstream section inherits it. v1's Phase 5B, WebView plumbing, and cookie Keychain work all descend from one unverified sentence.
- Before designing, search for the sibling that already did the job. It is the spec, and here it was also the finished product.
- "Read-only" is a property you must verify, not assume: the obvious way to read AI usage (ask the model) spends the thing you are measuring.
