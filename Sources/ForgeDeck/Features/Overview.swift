import ForgeDeckKit
import SwiftUI

// MARK: Shared product pieces

extension AppModel {
    struct Headline {
        var value: String
        var note: String
        var isDemo: Bool
    }

    /// The number on a product card: revenue when the product's own metrics source reports it,
    /// otherwise leads this week, otherwise nothing.
    func headline(_ product: Product) -> Headline {
        if let sample = cache.metrics.first(where: { $0.productID == product.id && $0.key == "mrr_cents" }) {
            let stale = sample.provenance.effectiveLevel(now: now) == .stale
            return Headline(value: Money.compact(cents: Int(sample.value)), note: stale ? "MRR · stale" : "MRR", isDemo: sample.provenance.isDemo)
        }
        let leads = MetricMath.count(cache.leads, kinds: [.lead, .signup], productID: product.id, within: 7 * 86_400, now: now)
        if leads > 0 { return Headline(value: "\(leads)", note: "leads · 7d", isDemo: product.isDemo) }
        return Headline(value: "—", note: product.lifecycle.title, isDemo: false)
    }

    func releaseLine(_ product: Product) -> String {
        if let production = product.environment(tier: .production) {
            let evidence = DriftAnalyzer.evidence(environment: production, product: product, cache: cache, now: now)
            if let observation = evidence.observation {
                let what = observation.version ?? shortSHA(observation.sha)
                let when = observation.deployedAt.map { "deployed \(RelativeTime.short($0, now: now))" } ?? "seen \(RelativeTime.short(observation.provenance.observedAt, now: now))"
                return "\(what) · \(when) · \(evidence.level.title.lowercased())"
            }
            return "Production: \(evidence.problem == .notConfigured ? "not connected" : (evidence.problem?.title.lowercased() ?? "unknown"))"
        }
        if let opened = product.lastOpenedAt { return "Opened \(RelativeTime.short(opened, now: now))" }
        return product.hasLocal ? "Local only" : product.hasRemote ? "GitHub only" : "Nothing connected yet"
    }
}

extension Money {
    static func compact(cents: Int) -> String {
        let dollars = Double(cents) / 100
        if dollars >= 1_000_000 { return String(format: "$%.1fM", dollars / 1_000_000) }
        if dollars >= 1_000 { return String(format: "$%.1fk", dollars / 1_000) }
        return format(cents: cents)
    }
}

struct SyncStrip: View {
    let cells: [ProductStatus.Cell]

    private func icon(_ title: String) -> KitIcon {
        switch title {
        case "Local": .laptop
        case "GitHub": .branch
        default: .globe
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.xs) {
                        Icon(icon(cell.title), size: 9, weight: .medium)
                        Text(cell.title).font(.system(size: 10.5))
                    }
                    .foregroundStyle(Ink.text3)
                    HStack(spacing: Space.xs) {
                        Dot(color: Ink.tone(cell.tone))
                        Text(cell.value).kitType(.labelMedium).lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.horizontal, Space.sm).padding(.vertical, Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { if index > 0 { Ink.line.frame(width: Metric.hairline) } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(cell.title): \(cell.value)")
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous).strokeBorder(Ink.line, lineWidth: Metric.hairline))
    }
}

struct ProductCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let headline = model.headline(product)
        SurfaceCard(lifts: true) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top, spacing: Space.md) {
                    ProjectIcon(product)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Space.sm) {
                            Text(product.name).kitType(.bodyStrong).lineLimit(1)
                            StatusPill(model.badge(product))
                            if product.isDemo { DemoBadge() }
                            if product.isFavorite { Icon(.starFill, size: 9).foregroundStyle(Ink.warn).accessibilityLabel("Favorite") }
                        }
                        Text(product.tagline.isEmpty ? (product.primaryCheckout?.path ?? product.repositories.first?.fullName ?? "No description") : product.tagline)
                            .kitType(.label, Ink.text2).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: Space.xs)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(headline.value).kitType(.section).monospacedDigit()
                        Text(headline.note).kitType(.meta, Ink.text3)
                    }
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                }
                if !product.stack.isEmpty {
                    HStack(spacing: Space.xs) {
                        ForEach(product.stack.prefix(4), id: \.self) { Chip($0) }
                        if product.components.count > 1 { Chip("\(product.components.count) components") }
                    }
                    .frame(height: 20)
                }
                SyncStrip(cells: ProductStatus.cells(product, cache: model.cache, now: model.now))
                HStack(spacing: Space.sm) {
                    Text(model.releaseLine(product)).font(.system(size: 11.5)).foregroundStyle(Ink.text3).lineLimit(1)
                    Spacer(minLength: Space.xs)
                    TerminalIndicator(product: product)
                    IconButton(.terminal, label: product.isDemo ? "Demo product: no folder to open" : "Open Terminal") { model.openTerminal(product) }
                        .disabled(product.isDemo || !product.hasLocal)
                    IconButton(.code, label: product.isDemo ? "Demo product: no folder to open" : "Open in Editor") { model.openEditor(product) }
                        .disabled(product.isDemo || !product.hasLocal)
                    IconButton(.sparkle, label: product.isDemo ? "Demo product: no folder to open" : "Open with \(AgentCatalog.name(model.portfolio.settings.aiAgentProgram)) and linked context") { model.openAgent(product) }
                        .disabled(product.isDemo || !product.hasLocal)
                    IconButton(.external, label: "Open Dashboard") { model.openDashboard(product) }
                        .disabled(product.isDemo || (product.links.isEmpty && product.repositories.isEmpty))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.open(product) }
        .contextMenu { ProductMenu(product: product) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(product.name), \(model.badge(product).label)")
        .accessibilityAction(named: "Open") { model.open(product) }
    }
}

struct ProductGrid: View {
    let products: [Product]
    var minimum: CGFloat = 320

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: Space.md, alignment: .top)], spacing: Space.md) {
            ForEach(products) { ProductCard(product: $0) }
        }
    }
}

// MARK: Activity panel

struct ActivityPanel: View {
    @Environment(AppModel.self) private var model
    var limit = 9

    var body: some View {
        @Bindable var model = model
        let events = model.cache.activity.filter { model.feedFilter == .all || $0.kind.category == model.feedFilter }.prefix(limit)
        let anyDemo = model.cache.activity.contains(where: \.isDemo)
        VStack(spacing: 0) {
            VStack(spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Text("Activity").kitType(.bodyStrong)
                    if anyDemo && model.cache.activity.allSatisfy(\.isDemo) {
                        DemoBadge()
                    } else {
                        HStack(spacing: Space.xs) {
                            Dot(color: model.isOnline ? Ink.ok : Ink.text3)
                            Text(model.isOnline ? (model.portfolio.settings.pollingEnabled ? "Polling" : "Manual") : "Offline").kitType(.metaStrong, model.isOnline ? Ink.ok : Ink.text3)
                        }
                        .help(model.portfolio.settings.pollingEnabled ? "Sources are checked every \(model.portfolio.settings.pollingIntervalSeconds / 60) minutes." : "Polling is off. Refresh with ⌘R.")
                    }
                    Spacer()
                    Button(model.portfolio.settings.pollingEnabled ? "Pause" : "Resume") {
                        model.portfolio.settings.pollingEnabled.toggle()
                        model.save()
                    }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Ink.text3)
                    .help("Pause or resume background polling")
                }
                SegmentedPill(options: ActivityKind.Category.allCases.map { ($0, $0.rawValue) }, selection: $model.feedFilter, compact: true, stretch: true)
            }
            .padding(.horizontal, Space.lg).padding(.top, Space.md).padding(.bottom, Space.sm)
            ForEach(Array(events)) { event in
                Button {
                    if let product = model.product(event.productID) { model.open(product, tab: .activity) }
                } label: {
                    ActivityRow(event: event, productName: model.product(event.productID)?.name, now: model.now)
                        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle(height: 44))
                .hairlineAbove()
            }
            if events.isEmpty {
                EmptyState(icon: .check, title: "Nothing here yet", message: "Commits, deploys, alerts, and leads appear here as sources report them.", compact: true)
                    .hairlineAbove()
            }
            Button { model.go(.activity) } label: {
                HStack {
                    Text("Open activity log").kitType(.labelMedium, Ink.accentText)
                    Spacer()
                    Kbd("⌘⇧A")
                }
                .padding(.horizontal, Space.lg)
            }
            .buttonStyle(RowButtonStyle(height: 36))
            .hairlineAbove(Ink.line)
        }
        .card()
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
    }
}

// MARK: Overview

struct OverviewPage: View {
    @Environment(AppModel.self) private var model

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: model.now)
        return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }

    private var windowSeconds: TimeInterval {
        switch model.overviewWindow {
        case "24h": 86_400
        case "30d": 30 * 86_400
        default: 7 * 86_400
        }
    }

    private var filtered: [Product] {
        let all = model.activeProducts
        switch model.projectFilter {
        case "All": return all
        case "Favorites": return all.filter(\.isFavorite)
        case "Recent": return all.filter { $0.lastOpenedAt != nil }.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        default: return all.filter { $0.group == model.projectFilter }
        }
    }

    var body: some View {
        @Bindable var model = model
        if model.products.isEmpty {
            FirstRun()
        } else {
            Page {
                PageHeader(title: greeting,
                           subtitle: "\(model.now.formatted(.dateTime.weekday(.wide).month(.wide).day())) · \(PortfolioPulse.headline(portfolio: model.portfolio, cache: model.cache, now: model.now))") {
                    SegmentedPill(options: [("24h", "24h"), ("7d", "7d"), ("30d", "30d")], selection: $model.overviewWindow)
                        .help("The period for lead counts")
                }
                .gridProbe("header", area: "overview")
                tiles.gridProbe("tiles", area: "overview")
                attention
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Space.xl) {
                        projects.frame(minWidth: 560)
                        ActivityPanel().frame(width: Metric.activityWidth)
                    }
                    VStack(alignment: .leading, spacing: Space.xl) {
                        projects
                        ActivityPanel()
                    }
                }
                .gridProbe("projects", area: "overview")
            }
            .gridArea("overview", inset: Metric.pagePadding)
        }
    }

    private var tiles: some View {
        let products = model.activeProducts
        let cache = model.cache
        let demoOnly = !products.isEmpty && products.allSatisfy(\.isDemo)
        // Healthy environments: only environments that have a health source count.
        var monitored = 0, healthy = 0
        var unhealthyName: String?
        for product in products {
            for environment in product.environments {
                let evidence = DriftAnalyzer.evidence(environment: environment, product: product, cache: cache, now: model.now)
                let samples = environment.probes.compactMap { cache.health[$0.id]?.last }
                guard evidence.observation != nil || !samples.isEmpty else { continue }
                monitored += 1
                let ok = samples.allSatisfy(\.ok) && (evidence.observation?.health ?? .healthy) != .unhealthy && (evidence.observation?.health ?? .healthy) != .degraded
                if ok { healthy += 1 } else if unhealthyName == nil { unhealthyName = product.name }
            }
        }
        let dirty = products.flatMap { product in product.checkouts.filter { cache.git[$0.id]?.isDirty == true }.map { _ in product.name } }
        let failing = products.filter { product in product.repositories.contains { cache.remotes[$0.id]?.defaultBranchRun?.failed == true } }
        let kinds: Set<BusinessEventKind> = [.lead, .signup]
        let leads = MetricMath.count(cache.leads, kinds: kinds, within: windowSeconds, now: model.now)
        let previous = MetricMath.count(cache.leads, kinds: kinds, within: windowSeconds, now: model.now.addingTimeInterval(-windowSeconds))
        let hasEarlier = cache.leads.contains { $0.occurredAt < model.now.addingTimeInterval(-windowSeconds) }
        let change = MetricMath.change(current: Double(leads), previous: hasEarlier ? Double(previous) : nil)
        let sources = Set(cache.leads.map(\.sourceID)).count
        let withProduction = products.filter(\.hasProduction).count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Space.md)], spacing: Space.md) {
            MetricTile(label: "Active products", value: "\(products.count)", sub: "\(withProduction) with production", tone: .accent, isDemo: demoOnly) { model.go(.projects) }
            MetricTile(label: "Healthy environments", value: monitored == 0 ? "—" : "\(healthy)/\(monitored)",
                       sub: monitored == 0 ? "No health source connected" : unhealthyName.map { "\($0) needs a look" } ?? "All monitored are healthy",
                       tone: monitored == 0 ? .muted : healthy == monitored ? .ok : .warn, isDemo: demoOnly) { model.infraTab = .health; model.go(.infrastructure) }
            MetricTile(label: "Uncommitted codebases", value: "\(dirty.count)", sub: dirty.isEmpty ? "Working trees are clean" : Array(Set(dirty)).sorted().prefix(2).joined(separator: ", "),
                       tone: dirty.isEmpty ? .ok : .warn, isDemo: demoOnly) { model.go(.git) }
            MetricTile(label: "Failing pipelines", value: "\(failing.count)", sub: failing.isEmpty ? "No failed runs on default branches" : failing.prefix(2).map(\.name).joined(separator: ", "),
                       tone: failing.isEmpty ? .ok : .err, isDemo: demoOnly) { model.go(.git) }
            MetricTile(label: "New leads · \(model.overviewWindow)", value: sources == 0 ? "—" : "\(leads)",
                       sub: sources == 0 ? "No lead source connected" : "From \(sources) source\(sources == 1 ? "" : "s")",
                       tone: sources == 0 ? .muted : .ok,
                       delta: change.map { String(format: "%+.0f%%", $0 * 100) }, deltaTone: (change ?? 0) >= 0 ? .ok : .warn,
                       spark: MetricMath.dailyCounts(cache.leads, kinds: kinds, days: 14, now: model.now),
                       isDemo: !cache.leads.isEmpty && cache.leads.allSatisfy(\.isDemo)) { model.go(.leads) }
        }
    }

    @ViewBuilder private var attention: some View {
        let insights = PortfolioPulse.insights(portfolio: model.portfolio, cache: model.cache, now: model.now, limit: 4)
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.sm) {
                    Text("Needs attention").kitType(.section)
                    Text("\(insights.count)").kitType(.meta, Ink.text3)
                    Spacer()
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
                ForEach(insights) { insight in
                    Button {
                        if let product = model.product(insight.productID) { model.open(product, tab: insight.id.hasPrefix("leads") ? .metrics : .development) } else { model.go(.git) }
                    } label: {
                        HStack(spacing: Space.sm) {
                            Dot(color: Ink.tone(insight.tone))
                            Text(insight.text).kitType(.label).lineLimit(1)
                            if insight.isDemo { DemoBadge() }
                            Spacer(minLength: Space.sm)
                            Icon(.chevronRight, size: 9, weight: .semibold).foregroundStyle(Ink.text3)
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

    private var projects: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text("Products").kitType(.cardTitle)
                Text("\(filtered.count)").kitType(.label, Ink.text3)
                Spacer(minLength: Space.sm)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.xs) {
                        ForEach(["All", "Favorites", "Recent"] + model.portfolio.groups, id: \.self) { name in
                            FilterChip(label: name, selected: model.projectFilter == name) { model.projectFilter = name }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440, alignment: .trailing)
            }
            if filtered.isEmpty {
                EmptyState(icon: .projects, title: "No products match", message: "Nothing is in “\(model.projectFilter)” yet.", cta: "Show All", compact: true) { model.projectFilter = "All" }
                    .card()
            } else {
                ProductGrid(products: filtered, minimum: 300)
            }
        }
    }
}

struct FirstRun: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: Space.lg) {
                EmptyState(icon: .hammer, title: "Welcome to \(Brand.name)",
                           message: "One place for every product you run: its folders, its repositories, what is deployed, and how it is doing. Everything stays on this Mac. No account is needed.",
                           cta: "Add Product", kbd: "⌘N", hint: "or drop a project folder here") { model.sheet = .addProduct }
                HStack(spacing: Space.sm) {
                    Button("Add 3 Demo Products") { model.addDemo(count: 3) }.buttonStyle(.kit(.secondary))
                        .help("Adds sample products from checked-in fixtures. They are labeled Demo and connect to nothing.")
                    Button("Check This Mac's Tools") { model.sheet = .doctor(.toolchain) }.buttonStyle(.kit(.secondary))
                }
                .padding(.top, -64)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Space.section)
        }
    }
}

// MARK: Projects

struct ProjectsPage: View {
    @Environment(AppModel.self) private var model
    @State private var filter = "All"
    @State private var stack = "Any stack"

    static let filters = ["All", "Favorites", "Local only", "GitHub only", "Production", "Broken", "Changed", "Archived"]

    private var results: [Product] {
        let cache = model.cache
        var list = filter == "Archived" ? model.products.filter(\.isArchived) : model.activeProducts
        switch filter {
        case "Favorites": list = list.filter(\.isFavorite)
        case "Local only": list = list.filter { $0.hasLocal && !$0.hasRemote }
        case "GitHub only": list = list.filter { $0.hasRemote && !$0.hasLocal }
        case "Production": list = list.filter(\.hasProduction)
        case "Broken": list = list.filter { [.err, .warn].contains(model.badge($0).tone) }
        case "Changed": list = list.filter { product in product.checkouts.contains { cache.git[$0.id]?.isDirty == true || (cache.git[$0.id]?.ahead ?? 0) > 0 } }
        default: break
        }
        if stack != "Any stack" { list = list.filter { $0.stack.contains(stack) } }
        let query = model.productSearch.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter { product in
                ([product.name, product.tagline, product.group, product.slug] + product.tags + product.stack + product.repositories.map(\.fullName))
                    .contains { $0.lowercased().contains(query) }
            }
        }
        return list
    }

    var body: some View {
        @Bindable var model = model
        let stacks = Array(Set(model.products.flatMap(\.stack))).sorted()
        Page {
            PageHeader(title: "All products", subtitle: "Every product, with where its code lives and what runs in production.") {
                HStack(spacing: Space.sm) {
                    KitField(placeholder: "Filter by name, tag, stack", text: $model.productSearch, icon: .search).frame(width: 240)
                    Menu {
                        Button("Any stack") { stack = "Any stack" }
                        Divider()
                        ForEach(stacks, id: \.self) { name in Button(name) { stack = name } }
                    } label: { Text(stack) }
                    .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
                    .accessibilityLabel("Stack filter: \(stack)")
                }
            }
            HStack(spacing: Space.xs) {
                ForEach(Self.filters, id: \.self) { name in
                    FilterChip(label: name, selected: filter == name) { filter = name }
                }
                Spacer(minLength: Space.sm)
                Text("\(results.count) shown").kitType(.label, Ink.text3)
                Button("Refresh Shown") {
                    let targets = results
                    Task {
                        for product in targets where !product.isDemo { await model.refresh(product, announce: false) }
                        model.show("Refreshed \(targets.filter { !$0.isDemo }.count) products")
                    }
                }
                .buttonStyle(.kit(.secondary, compact: true))
                .disabled(results.allSatisfy(\.isDemo))
                .help("Read-only: checks Git, GitHub, and status endpoints for the products shown")
            }
            if model.products.isEmpty {
                EmptyState(icon: .projects, title: "No products yet", message: "Add a local folder, a GitHub repository, an SSH host, or start with just a name.",
                           cta: "Add Product", kbd: "⌘N") { model.sheet = .addProduct }
            } else if results.isEmpty {
                EmptyState(icon: .search, title: "No products match", message: "Change the filter or clear the search.", cta: "Clear Filters") {
                    filter = "All"
                    stack = "Any stack"
                    model.productSearch = ""
                }
            } else {
                ProductGrid(products: results)
            }
        }
    }
}
