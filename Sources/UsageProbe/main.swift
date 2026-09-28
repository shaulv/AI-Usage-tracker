import Foundation
import ChatGPTUsageCore

/// A live-state probe: prints exactly what the app would show, so a bug report
/// can quote the real message instead of describing a screenshot.
///
/// It lives outside the test target on purpose. `swift test` must stay offline
/// and hermetic (it is asserted by the README), while this binary is allowed to
/// touch the network and the real home directory. Nothing here writes anything:
/// it only reads credentials through the app's own sources and calls the app's
/// own providers, so what it prints is exactly what the panel would render.
///
/// Usage:  swift run usage-probe chatgpt | claude | antigravity | cursor | grok | both | all
/// Exit:   0 when every requested provider answered, 1 when any failed.

func describe(_ provider: any UsageProvider) async -> Bool {
    print("== \(provider.displayName) ==")
    do {
        let limits = try await provider.fetchLimits()
        guard !limits.isEmpty else {
            print("state: ok")
            print("message: no usage limits available")
            return true
        }
        print("state: ok")
        for limit in limits {
            let reset = limit.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "no reset"
            print("  \(limit.name): \(limit.usedPercentRounded)%  resets \(reset)")
        }
        return true
    } catch let error as UsageProviderError {
        print("state: failed")
        print("message: \(error.message)")
        return false
    } catch {
        print("state: failed")
        print("message: Unexpected error")
        return false
    }
}

let requested = Array(CommandLine.arguments.dropFirst())
let targets = requested.isEmpty ? ["chatgpt"] : requested

var allOK = true
for target in targets {
    switch target {
    case "chatgpt":
        let ok = await describe(ChatGPTUsageProvider())
        allOK = ok && allOK
    case "claude":
        let ok = await describe(ClaudeUsageProvider())
        allOK = ok && allOK
    case "antigravity":
        let ok = await describe(AntigravityUsageProvider())
        allOK = ok && allOK
    case "cursor":
        let ok = await describe(CursorUsageProvider())
        allOK = ok && allOK
    case "grok":
        let ok = await describe(GrokUsageProvider())
        allOK = ok && allOK
    case "both":
        let chatGPT = await describe(ChatGPTUsageProvider())
        let claude = await describe(ClaudeUsageProvider())
        allOK = chatGPT && claude && allOK
    case "all":
        let chatGPT = await describe(ChatGPTUsageProvider())
        let claude = await describe(ClaudeUsageProvider())
        let antigravity = await describe(AntigravityUsageProvider())
        let cursor = await describe(CursorUsageProvider())
        let grok = await describe(GrokUsageProvider())
        allOK = chatGPT && claude && antigravity && cursor && grok && allOK
    default:
        print("unknown target '\(target)'. Use: chatgpt | claude | antigravity | cursor | grok | both | all")
        allOK = false
    }
}

exit(allOK ? 0 : 1)