import Foundation

/// Holds the current limits, the user's selection, and the refresh cadence.
///
/// One rule lives here and nowhere else: **a failed fetch discards the
/// previous limits.** A wrong percentage held on screen for days is worse than
/// an honest "unknown", and putting the rule in the store means no provider can
/// forget it.
@MainActor
public final class UsageStore: ObservableObject {
    /// Nil means "no data to show", which covers not-yet-fetched, fetch failed,
    /// and a genuine "this account has no limits". The UI distinguishes those
    /// using `state`.
    @Published public private(set) var limits: [UsageLimit]?
    @Published public private(set) var state: FetchState = .idle
    @Published public private(set) var lastUpdated: Date?
    /// Which limit the menu bar shows. Persisted so the choice survives relaunch.
    @Published public var selectedLimitName: String? {
        didSet {
            guard selectedLimitName != oldValue else { return }
            if let selectedLimitName {
                defaults.set(selectedLimitName, forKey: Self.selectionKey)
            } else {
                defaults.removeObject(forKey: Self.selectionKey)
            }
        }
    }

    public enum FetchState: Equatable {
        case idle
        case refreshing
        case ok
        case failed(String)

        public var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public static let minimumRefreshInterval: TimeInterval = 300

    /// The interval actually in force, after the floor is applied. Exposed so
    /// the floor can be asserted instead of assumed.
    public let effectiveRefreshInterval: TimeInterval

    private let provider: any UsageProvider
    private let refreshInterval: TimeInterval
    private let defaults: UserDefaults
    private var timer: Timer?

    private static let selectionKey = "selectedLimitName"

    public init(
        provider: any UsageProvider = ChatGPTUsageProvider(),
        refreshInterval: TimeInterval = 300,
        defaults: UserDefaults = .standard
    ) {
        self.provider = provider
        // A 5 minute floor. Polling faster buys nothing for windows that reset
        // on the scale of hours, and it makes the traffic pattern look less
        // like a person.
        self.refreshInterval = max(refreshInterval, Self.minimumRefreshInterval)
        self.effectiveRefreshInterval = self.refreshInterval
        self.defaults = defaults
        self.selectedLimitName = defaults.string(forKey: Self.selectionKey)
    }

    /// The limit shown in the menu bar. Falls back to the first row when the
    /// saved selection is no longer in the payload, which happens whenever
    /// OpenAI renames a limit.
    public var selectedLimit: UsageLimit? {
        guard let limits else { return nil }
        if let selectedLimitName, let match = limits.first(where: { $0.name == selectedLimitName }) {
            return match
        }
        return limits.first
    }

    /// "--%" whenever there is nothing honest to show.
    public var menuBarLabel: String {
        guard let selectedLimit else { return "--%" }
        return "\(selectedLimit.usedPercentRounded)%"
    }

    public var lastUpdatedText: String {
        guard let lastUpdated else { return "never" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: lastUpdated)
    }

    public func start() {
        stop()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() async {
        state = .refreshing
        do {
            let fetched = try await provider.fetchLimits()
            setLimits(fetched)
            lastUpdated = Date()
            state = .ok
        } catch let error as UsageProviderError {
            setLimits(nil)
            state = .failed(error.message)
        } catch {
            setLimits(nil)
            state = .failed("Unexpected error")
        }
    }

    /// The never-stale rule, in one place.
    private func setLimits(_ newLimits: [UsageLimit]?) {
        limits = newLimits
    }

    // No deinit: touching a MainActor-isolated property from deinit requires
    // Swift 6 semantics. The timer closure captures self weakly, so a
    // deallocated store simply stops receiving work. Call stop() explicitly if
    // you need the timer gone sooner.
}
