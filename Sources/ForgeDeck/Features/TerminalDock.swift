import AppKit
import ForgeDeckKit
import SwiftTerm
import SwiftUI

/// One terminal inside ForgeDeck: a real PTY running a shell or a command.
/// The view lives as long as the session, so switching tabs or pages never restarts it.
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case running
        case exited(Int32?)
        case failed(String)
    }

    let id = UUID()
    let launch: TerminalLaunch
    let productID: UUID?
    let checkoutID: UUID?
    let startedAt = Date.now
    var title: String
    var state: State = .running
    /// The program in the foreground, like "claude" or "npm". nil while the shell waits for input.
    var foreground: String?
    var directory: String

    @ObservationIgnored let view: LocalProcessTerminalView
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var delegateBox: Delegate?
    @ObservationIgnored var onExit: ((TerminalSession) -> Void)?

    var isRunning: Bool { state == .running }
    /// Running something other than an idle shell.
    var isBusy: Bool { isRunning && (launch.kind != .shell || foreground != nil) }

    var activity: String {
        switch state {
        case .running: foreground ?? (launch.kind == .shell ? "idle" : (launch.executable as NSString).lastPathComponent)
        case .exited(let code): code.map { "exited \($0)" } ?? "ended"
        case .failed: "failed to start"
        }
    }

    init(launch: TerminalLaunch, productID: UUID?, checkoutID: UUID?) {
        self.launch = launch
        self.productID = productID
        self.checkoutID = checkoutID
        title = launch.title
        directory = launch.directory
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        configureAppearance()
        let box = Delegate(session: self)
        delegateBox = box
        view.processDelegate = box
        if let banner = launch.banner { view.feed(text: banner) }
        view.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environment,
                          execName: launch.execName, currentDirectory: launch.directory)
        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshForeground() }
        }
    }

    @ObservationIgnored private var isDark: Bool?

    /// Matches the window's light or dark appearance. Called again whenever it changes.
    func configureAppearance(dark: Bool? = nil) {
        let dark = dark ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        guard dark != isDark else { return }
        isDark = dark
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = dark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : NSColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 1)
        view.nativeForegroundColor = dark ? NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1) : NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        view.caretColor = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.55, alpha: 1)
    }

    func refreshForeground() {
        guard isRunning else { return }
        let process = view.process
        let found = process.map { ProcessInspector.foreground(ptyFD: $0.childfd, shellPID: $0.shellPid)?.name } ?? nil
        if found != foreground { foreground = found }
    }

    /// The visible text, for tests and for Copy All.
    var text: String { String(decoding: view.getBufferAsData(), as: UTF8.self) }

    func send(_ text: String) { view.send(txt: text) }

    /// Ends the session: hang up the whole process group, like closing a terminal window.
    func terminate() {
        poll?.invalidate()
        guard isRunning, let process = view.process else { return }
        let pid = process.shellPid
        if pid > 0 {
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
        }
        view.terminate()
    }

    fileprivate func finished(_ code: Int32?) {
        poll?.invalidate()
        foreground = nil
        state = .exited(code)
        onExit?(self)
    }

    private final class Delegate: NSObject, LocalProcessTerminalViewDelegate {
        weak var session: TerminalSession?
        init(session: TerminalSession) { self.session = session }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        /// Shells set a title on every prompt. The session keeps its own name; the foreground program is read from the PTY instead.
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            if let directory, let url = URL(string: directory), url.isFileURL { session?.directory = url.path }
        }
        func processTerminated(source: TerminalView, exitCode: Int32?) { session?.finished(exitCode) }
        func processFailedToStart(source: TerminalView, error: LocalProcessError) {
            session?.state = .failed(String(describing: error))
        }
    }
}

/// All terminal sessions, and the dock that shows them.
/// On a product page the dock shows only that product's sessions (plus shells that belong to no product),
/// so a terminal from another product never sits under the wrong page.
@Observable
final class TerminalHost {
    var sessions: [TerminalSession] = []
    var selectedID: UUID?
    var isVisible = false
    var height: CGFloat = 300
    /// The product the window shows. nil on pages that are not about one product: the dock shows everything.
    var scope: UUID? {
        didSet { if scope != oldValue { showAll = false } }
    }
    /// The person chose to see every product's sessions on this product page.
    var showAll = false
    /// The session last picked for each product, so coming back to a product shows the same terminal.
    @ObservationIgnored private var lastSelected: [UUID: UUID] = [:]

    var isScoped: Bool { scope != nil && !showAll }
    /// The sessions the dock shows right now.
    var visible: [TerminalSession] {
        guard isScoped else { return sessions }
        return sessions.filter { $0.productID == scope || $0.productID == nil }
    }
    /// Sessions that belong to other products, hidden while the dock follows this one.
    var hiddenCount: Int { isScoped ? sessions.count - visible.count : 0 }

    var selected: TerminalSession? {
        let shown = visible
        if let id = selectedID, let session = shown.first(where: { $0.id == id }) { return session }
        if let scope, let id = lastSelected[scope], let session = shown.first(where: { $0.id == id }) { return session }
        return shown.last
    }
    var running: [TerminalSession] { sessions.filter(\.isRunning) }

    func sessions(for productID: UUID) -> [TerminalSession] { sessions.filter { $0.productID == productID && $0.isRunning } }

    func select(_ session: TerminalSession) {
        selectedID = session.id
        if let product = session.productID { lastSelected[product] = session.id }
        // Picking another product's session from "All" is fine; the dock stays on All until the page changes.
    }

    @discardableResult
    func open(_ launch: TerminalLaunch, productID: UUID?, checkoutID: UUID?) -> TerminalSession {
        let session = TerminalSession(launch: launch, productID: productID, checkoutID: checkoutID)
        sessions.append(session)
        // A session for another product than the page shows would be hidden: show everything instead.
        if let scope, let productID, productID != scope { showAll = true }
        select(session)
        isVisible = true
        // Focus the terminal so typing goes straight to the shell.
        DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) }
        return session
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        sessions.removeAll { $0.id == session.id }
        lastSelected = lastSelected.filter { $0.value != session.id }
        if selectedID == session.id { selectedID = visible.last?.id ?? sessions.last?.id }
        if sessions.isEmpty { isVisible = false }
    }

    func terminateAll() { for session in sessions { session.terminate() } }
}

// MARK: Views

/// Hosts a session's existing NSView. SwiftUI never creates a second terminal for the same session.
struct TerminalViewHost: NSViewRepresentable {
    let session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        session.configureAppearance(dark: colorScheme == .dark)
        if session.view.superview !== container { attach(to: container) }
        container.wantsLayer = true
        container.layer?.backgroundColor = session.view.nativeBackgroundColor.cgColor
    }

    private func attach(to container: NSView) {
        session.configureAppearance(dark: colorScheme == .dark)
        container.subviews.forEach { $0.removeFromSuperview() }
        session.view.removeFromSuperview()
        session.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(session.view)
        NSLayoutConstraint.activate([
            session.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            session.view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            session.view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            session.view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
    }
}

struct SessionDot: View {
    let session: TerminalSession

    var body: some View {
        let tone: Tone = !session.isRunning ? (session.state == .exited(0) ? .muted : .err) : session.isBusy ? .accent : .ok
        Dot(color: Ink.tone(tone), size: 7) // grid: ok status dot size from the design
            .accessibilityLabel(session.isRunning ? (session.isBusy ? "Running \(session.activity)" : "Idle shell") : session.activity)
    }
}

struct TerminalDock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragStart: CGFloat?

    var body: some View {
        let host = model.terminals
        VStack(spacing: 0) {
            // A drag handle on the top edge resizes the dock.
            Ink.line.frame(height: Metric.hairline)
                .overlay { Color.clear.frame(height: 8).contentShape(Rectangle()) }
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    let start = dragStart ?? host.height
                    dragStart = start
                    host.height = min(720, max(140, start - value.translation.height))
                }.onEnded { _ in dragStart = nil })
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            HStack(spacing: Space.xs) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(host.visible) { session in tab(session, selected: session.id == host.selected?.id) }
                    }
                }
                Spacer(minLength: Space.sm)
                scopeToggle
                if let product = model.currentProduct, product.hasLocal, !product.isDemo {
                    IconButton(.plus, label: "New shell in \(product.primaryCheckout?.name ?? product.name)", kind: .toolbar) { model.openTerminal(product) }
                }
                if let session = host.selected {
                    IconButton(.copy, label: "Copy everything in this terminal") { model.copy(session.text, message: "Copied the terminal text") }
                    if session.isRunning, let checkout = model.product(session.productID)?.checkout(id: session.checkoutID) ?? model.product(session.productID)?.primaryCheckout {
                        IconButton(.external, label: "Open this folder in \(KnownApps.descriptor(bundleID: model.portfolio.settings.preferredTerminalBundleID)?.name ?? "an external terminal")") {
                            if let product = model.product(session.productID) { model.openExternalTerminal(product, checkout: checkout) }
                        }
                    }
                }
                IconButton(.chevronDown, label: "Hide the terminal (⌘`)", kind: .toolbar) { host.isVisible = false }
            }
            .padding(.horizontal, Space.sm).frame(height: 32)
            .background(Ink.panel2)
            .hairlineBelow()
            if let session = host.selected {
                ZStack(alignment: .bottomTrailing) {
                    TerminalViewHost(session: session).id(session.id)
                    if !session.isRunning {
                        HStack(spacing: Space.sm) {
                            Text(session.state == .exited(0) ? "Finished" : "Ended: \(session.activity)").kitType(.labelMedium, session.state == .exited(0) ? Ink.ok : Ink.err)
                            if session.launch.kind != .shell {
                                Button("Run Again") { model.terminals.open(session.launch, productID: session.productID, checkoutID: session.checkoutID) }
                                    .buttonStyle(.kit(.secondary, compact: true))
                            }
                            Button("Close") { host.close(session) }.buttonStyle(.kit(.secondary, compact: true))
                        }
                        .padding(Space.sm)
                        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Metric.controlRadius))
                        .shadow(color: Ink.shadowLarge, radius: 6, y: 2)
                        .padding(Space.md)
                    }
                }
                .background(colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.985))
            } else {
                emptyForProduct
            }
        }
        .frame(height: host.height)
        .transition(.move(edge: .bottom))
    }

    /// "All terminals (3)" while the dock follows a product; "Only Lumen" while it shows everything.
    @ViewBuilder private var scopeToggle: some View {
        let host = model.terminals
        if let product = model.currentProduct {
            if host.isScoped, host.hiddenCount > 0 {
                Button("All Terminals (\(host.sessions.count))") { host.showAll = true }
                    .buttonStyle(.kit(.ghost, compact: true))
                    .help("\(host.hiddenCount) terminal\(host.hiddenCount == 1 ? "" : "s") from other products \(host.hiddenCount == 1 ? "is" : "are") hidden while you look at \(product.name)")
            } else if host.showAll {
                Button("Only \(product.name)") { host.showAll = false }
                    .buttonStyle(.kit(.ghost, compact: true))
                    .help("Show only the terminals that belong to \(product.name)")
            }
        }
    }

    /// The dock is open on a product that has no terminal yet.
    private var emptyForProduct: some View {
        let product = model.currentProduct
        let local = product.map { $0.hasLocal && !$0.isDemo } ?? false
        return VStack(spacing: Space.md) {
            Text(product.map { "No terminal for \($0.name)" } ?? "No terminal").kitType(.labelStrong, Ink.text)
            Text(local ? "Terminals from other products stay running. They show here when you open their product, or under All Terminals."
                       : product?.isDemo == true ? "Demo products do not open terminals." : "This product has no local checkout to open a terminal in.")
                .kitType(.meta, Ink.text3).multilineTextAlignment(.center).frame(maxWidth: 420)
            if let product, local {
                HStack(spacing: Space.sm) {
                    Button("Open Shell") { model.openTerminal(product) }.buttonStyle(.kit(.secondary, compact: true))
                    Button("Open \(AgentCatalog.name(model.portfolio.settings.aiAgentProgram))") { model.openAgent(product) }
                        .buttonStyle(.kit(.secondary, compact: true))
                }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.panel)
    }

    private func tab(_ session: TerminalSession, selected: Bool) -> some View {
        let product = model.product(session.productID)
        return HStack(spacing: Space.xs) {
            SessionDot(session: session)
            if let product { ProjectIcon(product, size: 14) }
            Text(session.title).kitType(selected ? .labelStrong : .label, selected ? Ink.text : Ink.text2).lineLimit(1)
            Text(session.activity).kitType(.meta, Ink.text3).lineLimit(1)
            Button { model.terminals.close(session) } label: { Icon(.xmark, size: 8, weight: .bold).foregroundStyle(Ink.text3) }
                .buttonStyle(.plain)
                .help(session.isRunning ? "Close and end \(session.activity)" : "Close")
                .accessibilityLabel("Close \(session.title)")
        }
        .padding(.horizontal, Space.sm).frame(height: 24)
        .background(selected ? Ink.panel : .clear, in: RoundedRectangle(cornerRadius: Metric.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            model.terminals.select(session)
            DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) }
        }
        .contextMenu {
            if let product { Button("Go to \(product.name)") { model.open(product) } }
            Button("Copy Text") { model.copy(session.text, message: "Copied the terminal text") }
            Divider()
            Button(session.isRunning ? "End Session" : "Close") { model.terminals.close(session) }
        }
        .help("\(session.title) · \(abbreviate(session.directory)) · started \(RelativeTime.short(session.startedAt))")
    }
}

/// "1 terminal running · claude": on product cards, headers, and sidebar rows.
struct TerminalIndicator: View {
    @Environment(AppModel.self) private var model
    let product: Product
    var compact = false

    var body: some View {
        let sessions = model.terminals.sessions(for: product.id)
        if !sessions.isEmpty {
            let busy = sessions.first(where: \.isBusy)
            Button {
                // On another product's page, go to this product so its terminal shows in the dock.
                if let current = model.currentProduct, current.id != product.id { model.open(product) }
                model.terminals.select(busy ?? sessions[0])
                model.terminals.isVisible = true
            } label: {
                HStack(spacing: Space.xs) {
                    Icon(.terminal, size: compact ? 9 : 10, weight: .semibold)
                    if !compact {
                        Text(busy.map { "\($0.activity)" } ?? (sessions.count == 1 ? "Shell open" : "\(sessions.count) shells open"))
                            .kitType(.metaMedium, busy == nil ? Ink.ok : Ink.accentText).lineLimit(1)
                    }
                }
                .foregroundStyle(busy == nil ? Ink.ok : Ink.accentText)
                .padding(.horizontal, compact ? 0 : 6).padding(.vertical, compact ? 0 : 1) // grid: ok pill inset from the design
                .background(compact ? .clear : (busy == nil ? Ink.ok : Ink.accent).soft(), in: RoundedRectangle(cornerRadius: Metric.chipRadius))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(sessions.map { "\($0.title): \($0.activity)" }.joined(separator: "\n"))
            .accessibilityLabel("\(sessions.count) terminal session\(sessions.count == 1 ? "" : "s") open\(busy.map { ", running \($0.activity)" } ?? "")")
        }
    }
}
