import AppKit
import ForgeDeckKit
import SwiftUI

// ForgeDeck
//   ForgeDeck                         the app
//   forgedeck <command>               the CLI: the same binary, started through the `forgedeck` link
//   FORGEDECK_HOME=<dir> ForgeDeck    use another data folder (tests, snapshots)
//   APP_SNAPSHOT=<dir> ForgeDeck      save a PNG of every page in light and dark, then quit (tools/snap.sh)
//   APP_SEED=demo|empty               what the snapshot run starts with
//   ForgeDeck --selftest              run the self-test on a temporary folder and quit with 0 or 1
//   APP_KIT_GALLERY=1 ForgeDeck       show the design kit instead of the app
//   APP_GRID=1 ForgeDeck              draw the grid and layout probes over the window

@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if CLI.isInvocation(arguments: arguments) {
            Task.detached {
                let code = await CLI().run(Array(arguments.dropFirst()))
                exit(code)
            }
            dispatchMain()
        }
        ForgeDeckApp.main()
    }
}

struct ForgeDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        let _ = { delegate.model = model }()
        Window(Brand.name, id: "main") {
            Group {
                if Runtime.isGallery { KitGallery() } else { RootView() }
            }
            .environment(model)
            .tint(Ink.accent)
            .preferredColorScheme(scheme)
            .overlay { if GridOverlay.enabled { GridOverlay() } }
            .frame(minWidth: 1000, minHeight: 640)
            .ignoresSafeArea()
            .background(WindowChrome())
            .focusEffectDisabled()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .tint(Ink.accent)
                .preferredColorScheme(scheme)
        }
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: Binding(get: { model.portfolio.settings.showMenuBarExtra && !Runtime.isAutomated },
                                         set: { value in
                                             // Writing an unchanged value would invalidate every view, forever.
                                             guard !Runtime.isAutomated, model.portfolio.settings.showMenuBarExtra != value else { return }
                                             model.portfolio.settings.showMenuBarExtra = value
                                             model.save()
                                         })) {
            MenuBarView().environment(model).tint(Ink.accent)
        } label: {
            Image(systemName: model.attentionIncidents.isEmpty ? "hammer" : "hammer.fill")
                .accessibilityLabel("\(Brand.name): \(model.attentionIncidents.count) alerts")
        }
        .menuBarExtraStyle(.window)
    }

    private var scheme: ColorScheme? {
        switch model.portfolio.settings.appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    /// Running terminals end when the app quits, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !Runtime.isAutomated, !model.skipQuitConfirmation else { return .terminateNow }
        let running = model.terminals.running
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "\(running.count) terminal session\(running.count == 1 ? " is" : "s are") still running"
        alert.informativeText = "Quitting ends: " + running.map { "\($0.title) (\($0.activity))" }.joined(separator: ", ") + "."
        alert.addButton(withTitle: "Quit and End Sessions")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.terminals.terminateAll()
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { Runtime.isAutomated }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { for window in sender.windows where window.canBecomeMain { window.makeKeyAndOrderFront(nil) } }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await model.checkForUpdates(userInitiated: true) } }.disabled(model.updateBusy)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Product…") { model.sheet = .addProduct }.keyboardShortcut("n")
            Divider()
            Button("Open in Terminal") { if let product = model.currentProduct { model.openTerminal(product) } }
                .keyboardShortcut("o").disabled(model.currentProduct == nil)
            Button("Open in Editor") { if let product = model.currentProduct { model.openEditor(product) } }
                .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.currentProduct == nil)
            Button("Open with \(AgentCatalog.name(model.portfolio.settings.aiAgentProgram))") { if let product = model.currentProduct { model.openAgent(product) } }
                .keyboardShortcut("o", modifiers: [.command, .option]).disabled(model.currentProduct.map { $0.isDemo || !$0.hasLocal } ?? true)
            Button("Play") { if let product = model.currentProduct { model.play(product) } }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.currentProduct.map { model.playOptions($0).isEmpty } ?? true)
            Button("Set Up Run…") { if let product = model.currentProduct { model.setUpRun(product) } }
                .disabled(model.currentProduct.map { $0.isDemo || !$0.hasLocal } ?? true)
            Button("Set Up Leads…") { if let product = model.currentProduct { model.setUpLeads(product) } }
                .disabled(model.currentProduct.map { $0.isDemo || !$0.hasLocal } ?? true)
            Button("Reveal in Finder") { if let product = model.currentProduct { model.reveal(product) } }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.currentProduct == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") { model.paletteOpen.toggle() }.keyboardShortcut("k")
            Button(model.terminals.isVisible ? "Hide Terminal" : "Show Terminal") {
                if model.terminals.visible.isEmpty, let product = model.currentProduct, product.hasLocal, !product.isDemo { model.openTerminal(product) }
                else { model.terminals.isVisible.toggle() }
            }
            .keyboardShortcut("`")
            Button(model.usagePanelVisible ? "Hide AI Usage" : "Show AI Usage") { model.toggleUsagePanel() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button(model.isRemoteRunning ? "Stop Forge Remote" : "Start Forge Remote") { model.setRemote(enabled: !model.isRemoteRunning) }
                .disabled(!model.isRemoteRunning && ExecutableLocator.find(ForgeRemote.program) == nil)
            Button("Refresh") { model.refreshCurrentPage() }.keyboardShortcut("r")
            Divider()
            Button("Overview") { model.go(.overview) }.keyboardShortcut("1")
            Button("Products") { model.go(.projects) }.keyboardShortcut("2")
            Button("Deployments") { model.go(.deployments) }.keyboardShortcut("3")
            Button("Leads & Metrics") { model.go(.leads) }.keyboardShortcut("4")
            Button("Infrastructure") { model.go(.infrastructure) }.keyboardShortcut("5")
            Button("Git & CI") { model.go(.git) }.keyboardShortcut("6")
            Button("Terminals & Actions") { model.go(.terminals) }.keyboardShortcut("7")
            Button("Toolbox") { model.go(.toolbox) }.keyboardShortcut("9")
            Button("Secrets Vault") { model.go(.secrets) }.keyboardShortcut("8")
            Button("Activity") { model.go(.activity) }.keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Back") { model.goBack() }.keyboardShortcut("[").disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }.keyboardShortcut("]").disabled(!model.canGoForward)
            Divider()
            Button(model.context == .production ? "Switch to Staging" : "Switch to Production") {
                model.context = model.context == .production ? .staging : .production
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }
}

/// Hides the title bar and puts the traffic lights where the design has them.
struct WindowChrome: NSViewRepresentable {
    var firstButtonCenter = CGPoint(x: 24, y: 26)
    var buttonSpacing: CGFloat = 20

    func makeNSView(context: Context) -> NSView {
        let view = ChromeView()
        view.configure = configure
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type), let container = button.superview else { continue }
            let x = firstButtonCenter.x + CGFloat(index) * buttonSpacing
            button.setFrameOrigin(NSPoint(x: x - button.frame.width / 2,
                                          y: container.frame.height - firstButtonCenter.y - button.frame.height / 2))
        }
    }

    private final class ChromeView: NSView {
        var configure: ((NSWindow) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in self?.configure?(window) }
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.configure?(window) }
                })
            }
        }
    }
}

/// The empty top strip of the window drags it, like a title bar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
    }
}
