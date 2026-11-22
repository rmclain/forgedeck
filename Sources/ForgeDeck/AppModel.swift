import AppKit
import ForgeDeckKit
import Network
import Observation
import SwiftUI

enum Route: Hashable {
    case overview, projects, deployments, leads, infrastructure, git, terminals, toolbox, secrets, activity
    case product(UUID)

    var title: String {
        switch self {
        case .overview: "Overview"
        case .projects: "Products"
        case .deployments: "Deployments"
        case .leads: "Leads & Metrics"
        case .infrastructure: "Infrastructure"
        case .git: "Git & CI"
        case .terminals: "Terminals & Actions"
        case .toolbox: "Toolbox"
        case .secrets: "Secrets Vault"
        case .activity: "Activity"
        case .product: "Product"
        }
    }

    var icon: KitIcon {
        switch self {
        case .overview: .overview
        case .projects, .product: .projects
        case .deployments: .deploy
        case .leads: .leads
        case .infrastructure: .infra
        case .git: .branch
        case .terminals: .terminal
        case .toolbox: .wrench
        case .secrets: .secrets
        case .activity: .activity
        }
    }

    /// Pages in the sidebar, in order.
    static let primary: [Route] = [.overview, .projects, .deployments, .leads, .infrastructure, .git, .terminals, .toolbox, .secrets, .activity]

    var key: String {
        switch self {
        case .product: "product"
        default: title.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-")
        }
    }
}

enum ProductTab: String, CaseIterable, Identifiable {
    case overview = "Overview", issues = "Issues", memory = "Memory", development = "Development", environments = "Environments", metrics = "Leads"
    case connections = "Connections", secrets = "Secrets", actions = "Actions", activity = "Activity", settings = "Settings"
    var id: String { rawValue }
}

enum InfraTab: String, CaseIterable { case health = "Health", connections = "Connections", ssh = "SSH", docker = "Docker" }

struct ConfirmRequest: Identifiable {
    struct Check: Identifiable {
        let id = UUID()
        var label: String
        var meta: String
        var ok: Bool
    }

    let id = UUID()
    var title: String
    var message: String
    var checks: [Check] = []
    var footnote = ""
    var isProduction = false
    var confirmLabel = "Confirm"
    /// Press and hold to confirm. Only for remote writes and production; local actions get a plain button.
    var requiresHold = false
    var icon: KitIcon?
    var action: @MainActor () async -> Void
}

struct RunLog: Identifiable {
    let id = UUID()
    var title: String
    var productName: String
    var startedAt = Date.now
    var output = ""
    var exitCode: Int32?
    var isRunning = true
    var task: Task<Void, Never>?
}

struct VariableDraft: Identifiable {
    var id = UUID()
    var existingID: UUID?
    var key = ""
    var scope: VariableScope = .global
    var isSecret = true
    var value = ""
    var origin: SecretOrigin = .keychain
    var locator = ""
    var allowedTiers: Set<EnvironmentTier> = [.development]
    var rotationDays = 0
    var note = ""
}

enum SheetKind: Identifiable {
    case addProduct
    case confirm(ConfirmRequest)
    case variable(VariableDraft)
    case probe(productID: UUID, environmentID: UUID)
    case metricSource(productID: UUID, environmentID: UUID)
    case sshHost(productID: UUID, environmentID: UUID)
    case environment(productID: UUID)
    case recipe(productID: UUID, recipeID: UUID?)
    case profile(productID: UUID, profileID: UUID?)
    /// A new profile with its fields filled in, for the person to review and save.
    case profileDraft(productID: UUID, TerminalProfile)
    case connectGitHub
    case doctor(DoctorTarget)
    case runLog(UUID)
    case ciFailure(productID: UUID, runID: Int?)
    case rename(RenameTarget)
    case update(AppRelease)
    case skills(SkillPlan)
    case releaseChannel(UUID)
    case environmentProposals(UUID)
    case runSetup(UUID)
    case leadsSetup(UUID)
    case newProject
    case blueprint(UUID)
    case plan(productID: UUID, planID: UUID)

    var id: String {
        switch self {
        case .addProduct: "add"
        case .confirm(let request): "confirm-\(request.id)"
        case .variable(let draft): "variable-\(draft.id)"
        case .probe(_, let e): "probe-\(e)"
        case .metricSource(_, let e): "source-\(e)"
        case .sshHost(_, let e): "ssh-\(e)"
        case .environment(let p): "env-\(p)"
        case .recipe(_, let r): "recipe-\(r?.uuidString ?? "new")"
        case .profile(_, let r): "profile-\(r?.uuidString ?? "new")"
        case .profileDraft(_, let draft): "profile-draft-\(draft.id)"
        case .connectGitHub: "github"
        case .doctor(let target): "doctor-\(target.id)"
        case .runLog(let id): "log-\(id)"
        case .ciFailure(let p, let r): "ci-\(p)-\(r.map(String.init) ?? "latest")"
        case .rename(let target): "rename-\(target.id)"
        case .update(let release): "update-\(release.version)"
        case .skills(let plan): "skills-\(plan.id)"
        case .releaseChannel(let product): "release-\(product)"
        case .environmentProposals(let product): "env-proposals-\(product)"
        case .runSetup(let product): "run-setup-\(product)"
        case .leadsSetup(let product): "leads-setup-\(product)"
        case .newProject: "new-project"
        case .blueprint(let product): "blueprint-\(product)"
        case .plan(_, let plan): "plan-\(plan)"
        }
    }
}

/// What the rename sheet names: a product, a sidebar group, or a new group for a product.
enum RenameTarget {
    case product(UUID)
    case group(String)
    case newGroup(productID: UUID)

    var id: String {
        switch self {
        case .product(let id): "product-\(id)"
        case .group(let name): "group-\(name)"
        case .newGroup(let id): "new-group-\(id)"
        }
    }
}

enum DoctorTarget: Identifiable {
    case github
    case probe(productID: UUID, environmentID: UUID, probeID: UUID)
    case ssh(alias: String)
    case toolchain

    var id: String {
        switch self {
        case .github: "github"
        case .probe(_, _, let id): id.uuidString
        case .ssh(let alias): "ssh-\(alias)"
        case .toolchain: "toolchain"
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError = false
}

enum Runtime {
    static let environment = ProcessInfo.processInfo.environment
    static let isSnapshot = !(environment["APP_SNAPSHOT"] ?? "").isEmpty
    static let isSelfTest = CommandLine.arguments.contains("--selftest")
    static let isGallery = environment["APP_KIT_GALLERY"] == "1"
    static let usesRealKeychain = isSelfTest && environment["APP_SELFTEST_KEYCHAIN"] == "1"
    /// Test runs never touch the network or the real data folder.
    static var isAutomated: Bool { isSnapshot || isSelfTest || isGallery }
}

@Observable
final class AppModel {
    let store: PortfolioStore
    let audit: AuditLog
    let engine: RefreshEngine
    let launcher: TerminalLauncher
    let keychain: any SecretStore
    let credentials: CredentialResolver
    /// Terminal sessions inside the app.
    let terminals = TerminalHost()

    var portfolio = Portfolio()
    var cache = ObservationCache()
    var loadError: String?

    // Navigation
    var route: Route = .overview {
        didSet { terminals.scope = currentProduct?.id }
    }
    private var backStack: [Route] = []
    private var forwardStack: [Route] = []
    var productTab: ProductTab = .overview
    var infraTab: InfraTab = .health
    /// The environment new terminals, previews, and actions are aimed at.
    var context: EnvironmentTier = .development
    var collapsedGroups: Set<String> = []
    // MCP servers, read from agent configs and product code on this Mac.
    var mcpEntries: [MCPServerEntry] = []
    var mcpCode: [String: MCPServerCode] = [:]
    var mcpScanning = false
    var mcpVersion = 0
    /// Versions each product's primary checkout declares (plugin header, package.json, ...). Read on refresh.
    var localReleases: [UUID: LocalRelease] = [:]
    /// `.forgedeck/environments.json` as last read from each product's folders.
    var environmentFiles: [UUID: [EnvironmentProposalFile]] = [:]
    /// `.forgedeck/run.json` in each product's checkouts, read on refresh.
    var runFiles: [UUID: [RunProposalFile]] = [:]
    /// `.forgedeck/skills.json` in each product's checkouts, read on refresh.
    var skillFiles: [UUID: SkillFile] = [:]
    /// `.forgedeck/blueprint.json` of a product started with New Project.
    var blueprintFiles: [UUID: BlueprintFile] = [:]
    /// `.forgedeck/plan.json` in each product's checkouts, kept to say why a waiting plan hasn't shown up.
    var planFiles: [UUID: [PlanFile]] = [:]
    /// A starter's generator running in a built-in terminal, per product.
    var genesisScaffolds: [UUID: TerminalSession] = [:]
    /// Watches on the files setup agents write, by product.
    @ObservationIgnored var agentFileWatches: [UUID: Task<Void, Never>] = [:]
    /// Claude Code plugins installed on this Mac, by name. nil until read.
    var installedPlugins: Set<String>?
    /// Plugins being installed right now.
    var installingSkills: Set<String> = []
    /// When a product's skills last changed (installed, or chosen for it). An agent session started before that
    /// has not loaded them: the Skills card offers to restart it.
    var skillsChangedAt: [UUID: Date] = [:]
    /// Set to move the cursor to the Issues tab's add field.
    var focusIssueField = false
    var focusMemoryField = false
    /// Items checked in the Issues tab, for its bulk actions.
    var selectedIssues: Set<UUID> = []
    /// GitHub issues checked in the Issues tab (not in the list yet), by link.
    var selectedGitHubIssues: Set<String> = []
    /// The Forge Remote terminal session, while it exists.
    var remoteSessionID: UUID?
    /// Bumped when the forgedeck skill is installed or removed, so Settings reads the folder again.
    var skillVersion = 0
    @ObservationIgnored var remoteActivity: (any NSObjectProtocol)?
    @ObservationIgnored var remoteRestarts: [Date] = []
    @ObservationIgnored var remoteStopping = false
    /// Set while a start waits for a server left from before to exit.
    var remoteWaiting = false
    @ObservationIgnored var mcpCache: [UUID: (product: Product, info: MCPProductInfo)] = [:]
    @ObservationIgnored var playCache: [UUID: (product: Product, options: [PlayOption])] = [:]
    /// Sites made with Local, read once at launch. Play opens a plugin's site from here.
    @ObservationIgnored lazy var localSites: [LocalSite] = Runtime.isAutomated ? [] : LocalSite.load()
    // Updates
    var updateStatus: UpdateCheck?
    var availableUpdate: AppRelease?
    var updateBusy = false
    var updateProgress: String?
    /// Set when an update relaunches the app, so quitting does not stop to ask.
    var skipQuitConfirmation = false
    /// A recipe Play asked to approve. It runs as soon as it is saved.
    var pendingPlay: (productID: UUID, recipeID: UUID, url: String?)?

    // Overlays
    var sheet: SheetKind?
    var paletteOpen = false
    var toast: ToastMessage?
    private var toastTask: Task<Void, Never>?

    // Filters
    var overviewWindow = "7d"
    var projectFilter = "All"
    var productSearch = ""
    var feedFilter: ActivityKind.Category = .all
    var feedLive = true

    // Work in progress
    var refreshing: Set<UUID> = []
    var packing: Set<UUID> = []
    /// Bumped to re-check which tools are installed.
    var toolsVersion = 0
    /// Tools being installed in the background, by catalog id.
    var installingTools: Set<String> = []
    /// The skill repository being downloaded, as owner/repo.
    var fetchingSkills: String?
    /// Bumped after skills are added or removed, so the Toolbox reads the folders again.
    var skillsVersion = 0
    /// Overrides the home folder where agents keep skills and MCP configs. The self-test and snapshots set it.
    var agentHome: URL?
    /// Bumped after a link changes, to re-read the file system.
    var linksVersion = 0
    // AI usage panel
    var usage: [ToolUsage] = []
    var usageUpdatedAt: Date?
    var usageLoading = false
    /// The last answer from Claude Code's own limit check, and when it was asked.
    @ObservationIgnored var claudeLimits: [UsageWindow]?
    @ObservationIgnored var claudeLimitsCheckedAt: Date?
    @ObservationIgnored var agyLimits: [UsageWindow]?
    @ObservationIgnored var agyLimitsCheckedAt: Date?
    /// Open until the person closes it; then it stays closed.
    var usagePanelVisible = !Runtime.isAutomated && (UserDefaults.standard.object(forKey: "usage.panel") as? Bool ?? true)
    var isRefreshingAll = false
    var lastRefresh: Date?
    var isOnline = true
    var runLogs: [RunLog] = []
    var doctorSteps: [String: [DoctorStep]] = [:]
    var dockerContainers: ConnectorResult<[DockerContainer]>?
    var dockerContext: String?
    var sshProbeOutput: [String: SSHProbeResult] = [:]
    var revealed: [UUID: String] = [:]
    var now = Date.now

    var saveTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private let monitor = NWPathMonitor()

    init(store: PortfolioStore = PortfolioStore()) {
        self.store = store
        audit = AuditLog(location: store.location)
        // Test runs keep secrets in memory, except the self-test's Keychain pass, which asks for the real one.
        let keychain: any SecretStore = Runtime.isAutomated && !Runtime.usesRealKeychain ? MemorySecretStore() : KeychainSecretStore()
        self.keychain = keychain
        credentials = CredentialResolver(keychain: keychain)
        engine = RefreshEngine(credentials: credentials)
        launcher = TerminalLauncher(launchDirectory: store.location.launchDirectory)
        do {
            portfolio = try store.loadPortfolio()
            cache = store.loadCache()
        } catch {
            loadError = String(describing: error)
        }
    }

    func start() {
        guard !Runtime.isAutomated else { return }
        Task.detached { MobileDevices.cached = await MobileDevices.detect() }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: .global(qos: .utility))
        cache.prune(retentionDays: portfolio.settings.cacheRetentionDays)
        checkForUpdatesIfDue()
        refreshMCP()
        // A skill this app wrote earlier is brought up to date, so a new version's commands (/products, /product) appear.
        if isSkillInstalled { _ = try? ForgeDeckSkill.install(in: ForgeDeckSkill.claudeSkills, cli: cliCommand) }
        if remoteSettings.enabled { startRemote(showTerminal: false) }
        watchIssueInbox()
        pollTask = Task { [weak self] in
            // Local Git state first: it is cheap and works offline.
            await self?.refreshLocal()
            await self?.refreshAll(announce: false)
            while !Task.isCancelled {
                let interval = max(60, self?.portfolio.settings.pollingIntervalSeconds ?? 300)
                try? await Task.sleep(for: .seconds(interval))
                guard let self, self.portfolio.settings.pollingEnabled else { continue }
                await self.refreshAll(announce: false)
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.now = .now
            }
        }
    }

    // MARK: Persistence

    func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        guard loadError == nil else { return }
        do {
            try store.save(portfolio)
            try store.save(cache)
            if isRemoteRunning { try? syncRemoteWorkspace() }
        } catch {
            show("Could not save: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: Lookups

    var products: [Product] { portfolio.products }
    var activeProducts: [Product] { portfolio.products.filter { !$0.isArchived } }
    func product(_ id: UUID?) -> Product? { portfolio.product(id: id) }
    var currentProduct: Product? { if case .product(let id) = route { product(id) } else { nil } }
    var hasDemo: Bool { portfolio.products.contains(where: \.isDemo) }
    var organizationName: String { portfolio.organizations.first?.name ?? "My Portfolio" }

    func badge(_ product: Product) -> StatusBadge { ProductStatus.badge(product, cache: cache, now: now) }

    var attentionIncidents: [Incident] {
        cache.incidents.filter { $0.needsAttention(now: now) }.sorted { $0.openedAt > $1.openedAt }
    }

    func update(_ id: UUID, _ change: (inout Product) -> Void) {
        guard let index = portfolio.products.firstIndex(where: { $0.id == id }) else { return }
        change(&portfolio.products[index])
        save()
    }

    // MARK: Navigation

    func go(_ destination: Route) {
        guard destination != route else { return }
        backStack.append(route)
        forwardStack = []
        route = destination
        paletteOpen = false
    }

    func open(_ product: Product, tab: ProductTab = .overview) {
        productTab = tab
        go(.product(product.id))
        update(product.id) { $0.lastOpenedAt = .now }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(route)
        route = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(route)
        route = next
    }

    // MARK: Feedback

    func show(_ text: String, isError: Bool = false) {
        toastTask?.cancel()
        toast = ToastMessage(text: text, isError: isError)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 4.5 : 2.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func copy(_ text: String, message: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(message)
    }

    func record(_ action: String, product: Product? = nil, environment: String? = nil, detail: String = "", outcome: String = "ok") {
        guard !Runtime.isAutomated else { return }
        audit.record(AuditEvent(actor: "app", action: action, product: product?.slug, environment: environment, detail: detail, outcome: outcome))
    }

    // MARK: Refresh

    func apply(_ updates: [CacheUpdate]) {
        guard !updates.isEmpty else { return }
        cache.apply(updates, portfolio: portfolio, now: .now)
        now = .now
        save()
    }

    func refreshLocal() async {
        for product in activeProducts where !product.isDemo {
            apply(await engine.refreshGit(product))
        }
    }

    /// Refreshes one product: Git first, then the network sources, then the commit counts between stages.
    func refresh(_ product: Product, announce: Bool = true) async {
        // Callers may hold a copy from before an edit; check what is saved now, including new checks.
        let product = self.product(product.id) ?? product
        guard !product.isDemo else {
            if announce { show("\(product.name) is a demo product. Its data comes from a fixture.") }
            return
        }
        guard !refreshing.contains(product.id) else { return }
        refreshing.insert(product.id)
        defer { refreshing.remove(product.id) }
        apply(await engine.refreshGit(product))
        if let path = product.primaryCheckout?.path {
            let found = await Task.detached { LocalRelease.detect(in: path) }.value
            if localReleases[product.id] != found { localReleases[product.id] = found }
        }
        await reloadAgentFiles(product)
        if isOnline {
            async let remote = engine.refreshRemote(product, portfolio: portfolio)
            async let probes = engine.refreshProbes(product, portfolio: portfolio)
            async let metrics = engine.refreshMetrics(product, portfolio: portfolio)
            async let releases = engine.refreshReleases(product)
            apply(await remote + probes + metrics + releases)
        }
        if let current = self.product(product.id) {
            apply(await engine.refreshComparisons(current, cache: cache))
        }
        if announce { show(isOnline ? "Refreshed \(product.name)" : "Offline: refreshed local state for \(product.name)") }
    }

    /// Reads the files a setup agent writes (environments, run, skills) and nothing else: no Git, no network.
    func reloadAgentFiles(_ product: Product) async {
        guard !product.isDemo else { return }
        let (proposals, runs, skillFile, blueprint, issueReports, plans, memory) = await Task.detached {
            (EnvironmentProposals.read(product), RunSetup.read(product), SkillSuggestions.read(product),
             product.genesis == nil ? nil : BlueprintCheck.read(product), IssueReports.read(product), FeaturePlans.read(product),
             ProductMemory.read(product))
        }.value
        applyMemoryFiles(memory, to: product.id)
        if planFiles[product.id] != plans { planFiles[product.id] = plans }
        applyPlanFiles(plans, to: product.id)
        applyIssueReports(issueReports, to: product.id)
        if blueprintFiles[product.id] != blueprint { blueprintFiles[product.id] = blueprint }
        if environmentFiles[product.id] != proposals { environmentFiles[product.id] = proposals }
        if runFiles[product.id] != runs { runFiles[product.id] = runs }
        if skillFiles[product.id] != skillFile { skillFiles[product.id] = skillFile }
    }

    /// While a setup agent runs, picks up what it writes within a second. One watch per product; it ends when
    /// `isActive` turns false (then reads once more) or after 45 minutes without a change.
    func watchAgentFiles(_ product: Product, while isActive: @escaping @MainActor () -> Bool) {
        guard !product.isDemo else { return }
        agentFileWatches[product.id]?.cancel()
        agentFileWatches[product.id] = Task { [weak self] in
            var stamps = await Task.detached { AgentFiles.stamps(product) }.value
            var lastChange = Date.now
            while !Task.isCancelled, isActive(), Date.now.timeIntervalSince(lastChange) < 45 * 60 {
                try? await Task.sleep(for: .seconds(1))
                let current = await Task.detached { AgentFiles.stamps(product) }.value
                let changed = AgentFiles.changed(from: stamps, to: current)
                guard !changed.isEmpty, let self else { continue }
                stamps = current
                lastChange = .now
                await self.agentFilesChanged(product, changed)
            }
            guard !Task.isCancelled, let self else { return }
            await self.reloadAgentFiles(product)
            self.agentFileWatches[product.id] = nil
        }
    }

    private func agentFilesChanged(_ product: Product, _ changed: Set<String>) async {
        let before = skillSuggestions(product).filter(\.isValid).count
        let hadBlueprint = blueprintFiles[product.id]?.isApprovable == true
        await reloadAgentFiles(product)
        if changed.contains(BlueprintCheck.relativePath), !hadBlueprint, let current = self.product(product.id), current.genesis?.approvedStack == nil,
           let blueprint = blueprintFiles[product.id]?.blueprint, blueprintFiles[product.id]?.isApprovable == true {
            show("The blueprint for \(product.name) is ready: \(blueprint.stack.name). Review it on the Overview.")
        }
        guard changed.contains(SkillSuggestions.relativePath) else { return }
        let after = skillSuggestions(product).filter(\.isValid).count
        if after > before {
            show("\(after) skill suggestion\(after == 1 ? "" : "s") for \(product.name), in Development › Skills")
        }
    }

    func refreshAll(announce: Bool = true) async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        let targets = activeProducts.filter { !$0.isDemo }
        await withTaskGroup(of: Void.self) { group in
            for product in targets { group.addTask { await self.refresh(product, announce: false) } }
        }
        lastRefresh = .now
        now = .now
        // Code scans are slower than config reads: only when someone asks, not on every poll.
        if announce { refreshMCP() }
        if announce {
            show(targets.isEmpty ? "Nothing to refresh yet" : isOnline ? "Refreshed \(targets.count) product\(targets.count == 1 ? "" : "s")" : "Offline: refreshed local state only")
        }
    }

    /// Cmd-R: refresh what the current page shows.
    func refreshCurrentPage() {
        Task {
            if let product = currentProduct { refreshMCP(only: product); await refresh(product) } else { await refreshAll() }
            if route == .infrastructure { await refreshDocker() }
        }
    }

    func fetch(_ checkout: LocalCheckout, in product: Product) {
        Task {
            show("Fetching \(checkout.name)…")
            let result = await engine.git.fetch(path: checkout.path)
            if result?.ok == true {
                await refresh(product, announce: false)
                show("Fetched \(checkout.name)")
            } else {
                show("Fetch failed: \(Redactor().redact(result?.stderr.split(separator: "\n").first.map(String.init) ?? "git could not run"))", isError: true)
            }
        }
    }

    func refreshDocker() async {
        let inspector = DockerInspector()
        dockerContext = await inspector.context()
        dockerContainers = await inspector.containers()
    }

    // MARK: Demo data

    func addDemo(count: Int = 3) {
        let added = DemoFixtures.install(count: count, into: &portfolio, cache: &cache)
        now = .now
        save()
        show(added == 0 ? "The demo products are already here" : "Added \(added) demo product\(added == 1 ? "" : "s")")
    }

    func removeDemo() {
        DemoFixtures.remove(from: &portfolio, cache: &cache)
        if case .product(let id) = route, product(id) == nil { route = .overview }
        save()
        show("Removed the demo products")
    }
}
