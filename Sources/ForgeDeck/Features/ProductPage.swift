import AppKit
import ForgeDeckKit
import SwiftUI

struct ProductPage: View {
    @Environment(AppModel.self) private var model
    let product: Product

    private func count(_ tab: ProductTab) -> String? {
        switch tab {
        case .connections:
            let n = product.repositories.count + product.environments.reduce(0) { $0 + $1.probes.count + $1.metricSources.count + $1.sshHosts.count }
            return n > 0 ? "\(n)" : nil
        case .secrets:
            let n = model.portfolio.variables.filter { $0.scope.productID == product.id }.count
            return n > 0 ? "\(n)" : nil
        case .issues:
            let n = ProductIssues.openCount(product)
            return n > 0 ? "\(n)" : nil
        case .memory:
            let n = ProductMemory.count(product)
            return n > 0 ? "\(n)" : nil
        case .actions: return product.recipes.isEmpty ? nil : "\(product.recipes.count)"
        case .environments: return product.environments.isEmpty ? nil : "\(product.environments.count)"
        default: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Group {
                    switch model.productTab {
                    case .overview: ProductOverviewTab(product: product)
                    case .issues: IssuesTab(product: product).id(IssuesTab.startsOnDone)
                    case .memory: MemoryTab(product: product)
                    case .development: DevelopmentTab(product: product)
                    case .environments: EnvironmentsTab(product: product)
                    case .metrics: LeadsContent(product: product)
                    case .connections: ConnectionsList(products: [product])
                    case .secrets: VariablesPanel(product: product)
                    case .actions: ActionsTab(product: product)
                    case .activity: ProductActivityTab(product: product)
                    case .settings: ProductSettingsTab(product: product)
                    }
                }
                .padding(.horizontal, Metric.pagePadding).padding(.top, Space.xl).padding(.bottom, Space.section)
            }
        }
    }

    private func headerActions(compact: Bool) -> some View {
        HStack(spacing: Space.sm) {
            IconButton(product.isFavorite ? .starFill : .star, label: product.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                model.update(product.id) { $0.isFavorite.toggle() }
            }
            playButton(compact: compact)
            if compact {
                IconButton(.sparkle, label: "Open with \(AgentCatalog.name(model.portfolio.agentProgram(for: product))) and linked context (⌘⌥O)") { model.openAgent(product) }
                    .disabled(product.isDemo || !product.hasLocal)
                IconButton(.code, label: "Open in Editor (⌘⇧O)") { model.openEditor(product) }.disabled(product.isDemo || !product.hasLocal)
                IconButton(.external, label: "Open Dashboard") { model.openDashboard(product) }
                    .disabled(product.isDemo || (product.links.isEmpty && product.repositories.isEmpty))
                IconButton(.sync, label: "Refresh (⌘R)") { Task { await model.refresh(product) } }
                    .disabled(product.isDemo || model.refreshing.contains(product.id))
            } else {
                Button { model.openAgent(product) } label: {
                    HStack(spacing: Space.sm) { Icon(.sparkle, size: 12); Text(AgentCatalog.name(model.portfolio.agentProgram(for: product))); Kbd("⌘⌥O") }
                }
                .buttonStyle(.kit(.secondary)).disabled(product.isDemo || !product.hasLocal)
                .help(product.contextLinks.isEmpty ? "Start \(AgentCatalog.name(model.portfolio.agentProgram(for: product))) in the checkout with a map of the repo" : "Start \(AgentCatalog.name(model.portfolio.agentProgram(for: product))) in the checkout with a map of this repo and \(product.contextLinks.count) linked product\(product.contextLinks.count == 1 ? "" : "s")")
                Button { model.openEditor(product) } label: {
                    HStack(spacing: Space.sm) { Icon(.code, size: 12); Text("Editor"); Kbd("⌘⇧O") }
                }
                .buttonStyle(.kit(.secondary)).disabled(product.isDemo || !product.hasLocal)
                Button { model.openDashboard(product) } label: {
                    HStack(spacing: Space.sm) { Icon(.external, size: 12); Text("Dashboard") }
                }
                .buttonStyle(.kit(.secondary)).disabled(product.isDemo || (product.links.isEmpty && product.repositories.isEmpty))
                Ink.line.frame(width: Metric.hairline, height: 20)
                Button { Task { await model.refresh(product) } } label: {
                    HStack(spacing: Space.sm) {
                        Icon(.sync, size: 12)
                        Text(model.refreshing.contains(product.id) ? "Refreshing…" : "Refresh")
                        Kbd("⌘R")
                    }
                }
                .buttonStyle(.kit(.secondary)).disabled(product.isDemo || model.refreshing.contains(product.id))
                .help(product.isDemo ? "Demo data comes from a fixture and is not refreshed" : "Check Git, GitHub, and status endpoints now")
            }
        }
        .fixedSize()
    }

    /// Play launches the best option; the menu lists the others and run setup. With nothing to launch yet,
    /// the button is Set Up Run.
    @ViewBuilder private func playButton(compact: Bool) -> some View {
        let options = product.isDemo ? PlayPlanner.options(for: product, localSites: [], allowDemo: true) : model.playOptions(product)
        let agent = AgentCatalog.name(model.portfolio.agentProgram(for: product))
        let pending = !product.isDemo && !model.runProposals(product).isEmpty
        if let first = options.first {
            Menu {
                ForEach(options) { option in
                    Button { model.play(product, option: option) } label: {
                        Text(option.title + (option.recipeID.flatMap { id in product.recipes.first { $0.id == id } }.map { $0.isApproved ? "" : " (approve first)" } ?? (option.suggestion != nil ? " (approve first)" : "")))
                    }
                }
                Divider()
                runSetupItems(agent: agent, pending: pending)
            } label: {
                HStack(spacing: Space.sm) { Icon(.play, size: 12); if !compact { Text("Play"); Kbd("⌘⇧P") } }
            } primaryAction: {
                model.play(product, option: first)
            }
            .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize().disabled(product.isDemo)
            .help(product.isDemo ? "Demo product: there is nothing to launch" : "\(first.title) (⌘⇧P). Open the menu for other ways to launch \(product.name), or to set up how it runs.")
            .accessibilityLabel("Play: \(first.title)")
        } else if product.hasLocal, !product.isArchived, !product.isDemo {
            Menu {
                runSetupItems(agent: agent, pending: pending)
            } label: {
                HStack(spacing: Space.sm) { Icon(.play, size: 12); if !compact { Text(pending ? "Review Run Setup" : "Set Up Run") } }
            } primaryAction: {
                if pending { model.reviewRunSetup(product) } else { model.setUpRun(product) }
            }
            .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
            .help(pending ? "Review the commands \(agent) proposed for running \(product.name)"
                          : "Nothing to launch yet. \(agent) works out how \(product.name) runs, tries it, and proposes the commands for you to review.")
            .accessibilityLabel(pending ? "Review Run Setup" : "Set Up Run")
        }
    }

    @ViewBuilder private func runSetupItems(agent: String, pending: Bool) -> some View {
        Button("Set Up Run with \(agent)…") { model.setUpRun(product) }
            .disabled(product.isDemo || !product.hasLocal)
        // Always offered: it reads the folder first, so a file the agent just wrote is found.
        Button(pending ? "Review Run Setup (\(model.runProposals(product).count))…" : "Review Run Setup…") { model.reviewRunSetup(product) }
            .disabled(product.isDemo || !product.hasLocal)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .top, spacing: Space.lg) {
                ProjectIcon(product, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.sm) {
                        Text(product.name).kitType(.productTitle).lineLimit(1).accessibilityAddTraits(.isHeader)
                        StatusPill(model.badge(product), large: true)
                        if product.isDemo { DemoBadge() }
                        if product.isArchived { TagBadge("Archived") }
                        TerminalIndicator(product: product)
                        MCPBadge(product: product)
                    }
                    Text(product.tagline.isEmpty ? "No description yet" : product.tagline).kitType(.body, Ink.text2).lineLimit(2)
                    HStack(spacing: Space.xs) {
                        ForEach(product.stack.prefix(5), id: \.self) { Chip($0) }
                        if let checkout = product.primaryCheckout {
                            Text(abbreviate(checkout.path)).kitType(.monoSmall, Ink.text3).lineLimit(1).truncationMode(.middle).padding(.leading, Space.xs)
                        }
                    }
                    .padding(.top, Space.sm)
                }
                .frame(minWidth: 260, alignment: .leading)
                Spacer(minLength: Space.sm)
                ViewThatFits(in: .horizontal) {
                    headerActions(compact: false)
                    headerActions(compact: true)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xl) {
                    ForEach(ProductTab.allCases) { tab in
                        let on = model.productTab == tab
                        Button { model.productTab = tab } label: {
                            HStack(spacing: Space.xs) {
                                Text(tab.rawValue).kitType(.bodyMedium, on ? Ink.text : Ink.text2)
                                if let count = count(tab) {
                                    Text(count).font(.system(size: 10.5)).foregroundStyle(Ink.text3)
                                        .padding(.horizontal, 6).padding(.vertical, 1) // grid: ok count inset from the design
                                        .background(Ink.chip, in: Capsule())
                                }
                            }
                            .frame(height: 36)
                            .overlay(alignment: .bottom) { (on ? Ink.accent : Color.clear).frame(height: 2) }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
        .padding(.horizontal, Metric.pagePadding).padding(.top, Space.xl)
        .hairlineBelow()
    }
}

func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

// MARK: Overview tab

struct ProductOverviewTab: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if let genesis = product.genesis, genesis.phase != .finished { ProjectSetupCard(product: product) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Space.lg, alignment: .top)], spacing: Space.lg) {
                LocalCard(product: product)
                EnvironmentCard(product: product, tier: .staging)
                EnvironmentCard(product: product, tier: .production)
            }
            if !model.environmentProposals(product).isEmpty { ProposedEnvironmentsCard(product: product) }
            if !model.runProposals(product).isEmpty { ProposedRunCard(product: product) }
            if !model.releaseState(product).isEmpty { ReleasesCard(product: product) }
            if !model.mcpInfo(product).isEmpty { MCPCard(product: product) }
            if product.hasLocal, !product.isDemo { ProductToolsCard(product: product) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Space.lg) {
                    VStack(spacing: Space.lg) {
                        TrendCard(product: product)
                        HStack(alignment: .top, spacing: Space.lg) {
                            HealthCard(product: product)
                            HostsCard(product: product)
                        }
                    }
                    .frame(minWidth: 560)
                    DeploymentTimeline(product: product).frame(width: 320)
                }
                VStack(spacing: Space.lg) {
                    TrendCard(product: product)
                    DeploymentTimeline(product: product)
                    HealthCard(product: product)
                    HostsCard(product: product)
                }
            }
        }
    }
}

struct EnvCardShell<Content: View, Actions: View>: View {
    let icon: KitIcon
    let name: String
    let badge: String
    var tone: Tone = .muted
    var production = false
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                Icon(icon, size: 13).foregroundStyle(production ? Ink.prod : tone == .accent ? Ink.accentText : Ink.text2)
                Text(name).kitType(.section, production ? Ink.prod : Ink.text)
                Spacer()
                TagBadge(badge, tone: production ? .prod : tone, filled: production)
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .background(production ? Ink.prod.soft(0.07) : .clear)
            .hairlineBelow(Ink.line2)
            VStack(alignment: .leading, spacing: Space.sm) { content }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            HStack(spacing: Space.sm) { actions }
                .padding(.horizontal, Space.lg).padding(.bottom, Space.md)
        }
        .card(border: production ? Ink.prod.opacity(0.38) : Ink.line)
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
    }
}

struct LocalCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let checkout = product.primaryCheckout
        let git = checkout.flatMap { model.cache.git[$0.id] }
        EnvCardShell(icon: .laptop, name: "Local", badge: "Dev") {
            if let checkout {
                HStack(alignment: .firstTextBaseline) {
                    Text(git?.isDetached == true ? "detached" : git?.branch ?? "—").kitType(.monoTitle).lineLimit(1)
                    Spacer(minLength: Space.sm)
                    if let git {
                        ConnectionState(kind: !git.available ? .failing : git.isDirty ? .stale : .connected,
                                        detail: !git.available ? "Folder missing" : !git.isRepository ? "Not a Git repo" : git.isDirty ? "\(git.changeCount) uncommitted" : "Clean")
                    }
                    if product.isDemo { DemoBadge() }
                }
                KeyValueRow(key: "Checkout", value: abbreviate(checkout.path), mono: true)
                KeyValueRow(key: "HEAD", value: git?.recentCommits.first.map { "\(shortSHA($0.sha)) · \($0.subject)" } ?? shortSHA(git?.headSHA), mono: true)
                KeyValueRow(key: "Upstream", value: git?.upstream.map { "\(git?.ahead ?? 0)↑ \(git?.behind ?? 0)↓ \($0)" } ?? "No tracking branch")
                if product.checkouts.count > 1 { KeyValueRow(key: "More checkouts", value: "\(product.checkouts.count - 1) in Development") }
            } else {
                Text("No local checkout").kitType(.monoTitle, Ink.text3)
                Text(product.hasRemote ? "Clone the repository or link a folder you already have." : "Link a folder to open it in a terminal and see its Git state.")
                    .kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if checkout != nil {
                Button { model.openTerminal(product) } label: { Text("Terminal").frame(maxWidth: .infinity) }.buttonStyle(.kit(.secondary)).disabled(product.isDemo)
                Button { model.openEditor(product) } label: { Text("Editor").frame(maxWidth: .infinity) }.buttonStyle(.kit(.secondary)).disabled(product.isDemo)
                Button { model.openAgent(product) } label: { Text("Agent").frame(maxWidth: .infinity) }.buttonStyle(.kit(.secondary)).disabled(product.isDemo)
                    .help("Open \(AgentCatalog.name(model.portfolio.agentProgram(for: product))) in the terminal with the repo map and linked context")
            } else {
                Button { model.productTab = .development } label: { Text("Set Up in Development").frame(maxWidth: .infinity) }.buttonStyle(.kit(.secondary))
            }
        }
    }
}

struct EnvironmentCard: View {
    @Environment(AppModel.self) private var model
    let product: Product
    let tier: EnvironmentTier

    var body: some View {
        let environment = product.environment(tier: tier)
        EnvCardShell(icon: tier.isProduction ? .globe : .branch, name: environment?.name ?? tier.title,
                     badge: tier.isProduction ? "Live" : "Preview", tone: .accent, production: tier.isProduction) {
            if let environment {
                let evidence = DriftAnalyzer.evidence(environment: environment, product: product, cache: model.cache, now: model.now)
                let observation = evidence.observation
                HStack(alignment: .firstTextBaseline) {
                    Text(observation.map { $0.version ?? shortSHA($0.sha) } ?? "Unknown").kitType(.monoTitle, observation == nil ? Ink.text3 : Ink.text).lineLimit(1)
                    Spacer(minLength: Space.sm)
                    SourceBadge(level: evidence.level, source: observation?.provenance.source.title, observedAt: observation?.provenance.observedAt,
                                isDemo: observation?.provenance.isDemo ?? false)
                }
                if let observation {
                    KeyValueRow(key: "Commit", value: shortSHA(observation.sha), mono: true)
                    KeyValueRow(key: "Health", value: observation.isMixed ? "Mixed revisions" : observation.health.title,
                                tone: observation.health == .healthy ? .ok : observation.health == .unknown ? nil : .warn)
                    KeyValueRow(key: "Deployed", value: observation.deployedAt.map { RelativeTime.short($0, now: model.now) } ?? "Not reported")
                    KeyValueRow(key: "Source", value: "\(observation.provenance.isDemo ? "Demo fixture" : observation.provenance.source.title) · \(RelativeTime.short(observation.provenance.observedAt, now: model.now))")
                }
                if let problem = evidence.problem {
                    Text(problem == .notConfigured ? evidence.problemDetail : "\(problem.title). \(evidence.problemDetail)")
                        .kitType(.label, problem == .notConfigured ? Ink.text2 : Ink.warn).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Not set up").kitType(.monoTitle, Ink.text3)
                Text("Add a \(tier.title.lowercased()) environment to track what runs there.").kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if let environment {
                if let domain = environment.domains.first {
                    Button { model.openLink(domain.contains("://") ? domain : "https://\(domain)") } label: { Text("Open ↗").frame(maxWidth: .infinity) }
                        .buttonStyle(.kit(.secondary)).disabled(product.isDemo)
                }
                Button { model.productTab = .environments } label: { Text(environment.probes.isEmpty ? "Connect" : "Details").frame(maxWidth: .infinity) }
                    .buttonStyle(.kit(.secondary))
            } else {
                Button { model.sheet = .environment(productID: product.id) } label: { Text("Add Environment").frame(maxWidth: .infinity) }.buttonStyle(.kit(.secondary))
            }
        }
    }
}

struct TrendCard: View {
    @Environment(AppModel.self) private var model
    let product: Product
    @State private var series = "Leads"

    var body: some View {
        let cache = model.cache
        let leads = cache.leads.filter { $0.productID == product.id }
        let revenue = cache.points.filter { $0.productID == product.id && $0.key == "mrr_cents" }.sorted { $0.day < $1.day }
        let mrr = cache.metrics.first { $0.productID == product.id && $0.key == "mrr_cents" }
        let hasData = !leads.isEmpty || !revenue.isEmpty
        SurfaceCard {
            if hasData {
                VStack(alignment: .leading, spacing: Space.md) {
                    let showRevenue = series == "MRR" && !revenue.isEmpty
                    let kinds: Set<BusinessEventKind> = series == "Signups" ? [.signup] : [.lead, .signup]
                    let total = MetricMath.count(leads, kinds: kinds, within: 30 * 86_400, now: model.now)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(showRevenue ? "Monthly recurring revenue" : "\(series) · last 30 days").kitType(.labelMedium, Ink.text2)
                            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                Text(showRevenue ? Money.format(cents: Int(mrr?.value ?? revenue.last?.value ?? 0)) : "\(total)").kitType(.metric).monospacedDigit()
                                if showRevenue, let mrr {
                                    SourceBadge(level: mrr.provenance.effectiveLevel(now: model.now), source: mrr.sourceLabel, observedAt: mrr.provenance.observedAt, isDemo: mrr.provenance.isDemo)
                                } else if leads.contains(where: \.isDemo) { DemoBadge() }
                            }
                        }
                        Spacer()
                        SegmentedPill(options: (["Leads", "Signups"] + (revenue.isEmpty ? [] : ["MRR"])).map { ($0, $0) }, selection: $series, compact: true)
                    }
                    TrendChart(values: showRevenue ? revenue.suffix(30).map { Optional($0.value) }
                                                   : MetricMath.dailyCounts(leads, kinds: kinds, days: 30, now: model.now),
                               labels: ["30d ago", "20d", "10d", "Today"])
                    HStack(spacing: 0) {
                        stat("Leads · 24h", "\(MetricMath.count(leads, kinds: [.lead], within: 86_400, now: model.now))")
                        stat("Signups · 24h", "\(MetricMath.count(leads, kinds: [.signup], within: 86_400, now: model.now))")
                        stat("Paid · 30d", "\(MetricMath.count(leads, kinds: [.paidConversion], within: 30 * 86_400, now: model.now))")
                        stat("Sources", "\(Set(leads.map(\.sourceID)).count)")
                    }
                    .padding(.top, Space.md).hairlineAbove()
                }
            } else {
                let agent = AgentCatalog.name(model.portfolio.agentProgram(for: product))
                EmptyState(icon: .chart, title: "Connect a metrics source",
                           message: "See leads, signups, and purchases here. \(product.hasLocal && !product.isDemo ? "\(agent) can find what \(product.name) collects and set up the check, or point" : "Point") \(Brand.name) at a metrics endpoint your app serves. Nothing is shown until a source reports it.",
                           cta: product.hasLocal && !product.isDemo ? "Set Up Leads with \(agent)…" : product.environments.isEmpty ? "Add Environment" : "Add Metrics Source", compact: true) {
                    if product.hasLocal && !product.isDemo {
                        model.setUpLeads(product)
                    } else if let environment = product.environment(tier: .production) ?? product.environments.first {
                        model.sheet = .metricSource(productID: product.id, environmentID: environment.id)
                    } else {
                        model.sheet = .environment(productID: product.id)
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).kitType(.meta, Ink.text3)
            Text(value).kitType(.bodyStrong).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct DeploymentTimeline: View {
    @Environment(AppModel.self) private var model
    let product: Product
    var limit = 6

    var body: some View {
        let history = model.cache.deployments.filter { $0.productID == product.id }
            .sorted { ($0.deployedAt ?? $0.provenance.observedAt) > ($1.deployedAt ?? $1.provenance.observedAt) }.prefix(limit)
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Deployments") {
                Button("History") { model.go(.deployments) }.buttonStyle(.kit(.link))
            }
            .padding(.horizontal, Space.lg).padding(.top, Space.md).padding(.bottom, Space.sm)
            if history.isEmpty {
                EmptyState(icon: .deploy, title: "No deployment evidence", message: "Connect a status endpoint, a GitHub environment, or a release file to see what was deployed and when.", compact: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, observation in
                        let environment = product.environment(id: observation.environmentID)
                        let level = observation.provenance.effectiveLevel(now: model.now)
                        let failed = observation.problem != nil || ["failure", "error"].contains(observation.deployState ?? "")
                        let tone: Tone = failed ? .err : level == .verified ? .ok : level == .reported ? .accent : .muted
                        HStack(alignment: .top, spacing: Space.md) {
                            VStack(spacing: Space.xs) {
                                Circle().strokeBorder(Ink.tone(tone), lineWidth: 2)
                                    .background(Circle().fill(tone == .accent || tone == .muted ? Ink.panel : Ink.tone(tone)))
                                    .frame(width: 10, height: 10).padding(.top, Space.xs) // grid: ok timeline dot from the design
                                if index < history.count - 1 { Ink.line.frame(width: 1.5).frame(maxHeight: .infinity) } // grid: ok drawing size from the design, not layout spacing
                            }
                            .frame(width: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Space.sm) {
                                    Text(observation.version ?? shortSHA(observation.sha)).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.text)
                                    TagBadge(environment?.tier.isProduction == true ? "Prod" : (environment?.name ?? "Env"), tone: environment?.tier.isProduction == true ? .prod : .accent)
                                    Spacer(minLength: Space.xs)
                                    Text(RelativeTime.short(observation.deployedAt ?? observation.provenance.observedAt, now: model.now)).kitType(.meta, Ink.text3)
                                }
                                Text(failed ? (observation.problem?.title ?? "Deploy \(observation.deployState ?? "failed")")
                                            : observation.detail.isEmpty ? "Commit \(shortSHA(observation.sha))" : observation.detail)
                                    .kitType(.label).lineLimit(2)
                                HStack(spacing: Space.xs) {
                                    Text(level.title).kitType(.metaMedium, Ink.tone(tone))
                                    Text("· \(observation.provenance.isDemo ? "Demo fixture" : observation.provenance.source.title)").kitType(.meta, Ink.text3).lineLimit(1)
                                }
                            }
                            .padding(.bottom, Space.lg)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, Space.lg).padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct HealthCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let probes = product.environments.flatMap { environment in environment.probes.map { (environment, $0) } }
        VStack(alignment: .leading, spacing: Space.sm) {
            CardHeader(title: "Health", subtitle: probes.isEmpty ? nil : "Last 30 checks")
            if probes.isEmpty {
                Text("No health checks yet. Add one under Environments to watch a URL.").kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                Button("Go to Environments") { model.productTab = .environments }.buttonStyle(.kit(.link))
            } else {
                ForEach(probes, id: \.1.id) { environment, probe in
                    let samples = model.cache.health[probe.id] ?? []
                    let passed = samples.filter(\.ok).count
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.sm) {
                            Text("\(environment.name) · \(probe.name.isEmpty ? (URL(string: probe.url)?.path ?? probe.url) : probe.name)").kitType(.monoSmall).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: Space.xs)
                            if let last = samples.last {
                                Text(last.latencyMS.map { "\($0) ms" } ?? (last.problem?.title ?? "failed")).kitType(.labelMedium, last.ok ? ((last.latencyMS ?? 0) > 800 ? Ink.warn : Ink.ok) : Ink.err).monospacedDigit()
                                Text(samples.isEmpty ? "" : String(format: "%.0f%%", Double(passed) / Double(samples.count) * 100)).kitType(.label, Ink.text3).monospacedDigit()
                            } else {
                                Text("Not checked").kitType(.label, Ink.text3)
                            }
                        }
                        HealthBars(samples: samples)
                    }
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

struct HostsCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let hosts = product.environments.flatMap { environment in environment.sshHosts.map { (environment, $0) } }
        VStack(alignment: .leading, spacing: Space.sm) {
            CardHeader(title: "SSH hosts") {
                if let environment = product.environment(tier: model.context) ?? product.environments.first {
                    Button("+ Host") { model.sheet = .sshHost(productID: product.id, environmentID: environment.id) }.buttonStyle(.kit(.link))
                }
            }
            if hosts.isEmpty {
                Text("No hosts linked. Hosts come from your own ~/.ssh/config: keys stay with the SSH agent.").kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(hosts, id: \.1.id) { environment, host in
                    let result = model.sshProbeOutput[host.alias]
                    HStack(spacing: Space.sm) {
                        Dot(color: result == nil ? Ink.text3 : result!.ok ? Ink.ok : Ink.err, size: 7) // grid: ok status dot size from the design
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: Space.xs) {
                                Text(host.alias).kitType(.mono).lineLimit(1)
                                if environment.tier.isProduction { TagBadge("Prod", tone: .prod) }
                            }
                            Text(result.map { $0.ok ? $0.output.trimmingCharacters(in: .whitespacesAndNewlines) : $0.detail } ?? "\(environment.name) · not probed")
                                .kitType(.meta, Ink.text3).lineLimit(1)
                        }
                        Spacer(minLength: Space.xs)
                        Button("Probe") { model.runSSHProbe(alias: host.alias, commandID: "uptime") }.buttonStyle(.kit(.secondary, compact: true))
                            .disabled(product.isDemo).help("Read-only: runs `uptime` with strict host key checking")
                        Button("Connect") { model.openSSH(alias: host.alias, product: product) }.buttonStyle(.kit(.secondary, compact: true))
                            .disabled(product.isDemo).help("Opens an SSH session in your terminal")
                    }
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

// MARK: Development tab

struct EvidenceChain: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let nodes = DriftAnalyzer.chain(product: product, cache: model.cache, now: model.now)
        let relations = DriftAnalyzer.relations(product: product, cache: model.cache, now: model.now)
        VStack(alignment: .leading, spacing: Space.md) {
            CardHeader(title: "Source of truth", subtitle: "Each stage shows what was observed, not what is assumed")
            HStack(alignment: .top, spacing: Space.sm) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    if index > 0 { Icon(.chevronRight, size: 10, weight: .semibold).foregroundStyle(Ink.text3).padding(.top, Space.xl) }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(node.stage.rawValue.uppercased()).kitType(.badge, node.stage == .production ? Ink.prod : Ink.text3)
                            .lineLimit(1).fixedSize()
                        SourceBadge(level: node.level, source: node.sourceTitle, observedAt: node.observedAt, isDemo: node.isDemo)
                        Text(node.headline).kitType(.monoTitle, node.sha == nil && node.version == nil ? Ink.text3 : Ink.text).lineLimit(1).minimumScaleFactor(0.7)
                        if node.version != nil, node.sha != nil { Text(shortSHA(node.sha)).kitType(.monoSmall, Ink.text3) }
                        Text(node.detail).kitType(.label, node.problem != nil && node.problem != .notConfigured ? Ink.warn : Ink.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text("\(node.sourceTitle)\(node.observedAt.map { " · \(RelativeTime.short($0, now: model.now))" } ?? "")").kitType(.meta, Ink.text3).lineLimit(1)
                        if node.isMixed { TagBadge("Mixed revisions", tone: .warn) }
                        if node.isDirty { TagBadge("Uncommitted work", tone: .warn) }
                    }
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                    .background(node.stage == .production ? Ink.prod.soft(0.05) : Ink.panel2.opacity(0.6), in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous).strokeBorder(node.stage == .production ? Ink.prod.opacity(0.3) : Ink.line, lineWidth: Metric.hairline))
                    .accessibilityElement(children: .combine)
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(relations) { relation in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text("\(relation.from.rawValue) → \(relation.to.rawValue)").kitType(.monoSmall, Ink.text3).frame(width: 140, alignment: .leading)
                        Text(relation.sentence).kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(Space.lg)
        .card()
    }
}

struct DevelopmentTab: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            EvidenceChain(product: product)
            InstallLinksCard(product: product)
            AgentContextCard(product: product)
            SkillsCard(product: product)
            checkouts
            repositories
            HStack(alignment: .top, spacing: Space.lg) {
                pullRequests
                runs
            }
            commits
        }
    }

    private func linkFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Link"
        panel.message = "Choose folders that belong to \(product.name)."
        guard panel.runModal() == .OK else { return }
        let discovery = ProjectDiscovery()
        let proposals = panel.urls.map { url -> ImportProposal in
            let project = discovery.inspect(url) ?? DiscoveredProject(path: url.path, name: url.lastPathComponent, isGitRepository: false, isWorktree: false,
                                                                      mainWorktreePath: nil, remoteURL: nil, repository: nil, metadata: DetectedMetadata(), description: nil)
            if let existing = product.checkouts.first(where: { $0.path == url.path }) {
                return ImportProposal(project: project, action: .refresh(productID: product.id, checkoutID: existing.id))
            }
            return ImportProposal(project: project, action: .addCheckout(productID: product.id))
        }
        _ = model.applyImport(proposals, group: product.group)
        model.show("Linked \(proposals.count) folder\(proposals.count == 1 ? "" : "s")")
    }

    private var checkouts: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Local checkouts", subtitle: "\(product.checkouts.count)") {
                Button("Link Folder…") { linkFolder() }.buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
            }
            .padding(Space.lg)
            if product.checkouts.isEmpty {
                EmptyState(icon: .laptop, title: "No local checkout", message: product.hasRemote ? "Clone the repository below, or link a folder you already have." : "Link a folder to see its Git state and open it in one click.", compact: true)
                    .hairlineAbove()
            }
            ForEach(product.checkouts) { checkout in
                let git = model.cache.git[checkout.id]
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(spacing: Space.sm) {
                        ToneIcon(icon: checkout.isWorktree ? .branch : .laptop, tone: git?.available == false ? .err : git?.isDirty == true ? .warn : .muted)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Space.sm) {
                                Text(checkout.name).kitType(.bodyMedium)
                                if checkout.isWorktree { TagBadge("Worktree", tone: .accent) }
                                if let component = product.component(id: checkout.componentID) { Chip(component.name) }
                                if product.isDemo { DemoBadge() }
                            }
                            CopyableValue(value: checkout.path, display: abbreviate(checkout.path))
                        }
                        Spacer(minLength: Space.sm)
                        HStack(spacing: Space.xs) {
                            IconButton(.terminal, label: "Open Terminal") { model.openTerminal(product, checkout: checkout) }
                            IconButton(.code, label: "Open in Editor") { model.openEditor(product, checkout: checkout) }
                            IconButton(.finder, label: "Reveal in Finder") { model.reveal(product, checkout: checkout) }
                            IconButton(.sparkle, label: "Open with \(AgentCatalog.name(model.portfolio.agentProgram(for: product)))") { model.openAgent(product, checkout: checkout) }
                            IconButton(.download, label: "Fetch from the remote") { model.fetch(checkout, in: product) }
                        }
                        .disabled(product.isDemo)
                        Menu {
                            ForEach(model.launcher.installed(KnownApps.terminals)) { app in
                                Button("Open in \(app.name)\(app.verified ? "" : " (not verified on this Mac)")") { model.openTerminal(product, checkout: checkout, bundleID: app.bundleID) }
                            }
                            Divider()
                            Button("Copy cd Command") { model.copy(TerminalLauncher.copyCommand(directory: checkout.path), message: "Copied the cd command") }
                            Button("Remove from \(product.name)") {
                                model.update(product.id) { $0.checkouts.removeAll { $0.id == checkout.id } }
                                model.show("Unlinked \(checkout.name). The folder was not touched.")
                            }
                        } label: { Icon(.more, size: 12) }
                        .menuStyle(.button).buttonStyle(.kit(.icon)).menuIndicator(.hidden).fixedSize().disabled(product.isDemo)
                        .accessibilityLabel("More actions for \(checkout.name)")
                    }
                    if let git {
                        if !git.available {
                            ErrorState(title: "Folder missing", detail: "Nothing is at \(abbreviate(checkout.path)). It may have moved.", retryLabel: "Find It") {
                                if let path = ImportPlanner.recoverPath(for: checkout) {
                                    model.update(product.id) { product in
                                        if let index = product.checkouts.firstIndex(where: { $0.id == checkout.id }) { product.checkouts[index].path = path }
                                    }
                                    Task { await model.refreshLocal() }
                                    model.show("Found it at \(abbreviate(path))")
                                } else {
                                    model.show("The folder could not be found. Link it again with Link Folder.", isError: true)
                                }
                            }
                        } else if !git.isRepository {
                            Text("Not a Git repository. \(Brand.name) can still open it.").kitType(.label, Ink.text2)
                        } else {
                            HStack(spacing: Space.lg) {
                                fact("Branch", git.isDetached ? "detached" : git.branch ?? "—", mono: true)
                                fact("HEAD", shortSHA(git.headSHA), mono: true)
                                fact("Staged", "\(git.staged)", tone: git.staged > 0 ? .warn : nil)
                                fact("Unstaged", "\(git.unstaged)", tone: git.unstaged > 0 ? .warn : nil)
                                fact("Untracked", "\(git.untracked)", tone: git.untracked > 0 ? .warn : nil)
                                fact("Conflicts", "\(git.conflicted)", tone: git.conflicted > 0 ? .err : nil)
                                fact("Stashes", "\(git.stashes)")
                                fact("Upstream", git.upstream == nil ? "none" : "\(git.ahead ?? 0)↑ \(git.behind ?? 0)↓", tone: (git.ahead ?? 0) + (git.behind ?? 0) > 0 ? .accent : nil)
                                fact("Last fetch", git.lastFetch.map { RelativeTime.short($0, now: model.now) } ?? "never")
                                if git.isShallow { fact("History", "shallow", tone: .warn) }
                            }
                        }
                    } else {
                        Text("Not inspected yet. Press ⌘R.").kitType(.label, Ink.text3)
                    }
                }
                .padding(Space.lg)
                .hairlineAbove()
            }
        }
        .card()
    }

    private func fact(_ label: String, _ value: String, mono: Bool = false, tone: Tone? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).kitType(.meta, Ink.text3)
            Text(value).kitType(mono ? .mono : .labelMedium, tone.map(Ink.tone) ?? Ink.text).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var repositories: some View {
        if !product.repositories.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Repositories", subtitle: "\(product.repositories.count)").padding(Space.lg)
                ForEach(product.repositories) { repo in
                    let remote = model.cache.remotes[repo.id]
                    let hasCheckout = product.checkouts.contains { $0.repositoryID == repo.id }
                    ActionRow(icon: .branch, tone: remote?.problem != nil ? .warn : .muted, title: repo.fullName,
                              subtitle: remote.map { remote in
                                  remote.headSHA == nil ? (remote.problem?.title ?? "Not fetched")
                                      : "\(remote.defaultBranch) · \(shortSHA(remote.headSHA)) · \(remote.headMessage ?? "") · seen \(RelativeTime.short(remote.provenance.observedAt, now: model.now))"
                              } ?? "Not fetched yet", mono: true) {
                        if let remote { SourceBadge(level: remote.headSHA == nil ? .unknown : remote.provenance.effectiveLevel(now: model.now), source: "GitHub API", observedAt: remote.provenance.observedAt, isDemo: remote.provenance.isDemo) }
                        if !hasCheckout { TagBadge("No checkout") }
                        Button("View on GitHub") { model.openLink(repo.webURL) }.buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                        if !hasCheckout {
                            Button("Clone…") { model.clone(repo, in: product) }.buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                                .help("Choose a destination folder. An existing folder is never overwritten.")
                            Button("Link Existing…") { linkFolder() }.buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                        }
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.xs)
                    .hairlineAbove()
                }
            }
            .card()
        }
    }

    private var pullRequests: some View {
        let pulls = product.repositories.flatMap { model.cache.remotes[$0.id]?.pullRequests ?? [] }
        return VStack(alignment: .leading, spacing: Space.sm) {
            CardHeader(title: "Open pull requests", subtitle: "\(pulls.count)")
            if pulls.isEmpty {
                Text(product.hasRemote ? "None open, as of the last fetch." : "Link a GitHub repository to see pull requests.").kitType(.label, Ink.text2)
            }
            ForEach(pulls.prefix(6)) { pr in
                ActionRow(icon: .pullRequest, tone: .accent, title: "#\(pr.number) \(pr.title)", subtitle: "\(pr.author)\(pr.isDraft ? " · draft" : "") · updated \(RelativeTime.short(pr.updatedAt, now: model.now))") {
                    if !pr.url.isEmpty, !product.isDemo { IconButton(.external, label: "Open pull request") { model.openLink(pr.url) } }
                }
            }
        }
        .padding(Space.lg).frame(maxWidth: .infinity, alignment: .topLeading).card()
    }

    private var runs: some View {
        let runs = product.repositories.flatMap { model.cache.remotes[$0.id]?.runs ?? [] }.sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: Space.sm) {
            CardHeader(title: "CI runs", subtitle: "A passing run is a build, not a deployment") {
                if product.repositories.contains(where: { $0.provider == "github" }) {
                    Button("Last Failure Logs") { model.sheet = .ciFailure(productID: product.id, runID: nil) }
                        .buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                        .help("The newest failed deploy or release run, else the newest failed run, with its failing log and a fix prompt")
                }
            }
            if runs.isEmpty {
                Text(product.hasRemote ? "No workflow runs were returned." : "Link a GitHub repository to see CI.").kitType(.label, Ink.text2)
            }
            ForEach(runs.prefix(6)) { run in
                ActionRow(icon: run.failed ? .error : run.succeeded ? .check : .clock, tone: run.failed ? .err : run.succeeded ? .ok : .muted,
                          title: run.name.isEmpty ? "Workflow" : run.name,
                          subtitle: "\(run.branch) · \(shortSHA(run.headSHA)) · \(run.conclusion.isEmpty ? run.status : run.conclusion) · \(RelativeTime.short(run.createdAt, now: model.now))") {
                    if run.failed, !product.isDemo {
                        Button("Logs") { model.sheet = .ciFailure(productID: product.id, runID: run.id) }.buttonStyle(.kit(.secondary, compact: true))
                    }
                    if !run.url.isEmpty, !product.isDemo { IconButton(.external, label: "Open run") { model.openLink(run.url) } }
                }
            }
        }
        .padding(Space.lg).frame(maxWidth: .infinity, alignment: .topLeading).card()
    }

    @ViewBuilder private var commits: some View {
        if let checkout = product.primaryCheckout, let git = model.cache.git[checkout.id], !git.recentCommits.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                CardHeader(title: "Recent local commits", subtitle: checkout.name)
                ForEach(git.recentCommits) { commit in
                    HStack(spacing: Space.md) {
                        Text(shortSHA(commit.sha)).kitType(.monoSmall, Ink.accentText)
                        Text(commit.subject).kitType(.label).lineLimit(1)
                        Spacer(minLength: Space.sm)
                        Text("\(commit.author) · \(RelativeTime.short(commit.date, now: model.now))").kitType(.meta, Ink.text3).lineLimit(1)
                    }
                }
            }
            .padding(Space.lg).card()
        }
    }
}
