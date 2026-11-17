import UniformTypeIdentifiers
import ForgeDeckKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            VStack(spacing: 0) {
                TopBar()
                if model.context == .production { ProductionBanner() }
                if !model.isOnline { OfflineBanner() }
                content
                if model.terminals.isVisible, !model.terminals.sessions.isEmpty { TerminalDock() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ink.window)
            if model.usagePanelVisible { UsagePanel().transition(.move(edge: .trailing)) }
        }
        .animation(Motion.pop, value: model.usagePanelVisible)
        .overlay { SheetHost() }
        .overlay { if model.paletteOpen { CommandPalette() } }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(text: toast.text, isError: toast.isError)
                    .padding(.bottom, Space.xxl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(Motion.toast, value: model.toast)
        .animation(Motion.pop, value: model.terminals.isVisible)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            DropImport.handle(providers, model: model)
        }
        .task {
            model.start()
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
        }
    }

    @ViewBuilder private var content: some View {
        if let error = model.loadError {
            VStack {
                ErrorState(title: "\(Brand.name) could not read its data", detail: "\(error)\nNothing was changed. The files are in \(model.store.location.directory.path).")
                    .frame(maxWidth: 560)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch model.route {
            case .overview: OverviewPage()
            case .projects: ProjectsPage()
            case .deployments: DeploymentsPage()
            case .leads: LeadsPage()
            case .infrastructure: InfrastructurePage()
            case .git: GitPage()
            case .terminals: TerminalsPage()
            case .toolbox: ToolboxPage()
            case .secrets: SecretsPage()
            case .activity: ActivityPage()
            case .product(let id):
                if let product = model.product(id) { ProductPage(product: product) } else {
                    EmptyState(icon: .projects, title: "This product is gone", message: "It was removed.", cta: "All Products") { model.go(.projects) }
                }
            }
        }
    }
}

/// A page: scrolling content with the standard margins.
struct Page<Content: View>: View {
    var spacing: CGFloat = Space.xxl
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, Metric.pagePadding).padding(.top, Space.xxl).padding(.bottom, Space.section)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).kitType(.pageTitle).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).kitType(.body, Ink.text2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Space.lg)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

// MARK: Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    /// The group a dragged product would land in.
    @State private var dropTarget: String?

    private func badge(_ route: Route) -> String? {
        switch route {
        case .deployments:
            let drift = model.cache.incidents.filter { $0.isOpen && ($0.rule == .productionDrift || $0.rule == .deployFailed) }.count
            return drift > 0 ? "\(drift)" : nil
        case .activity:
            return model.attentionIncidents.isEmpty ? nil : "\(model.attentionIncidents.count)"
        case .leads:
            let fresh = model.cache.leads.filter { $0.state == .new && $0.kind.isRevenue }.count
            return fresh > 0 ? "\(fresh)" : nil
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowDragArea().frame(height: Metric.toolbarHeight)
            workspace.padding(.horizontal, Space.sm).padding(.bottom, Space.sm)
            VStack(spacing: 1) {
                ForEach(Route.primary, id: \.self) { route in
                    Button { model.go(route) } label: {
                        HStack(spacing: Space.sm) {
                            Icon(route.icon, size: 14).foregroundStyle(model.route == route ? Ink.accentText : Ink.text2).frame(width: 16)
                            Text(route.title).kitType(model.route == route ? .bodyMedium : .body).lineLimit(1)
                            Spacer(minLength: 0)
                            if let badge = badge(route) {
                                Text(badge).kitType(.metaStrong, Ink.text2).monospacedDigit()
                                    .padding(.horizontal, 7).padding(.vertical, 1) // grid: ok badge inset from the design
                                    .background(Ink.chip, in: Capsule())
                            }
                        }
                        .padding(.horizontal, Space.sm)
                    }
                    .buttonStyle(RowButtonStyle(selected: model.route == route))
                    .accessibilityLabel(route.title + (badge(route).map { ", \($0)" } ?? ""))
                }
                Button { openSettings() } label: {
                    HStack(spacing: Space.sm) {
                        Icon(.settings, size: 14).foregroundStyle(Ink.text2).frame(width: 16)
                        Text("Settings").kitType(.body)
                        Spacer(minLength: 0)
                        Kbd("⌘,")
                    }
                    .padding(.horizontal, Space.sm)
                }
                .buttonStyle(RowButtonStyle())
            }
            .padding(.horizontal, Space.sm)
            projects
            footer
        }
        .frame(width: Metric.sidebarWidth)
        .background { ZStack { VisualEffect(material: .sidebar); Ink.sidebarTint } }
        .overlay(alignment: .trailing) { Ink.line.frame(width: Metric.hairline) }
    }

    private var workspace: some View {
        HStack(spacing: Space.sm) {
            RoundedRectangle(cornerRadius: 7, style: .continuous) // grid: ok brand tile radius from the design
                .fill(LinearGradient(colors: Ink.brandGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 28, height: 28)
                .overlay { Icon(.hammer, size: 13, weight: .semibold).foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 0) {
                Text(model.organizationName).kitType(.section).lineLimit(1)
                Text("\(Brand.name) · \(model.activeProducts.count) product\(model.activeProducts.count == 1 ? "" : "s")").kitType(.meta, Ink.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let release = model.availableUpdate {
                Button { model.sheet = .update(release) } label: {
                    Text("Update").kitType(.metaStrong, Ink.onAccent).padding(.horizontal, Space.sm).padding(.vertical, 2)
                        .background(Ink.accent, in: Capsule())
                }
                .buttonStyle(.plain).help("\(Brand.name) \(release.version) is available").accessibilityLabel("Install \(Brand.name) \(release.version)")
            }
        }
        .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
    }

    private var projects: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack {
                    Text("Products").kitType(.metaStrong, Ink.text3)
                    Spacer()
                    Button { model.sheet = .addProduct } label: { Icon(.plus, size: 11, weight: .semibold).foregroundStyle(Ink.text3) }
                        .buttonStyle(.plain).help("Add Product (⌘N)").accessibilityLabel("Add Product")
                }
                .padding(.horizontal, Space.sm).padding(.bottom, 2)
                if model.activeProducts.isEmpty {
                    Text("No products yet").kitType(.label, Ink.text3).padding(.horizontal, Space.sm)
                }
                let favorites = model.activeProducts.filter(\.isFavorite)
                if !favorites.isEmpty { group("Favorites", favorites, isFavorites: true) }
                ForEach(model.portfolio.groups, id: \.self) { name in
                    let items = model.activeProducts.filter { $0.group == name }
                    if !items.isEmpty { group(name, items) }
                }
            }
            .padding(.horizontal, Space.sm).padding(.top, Space.lg).padding(.bottom, Space.sm)
        }
        .frame(maxHeight: .infinity)
    }

    private func group(_ name: String, _ items: [Product], isFavorites: Bool = false) -> some View {
        let open = !model.collapsedGroups.contains(name)
        let targeted = dropTarget == name && !isFavorites
        return VStack(spacing: 1) {
            Button {
                if open { model.collapsedGroups.insert(name) } else { model.collapsedGroups.remove(name) }
            } label: {
                HStack(spacing: Space.xs) {
                    Icon(.chevronRight, size: 8, weight: .bold).foregroundStyle(Ink.text3).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                    Text(name).kitType(.labelMedium, targeted ? Ink.accentText : Ink.text2).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(items.count)").kitType(.meta, Ink.text3).monospacedDigit()
                }
                .padding(.horizontal, Space.sm)
            }
            .buttonStyle(RowButtonStyle(height: 24))
            .contextMenu {
                if !isFavorites {
                    Button("Rename Group…") { model.sheet = .rename(.group(name)) }
                }
            }
            .accessibilityLabel("\(name), \(items.count) products, \(open ? "expanded" : "collapsed")")
            .accessibilityAction(named: "Rename Group") { if !isFavorites { model.sheet = .rename(.group(name)) } }
            if open {
                ForEach(items) { product in
                    Button { model.open(product) } label: {
                        HStack(spacing: Space.sm) {
                            ProjectIcon(product, size: 16)
                            Text(product.name).kitType(model.route == .product(product.id) ? .bodyMedium : .body).lineLimit(1)
                            Spacer(minLength: 0)
                            TerminalIndicator(product: product, compact: true)
                            MCPBadge(product: product, compact: true)
                            Dot(color: Ink.tone(model.badge(product).tone))
                        }
                        .padding(.leading, Space.xl).padding(.trailing, Space.sm)
                    }
                    .buttonStyle(RowButtonStyle(selected: model.route == .product(product.id)))
                    .draggable(ProductDrag(id: product.id)) {
                        HStack(spacing: Space.sm) {
                            ProjectIcon(product, size: 16)
                            Text(product.name).kitType(.body)
                        }
                        .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
                        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Metric.rowRadius))
                    }
                    .contextMenu { ProductMenu(product: product) }
                    .accessibilityLabel("\(product.name), \(model.badge(product).label)")
                }
            }
        }
        .padding(.bottom, Space.xs)
        .background {
            if targeted { RoundedRectangle(cornerRadius: Metric.rowRadius, style: .continuous).strokeBorder(Ink.accent, lineWidth: 1.5) } // grid: ok drop outline weight
        }
        .dropDestination(for: ProductDrag.self) { drops, _ in
            guard !isFavorites else { return false }
            for drop in drops { model.move(drop.id, toGroup: name) }
            return !drops.isEmpty
        } isTargeted: { over in
            if over { dropTarget = name } else if dropTarget == name { dropTarget = nil }
        }
    }

    private var footer: some View {
        let real = model.activeProducts.filter { !$0.isDemo }
        let checkouts = real.flatMap(\.checkouts)
        let title: String = !model.isOnline ? "Offline"
            : model.isRefreshingAll ? "Refreshing…"
            : checkouts.isEmpty ? (model.hasDemo ? "Demo data" : "Nothing to sync")
            : "\(checkouts.count) checkout\(checkouts.count == 1 ? "" : "s") tracked"
        let subtitle: String = !model.isOnline ? "Showing last known state"
            : model.lastRefresh.map { "Refreshed \(RelativeTime.short($0, now: model.now))" } ?? (model.hasDemo && checkouts.isEmpty ? "Fixtures, not live" : "Not refreshed yet")
        return Button { model.refreshCurrentPage() } label: {
            HStack(spacing: Space.sm) {
                Icon(model.isOnline ? .sync : .wifiOff, size: 13).foregroundStyle(model.isOnline ? Ink.ok : Ink.warn)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).kitType(.labelMedium).lineLimit(1)
                    Text(subtitle).kitType(.meta, Ink.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                Kbd("⌘R")
            }
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
        }
        .buttonStyle(RowButtonStyle(height: 36))
        .padding(Space.sm)
        .hairlineAbove(Ink.line)
        .help("Refresh this page (⌘R)")
    }
}

/// The right-click menu for a product, wherever it appears.
struct ProductMenu: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        Button("Open") { model.open(product) }
        Divider()
        Button("Open in Terminal") { model.openTerminal(product) }.disabled(product.isDemo || !product.hasLocal)
        Button("Open in External Terminal") { model.openExternalTerminal(product) }.disabled(product.isDemo || !product.hasLocal)
        Button("Open with \(AgentCatalog.name(model.portfolio.settings.aiAgentProgram))") { model.openAgent(product) }.disabled(product.isDemo || !product.hasLocal)
        Button("Open in Editor") { model.openEditor(product) }.disabled(product.isDemo || !product.hasLocal)
        Button("Reveal in Finder") { model.reveal(product) }.disabled(product.isDemo || !product.hasLocal)
        if let repo = product.repositories.first, !product.isDemo {
            Button("Open on GitHub") { model.openLink(repo.webURL) }
        }
        let options = product.isDemo ? [] : model.playOptions(product)
        if !product.isDemo, product.hasLocal || !options.isEmpty {
            Menu("Play") {
                ForEach(options) { option in Button(option.title) { model.play(product, option: option) } }
                if !options.isEmpty { Divider() }
                Button("Set Up Run…") { model.setUpRun(product) }.disabled(!product.hasLocal)
                Button("Review Run Setup…") { model.reviewRunSetup(product) }.disabled(!product.hasLocal)
            }
            Button("Set Up Leads…") { model.setUpLeads(product) }.disabled(!product.hasLocal)
            Button("Suggest Skills…") { model.suggestSkills(product) }.disabled(!product.hasLocal)
        }
        Divider()
        Button("Rename…") { model.sheet = .rename(.product(product.id)) }
        Menu("Move to Group") {
            ForEach(model.portfolio.groups, id: \.self) { name in
                Button(name) { model.move(product.id, toGroup: name) }.disabled(name == product.group)
            }
            Divider()
            Button("New Group…") { model.sheet = .rename(.newGroup(productID: product.id)) }
        }
        Button(product.isFavorite ? "Remove from Favorites" : "Add to Favorites") { model.update(product.id) { $0.isFavorite.toggle() } }
        Divider()
        Button("Refresh") { Task { await model.refresh(product) } }.disabled(product.isDemo)
        Button("Copy CLI Name") { model.copy(product.slug, message: "Copied \(product.slug)") }
        Divider()
        Button("Remove from \(Brand.name)…") { model.confirmRemove(product) }
    }
}

/// A product dragged between sidebar groups.
nonisolated struct ProductDrag: Codable, Transferable {
    var id: UUID
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .forgeDeckProduct) }
}

extension UTType {
    nonisolated static let forgeDeckProduct = UTType(exportedAs: "com.forgedeck.app.product")
}

// MARK: Top bar

struct TopBar: View {
    @Environment(AppModel.self) private var model

    private var titles: (String, String) {
        if let product = model.currentProduct { return (product.name, "Products › \(product.group)") }
        let count = model.activeProducts.count
        switch model.route {
        case .overview: return ("Overview", model.organizationName)
        case .projects: return ("Products", "\(count) active · \(model.portfolio.groups.count) group\(model.portfolio.groups.count == 1 ? "" : "s")")
        case .deployments: return ("Deployments", "What runs where, and how we know")
        case .leads: return ("Leads & Metrics", "From connected sources")
        case .infrastructure: return ("Infrastructure", "Health, connections, hosts")
        case .git: return ("Git & CI", "\(model.activeProducts.flatMap(\.checkouts).count) checkouts")
        case .terminals: return ("Terminals & Actions", "Launchers, profiles, recipes")
        case .toolbox: return ("Toolbox", "Tools that save tokens or check repositories")
        case .secrets: return ("Secrets Vault", "\(model.portfolio.variables.count) variables")
        case .activity: return ("Activity", "\(model.attentionIncidents.count) need attention")
        case .product: return ("Product", "")
        }
    }

    private var services: (String, Tone, String) {
        var total = 0, failing = 0
        for product in model.activeProducts {
            for environment in product.environments {
                for probe in environment.probes {
                    total += 1
                    if let last = model.cache.health[probe.id]?.last, !last.ok { failing += 1 }
                }
            }
        }
        if total == 0 { return ("No checks", .muted, "No health checks are configured yet.") }
        if failing > 0 { return ("\(failing) of \(total) failing", .err, "\(failing) health checks failed on their last run.") }
        return ("\(total) check\(total == 1 ? "" : "s")", .ok, "Every configured health check passed on its last run.")
    }

    var body: some View {
        // The full bar when it fits, otherwise one without the search field's text and the check count.
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
        .frame(height: Metric.toolbarHeight)
        .background { ZStack { WindowDragArea(); Ink.toolbar.allowsHitTesting(false) } }
        .hairlineBelow()
    }

    private func bar(compact: Bool) -> some View {
        @Bindable var model = model
        return HStack(spacing: Space.sm) {
            HStack(spacing: 2) {
                IconButton(.chevronLeft, label: "Back (⌘[)", kind: .toolbar) { model.goBack() }.disabled(!model.canGoBack)
                IconButton(.chevronRight, label: "Forward (⌘])", kind: .toolbar) { model.goForward() }.disabled(!model.canGoForward)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(titles.0).kitType(.section).lineLimit(1)
                Text(titles.1).kitType(.meta, Ink.text3).lineLimit(1)
            }
            .frame(minWidth: compact ? 80 : 120, alignment: .leading)
            .accessibilityElement(children: .combine)
            Spacer(minLength: Space.sm)
            if compact {
                IconButton(.search, label: "Search or run a command (⌘K)", kind: .toolbar) { model.paletteOpen = true }
            } else {
                Button { model.paletteOpen = true } label: {
                    HStack(spacing: Space.sm) {
                        Icon(.search, size: 12).foregroundStyle(Ink.text3)
                        Text("Search or run a command").font(.system(size: 12.5)).foregroundStyle(Ink.text3).lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                        Text("⌘K").kitType(.meta, Ink.text3)
                            .padding(.horizontal, Space.xs).padding(.vertical, 2)
                            .background(Ink.panel, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.line, lineWidth: Metric.hairline))
                    }
                    .padding(.leading, Space.sm).padding(.trailing, Space.xs)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 300).frame(height: Metric.controlHeight)
                    .background(Ink.field, in: RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Command palette")
                Spacer(minLength: Space.sm)
            }
            EnvironmentPicker(selection: $model.context)
            HStack(spacing: Space.sm) {
                Dot(color: Ink.tone(services.1), size: 7) // grid: ok status dot size from the design
                if !compact { Text(services.0).kitType(.label, Ink.text2).lineLimit(1) }
            }
            .fixedSize()
            .help(services.2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(services.2)
            Ink.line.frame(width: Metric.hairline, height: 16)
            if !compact { IconButton(.bolt, label: "Quick actions (⌘K)", kind: .toolbar) { model.paletteOpen = true } }
            IconButton(.terminal, label: model.terminals.sessions.isEmpty ? "No terminal sessions (⌘`)" : "\(model.terminals.running.count) terminal session\(model.terminals.running.count == 1 ? "" : "s") running (⌘`)", kind: .toolbar) {
                if model.terminals.visible.isEmpty, let product = model.currentProduct, product.hasLocal, !product.isDemo {
                    model.openTerminal(product)
                } else {
                    model.terminals.isVisible.toggle()
                }
            }
            .overlay(alignment: .topTrailing) {
                if !model.terminals.running.isEmpty {
                    Text("\(model.terminals.running.count)").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.onAccent)
                        .frame(minWidth: 14, minHeight: 14).background(Ink.accent, in: Circle())
                        .padding(.top, 2).allowsHitTesting(false)
                }
            }
            IconButton(.gauge, label: model.usagePanelVisible ? "Hide AI usage (⌘⇧U)" : "Show AI usage (⌘⇧U)", kind: .toolbar) { model.toggleUsagePanel() }
            IconButton(.bell, label: "\(model.attentionIncidents.count) alerts need attention", kind: .toolbar) { model.go(.activity) }
                .overlay(alignment: .topTrailing) {
                    if !model.attentionIncidents.isEmpty {
                        Circle().fill(Ink.err).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Ink.window, lineWidth: 2))
                            .padding(.top, Space.xs).padding(.trailing, Space.xs)
                            .allowsHitTesting(false)
                    }
                }
            primaryAction.fixedSize()
        }
        .padding(.leading, Space.md).padding(.trailing, Space.md)
    }

    /// One primary action, chosen by the page.
    @ViewBuilder private var primaryAction: some View {
        if let product = model.currentProduct, product.hasLocal, !product.isDemo {
            Button { model.openTerminal(product) } label: { Label { Text("Open Terminal") } icon: { Icon(.terminal, size: 12) } }
                .buttonStyle(.kit(.primary)).help("Open \(product.primaryCheckout?.name ?? "the checkout") in the terminal (⌘O)")
        } else if [.deployments, .git, .infrastructure, .leads, .activity].contains(model.route) {
            Button { model.refreshCurrentPage() } label: { Label { Text("Refresh") } icon: { Icon(.sync, size: 12) } }
                .buttonStyle(.kit(.primary)).help("Refresh this page (⌘R)")
        } else if model.route == .secrets {
            Button { model.sheet = .variable(VariableDraft()) } label: { Label { Text("Add Variable") } icon: { Icon(.plus, size: 12) } }
                .buttonStyle(.kit(.primary))
        } else {
            Button { model.sheet = .addProduct } label: { Label { Text("Add Product") } icon: { Icon(.plus, size: 12) } }
                .buttonStyle(.kit(.primary)).help("Add a product (⌘N)")
        }
    }
}

/// Local, Staging, Production. Production is drawn in its own color so it is never missed.
struct EnvironmentPicker: View {
    @Binding var selection: EnvironmentTier
    var tiers: [EnvironmentTier] = [.development, .staging, .production]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tiers, id: \.self) { tier in
                let on = tier == selection
                let prod = tier.isProduction
                Button { selection = tier } label: {
                    HStack(spacing: 6) { // grid: ok dot gap from the design
                        Dot(color: on && prod ? Ink.onProd : prod ? Ink.prod : tier == .staging ? Ink.accent : Ink.text3)
                        Text(tier.title).kitType(.labelMedium, on ? (prod ? Ink.onProd : Ink.text) : Ink.text2)
                    }
                    .padding(.horizontal, Space.sm).frame(height: 24)
                    .background(on ? (prod ? Ink.prod : Ink.panel) : .clear, in: RoundedRectangle(cornerRadius: Metric.rowRadius, style: .continuous))
                    .shadow(color: on && !prod ? Ink.shadow : .clear, radius: 1, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tier.title) context")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Ink.field, in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
        .fixedSize()
        .help("The environment that previews, variables, and actions are aimed at (⌘⇧E)")
    }
}

struct ProductionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.sm) {
            Icon(.alert, size: 12, weight: .semibold).foregroundStyle(Ink.prod)
            Text("Production context").kitType(.labelStrong, Ink.prod)
            Text("Variable previews and actions are aimed at live systems. Production actions ask for confirmation.").kitType(.label, Ink.text2).lineLimit(1)
            Spacer(minLength: Space.sm)
            Button("Switch to Staging") { model.context = .staging }.buttonStyle(.plain).font(KitType.labelMedium.font).foregroundStyle(Ink.prod)
            Kbd("⌘⇧E")
        }
        .padding(.horizontal, Space.lg).frame(height: 32)
        .background(Ink.prod.soft(0.11))
        .hairlineBelow(Ink.prod.opacity(0.28))
        .transition(.opacity)
    }
}

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: Space.sm) {
            Icon(.wifiOff, size: 12).foregroundStyle(Ink.warn)
            Text("Offline").kitType(.labelStrong, Ink.warn)
            Text("Local folders and Git state are current. Remote facts show their last known value and age.").kitType(.label, Ink.text2).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Space.lg).frame(height: 32)
        .background(Ink.warn.soft(0.1))
        .hairlineBelow(Ink.warn.opacity(0.25))
    }
}

enum DropImport {
    /// Folders dropped on the window open the Add Product sheet with those folders scanned.
    static func handle(_ providers: [NSItemProvider], model: AppModel) -> Bool {
        let group = DispatchGroup()
        let box = URLBox()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let folders = box.urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                guard !folders.isEmpty else { return }
                AddProductState.shared.pendingFolders = folders
                model.sheet = .addProduct
            }
        }
        return true
    }

    private final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var stored: [URL] = []
        nonisolated init() {}
        nonisolated func add(_ url: URL) { lock.withLock { stored.append(url) } }
        nonisolated var urls: [URL] { lock.withLock { stored } }
    }
}
