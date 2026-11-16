import ForgeDeckKit
import SwiftUI

// MARK: Deployments

struct DeploymentsPage: View {
    @Environment(AppModel.self) private var model
    @State private var tier: EnvironmentTier = .production

    var body: some View {
        let products = model.activeProducts.filter { !$0.environments.isEmpty || $0.hasRemote }
        Page {
            PageHeader(title: "Deployments", subtitle: "What runs in each environment, where that fact came from, and how fresh it is. A green CI run or a newer commit on main is never shown as deployed.") {
                SegmentedPill(options: [(.staging, "Staging"), (.production, "Production")], selection: $tier)
            }
            if products.isEmpty {
                EmptyState(icon: .deploy, title: "Nothing to track yet", message: "Add a product with a staging or production environment to see what is deployed there.",
                           cta: "Add Product") { model.sheet = .addProduct }
            } else {
                drift
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Space.md) {
                        Text("Product").frame(width: 200, alignment: .leading)
                        Text("Local").frame(maxWidth: .infinity, alignment: .leading)
                        Text("GitHub").frame(maxWidth: .infinity, alignment: .leading)
                        Text(tier.title).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Evidence").frame(width: 120, alignment: .leading)
                        Text("Seen").frame(width: 72, alignment: .trailing)
                    }
                    .kitType(.metaStrong, Ink.text3)
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                    ForEach(products) { product in row(product) }
                }
                .card()
                .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
                HStack(spacing: Space.lg) {
                    ForEach([EvidenceLevel.verified, .reported, .stale, .unknown], id: \.self) { level in
                        SourceBadge(level: level)
                    }
                    Text("Hover a label for what it means.").kitType(.meta, Ink.text3)
                }
            }
        }
    }

    private func cell(_ node: ChainNode?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node?.headline ?? "—").kitType(.mono, node?.sha == nil && node?.version == nil ? Ink.text3 : Ink.text).lineLimit(1)
            Text(node?.detail ?? "").kitType(.meta, Ink.text3).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ product: Product) -> some View {
        let nodes = DriftAnalyzer.chain(product: product, cache: model.cache, now: model.now)
        let target = nodes.first { $0.stage == (tier == .production ? .production : .staging) }
        return Button { model.open(product, tab: .development) } label: {
            HStack(spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    ProjectIcon(product, size: 24)
                    Text(product.name).kitType(.bodyMedium).lineLimit(1)
                    if product.isDemo { DemoBadge() }
                }
                .frame(width: 200, alignment: .leading)
                cell(nodes.first { $0.stage == .local })
                cell(nodes.first { $0.stage == .github })
                cell(target)
                HStack(spacing: Space.xs) {
                    SourceBadge(level: target?.level ?? .unknown, source: target?.sourceTitle, observedAt: target?.observedAt)
                    if target?.isMixed == true { TagBadge("Mixed", tone: .warn) }
                }
                .frame(width: 120, alignment: .leading)
                Text(target?.observedAt.map { RelativeTime.compact($0, now: model.now) } ?? "—").kitType(.meta, Ink.text3).frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, Space.lg)
        }
        .buttonStyle(RowButtonStyle(height: 48))
        .hairlineAbove()
        .contextMenu { ProductMenu(product: product) }
        .accessibilityLabel("\(product.name): \(tier.title) \(target?.headline ?? "unknown"), \(target?.level.title ?? "Unknown") evidence")
    }

    @ViewBuilder private var drift: some View {
        let items = model.activeProducts.flatMap { product in
            DriftAnalyzer.relations(product: product, cache: model.cache, now: model.now)
                .filter { if case .same = $0.comparison { false } else if case .unknown = $0.comparison { false } else { true } }
                .map { (product, $0) }
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Drift", subtitle: "Stages that differ, from known evidence").padding(Space.lg)
                ForEach(Array(items.prefix(8).enumerated()), id: \.offset) { _, item in
                    let (product, relation) = item
                    Button { model.open(product, tab: .development) } label: {
                        HStack(spacing: Space.sm) {
                            ProjectIcon(product, size: 16)
                            Text(product.name).kitType(.labelMedium).frame(width: 132, alignment: .leading).lineLimit(1)
                            Text(relation.sentence).kitType(.label, Ink.text2).lineLimit(1)
                            if product.isDemo { DemoBadge() }
                            Spacer(minLength: Space.sm)
                            StatusPill(relation.comparison.title, tone: relation.comparison == .notEnoughHistory ? .muted : .accent)
                        }
                        .padding(.horizontal, Space.lg)
                    }
                    .buttonStyle(RowButtonStyle(height: 32))
                    .hairlineAbove()
                }
            }
            .card()
            .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
        }
    }
}

// MARK: Leads and metrics

struct LeadsPage: View {
    var body: some View {
        Page {
            PageHeader(title: "Leads & Metrics", subtitle: "Numbers come only from sources you connected. Each shows its source and age. A source that stops answering turns Stale: it never drops to zero.")
            LeadsContent(product: nil)
        }
    }
}

struct LeadsContent: View {
    @Environment(AppModel.self) private var model
    let product: Product?
    @State private var window = "7d"
    @State private var inbox: LeadState? = .new
    @State private var showContacts = false

    private var days: Int { window == "24h" ? 1 : window == "30d" ? 30 : window == "90d" ? 90 : 7 }

    var body: some View {
        let cache = model.cache
        let leads = cache.leads.filter { product == nil || $0.productID == product!.id }
        let seconds = Double(days) * 86_400
        let sources = model.activeProducts.filter { product == nil || $0.id == product!.id }
            .flatMap { product in product.environments.flatMap { environment in environment.metricSources.map { (product, environment, $0) } } }
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                SegmentedPill(options: ["24h", "7d", "30d", "90d"].map { ($0, $0) }, selection: $window)
                Spacer()
                if let newest = leads.map(\.receivedAt).max() {
                    Text("Last event received \(RelativeTime.short(newest, now: model.now))").kitType(.label, Ink.text3)
                }
            }
            if leads.isEmpty && sources.isEmpty {
                EmptyState(icon: .leads, title: "No lead source connected",
                           message: "Add a metrics source to a product's environment. It reads a small versioned endpoint your own app serves: counts by default, no contact details.",
                           cta: product == nil ? nil : "Add Metrics Source") {
                    if let product, let environment = product.environment(tier: .production) ?? product.environments.first {
                        model.sheet = .metricSource(productID: product.id, environmentID: environment.id)
                    } else if let product {
                        model.sheet = .environment(productID: product.id)
                    }
                }
                .card()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Space.md)], spacing: Space.md) {
                    tile("Leads", [.lead], leads, seconds)
                    tile("Signups", [.signup], leads, seconds)
                    tile("Paid", [.paidConversion], leads, seconds)
                    tile("Cancellations", [.cancellation], leads, seconds)
                }
                funnel(leads, seconds: seconds)
                reported(sources: sources)
                inboxCard(leads)
            }
        }
    }

    private func tile(_ label: String, _ kinds: Set<BusinessEventKind>, _ leads: [LeadEvent], _ seconds: Double) -> some View {
        let current = MetricMath.count(leads, kinds: kinds, within: seconds, now: model.now)
        let previous = MetricMath.count(leads, kinds: kinds, within: seconds, now: model.now.addingTimeInterval(-seconds))
        let hasEarlier = leads.contains { $0.occurredAt < model.now.addingTimeInterval(-seconds) }
        let change = MetricMath.change(current: Double(current), previous: hasEarlier ? Double(previous) : nil)
        let bad = label == "Cancellations"
        let up = (change ?? 0) >= 0
        return MetricTile(label: "\(label) · \(window)", value: "\(current)",
                          sub: change == nil ? "No earlier period" : "\(previous) the period before",
                          tone: bad ? .warn : .ok, delta: change.map { String(format: "%+.0f%%", $0 * 100) },
                          deltaTone: up == bad ? .warn : .ok,
                          spark: MetricMath.dailyCounts(leads, kinds: kinds, days: max(7, min(days, 30)), now: model.now),
                          isDemo: !leads.isEmpty && leads.allSatisfy(\.isDemo))
    }

    private func funnel(_ leads: [LeadEvent], seconds: Double) -> some View {
        let steps: [(String, Int)] = [("Leads", MetricMath.count(leads, kinds: [.lead], within: seconds, now: model.now)),
                                      ("Signups", MetricMath.count(leads, kinds: [.signup], within: seconds, now: model.now)),
                                      ("Paid", MetricMath.count(leads, kinds: [.paidConversion], within: seconds, now: model.now))]
        let top = max(1, steps.map(\.1).max() ?? 1)
        return VStack(alignment: .leading, spacing: Space.sm) {
            CardHeader(title: "Funnel", subtitle: "Event counts in the window. Each event counts once, whatever source reported it.")
            ForEach(steps, id: \.0) { label, count in
                HStack(spacing: Space.md) {
                    Text(label).kitType(.label, Ink.text2).frame(width: 72, alignment: .leading)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 4).fill(Ink.accent.opacity(0.75))
                            .frame(width: max(2, proxy.size.width * CGFloat(count) / CGFloat(top)))
                    }
                    .frame(height: 12)
                    Text("\(count)").kitType(.labelMedium).monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("\(label): \(count)")
            }
        }
        .padding(Space.lg).card()
    }

    @ViewBuilder private func reported(sources: [(Product, ProductEnvironment, MetricSource)]) -> some View {
        let samples = model.cache.metrics.filter { product == nil || $0.productID == product!.id }
        if !samples.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Reported by sources", subtitle: "Counters as each source states them, with their own window").padding(Space.lg)
                ForEach(Array(samples.sorted { ($0.productID.uuidString, $0.key, $0.window) < ($1.productID.uuidString, $1.key, $1.window) }.enumerated()), id: \.offset) { _, sample in
                    let level = sample.provenance.effectiveLevel(now: model.now)
                    HStack(spacing: Space.md) {
                        Text(model.product(sample.productID)?.name ?? "—").kitType(.labelMedium).frame(width: 140, alignment: .leading).lineLimit(1)
                        Text(sample.key).kitType(.mono).frame(width: 140, alignment: .leading).lineLimit(1)
                        Text(sample.window).kitType(.label, Ink.text3).frame(width: 40, alignment: .leading)
                        Text(sample.key.hasSuffix("_cents") ? Money.format(cents: Int(sample.value)) : String(format: "%g", sample.value)).kitType(.labelStrong).monospacedDigit()
                        Spacer(minLength: Space.sm)
                        Text(sample.sourceLabel).kitType(.meta, Ink.text3).lineLimit(1)
                        SourceBadge(level: level, source: sample.sourceLabel, observedAt: sample.provenance.observedAt, isDemo: sample.provenance.isDemo)
                        Text("as of \(RelativeTime.short(sample.provenance.observedAt, now: model.now))").kitType(.meta, level == .stale ? Ink.warn : Ink.text3).frame(width: 96, alignment: .trailing)
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.sm).hairlineAbove()
                }
            }
            .card()
        }
    }

    private func inboxCard(_ leads: [LeadEvent]) -> some View {
        let revenue = leads.filter(\.kind.isRevenue)
        let shown = revenue.filter { inbox == nil || $0.state == inbox }.prefix(40)
        return VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Lead inbox", subtitle: "\(revenue.filter { $0.state == .new }.count) new") {
                Toggle("Show masked contacts", isOn: $showContacts).toggleStyle(.checkbox).font(KitType.label.font)
                    .help("Contacts are masked when they arrive. The full value is never stored.")
                SegmentedPill(options: [(LeadState?.some(.new), "New"), (.some(.flagged), "Flagged"), (.some(.handled), "Handled"), (nil, "All")], selection: $inbox, compact: true)
            }
            .padding(Space.lg)
            if shown.isEmpty {
                Text(inbox == .new ? "No new leads. Everything here was read or handled." : "Nothing in this list.").kitType(.label, Ink.text2)
                    .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
            }
            ForEach(Array(shown)) { lead in
                ActionRow(icon: lead.kind == .paidConversion || lead.kind == .renewal ? .purchase : .lead, tone: lead.state == .new ? .accent : .muted,
                          title: lead.title + (lead.valueCents.map { " · " + Money.format(cents: $0) } ?? ""),
                          subtitle: [model.product(lead.productID)?.name, lead.kind.title, lead.sourceLabel, showContacts ? lead.maskedContact : nil].compactMap { $0 }.joined(separator: " · ")) {
                    if lead.isDemo { DemoBadge() }
                    Text(RelativeTime.short(lead.occurredAt, now: model.now)).kitType(.meta, Ink.text3)
                    Menu(lead.state.rawValue.capitalized) {
                        ForEach(LeadState.allCases, id: \.self) { state in Button(state.rawValue.capitalized) { model.setLead(lead, state) } }
                    }
                    .menuStyle(.button).buttonStyle(.kit(.secondary, compact: true)).fixedSize()
                    .accessibilityLabel("Lead state: \(lead.state.rawValue)")
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
            }
        }
        .card()
    }
}

// MARK: Infrastructure

struct InfrastructurePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Page {
            PageHeader(title: "Infrastructure", subtitle: "Read-only by default: health checks, connections, SSH hosts, and local Docker.") {
                SegmentedPill(options: InfraTab.allCases.map { ($0, $0.rawValue) }, selection: $model.infraTab)
            }
            switch model.infraTab {
            case .health: health
            case .connections:
                ConnectionsList(products: model.activeProducts)
                planned
            case .ssh: ssh
            case .docker: docker
            }
        }
    }

    private var health: some View {
        let rows = model.activeProducts.flatMap { product in product.environments.flatMap { environment in environment.probes.map { (product, environment, $0) } } }
        return VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Health checks", subtitle: "An alert opens after \(AlertEngine.consecutiveFailures) failures in a row, once").padding(Space.lg)
            if rows.isEmpty {
                EmptyState(icon: .activity, title: "No health checks yet", message: "Open a product, go to Environments, and add a health check or a status endpoint.", compact: true).hairlineAbove()
            }
            ForEach(rows, id: \.2.id) { product, environment, probe in
                let samples = model.cache.health[probe.id] ?? []
                Button { model.open(product, tab: .environments) } label: {
                    HStack(spacing: Space.md) {
                        ProjectIcon(product, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Space.xs) {
                                Text("\(product.name) · \(environment.name)").kitType(.labelMedium).lineLimit(1)
                                if environment.tier.isProduction { TagBadge("Prod", tone: .prod) }
                                if product.isDemo { DemoBadge() }
                            }
                            Text(probe.url).kitType(.monoSmall, Ink.text3).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(width: 280, alignment: .leading)
                        HealthBars(samples: samples)
                        Text(samples.last.map { $0.ok ? "\($0.latencyMS ?? 0) ms" : ($0.problem?.title ?? "Failing") } ?? "Not checked")
                            .kitType(.labelMedium, samples.last == nil ? Ink.text3 : samples.last!.ok ? Ink.ok : Ink.err).frame(width: 132, alignment: .trailing)
                    }
                    .padding(.horizontal, Space.lg)
                }
                .buttonStyle(RowButtonStyle(height: 48))
                .hairlineAbove()
            }
        }
        .card()
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
    }

    private var planned: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            CardHeader(title: "Not built yet", subtitle: "Listed so nothing here looks connected when it is not")
            Text("Stripe, WooCommerce direct, Plausible, PostHog, Sentry, Vercel, Cloudflare, Fly, Railway, GitLab, and Bitbucket have no connector in this version. A product can report the same numbers today through the metrics endpoint in Companions/.")
                .kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.lg).card()
    }

    private var ssh: some View {
        let hosts = SSHConfig.load()
        let linked = model.activeProducts.flatMap { product in product.environments.flatMap { environment in environment.sshHosts.map { ($0.alias, product, environment) } } }
        return VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Hosts in ~/.ssh/config", subtitle: "\(hosts.count) · keys stay with your SSH agent").padding(Space.lg)
            if hosts.isEmpty {
                EmptyState(icon: .infra, title: "No hosts found", message: "\(Brand.name) reads Host aliases from ~/.ssh/config. Add one there, then link it to a product's environment.", compact: true).hairlineAbove()
            }
            ForEach(hosts) { host in
                let owner = linked.first { $0.0 == host.alias }
                let result = model.sshProbeOutput[host.alias]
                ActionRow(icon: .infra, tone: result == nil ? .muted : result!.ok ? .ok : .err, title: host.alias,
                          subtitle: result.map { $0.ok ? $0.output.trimmingCharacters(in: .whitespacesAndNewlines) : $0.detail }
                              ?? [host.user.map { "\($0)@" + (host.hostName ?? host.alias) } ?? host.hostName, owner.map { "\($0.1.name) · \($0.2.name)" } ?? "Not linked to a product"].compactMap { $0 }.joined(separator: " · "),
                          mono: true) {
                    if owner?.2.tier.isProduction == true { TagBadge("Prod", tone: .prod) }
                    Menu("Probe") {
                        ForEach(SSHProbeCommand.catalog) { command in Button(command.title) { model.runSSHProbe(alias: host.alias, commandID: command.id) } }
                    }
                    .menuStyle(.button).buttonStyle(.kit(.secondary, compact: true)).fixedSize().help("Fixed read-only commands. Host keys are always checked.")
                    Button("Doctor") { model.sheet = .doctor(.ssh(alias: host.alias)) }.buttonStyle(.kit(.secondary, compact: true))
                    Button("Connect") { model.openSSH(alias: host.alias, product: owner?.1) }.buttonStyle(.kit(.secondary, compact: true))
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
            }
        }
        .card()
    }

    private var docker: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Local Docker", subtitle: model.dockerContext.map { "context \($0)" } ?? "Status and bounded logs only") {
                Button("Refresh") { Task { await model.refreshDocker() } }.buttonStyle(.kit(.secondary, compact: true))
            }
            .padding(Space.lg)
            switch model.dockerContainers {
            case nil:
                LoadingState(rows: 2, label: "Asking Docker").padding(Space.lg).hairlineAbove()
            case .failure(let problem, let detail, _)?:
                ErrorState(title: problem == .notConfigured ? "Docker is not installed" : "Docker is not answering", detail: detail, retry: { Task { await model.refreshDocker() } })
                    .padding(Space.lg).hairlineAbove()
            case .success(let containers)?, .partial(let containers, _)?:
                if containers.isEmpty {
                    Text("Docker is running with no containers.").kitType(.label, Ink.text2).padding(Space.lg).hairlineAbove()
                }
                ForEach(containers) { container in
                    ActionRow(icon: .docker, tone: container.isRunning ? .ok : .muted, title: container.name,
                              subtitle: "\(container.image) · \(container.status)\(container.composeProject.map { " · compose \($0)" } ?? "")", mono: true) {
                        StatusPill(container.state.capitalized, tone: container.isRunning ? .ok : .muted)
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
                }
            }
        }
        .card()
        .task { if model.dockerContainers == nil, !Runtime.isAutomated { await model.refreshDocker() } }
    }
}

// MARK: Git and CI

struct GitPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.activeProducts.flatMap { product in product.checkouts.map { (product, $0) } }
        let remoteOnly = model.activeProducts.filter { $0.hasRemote && !$0.hasLocal }
        Page {
            PageHeader(title: "Git & CI", subtitle: "Every checkout and worktree, with its working tree and its remote. Local state is read straight from disk and works offline.")
            if rows.isEmpty && remoteOnly.isEmpty {
                EmptyState(icon: .branch, title: "No checkouts yet", message: "Add a local folder or a GitHub repository to see branches, changes, pull requests, and CI.",
                           cta: "Add Product") { model.sheet = .addProduct }
            }
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Space.md) {
                        Text("Checkout").frame(width: 240, alignment: .leading)
                        Text("Branch").frame(width: 140, alignment: .leading)
                        Text("Working tree").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Remote").frame(width: 168, alignment: .leading)
                        Text("CI").frame(width: 96, alignment: .leading)
                        Text("").frame(width: 68)
                    }
                    .kitType(.metaStrong, Ink.text3).padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                    ForEach(rows, id: \.1.id) { product, checkout in
                        let git = model.cache.git[checkout.id]
                        let remote = checkout.repositoryID.flatMap { model.cache.remotes[$0] }
                        let run = remote?.defaultBranchRun
                        HStack(spacing: Space.md) {
                            Button { model.open(product, tab: .development) } label: {
                                HStack(spacing: Space.sm) {
                                    ProjectIcon(product, size: 24)
                                    VStack(alignment: .leading, spacing: 0) {
                                        HStack(spacing: Space.xs) {
                                            Text(checkout.name).kitType(.labelMedium).lineLimit(1)
                                            if checkout.isWorktree { TagBadge("Worktree", tone: .accent) }
                                            if product.isDemo { DemoBadge() }
                                        }
                                        Text(product.name).kitType(.meta, Ink.text3).lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain).frame(width: 240, alignment: .leading)
                            Text(git?.isDetached == true ? "detached \(shortSHA(git?.headSHA))" : git?.branch ?? "—").kitType(.mono).lineLimit(1).frame(width: 140, alignment: .leading)
                            HStack(spacing: Space.xs) {
                                if let git {
                                    if !git.available { StatusPill("Folder missing", tone: .err) }
                                    else if !git.isRepository { StatusPill("Not a repo", tone: .muted) }
                                    else if git.conflicted > 0 { StatusPill("\(git.conflicted) conflicted", tone: .err) }
                                    else if git.isDirty { StatusPill("\(git.changeCount) uncommitted", tone: .warn) }
                                    else { StatusPill("Clean", tone: .ok) }
                                    if git.stashes > 0 { Chip("\(git.stashes) stashed") }
                                } else {
                                    Text("Not inspected").kitType(.label, Ink.text3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(git?.upstream == nil ? "No upstream" : "\(git?.ahead ?? 0) ahead · \(git?.behind ?? 0) behind").kitType(.label, Ink.text2).lineLimit(1)
                                Text(git?.lastFetch.map { "fetched \(RelativeTime.short($0, now: model.now))" } ?? "never fetched").kitType(.meta, Ink.text3).lineLimit(1)
                            }
                            .frame(width: 168, alignment: .leading)
                            Group {
                                if let run, run.failed, !product.isDemo {
                                    Button { model.sheet = .ciFailure(productID: product.id, runID: run.id) } label: { StatusPill("Failing · Logs", tone: .err) }
                                        .buttonStyle(.plain).help("Show the failing log and a fix prompt")
                                } else if let run { StatusPill(run.failed ? "Failing" : run.succeeded ? "Passing" : run.status, tone: run.failed ? .err : run.succeeded ? .ok : .muted) }
                                else { Text("—").kitType(.label, Ink.text3) }
                            }
                            .frame(width: 96, alignment: .leading)
                            HStack(spacing: Space.xs) {
                                IconButton(.terminal, label: "Open Terminal") { model.openTerminal(product, checkout: checkout) }
                                IconButton(.download, label: "Fetch") { model.fetch(checkout, in: product) }
                            }
                            .disabled(product.isDemo).frame(width: 68)
                        }
                        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                        .hairlineAbove()
                        .contextMenu { ProductMenu(product: product) }
                    }
                }
                .card()
            }
            if !remoteOnly.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(title: "GitHub only", subtitle: "No checkout on this Mac").padding(Space.lg)
                    ForEach(remoteOnly) { product in
                        ForEach(product.repositories) { repo in
                            let remote = model.cache.remotes[repo.id]
                            ActionRow(icon: .branch, title: repo.fullName, subtitle: remote?.headSHA.map { "\(remote?.defaultBranch ?? "main") · \(shortSHA($0)) · seen \(RelativeTime.short(remote!.provenance.observedAt, now: model.now))" } ?? (remote?.problem?.title ?? "Not fetched yet"), mono: true) {
                                Button("View Remote") { model.open(product, tab: .development) }.buttonStyle(.kit(.secondary, compact: true))
                                Button("Clone…") { model.clone(repo, in: product) }.buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                                Button("Open in Browser") { model.openLink(repo.webURL) }.buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                            }
                            .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
                        }
                    }
                }
                .card()
            }
        }
    }
}

// MARK: Terminals and actions

struct TerminalsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let terminals = model.launcher.installed(KnownApps.terminals)
        let editors = model.launcher.installed(KnownApps.editors)
        Page {
            PageHeader(title: "Terminals & Actions", subtitle: "Folders open through macOS itself, so no path is ever typed into a shell and no Automation permission is needed.")
            HStack(alignment: .top, spacing: Space.lg) {
                appList("Terminals", terminals, selected: model.portfolio.settings.preferredTerminalBundleID) { model.portfolio.settings.preferredTerminalBundleID = $0; model.save() }
                appList("Editors", editors, selected: model.portfolio.settings.preferredEditorBundleID) { model.portfolio.settings.preferredEditorBundleID = $0; model.save() }
            }
            sessions
            ForEach(model.activeProducts.filter { !$0.recipes.isEmpty || !$0.profiles.isEmpty }) { product in
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(spacing: Space.sm) {
                        ProjectIcon(product, size: 24)
                        Text(product.name).kitType(.cardTitle)
                        if product.isDemo { DemoBadge() }
                    }
                    if !product.recipes.isEmpty { RecipeList(product: product) }
                    if !product.profiles.isEmpty { ProfileList(product: product) }
                }
            }
            if model.activeProducts.allSatisfy({ $0.recipes.isEmpty && $0.profiles.isEmpty }) {
                EmptyState(icon: .play, title: "No recipes or profiles yet", message: "Open a product's Actions tab to add a recipe or a terminal profile. Commands found in a project (tests, dev server, Compose) show up there as suggestions to approve.", compact: true)
                    .card()
            }
        }
    }

    private func appList(_ title: String, _ apps: [AppDescriptor], selected: String, choose: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: title, subtitle: "Installed on this Mac").padding(Space.lg)
            if apps.isEmpty { Text("None found.").kitType(.label, Ink.text2).padding(.horizontal, Space.lg).padding(.bottom, Space.lg) }
            ForEach(apps) { app in
                ActionRow(icon: app.role == .terminal ? .terminal : .code, tone: app.bundleID == selected ? .accent : .muted, title: app.name,
                          subtitle: [app.opensFolder ? "Opens folders" : nil, app.runsCommandFile ? "runs commands" : (app.role == .terminal ? "commands are copied, not run" : nil),
                                     app.verified ? nil : "follows its documentation, not exercised on a test Mac"].compactMap { $0 }.joined(separator: " · ")) {
                    if app.bundleID == selected { TagBadge("Default", tone: .accent) } else {
                        Button("Make Default") { choose(app.bundleID) }.buttonStyle(.kit(.secondary, compact: true))
                    }
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    private var sessions: some View {
        let sessions = model.cache.sessions.suffix(12).reversed()
        return VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Recent sessions", subtitle: "What was opened and when. No transcripts are kept.").padding(Space.lg)
            if sessions.isEmpty { Text("Nothing opened yet.").kitType(.label, Ink.text2).padding(.horizontal, Space.lg).padding(.bottom, Space.lg) }
            ForEach(Array(sessions)) { session in
                let product = model.product(session.productID)
                ActionRow(icon: .clock, title: "\(product?.name ?? "—") · \(session.commandIdentifier)",
                          subtitle: [session.app, product?.checkout(id: session.checkoutID)?.name, product?.environment(id: session.environmentID)?.name].compactMap { $0 }.joined(separator: " · ")) {
                    if let exit = session.exitStatus { StatusPill("exit \(exit)", tone: exit == 0 ? .ok : .err) }
                    Text(RelativeTime.short(session.startedAt, now: model.now)).kitType(.meta, Ink.text3)
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
            }
        }
        .card()
    }
}

// MARK: Secrets vault

struct SecretsPage: View {
    @Environment(AppModel.self) private var model
    @State private var scope = "All"
    @State private var previewProduct: UUID?
    @State private var tier: EnvironmentTier = .development
    @State private var showAudit = false

    var body: some View {
        let variables = model.portfolio.variables.filter { variable in
            switch scope {
            case "Global": variable.scope == .global
            case "Organization": if case .organization = variable.scope { true } else { false }
            case "Product": variable.scope.productID != nil
            case "Production": variable.allowedTiers.contains(.production)
            default: true
            }
        }.sorted { ($0.scope.precedence, $0.key) < ($1.scope.precedence, $1.key) }
        let warnings = VariableResolver.warnings(model.portfolio.variables)
        Page {
            PageHeader(title: "Secrets Vault", subtitle: "Secret values live in the macOS Keychain. \(Brand.name) stores only names, scopes, and references. Values are hidden until you ask, and production values ask for Touch ID.") {
                SegmentedPill(options: ["All", "Global", "Organization", "Product", "Production"].map { ($0, $0) }, selection: $scope)
            }
            ForEach(warnings, id: \.self) { warning in ErrorState(title: "Check this", detail: warning) }
            AdaptiveColumns {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(title: "Variables", subtitle: "\(variables.count)") {
                        Button("Add Variable") { model.sheet = .variable(VariableDraft()) }.buttonStyle(.kit(.secondary, compact: true))
                    }
                    .padding(Space.lg)
                    if variables.isEmpty {
                        EmptyState(icon: .key, title: model.portfolio.variables.isEmpty ? "The vault is empty" : "Nothing in this scope",
                                   message: "Add an API key, token, or setting. Choose where it applies and which environments may use it. A production secret can never reach a development session.", compact: true)
                            .hairlineAbove()
                    }
                    ForEach(variables) { VariableRowView(variable: $0).hairlineAbove() }
                }
                .card()
                .frame(minWidth: 520, maxWidth: .infinity)
                VStack(spacing: Space.lg) {
                    if let product = model.product(previewProduct) ?? model.activeProducts.first(where: { !$0.environments.isEmpty }) {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Menu(product.name) {
                                ForEach(model.activeProducts) { candidate in Button(candidate.name) { previewProduct = candidate.id } }
                            }
                            .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize().accessibilityLabel("Preview for \(product.name)")
                            ResolutionPreview(product: product, tier: $tier)
                        }
                    }
                }
                .frame(minWidth: 320)
            }
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Access audit", subtitle: "Reveals, copies, grants, and denials. Names only.") {
                    Button(showAudit ? "Hide" : "Show") { showAudit.toggle() }.buttonStyle(.kit(.secondary, compact: true))
                }
                .padding(Space.lg)
                if showAudit {
                    let events = Runtime.isAutomated ? [] : model.audit.read(limit: 60)
                    if events.isEmpty { Text("No events yet.").kitType(.label, Ink.text2).padding(.horizontal, Space.lg).padding(.bottom, Space.lg) }
                    ForEach(events) { event in
                        HStack(spacing: Space.md) {
                            Text(event.at.formatted(date: .abbreviated, time: .standard)).kitType(.monoSmall, Ink.text3).frame(width: 168, alignment: .leading)
                            Text(event.actor).kitType(.label, Ink.text3).frame(width: 32, alignment: .leading)
                            Text(event.action).kitType(.mono).frame(width: 140, alignment: .leading)
                            Text([event.product, event.environment, event.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).kitType(.label, Ink.text2).lineLimit(1)
                            Spacer(minLength: Space.sm)
                            StatusPill(event.outcome, tone: event.outcome == "ok" ? .ok : event.outcome == "denied" ? .err : .warn)
                        }
                        .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
                    }
                }
            }
            .card()
        }
        .onAppear { tier = model.context }
    }
}

// MARK: Activity and alerts

struct ActivityPage: View {
    @Environment(AppModel.self) private var model
    @State private var showResolved = false

    var body: some View {
        @Bindable var model = model
        let incidents = model.cache.incidents.filter { showResolved || $0.isOpen }.sorted { $0.openedAt > $1.openedAt }
        let events = model.cache.activity.filter { model.feedFilter == .all || $0.kind.category == model.feedFilter }
        Page {
            PageHeader(title: "Activity", subtitle: "One feed: commits, pull requests, deployments, checks, leads. An event appears once, and an alert stays quiet until its state changes.") {
                SegmentedPill(options: ActivityKind.Category.allCases.map { ($0, $0.rawValue) }, selection: $model.feedFilter)
            }
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Alerts", subtitle: "\(model.attentionIncidents.count) need attention") {
                    Toggle("Show resolved", isOn: $showResolved).toggleStyle(.checkbox).font(KitType.label.font)
                }
                .padding(Space.lg)
                if incidents.isEmpty {
                    EmptyState(icon: .check, title: "No open alerts", message: "Alerts open for failing health checks, failed deploys, broken pipelines, production drift, secrets due for rotation, and stalled lead sources.", compact: true)
                        .hairlineAbove()
                }
                ForEach(incidents.prefix(30)) { IncidentRow(incident: $0).hairlineAbove() }
            }
            .card()
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Events", subtitle: "\(events.count)").padding(Space.lg)
                if events.isEmpty {
                    EmptyState(icon: .activity, title: "Nothing here yet", message: "Events appear as connected sources report them.", compact: true).hairlineAbove()
                }
                ForEach(events.prefix(100)) { event in
                    Button { if let product = model.product(event.productID) { model.open(product, tab: .activity) } } label: {
                        ActivityRow(event: event, productName: model.product(event.productID)?.name, now: model.now)
                            .padding(.horizontal, Space.lg).padding(.vertical, Space.sm).contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle(height: 44))
                    .hairlineAbove()
                }
            }
            .card()
            .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
        }
    }
}
