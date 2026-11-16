import ForgeDeckKit
import SwiftUI

// MARK: Environments

struct EnvironmentsTab: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                Text("Each environment is its own context: its own endpoints, hosts, and secrets.").kitType(.body, Ink.text2)
                Spacer()
                Button("Add Environment") { model.sheet = .environment(productID: product.id) }.buttonStyle(.kit(.secondary))
            }
            if product.environments.isEmpty {
                EmptyState(icon: .globe, title: "No environments yet", message: "Add Local, Staging, or Production to map this product to where it runs.",
                           cta: "Add Environment") { model.sheet = .environment(productID: product.id) }.card()
            }
            ForEach(product.environments) { environment in card(environment) }
        }
    }

    private func remove(_ change: @escaping (inout ProductEnvironment) -> Void, from environment: ProductEnvironment) {
        model.update(product.id) { product in
            if let index = product.environments.firstIndex(where: { $0.id == environment.id }) { change(&product.environments[index]) }
        }
    }

    private func card(_ environment: ProductEnvironment) -> some View {
        let evidence = DriftAnalyzer.evidence(environment: environment, product: product, cache: model.cache, now: model.now)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Icon(environment.tier.isProduction ? .globe : environment.tier == .development ? .laptop : .branch, size: 13)
                    .foregroundStyle(environment.tier.isProduction ? Ink.prod : Ink.text2)
                Text(environment.name).kitType(.section, environment.tier.isProduction ? Ink.prod : Ink.text)
                TagBadge(environment.tier.rawValue, tone: environment.tier.isProduction ? .prod : .muted)
                if !environment.domains.isEmpty { Text(environment.domains.joined(separator: ", ")).kitType(.monoSmall, Ink.text3).lineLimit(1) }
                Spacer()
                if environment.tier != .development {
                    Text(evidence.observation.map { $0.version ?? shortSHA($0.sha) } ?? (evidence.problem?.title ?? "Unknown")).kitType(.mono, Ink.text2)
                    SourceBadge(level: evidence.level, source: evidence.observation?.provenance.source.title, observedAt: evidence.observation?.provenance.observedAt,
                                isDemo: evidence.observation?.provenance.isDemo ?? false)
                }
                Menu {
                    Button("Add Version, Status, or Health Check…") { model.sheet = .probe(productID: product.id, environmentID: environment.id) }
                    Button("Add Metrics Source…") { model.sheet = .metricSource(productID: product.id, environmentID: environment.id) }
                    Button("Add SSH Host…") { model.sheet = .sshHost(productID: product.id, environmentID: environment.id) }
                    Divider()
                    Button("Remove Environment") {
                        model.sheet = .confirm(ConfirmRequest(title: "Remove \(environment.name)", message: "Removes this environment's checks, sources, and hosts from \(product.name). Nothing on any server changes.",
                                                              confirmLabel: "Remove") {
                            model.update(product.id) { $0.environments.removeAll { $0.id == environment.id } }
                        })
                    }
                } label: { Icon(.plus, size: 12) }
                .menuStyle(.button).buttonStyle(.kit(.icon)).menuIndicator(.hidden).fixedSize().disabled(product.isDemo)
                .accessibilityLabel("Add to \(environment.name)")
            }
            .padding(Space.lg)
            .background(environment.tier.isProduction ? Ink.prod.soft(0.06) : .clear)
            if environment.probes.isEmpty && environment.metricSources.isEmpty && environment.sshHosts.isEmpty && environment.githubEnvironmentName == nil {
                Text(environment.tier == .development ? "Nothing is connected. Local state comes from the checkouts under Development."
                     : "Nothing is connected, so what runs here is Unknown. Add a status endpoint for verified evidence, or map a GitHub environment for reported evidence.")
                    .kitType(.label, Ink.text2).padding(Space.lg).hairlineAbove()
            }
            if let name = environment.githubEnvironmentName, !name.isEmpty {
                ActionRow(icon: .branch, title: "GitHub environment \"\(name)\"", subtitle: "Deployment records give Reported evidence. They do not prove what is running.") {
                    Button("Unmap") { remove({ $0.githubEnvironmentName = nil }, from: environment) }.buttonStyle(.kit(.secondary, compact: true))
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
            }
            ForEach(environment.probes) { probe in
                let last = model.cache.health[probe.id]?.last
                ActionRow(icon: probe.kind == .companion ? .shield : probe.kind == .release ? .tag : .activity, tone: last == nil ? .muted : last!.ok ? .ok : .err,
                          title: probe.name.isEmpty ? probe.url : probe.name,
                          subtitle: "\(probe.kind == .companion ? "Status endpoint (verifies the running release)" : probe.kind == .release ? "Version URL (reads the running release)" : "Health check") · \(probe.url)\(probe.bearerVariableKey.map { " · token from \($0)" } ?? "")") {
                    ConnectionState(kind: last == nil ? .notConfigured : ConnectionState.kind(for: last!.problem),
                                    detail: last.map { $0.ok ? "\($0.latencyMS ?? 0) ms · \(RelativeTime.short($0.at, now: model.now))" : ($0.problem?.title ?? "Failing") } ?? "Not checked")
                    Button("Doctor") { model.sheet = .doctor(.probe(productID: product.id, environmentID: environment.id, probeID: probe.id)) }
                        .buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                    IconButton(.trash, label: "Remove \(probe.name)") { remove({ $0.probes.removeAll { $0.id == probe.id } }, from: environment) }.disabled(product.isDemo)
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
            }
            ForEach(environment.metricSources) { source in
                let state = model.cache.sync["metrics:\(source.id.uuidString)"]
                ActionRow(icon: .chart, tone: state?.lastProblem != nil ? .warn : state?.lastSuccess != nil ? .ok : .muted, title: source.name,
                          subtitle: "Metrics\(source.leadsEnabled ? " and leads" : "") · \(source.baseURL)") {
                    ConnectionState(kind: state == nil ? .notConfigured : state?.lastProblem == nil ? .connected : state?.lastSuccess != nil ? .stale : ConnectionState.kind(for: state?.lastProblem),
                                    detail: state.map { $0.lastProblem == nil ? "Reported \(RelativeTime.short($0.lastSuccess ?? .now, now: model.now))"
                                        : "\($0.lastProblem!.title) · last good \($0.lastSuccess.map { RelativeTime.short($0, now: model.now) } ?? "never")" } ?? "Not checked")
                    IconButton(.trash, label: "Remove \(source.name)") { remove({ $0.metricSources.removeAll { $0.id == source.id } }, from: environment) }
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
            }
            ForEach(environment.sshHosts) { host in
                ActionRow(icon: .infra, title: host.alias, subtitle: "SSH host\(host.releaseFilePath.map { " · release file \($0)" } ?? "") · read-only probes: \(host.allowedProbeIDs.joined(separator: ", "))", mono: true) {
                    Button("Doctor") { model.sheet = .doctor(.ssh(alias: host.alias)) }.buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                    Button("Connect") { model.openSSH(alias: host.alias, product: product) }.buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                    IconButton(.trash, label: "Remove \(host.alias)") { remove({ $0.sshHosts.removeAll { $0.id == host.id } }, from: environment) }.disabled(product.isDemo)
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
            }
        }
        .card(border: environment.tier.isProduction ? Ink.prod.opacity(0.38) : Ink.line)
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
    }
}

// MARK: Connections

struct ConnectionsList: View {
    @Environment(AppModel.self) private var model
    let products: [Product]
    var showsGitHub = true

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if showsGitHub { GitHubConnectionCard() }
            let rows = products.flatMap { product in product.environments.flatMap { environment in
                environment.probes.map { (product, environment, $0) }
            } }
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Endpoints", subtitle: "\(rows.count)").padding(Space.lg)
                if rows.isEmpty {
                    Text("No health checks or status endpoints yet. Add one from a product's Environments tab.").kitType(.label, Ink.text2)
                        .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
                }
                ForEach(rows, id: \.2.id) { product, environment, probe in
                    let samples = model.cache.health[probe.id] ?? []
                    let last = samples.last
                    ActionRow(icon: probe.kind == .companion ? .shield : probe.kind == .release ? .tag : .activity, tone: last == nil ? .muted : last!.ok ? .ok : .err,
                              title: "\(product.name) · \(environment.name) · \(probe.name.isEmpty ? "check" : probe.name)",
                              subtitle: "\(probe.kind == .companion ? "status:read" : probe.kind == .release ? "version" : "HTTP \(probe.expectedStatus)") · \(probe.url)") {
                        if product.isDemo { DemoBadge() }
                        ConnectionState(kind: last == nil ? .notConfigured : ConnectionState.kind(for: last!.problem),
                                        detail: last.map { $0.ok ? "OK \(RelativeTime.short($0.at, now: model.now))" : ($0.problem?.title ?? "Failing") })
                        Button("Doctor") { model.sheet = .doctor(.probe(productID: product.id, environmentID: environment.id, probeID: probe.id)) }
                            .buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
                }
            }
            .card()
            let sources = products.flatMap { product in product.environments.flatMap { environment in environment.metricSources.map { (product, environment, $0) } } }
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(title: "Metrics sources", subtitle: "\(sources.count)").padding(Space.lg)
                    ForEach(sources, id: \.2.id) { product, environment, source in
                        let state = model.cache.sync["metrics:\(source.id.uuidString)"]
                        ActionRow(icon: .chart, tone: state?.lastProblem != nil ? .warn : .ok, title: "\(product.name) · \(environment.name) · \(source.name)",
                                  subtitle: "metrics:read\(source.leadsEnabled ? ", leads:read" : "") · \(source.baseURL)") {
                            ConnectionState(kind: state?.lastProblem == nil ? (state == nil ? .notConfigured : .connected) : .stale,
                                            detail: state.map { $0.lastProblem?.title ?? "OK \(RelativeTime.short($0.lastSuccess ?? .now, now: model.now))" })
                        }
                        .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
                    }
                }
                .card()
            }
        }
    }
}

struct GitHubConnectionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let connection = model.githubConnection
        let problems = model.cache.remotes.values.compactMap(\.problem)
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                ToneIcon(icon: .branch, tone: connection == nil ? .muted : problems.contains(.unauthorized) ? .warn : .ok, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub").kitType(.bodyStrong)
                    Text(connection.map { "Signed in as \($0.accountIdentity) · token in the Keychain\($0.scopes.isEmpty ? " · fine-grained" : " · scopes: \($0.scopes.joined(separator: ", "))")" }
                         ?? "Not connected. Public repositories still work, with GitHub's lower anonymous rate limit.")
                        .kitType(.label, Ink.text2).lineLimit(2)
                }
                Spacer(minLength: Space.sm)
                ConnectionState(kind: connection == nil ? .notConfigured : problems.contains(.unauthorized) ? .needsAuth : problems.contains(.rateLimited) ? .stale : .connected,
                                detail: problems.contains(.rateLimited) ? "Rate limited" : nil)
                Button("Doctor") { model.sheet = .doctor(.github) }.buttonStyle(.kit(.secondary, compact: true))
                if connection != nil {
                    Button("Reconnect") { model.sheet = .connectGitHub }.buttonStyle(.kit(.secondary, compact: true))
                    Button("Disconnect") {
                        model.sheet = .confirm(ConfirmRequest(title: "Disconnect GitHub", message: "Deletes the token from the Keychain. Private repositories stop refreshing. Nothing changes on GitHub.",
                                                              confirmLabel: "Disconnect") { model.disconnectGitHub() })
                    }
                    .buttonStyle(.kit(.secondary, compact: true))
                } else {
                    Button("Connect") { model.sheet = .connectGitHub }.buttonStyle(.kit(.primary, compact: true))
                }
            }
            HStack(spacing: Space.xs) {
                Text("Reads").kitType(.meta, Ink.text3)
                ForEach(["Repositories", "Branches", "Pull requests", "Workflow runs", "Deployments", "Releases"], id: \.self) { Chip($0) }
                Spacer()
                Text("Read-only").kitType(.metaMedium, Ink.ok)
            }
        }
        .padding(Space.lg)
        .card()
    }
}

// MARK: Variables (shared by the product Secrets tab and the vault)

struct VariableRowView: View {
    @Environment(AppModel.self) private var model
    let variable: VariableDefinition

    private func draft() -> VariableDraft {
        var draft = VariableDraft()
        draft.existingID = variable.id
        draft.key = variable.key
        draft.scope = variable.scope
        draft.isSecret = variable.isSecret
        draft.value = variable.isSecret ? "" : (variable.plainValue ?? "")
        draft.origin = variable.credential?.origin ?? .keychain
        draft.locator = variable.credential?.origin == .keychain ? "" : (variable.credential?.locator ?? "")
        draft.allowedTiers = Set(variable.allowedTiers)
        draft.rotationDays = variable.credential?.rotationIntervalDays ?? 0
        draft.note = variable.note
        return draft
    }

    var body: some View {
        let credential = variable.credential
        let production = variable.allowedTiers.contains(.production)
        let due = credential?.rotationDue(now: model.now)
        let overdue = due.map { $0 <= model.now } ?? false
        HStack(spacing: Space.md) {
            ToneIcon(icon: variable.isSecret ? .key : .code, tone: production && variable.isSecret ? .prod : .muted)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.sm) {
                    Text(variable.key).kitType(.mono).lineLimit(1).fixedSize()
                    ForEach(variable.allowedTiers, id: \.self) { tier in TagBadge(tier.title, tone: tier.isProduction ? .prod : .muted) }
                    if overdue { TagBadge("Rotate", tone: .warn) }
                    if credential?.isExpired(now: model.now) == true { TagBadge("Expired", tone: .err) }
                }
                Text([variable.scope.title + scopeName, variable.isSecret ? (credential?.origin.title ?? "No credential") : "Plain value",
                      due.map { "rotate \(RelativeTime.short($0, now: model.now))" }, variable.note.isEmpty ? nil : variable.note]
                    .compactMap { $0 }.joined(separator: " · "))
                    .kitType(.meta, Ink.text3).lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            if variable.isSecret {
                // The value is shown only after a deliberate click, and never to assistive snapshots.
                Text(model.revealed[variable.id] ?? "••••••••••••").kitType(.mono, Ink.text2).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: model.revealed[variable.id] == nil ? 96 : 220, alignment: .trailing)
                    .accessibilityLabel(model.revealed[variable.id] == nil ? "Hidden secret" : "Secret value shown on screen")
                IconButton(model.revealed[variable.id] == nil ? .eye : .eyeSlash,
                           label: model.revealed[variable.id] == nil ? "Reveal for \(model.portfolio.settings.revealTimeoutSeconds) seconds\(production ? " (asks for Touch ID)" : "")" : "Hide") {
                    if model.revealed[variable.id] == nil { model.reveal(variable) } else { model.revealed[variable.id] = nil }
                }
                IconButton(.copy, label: "Copy the value\(production ? " (asks for Touch ID)" : ""). The clipboard is cleared afterwards.") { model.reveal(variable, copyOnly: true) }
            } else {
                Text(variable.plainValue ?? "").kitType(.mono, Ink.text2).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .trailing)
            }
            IconButton(.pencil, label: variable.isSecret ? "Edit or rotate \(variable.key)" : "Edit \(variable.key)") { model.sheet = .variable(draft()) }
            IconButton(.trash, label: "Delete \(variable.key)") {
                model.sheet = .confirm(ConfirmRequest(title: "Delete \(variable.key)", message: variable.isSecret ? "Removes the variable and deletes its Keychain item. This cannot be undone." : "Removes the variable.",
                                                      isProduction: production && variable.isSecret,
                                                      confirmLabel: production && variable.isSecret ? "Hold to Delete" : "Delete",
                                                      requiresHold: production && variable.isSecret) { model.deleteVariable(variable) })
            }
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
    }

    private var scopeName: String {
        switch variable.scope {
        case .global, .organization: ""
        case .product(let id): " · \(model.product(id)?.name ?? "?")"
        case .component(let id, let component): " · \(model.product(id)?.component(id: component)?.name ?? "?")"
        case .environment(let id, let environment): " · \(model.product(id)?.environment(id: environment)?.name ?? "?")"
        case .profile(let id, let profile): " · \(model.product(id)?.profiles.first { $0.id == profile }?.name ?? "?")"
        }
    }
}

struct ResolutionPreview: View {
    @Environment(AppModel.self) private var model
    let product: Product
    @Binding var tier: EnvironmentTier

    var body: some View {
        let resolved = model.resolved(for: product, tier: tier)
        InspectorPanel(title: "What a process would receive", subtitle: "\(product.name) · names and sources only") {
            VStack(alignment: .leading, spacing: Space.md) {
                EnvironmentPicker(selection: $tier, tiers: product.environments.map(\.tier))
                if product.environment(tier: tier) == nil {
                    Text("\(product.name) has no \(tier.title.lowercased()) environment.").kitType(.label, Ink.text2)
                } else if resolved.isEmpty {
                    Text("No variables are in scope here.").kitType(.label, Ink.text2)
                }
                ForEach(resolved) { variable in
                    HStack(alignment: .top, spacing: Space.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(variable.key).kitType(.mono).lineLimit(1)
                            Text(variable.note).kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Space.xs)
                        StatusPill(variable.state.title, tone: variable.state.delivers ? (variable.state == .overridden ? .accent : .ok)
                                                                 : variable.state == .blocked || variable.state == .expired ? .err : .warn)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Global < Organization < Product < Component < Environment < Profile. A secret is delivered only in the environments it lists.")
                    .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Two columns side by side when there is room, stacked when there is not.
struct AdaptiveColumns<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.lg) { content }
            VStack(alignment: .leading, spacing: Space.lg) { content }
        }
    }
}

struct VariablesPanel: View {
    @Environment(AppModel.self) private var model
    let product: Product
    @State private var tier: EnvironmentTier = .development

    var body: some View {
        let variables = model.portfolio.variables.filter { $0.scope.productID == product.id }.sorted { $0.key < $1.key }
        let inherited = model.portfolio.variables.filter { $0.scope.productID == nil }
        AdaptiveColumns {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Variables for \(product.name)", subtitle: "\(variables.count)") {
                    Button("Add Variable") {
                        var draft = VariableDraft()
                        draft.scope = product.environment(tier: model.context).map { .environment(product: product.id, environment: $0.id) } ?? .product(product.id)
                        draft.allowedTiers = [model.context]
                        model.sheet = .variable(draft)
                    }
                    .buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                }
                .padding(Space.lg)
                if variables.isEmpty {
                    EmptyState(icon: .key, title: "No variables yet", message: "Add API keys and settings this product's commands need. Secret values go to the macOS Keychain and are never written to disk by \(Brand.name).", compact: true)
                        .hairlineAbove()
                }
                ForEach(variables) { VariableRowView(variable: $0).hairlineAbove() }
                if !inherited.isEmpty {
                    Text("\(inherited.count) more inherited from Global or Organization scope. See them in the Secrets Vault.").kitType(.meta, Ink.text3)
                        .padding(Space.lg).hairlineAbove()
                }
            }
            .card()
            .frame(minWidth: 520, maxWidth: .infinity)
            ResolutionPreview(product: product, tier: $tier).frame(minWidth: 320)
        }
        .onAppear { tier = product.environment(tier: model.context) != nil ? model.context : (product.environments.first?.tier ?? .development) }
    }
}

// MARK: Actions

struct ActionsTab: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if product.isArchived { ErrorState(title: "Archived", detail: "Actions are disabled for archived products.") }
            RecipeList(product: product)
            ProfileList(product: product)
        }
    }
}

struct RecipeList: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Action recipes", subtitle: "Only approved recipes run") {
                if product.checkouts.contains(where: { MobileRecipes.inspect($0.path) != nil }) {
                    Button("Suggest Mobile Recipes") { model.suggestMobileRecipes(product) }
                        .buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                        .help("Reads the Capacitor or Xcode project and the simulators on this Mac, and adds recipes for you to review")
                }
                Button("Add Recipe") { model.sheet = .recipe(productID: product.id, recipeID: nil) }.buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
            }
            .padding(Space.lg)
            if product.recipes.isEmpty {
                EmptyState(icon: .play, title: "No recipes yet", message: "A recipe is a reviewed command: a program, its arguments, a folder, and the variables it may receive. Detected commands appear here as suggestions.", compact: true)
                    .hairlineAbove()
            }
            ForEach(product.recipes) { recipe in
                let environment = product.environment(id: recipe.environmentID)
                let command = recipe.executor == .openURL ? (recipe.url ?? "") : recipe.executor == .ssh ? "ssh \(recipe.sshAlias ?? "?"): \(SSHProbeCommand.find(recipe.executable)?.title ?? recipe.executable)"
                    : recipe.steps.map(ShellQuote.join).joined(separator: " → ")
                ActionRow(icon: recipe.executor == .openURL ? .external : recipe.executor == .ssh ? .infra : .play,
                          tone: recipe.safety == .productionCritical ? .prod : recipe.safety == .remoteWrite ? .warn : .muted,
                          title: recipe.label, subtitle: "\(command)\(environment.map { " · \($0.name)" } ?? "")\(recipe.variableKeys.isEmpty ? "" : " · receives \(recipe.variableKeys.joined(separator: ", "))")") {
                    TagBadge(recipe.safety.title, tone: recipe.safety == .productionCritical ? .prod : recipe.safety == .remoteWrite ? .warn : .muted)
                    if recipe.isApproved {
                        Button(recipe.opensInTerminal ? "Run in Terminal" : "Run") { model.run(recipe, in: product) }
                            .buttonStyle(.kit(recipe.safety == .productionCritical ? .production : .secondary, compact: true))
                            .disabled(product.isDemo || product.isArchived)
                    } else {
                        TagBadge("Suggested", tone: .accent)
                        Button("Approve") {
                            model.update(product.id) { product in
                                if let index = product.recipes.firstIndex(where: { $0.id == recipe.id }) { product.recipes[index].isApproved = true }
                            }
                            model.record("recipe.approve", product: product, detail: "recipe=\(recipe.label)")
                        }
                        .buttonStyle(.kit(.secondary, compact: true)).help("Review the command first. Approving lets it run on this Mac.")
                    }
                    IconButton(.pencil, label: "Edit \(recipe.label)") { model.sheet = .recipe(productID: product.id, recipeID: recipe.id) }
                    IconButton(.trash, label: "Delete \(recipe.label)") { model.update(product.id) { $0.recipes.removeAll { $0.id == recipe.id } } }
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
            }
        }
        .card()
    }
}

struct ProfileList: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Terminal profiles", subtitle: "What `\(Brand.cliName) exec` may start, and with which variables") {
                Button("Add Profile") { model.sheet = .profile(productID: product.id, profileID: nil) }.buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
            }
            .padding(Space.lg)
            if product.profiles.isEmpty {
                EmptyState(icon: .terminal, title: "No profiles yet", message: "A profile names the programs a terminal command may start and the variables it may receive, for one environment.", compact: true)
                    .hairlineAbove()
            }
            ForEach(product.profiles) { profile in
                let environment = product.environment(id: profile.environmentID)
                let command = "\(Brand.cliName) exec --product \(product.slug) --environment \(environment?.tier.rawValue ?? "development") --profile \(ShellQuote.quote(profile.name)) -- \(profile.allowedExecutables.first ?? "<program>")"
                VStack(alignment: .leading, spacing: Space.xs) {
                    ActionRow(icon: .terminal, tone: environment?.tier.isProduction == true ? .prod : .muted, title: profile.name,
                              subtitle: "\(environment?.name ?? "Any environment") · programs: \(profile.allowedExecutables.isEmpty ? "none" : profile.allowedExecutables.joined(separator: ", ")) · variables: \(profile.variableAllowlist.isEmpty ? "none" : profile.variableAllowlist.joined(separator: ", "))") {
                        IconButton(.pencil, label: "Edit \(profile.name)") { model.sheet = .profile(productID: product.id, profileID: profile.id) }
                        IconButton(.trash, label: "Delete \(profile.name)") { model.update(product.id) { $0.profiles.removeAll { $0.id == profile.id } } }
                    }
                    CopyableValue(value: command).padding(.leading, 36)
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.sm).hairlineAbove()
            }
        }
        .card()
    }
}

// MARK: Activity

struct IncidentRow: View {
    @Environment(AppModel.self) private var model
    let incident: Incident

    var body: some View {
        let product = model.product(incident.productID)
        ActionRow(icon: incident.isOpen ? .alert : .check, tone: !incident.isOpen ? .ok : incident.acknowledgedAt != nil ? .muted : .err,
                  title: incident.title, subtitle: "\(product?.name ?? "Portfolio") · \(incident.detail)") {
            if incident.isDemo { DemoBadge() }
            Text(incident.isOpen ? "Opened \(RelativeTime.short(incident.openedAt, now: model.now))" : "Resolved \(RelativeTime.short(incident.resolvedAt ?? .now, now: model.now))")
                .kitType(.meta, Ink.text3)
            if incident.isOpen {
                if incident.acknowledgedAt != nil {
                    TagBadge("Acknowledged")
                } else if let until = incident.snoozedUntil, until > model.now {
                    TagBadge("Snoozed")
                } else {
                    Button("Acknowledge") { model.acknowledge(incident) }.buttonStyle(.kit(.secondary, compact: true))
                    Menu("Snooze") {
                        Button("1 hour") { model.snooze(incident, hours: 1) }
                        Button("8 hours") { model.snooze(incident, hours: 8) }
                        Button("24 hours") { model.snooze(incident, hours: 24) }
                    }
                    .menuStyle(.button).buttonStyle(.kit(.secondary, compact: true)).fixedSize()
                }
            }
            if let product { IconButton(.chevronRight, label: "Open \(product.name)") { model.open(product, tab: .development) } }
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.xs)
    }
}

struct ProductActivityTab: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let incidents = model.cache.incidents.filter { $0.productID == product.id }.sorted { $0.openedAt > $1.openedAt }
        let events = model.cache.activity.filter { $0.productID == product.id }
        VStack(alignment: .leading, spacing: Space.lg) {
            if !incidents.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(title: "Alerts", subtitle: "\(incidents.filter(\.isOpen).count) open").padding(Space.lg)
                    ForEach(incidents.prefix(10)) { IncidentRow(incident: $0).hairlineAbove() }
                }
                .card()
            }
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Events", subtitle: "\(events.count)").padding(Space.lg)
                if events.isEmpty {
                    EmptyState(icon: .activity, title: "A quiet stretch", message: "No events for \(product.name) yet. Commits, deploys, alerts, and leads appear here as sources report them.", compact: true)
                        .hairlineAbove()
                }
                ForEach(events.prefix(60)) { event in
                    ActivityRow(event: event, productName: nil, now: model.now).padding(.horizontal, Space.lg).padding(.vertical, Space.sm).hairlineAbove()
                }
            }
            .card()
        }
    }
}

// MARK: Product settings

struct ProductSettingsTab: View {
    @Environment(AppModel.self) private var model
    let product: Product
    @State private var name = ""
    @State private var tagline = ""
    @State private var group = ""
    @State private var tags = ""
    @State private var notes = ""
    @State private var linkLabel = ""
    @State private var linkURL = ""

    private func saveDetails() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.show("A product needs a name.", isError: true) }
        model.update(product.id) { product in
            product.name = trimmed
            product.tagline = tagline
            product.group = group.trimmingCharacters(in: .whitespaces).isEmpty ? "Products" : group.trimmingCharacters(in: .whitespaces)
            product.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            product.notes = notes
            product.monogram = Monogram.make(trimmed)
        }
        model.show("Saved")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if product.isDemo { ErrorState(title: "Demo product", detail: "This product comes from a fixture. Remove the demo products in Settings > Data.") }
            VStack(alignment: .leading, spacing: Space.md) {
                CardHeader(title: "Details")
                HStack(alignment: .top, spacing: Space.lg) {
                    LabeledField(label: "Name") { KitField(placeholder: "Name", text: $name) }
                    LabeledField(label: "Group", hint: "The sidebar section") { KitField(placeholder: "Products", text: $group) }
                }
                LabeledField(label: "Description") { KitField(placeholder: "What it is, in one line", text: $tagline) }
                LabeledField(label: "Tags", hint: "Separate with commas") { KitField(placeholder: "saas, client", text: $tags) }
                LabeledField(label: "Notes") {
                    TextEditor(text: $notes).font(KitType.body.font).scrollContentBackground(.hidden).padding(Space.xs)
                        .frame(height: 72).background(Ink.field, in: RoundedRectangle(cornerRadius: Metric.controlRadius))
                }
                HStack {
                    LabeledField(label: "Lifecycle") {
                        SegmentedPill(options: Lifecycle.allCases.map { ($0, $0.title) },
                                      selection: Binding(get: { product.lifecycle }, set: { value in model.update(product.id) { $0.lifecycle = value } }))
                    }
                    Spacer()
                    Text("CLI name").kitType(.label, Ink.text3)
                    CopyableValue(value: product.slug)
                    Button("Save Details") { saveDetails() }.buttonStyle(.kit(.primary)).disabled(product.isDemo)
                }
                if product.isArchived {
                    Text("Archived: history is kept, polling and actions are off.").kitType(.label, Ink.text2)
                }
            }
            .padding(Space.lg).card()

            VStack(alignment: .leading, spacing: Space.sm) {
                CardHeader(title: "Links", subtitle: "Site, dashboards, runbooks")
                ForEach(product.links) { link in
                    ActionRow(icon: .link, title: link.label, subtitle: link.url) {
                        Button("Open") { model.openLink(link.url) }.buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                        IconButton(.trash, label: "Remove \(link.label)") { model.update(product.id) { $0.links.removeAll { $0.id == link.id } } }
                    }
                }
                HStack(spacing: Space.sm) {
                    KitField(placeholder: "Label", text: $linkLabel).frame(width: 160)
                    KitField(placeholder: "https://…", text: $linkURL, monospaced: true)
                    Button("Add Link") {
                        do {
                            _ = try URLPolicy.validate(linkURL)
                            model.update(product.id) { $0.links.append(ProductLink(label: linkLabel.isEmpty ? "Link" : linkLabel, url: linkURL, kind: .dashboard)) }
                            linkLabel = ""
                            linkURL = ""
                        } catch {
                            model.show(String(describing: error), isError: true)
                        }
                    }
                    .buttonStyle(.kit(.secondary)).disabled(linkURL.isEmpty || product.isDemo)
                }
            }
            .padding(Space.lg).card()

            VStack(alignment: .leading, spacing: Space.sm) {
                CardHeader(title: "Components", subtitle: "\(product.components.count)")
                if product.components.isEmpty { Text("Components appear when you link folders or repositories.").kitType(.label, Ink.text2) }
                ForEach(product.components) { component in
                    ActionRow(icon: .projects, title: component.name, subtitle: ([component.kind.title] + component.stack).joined(separator: " · ")) {
                        Menu(component.kind.title) {
                            ForEach(ComponentKind.allCases, id: \.self) { kind in
                                Button(kind.title) {
                                    model.update(product.id) { product in
                                        if let index = product.components.firstIndex(where: { $0.id == component.id }) { product.components[index].kind = kind }
                                    }
                                }
                            }
                        }
                        .menuStyle(.button).buttonStyle(.kit(.secondary, compact: true)).fixedSize()
                    }
                }
            }
            .padding(Space.lg).card()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove \(product.name)").kitType(.bodyMedium)
                    Text("Removes it from \(Brand.name) with its cached observations and its scoped secrets. Folders, repositories, and servers are not touched. Rename it or change its group from the sidebar too.").kitType(.label, Ink.text2)
                }
                Spacer()
                Button("Remove Product…") { model.confirmRemove(product) }
                .buttonStyle(.kit(.secondary))
            }
            .padding(Space.lg).card()
        }
        .onAppear {
            name = product.name
            tagline = product.tagline
            group = product.group
            tags = product.tags.joined(separator: ", ")
            notes = product.notes
        }
    }
}
