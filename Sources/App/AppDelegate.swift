import AppKit
import Combine
import SwiftUI
import ServiceManagement
import ChatGPTUsageCore

/// Owns everything the SwiftUI scene no longer owns after the shell swap:
/// the menu-bar status item, the floating panel, the right-click settings
/// menu, and both provider stores.
///
/// Why AppKit for the shell: MenuBarExtra cannot be dragged, cannot span the
/// screen, and offers no right-click path — the three features this version
/// requires. NSStatusItem + NSPanel can do all three, and NSStatusItem also
/// survives the macOS 26 toggle that silently kills MenuBarExtra apps.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel?
    private let settings = AppSettings()
    // Lazy: UsageStore is MainActor-isolated and these stored properties are
    // initialized in applicationDidFinishLaunching, which is MainActor context.
    @MainActor private lazy var chatGPTStore = UsageStore(
        provider: ChatGPTUsageProvider(),
        selectionKey: "selectedLimitName.chatgpt"
    )
    @MainActor private lazy var claudeStore = UsageStore(
        provider: ClaudeUsageProvider(),
        selectionKey: "selectedLimitName.claude"
    )
    @MainActor private lazy var antigravityStore = UsageStore(
        provider: AntigravityUsageProvider(),
        selectionKey: "selectedLimitName.antigravity"
    )
    @MainActor private lazy var cursorStore = UsageStore(
        provider: CursorUsageProvider(),
        selectionKey: "selectedLimitName.cursor"
    )
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When the app is launched as an XCTest host it is a test runner, not
        // the product: no status item, no timers, no network, no Keychain
        // prompt. The suite must stay hermetic and must never block on a
        // consent dialog nobody may be present to answer.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        if isTestHost { return }

        buildStatusItem()
        wireObservation()
        wireProviderToggles()

        // The panel reopens in the state the user left it in.
        if settings.panelEnabled {
            showPanel()
        }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(statusItemClicked(_:))
            button.target = self
        }
        updateStatusTitle()
    }

    /// Title recomputes from whichever provider is enabled: ChatGPT first,
    /// Claude when ChatGPT is off, Cursor next, Gemini last, honest dashes
    /// when no provider has data.
    private func updateStatusTitle() {
        let primary: UsageStore?
        if settings.chatGPTEnabled {
            primary = chatGPTStore
        } else if settings.claudeEnabled {
            primary = claudeStore
        } else if settings.cursorEnabled {
            primary = cursorStore
        } else if settings.antigravityEnabled {
            primary = antigravityStore
        } else {
            primary = nil
        }
        let title: String
        if primary === cursorStore, let store = primary {
            let limits = store.limits
            let auto = settings.showRemaining
                ? limits.flatMap(UsageWindowLookup.cursorAutoRemainingPercent(in:))
                : limits.flatMap(UsageWindowLookup.cursorAutoPercent(in:))
            let api = settings.showRemaining
                ? limits.flatMap(UsageWindowLookup.cursorApiRemainingPercent(in:))
                : limits.flatMap(UsageWindowLookup.cursorApiPercent(in:))
            title = HeaderFormatter.cursorTitle(autoLeft: auto, apiLeft: api)
        } else if let store = primary {
            let limits = store.limits
            let session = settings.showRemaining
                ? limits.flatMap(UsageWindowLookup.sessionRemainingPercent(in:))
                : limits.flatMap(UsageWindowLookup.sessionPercent(in:))
            let weekly = settings.showRemaining
                ? limits.flatMap(UsageWindowLookup.weeklyRemainingPercent(in:))
                : limits.flatMap(UsageWindowLookup.weeklyPercent(in:))
            title = HeaderFormatter.title(
                style: settings.headerStyle,
                sessionPercent: session,
                weeklyPercent: weekly
            )
        } else {
            title = HeaderFormatter.title(
                style: settings.headerStyle,
                sessionPercent: nil,
                weeklyPercent: nil
            )
        }
        statusItem.button?.title = title
    }

    private func wireObservation() {
        // objectWillChange fires before the new value lands; the hop to the
        // main queue runs the title rebuild after it has.
        Publishers.MergeMany(
            settings.objectWillChange,
            chatGPTStore.objectWillChange,
            claudeStore.objectWillChange,
            antigravityStore.objectWillChange,
            cursorStore.objectWillChange
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.updateStatusTitle() }
        .store(in: &cancellables)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // The classic NSStatusItem right-click trick: attach the menu for
            // one click, perform it, detach, so left-click stays ours.
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    // MARK: - Panel

    private func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // First run, or a saved frame rejected as off-screen: take the size from
        // the actual content so a second provider cannot push the footer outside
        // the window. After this the user's own drag/resize is authoritative and
        // persisted, so this never fights a deliberate size.
        if savedFrame() == nil, let hosting = panel.contentView {
            let fitting = hosting.fittingSize
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let height = min(max(fitting.height, panel.minSize.height), visible.height * 0.4)
            let width = min(max(fitting.width, panel.minSize.width), visible.width * 0.5)
            panel.setContentSize(NSSize(width: width, height: height))
        }
        panel.makeKeyAndOrderFront(nil)
        settings.panelEnabled = true
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        settings.panelEnabled = false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: savedFrame() ?? defaultFrame(),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        // Above normal windows and present in every space, including over
        // fullscreen apps — the whole point of a strip you keep on screen.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        // Strip floor: one condensed line of usage, never a tiny unusable sliver.
        panel.minSize = NSSize(width: 260, height: 56)
        panel.delegate = self

        // Claude and Gemini are passed as arguments, not as environment
        // objects: the environment is keyed by type, so extra `UsageStore`s
        // there would silently overwrite ChatGPT's (measured before this fix).
        let root = LimitsPanel(claude: claudeStore, antigravity: antigravityStore, cursor: cursorStore)
            .environmentObject(chatGPTStore)
            .environmentObject(settings)
        panel.contentView = NSHostingView(rootView: root)
        return panel
    }

    private func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 480, height: 150)
        return NSRect(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
    }

    private func savedFrame() -> NSRect? {
        guard let parts = UserDefaults.standard.array(forKey: "panelFrame") as? [Double],
              parts.count == 4
        else { return nil }
        let stored = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        guard stored.width >= 1, stored.height >= 1 else { return nil }

        // A frame saved on a screen that is gone, or a stale off-screen frame
        // (this app has already shipped one: panelFrame = (13, -12, ...) put the
        // panel above the top edge), must not be restored verbatim or the user
        // cannot reach the window. Only a frame that still intersects a visible
        // screen is trusted; anything else falls back to defaultFrame().
        let screens = NSScreen.screens
        guard let first = screens.first else { return stored }
        let visible = screens.dropFirst().reduce(first.visibleFrame) { $0.union($1.visibleFrame) }
        guard stored.intersects(visible) else { return nil }
        return stored
    }

    func windowDidMove(_ notification: Notification) { persistFrame() }
    func windowDidResize(_ notification: Notification) { persistFrame() }

    /// The red close button is not `hidePanel()`, so without this the panel
    /// reopened on the next launch even though the user had deliberately closed
    /// it: only the flag written here makes "closed" survive a relaunch.
    func windowWillClose(_ notification: Notification) {
        settings.panelEnabled = false
    }

    private func persistFrame() {
        guard let panel, panel.isVisible else { return }
        let frame = panel.frame
        UserDefaults.standard.set([frame.origin.x, frame.origin.y, frame.width, frame.height], forKey: "panelFrame")
    }

    // MARK: - Right-click menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let panelItem = NSMenuItem(
            title: panel?.isVisible == true ? "Hide Panel" : "Show Panel",
            action: #selector(menuTogglePanel),
            keyEquivalent: ""
        )
        panelItem.target = self
        menu.addItem(panelItem)

        let loginItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(menuToggleLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let chatItem = NSMenuItem(title: "ChatGPT", action: #selector(menuToggleChatGPT), keyEquivalent: "")
        chatItem.target = self
        chatItem.state = settings.chatGPTEnabled ? .on : .off
        menu.addItem(chatItem)

        let claudeItem = NSMenuItem(title: "Claude", action: #selector(menuToggleClaude), keyEquivalent: "")
        claudeItem.target = self
        claudeItem.state = settings.claudeEnabled ? .on : .off
        menu.addItem(claudeItem)

        let antigravityItem = NSMenuItem(title: "Gemini", action: #selector(menuToggleAntigravity), keyEquivalent: "")
        antigravityItem.target = self
        antigravityItem.state = settings.antigravityEnabled ? .on : .off
        menu.addItem(antigravityItem)

        let cursorItem = NSMenuItem(title: "Cursor", action: #selector(menuToggleCursor), keyEquivalent: "")
        cursorItem.target = self
        cursorItem.state = settings.cursorEnabled ? .on : .off
        menu.addItem(cursorItem)

        menu.addItem(.separator())

        let headerRoot = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        let headerMenu = NSMenu(title: "Menu Bar Shows")
        for style in HeaderStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: #selector(menuSetHeaderStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = settings.headerStyle == style ? .on : .off
            headerMenu.addItem(item)
        }
        headerRoot.submenu = headerMenu
        menu.addItem(headerRoot)

        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Show Remaining %", action: #selector(menuToggleShowRemaining), keyEquivalent: "")
        showItem.target = self
        showItem.state = settings.showRemaining ? .on : .off
        menu.addItem(showItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func menuTogglePanel() { togglePanel() }

    @objc private func menuToggleShowRemaining() {
        settings.showRemaining.toggle()
        updateStatusTitle()
    }

    @objc private func menuToggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Unsigned builds can fail registration; say so instead of
            // silently flipping the checkmark back.
            let alert = NSAlert()
            alert.messageText = "Could not change launch at login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func menuToggleChatGPT() {
        settings.chatGPTEnabled.toggle()
    }

    @objc private func menuToggleClaude() {
        settings.claudeEnabled.toggle()
    }

    @objc private func menuToggleAntigravity() {
        settings.antigravityEnabled.toggle()
    }

    @objc private func menuToggleCursor() {
        settings.cursorEnabled.toggle()
    }

    @objc private func menuSetHeaderStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = HeaderStyle(rawValue: raw)
        else { return }
        settings.headerStyle = style
    }

    @objc private func menuQuit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Provider lifecycle

    private func wireProviderToggles() {
        settings.$chatGPTEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.apply(chatGPT: enabled) }
            .store(in: &cancellables)
        settings.$claudeEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.apply(claude: enabled) }
            .store(in: &cancellables)
        settings.$antigravityEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.apply(antigravity: enabled) }
            .store(in: &cancellables)
        settings.$cursorEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.apply(cursor: enabled) }
            .store(in: &cancellables)
    }

    private func apply(chatGPT enabled: Bool) {
        guard enabled else {
            chatGPTStore.stop()
            return
        }
        chatGPTStore.start()
        Task { await chatGPTStore.refresh() }
    }

    private func apply(claude enabled: Bool) {
        guard enabled else {
            claudeStore.stop()
            return
        }
        claudeStore.start()
        Task { await claudeStore.refresh() }
    }

    private func apply(antigravity enabled: Bool) {
        guard enabled else {
            antigravityStore.stop()
            return
        }
        antigravityStore.start()
        Task { await antigravityStore.refresh() }
    }

    private func apply(cursor enabled: Bool) {
        guard enabled else {
            cursorStore.stop()
            return
        }
        cursorStore.start()
        Task { await cursorStore.refresh() }
    }
}
