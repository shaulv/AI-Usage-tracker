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
    /// Which limit the menu bar shows. Persisted under a per-store key so the
    /// ChatGPT and Claude stores never overwrite each other's choice.
    @Published public var selectedLimitName: String? {
        didSet {
            guard selectedLimitName != oldValue else { return }
            if let selectedLimitName {
                defaults.set(selectedLimitName, forKey: selectionKey)
            } else {
                defaults.removeObject(forKey: selectionKey)
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

    /// A 60 second floor. This is the idle cadence: slow enough that the traffic
    /// pattern still looks like a person checking, fast enough that a moved
    /// percentage is noticed within a minute.
    public static let minimumRefreshInterval: TimeInterval = 60
    /// Cadence while a burst is active: percentages started moving, so watch
    /// every 10 seconds until the minute-long burst window closes.
    public static let burstRefreshInterval: TimeInterval = 10
    /// How long the fast cadence runs after movement is first seen. Movement
    /// seen during a burst re-arms the window (a value still climbing keeps
    /// being watched); once values sit still the window drains and cadence
    /// returns to the 60 second idle rate.
    public static let burstDuration: TimeInterval = 60

    /// The interval actually in force, after the floor is applied. Exposed so
    /// the floor can be asserted instead of assumed.
    public let effectiveRefreshInterval: TimeInterval

    /// Pure cadence decision, separated so the burst behavior is unit-testable
    /// without sleeping through real timers. `idle` is the configured idle
    /// cadence (floored at `minimumRefreshInterval` by `init`), not a constant,
    /// so a caller that asks for five minutes actually gets five minutes. A
    /// burst window still wins while it is open.
    public static func refreshDelay(
        now: Date,
        burstDeadline: Date?,
        idle: TimeInterval = minimumRefreshInterval
    ) -> TimeInterval {
        if let burstDeadline, now < burstDeadline {
            return burstRefreshInterval
        }
        return idle
    }

    /// Non-nil while a burst window is open. Drives `refreshDelay` and the
    /// status line, and is asserted by the burst tests.
    public private(set) var burstDeadline: Date?

    private let provider: any UsageProvider
    private let refreshInterval: TimeInterval
    private let defaults: UserDefaults
    private var timer: Timer?
    /// True between `start()` and `stop()`. Timers only chain while started,
    /// so a test that calls `refresh()` directly never spawns timers.
    private var started = false
    /// Signature of the last successful payload; movement against it opens a
    /// burst. Cleared on failure so a recovery does not read as movement.
    private var lastSuccessfulSignature: String?
    private let now: () -> Date

    private let selectionKey: String

    public init(
        provider: any UsageProvider = ChatGPTUsageProvider(),
        refreshInterval: TimeInterval = 60,
        defaults: UserDefaults = .standard,
        selectionKey: String = "selectedLimitName",
        now: @escaping () -> Date = { Date() }
    ) {
        self.provider = provider
        self.refreshInterval = max(refreshInterval, Self.minimumRefreshInterval)
        self.effectiveRefreshInterval = self.refreshInterval
        self.defaults = defaults
        self.selectionKey = selectionKey
        self.now = now
        self.selectedLimitName = defaults.string(forKey: selectionKey)
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
        started = true
        scheduleNext()
    }

    public func stop() {
        started = false
        timer?.invalidate()
        timer = nil
    }

    /// One-shot reschedule after every completed refresh while started: the
    /// next delay is 10s inside a burst window and 60s outside one, so the
    /// cadence follows the data instead of a fixed interval.
    private func scheduleNext() {
        timer?.invalidate()
        guard started else { return }
        let delay = Self.refreshDelay(now: now(), burstDeadline: burstDeadline, idle: refreshInterval)
        let timer = Timer(fire: now().addingTimeInterval(delay), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func refresh() async {
        state = .refreshing
        do {
            let fetched = try await provider.fetchLimits()
            setLimits(fetched)
            lastUpdated = Date()
            state = .ok
            let signature = Self.signature(of: fetched)
            if let previous = lastSuccessfulSignature, previous != signature {
                // Percentages moved: open (or re-arm) the one-minute fast window.
                burstDeadline = now().addingTimeInterval(Self.burstDuration)
            }
            lastSuccessfulSignature = signature
        } catch let error as UsageProviderError {
            setLimits(nil)
            state = .failed(error.message)
            // A failure is not movement; drop the baseline so the recovery
            // fetch does not masquerade as a percentage change.
            lastSuccessfulSignature = nil
        } catch {
            setLimits(nil)
            state = .failed("Unexpected error")
            lastSuccessfulSignature = nil
        }
        if started {
            scheduleNext()
        }
    }

    /// Order-sensitive so a reordering of the same rows counts as movement.
    static func signature(of limits: [UsageLimit]) -> String {
        limits.map { "\($0.name):\($0.usedPercentRounded)" }.joined(separator: "|")
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
