import AppKit
import ForgeDeckKit
import SwiftUI

// MARK: Add Product

@Observable
final class AddProductState {
    static let shared = AddProductState()
    /// Folders dropped on the window, waiting for the sheet to scan them.
    var pendingFolders: [URL] = []
}

struct AddProductSheet: View {
    enum Mode: String, CaseIterable { case local = "Local Folder", github = "GitHub Repository", server = "Server / SSH", manual = "Manual" }

    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .local
    @State private var group = ""
    // Local
    @State private var proposals: [ImportProposal] = []
    @State private var scanning = false
    @State private var scanNote = ""
    @State private var scanTask: Task<Void, Never>?
    // GitHub
    @State private var repoURL = ""
    @State private var organization = ""
    @State private var listings: [GitHubConnector.RepositoryListing] = []
    @State private var chosen: Set<Int> = []
    @State private var listNote = ""
    @State private var listing = false
    @State private var listFilter = ""
    // Server
    @State private var alias = ""
    @State private var serverName = ""
    @State private var tier: EnvironmentTier = .production
    // Manual
    @State private var name = ""

    private func finish(_ ids: [UUID], message: String) {
        model.sheet = nil
        model.show(message)
        if ids.count == 1, let product = model.product(ids[0]) { model.open(product) } else if !ids.isEmpty { model.go(.projects) }
        for id in ids { if let product = model.product(id) { Task { await model.refresh(product, announce: false) } } }
    }

    private func scan(_ roots: [URL]) {
        scanTask?.cancel()
        scanning = true
        scanNote = ""
        let portfolio = model.portfolio
        scanTask = Task {
            var found: [DiscoveredProject] = []
            var limited = false
            for root in roots {
                let result = await Task.detached { await ProjectDiscovery().scan(root: root) }.value
                found += result.projects
                limited = limited || result.hitLimit
                if Task.isCancelled { break }
            }
            var seen = Set<String>()
            found = found.filter { seen.insert($0.path).inserted }
            proposals = ImportPlanner.plan(found, portfolio: portfolio)
            scanning = false
            scanNote = Task.isCancelled ? "Scan cancelled." : found.isEmpty ? "No projects were found in the chosen folders."
                : "\(found.count) found\(limited ? ". The scan stopped at its limit: choose a narrower folder to see the rest." : ".")"
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Scan"
        panel.message = "Choose project folders, or a folder that holds several. Only project metadata is read. Files that hold secrets are never opened."
        if panel.runModal() == .OK { scan(panel.urls) }
    }

    var body: some View {
        SheetPanel(width: 640) {
            SheetHeader(icon: .plus, title: "Add Product", message: "Everything is read-only until you approve it. Nothing is saved before you press Add.")
            VStack(alignment: .leading, spacing: Space.md) {
                SegmentedPill(options: Mode.allCases.map { ($0, $0.rawValue) }, selection: $mode, stretch: true)
                Group {
                    switch mode {
                    case .local: local
                    case .github: github
                    case .server: server
                    case .manual: manual
                    }
                }
                .frame(minHeight: 260, alignment: .top)
                LabeledField(label: "Sidebar group") { KitField(placeholder: "Products", text: $group) }
            }
            .padding(.horizontal, Space.xl)
            SheetFooter(note: footnote) {
                Button("Cancel") { scanTask?.cancel(); model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button(addLabel) { add() }.buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction).disabled(!canAdd)
            }
        }
        .onAppear {
            let pending = AddProductState.shared.pendingFolders
            if !pending.isEmpty {
                AddProductState.shared.pendingFolders = []
                scan(pending)
            }
        }
    }

    private var footnote: String {
        switch mode {
        case .local: "Skips node_modules, .venv, vendor, build folders, and symlinks."
        case .github: "Cloning is a separate step you start yourself."
        case .server: "Keys stay with your SSH agent. Host keys are always checked."
        case .manual: "Add folders, repositories, and environments later."
        }
    }

    private var selectedProposals: [ImportProposal] { proposals.filter(\.isSelected) }

    private var addLabel: String {
        switch mode {
        case .local: "Add \(selectedProposals.count)"
        case .github: chosen.isEmpty ? "Add Repository" : "Add \(chosen.count)"
        case .server: "Add Server"
        case .manual: "Add Product"
        }
    }

    private var canAdd: Bool {
        switch mode {
        case .local: !selectedProposals.isEmpty && !scanning
        case .github: !chosen.isEmpty || RepositoryURL.parse(repoURL) != nil
        case .server: SSHConfig.isValidAlias(alias)
        case .manual: !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func add() {
        switch mode {
        case .local:
            let ids = model.applyImport(selectedProposals, group: group)
            finish(Array(Set(ids)), message: "Added \(selectedProposals.count) project\(selectedProposals.count == 1 ? "" : "s")")
        case .github:
            var ids: [UUID] = []
            if let url = RepositoryURL.parse(repoURL) { ids.append(model.addRepository(url, original: repoURL, group: group).id) }
            for item in listings where chosen.contains(item.id) {
                if let url = RepositoryURL.parse(item.webURL) { ids.append(model.addRepository(url, original: item.sshURL, group: group).id) }
            }
            finish(Array(Set(ids)), message: "Added \(Set(ids).count) repositor\(Set(ids).count == 1 ? "y" : "ies")")
        case .server:
            finish([model.addServer(alias: alias, name: serverName, group: group, tier: tier).id], message: "Added \(serverName.isEmpty ? alias : serverName)")
        case .manual:
            finish([model.addManual(name: name.trimmingCharacters(in: .whitespaces), group: group).id], message: "Added \(name)")
        }
    }

    private var local: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Button("Choose Folders…") { chooseFolders() }.buttonStyle(.kit(.secondary))
                if scanning {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").kitType(.label, Ink.text2)
                    Button("Stop") { scanTask?.cancel() }.buttonStyle(.kit(.secondary, compact: true))
                } else {
                    Text(scanNote.isEmpty ? "Or drop folders onto the window." : scanNote).kitType(.label, Ink.text2)
                }
            }
            if proposals.isEmpty && !scanning {
                EmptyState(icon: .projects, title: "Choose where your projects live", message: "Git repositories, worktrees, and folders with a package.json, composer.json, pyproject.toml, Package.swift, Dockerfile, or a WordPress plugin header are recognized.", compact: true)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($proposals) { $proposal in
                            HStack(spacing: Space.sm) {
                                Toggle("", isOn: $proposal.isSelected).toggleStyle(.checkbox).labelsHidden()
                                    .accessibilityLabel("Include \(proposal.project.name)")
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: Space.xs) {
                                        Text(proposal.project.name).kitType(.labelMedium).lineLimit(1)
                                        if proposal.project.isWorktree { TagBadge("Worktree", tone: .accent) }
                                        if !proposal.project.isGitRepository { TagBadge("No Git") }
                                        ForEach(proposal.project.metadata.stack.prefix(3), id: \.self) { Chip($0) }
                                    }
                                    Text(abbreviate(proposal.project.path)).kitType(.monoSmall, Ink.text3).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: Space.sm)
                                Text(actionLabel(proposal.action)).kitType(.meta, Ink.text2).lineLimit(1)
                            }
                            .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                            .hairlineAbove()
                        }
                    }
                }
                .frame(height: 200)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous).strokeBorder(Ink.line, lineWidth: Metric.hairline))
            }
        }
    }

    private func actionLabel(_ action: ImportProposal.Action) -> String {
        switch action {
        case .createProduct: "New product"
        case .addCheckout(let id): "Adds a checkout to \(model.product(id)?.name ?? "a product")"
        case .refresh(let id, _): "Already in \(model.product(id)?.name ?? "a product"): refreshes metadata"
        }
    }

    private var github: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            LabeledField(label: "Repository URL", hint: RepositoryURL.parse(repoURL).map { "\($0.owner)/\($0.name) on \($0.host)" } ?? "https://github.com/owner/repo, git@github.com:owner/repo.git, or owner/repo") {
                KitField(placeholder: "owner/repo", text: $repoURL, icon: .branch, monospaced: true)
            }
            HStack(spacing: Space.sm) {
                KitField(placeholder: "Organization (blank for your account)", text: $organization).frame(width: 260)
                Button(listing ? "Listing…" : "List Repositories") {
                    listing = true
                    listNote = ""
                    Task {
                        let connector = GitHubConnector(token: await model.engine.githubToken(model.portfolio))
                        let result = await connector.repositories(organization: organization.isEmpty ? nil : organization)
                        listings = result.value ?? []
                        listNote = result.problem.map { $0 == .unauthorized ? "Connect GitHub first to list your repositories." : result.detail }
                            ?? "\(listings.count) repositories\(result.detail.isEmpty ? "" : " · \(result.detail)")"
                        listing = false
                    }
                }
                .buttonStyle(.kit(.secondary)).disabled(listing)
                if model.githubConnection == nil {
                    Button("Connect GitHub…") { model.sheet = .connectGitHub }.buttonStyle(.kit(.link))
                }
            }
            if !listNote.isEmpty { Text(listNote).kitType(.label, Ink.text2) }
            if !listings.isEmpty {
                KitField(placeholder: "Filter", text: $listFilter, icon: .search)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(listings.filter { listFilter.isEmpty || "\($0.owner)/\($0.name)".lowercased().contains(listFilter.lowercased()) }) { item in
                            let known = model.products.contains { $0.repositories.contains { $0.owner.lowercased() == item.owner.lowercased() && $0.name.lowercased() == item.name.lowercased() } }
                            HStack(spacing: Space.sm) {
                                Toggle("", isOn: Binding(get: { chosen.contains(item.id) }, set: { if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) } }))
                                    .toggleStyle(.checkbox).labelsHidden().disabled(known).accessibilityLabel("Include \(item.name)")
                                Text("\(item.owner)/\(item.name)").kitType(.mono).lineLimit(1)
                                if item.isPrivate { TagBadge("Private") }
                                if item.isArchived { TagBadge("Archived") }
                                if known { TagBadge("Already added", tone: .accent) }
                                Spacer(minLength: Space.sm)
                                Text(item.language ?? "").kitType(.meta, Ink.text3)
                            }
                            .padding(.horizontal, Space.md).padding(.vertical, Space.xs)
                            .hairlineAbove()
                        }
                    }
                }
                .frame(height: 120)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous).strokeBorder(Ink.line, lineWidth: Metric.hairline))
            }
        }
    }

    private var server: some View {
        let hosts = SSHConfig.load()
        return VStack(alignment: .leading, spacing: Space.md) {
            LabeledField(label: "Host alias", hint: hosts.isEmpty ? "No hosts were found in ~/.ssh/config. Type an alias or a host name ssh can resolve." : "From your ~/.ssh/config. \(Brand.name) does not copy or read keys.") {
                HStack(spacing: Space.sm) {
                    KitField(placeholder: "my-server", text: $alias, icon: .infra, monospaced: true)
                    if !hosts.isEmpty {
                        Menu("Choose") { ForEach(hosts) { host in Button(host.alias) { alias = host.alias } } }
                            .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
                    }
                }
            }
            LabeledField(label: "Product name") { KitField(placeholder: alias.isEmpty ? "Name" : alias, text: $serverName) }
            LabeledField(label: "This host is") {
                SegmentedPill(options: [(.staging, "Staging"), (.production, "Production"), (.custom, "Other")], selection: $tier)
            }
            Text("After adding, run the Connection Doctor: it checks the host key in known_hosts and never accepts a new one for you.").kitType(.label, Ink.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manual: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            LabeledField(label: "Name", hint: "An idea with nothing connected yet is fine.") { KitField(placeholder: "Product name", text: $name) }
        }
    }
}

// MARK: Variable

struct VariableSheet: View {
    @Environment(AppModel.self) private var model
    @State var draft: VariableDraft
    @State private var error: String?
    @State private var scopeKind = "Global"
    @State private var productID: UUID?
    @State private var environmentID: UUID?

    private func applyScope() {
        let product = model.product(productID)
        switch scopeKind {
        case "Organization": draft.scope = .organization(model.portfolio.organizations.first?.id ?? UUID())
        case "Product": if let product { draft.scope = .product(product.id) }
        case "Environment":
            if let product, let environment = product.environment(id: environmentID) ?? product.environments.first {
                draft.scope = .environment(product: product.id, environment: environment.id)
                environmentID = environment.id
                // An environment-scoped value belongs to that environment only.
                draft.allowedTiers = [environment.tier]
            }
        default: draft.scope = .global
        }
    }

    var body: some View {
        let editing = draft.existingID != nil
        SheetPanel(width: 560, stripe: draft.isSecret && draft.allowedTiers.contains(.production) ? Ink.prod : nil) {
            SheetHeader(icon: .key, tone: draft.allowedTiers.contains(.production) && draft.isSecret ? .prod : .accent,
                        title: editing ? (draft.isSecret ? "Edit or Rotate \(draft.key)" : "Edit \(draft.key)") : "Add Variable",
                        message: "A secret's value goes to the macOS Keychain. \(Brand.name) keeps only its name, scope, and a reference.")
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top, spacing: Space.md) {
                    LabeledField(label: "Name") { KitField(placeholder: "STRIPE_SECRET_KEY", text: $draft.key, monospaced: true) }
                    LabeledField(label: "Kind") {
                        SegmentedPill(options: [(true, "Secret"), (false, "Plain")], selection: $draft.isSecret)
                    }
                    .fixedSize()
                }
                if draft.isSecret {
                    LabeledField(label: "Stored in") {
                        SegmentedPill(options: [(.keychain, "Keychain"), (.onePassword, "1Password CLI"), (.environmentReference, "Environment variable")], selection: $draft.origin)
                    }
                    switch draft.origin {
                    case .keychain:
                        LabeledField(label: editing ? "New value" : "Value", hint: editing ? "Leave empty to keep the current value. Entering a value rotates the secret." : nil) {
                            KitField(placeholder: editing ? "Unchanged" : "Paste the secret", text: $draft.value, secure: true, monospaced: true)
                        }
                    case .onePassword:
                        LabeledField(label: "1Password reference", hint: ExecutableLocator.find("op") == nil ? "The op CLI is not installed on this Mac, so this reference cannot be read yet." : "Read with `op read` when a command needs it.") {
                            KitField(placeholder: "op://vault/item/field", text: $draft.locator, monospaced: true)
                        }
                    default:
                        LabeledField(label: "Environment variable name", hint: "Read from \(Brand.name)'s own environment when a command needs it.") {
                            KitField(placeholder: "MY_TOKEN", text: $draft.locator, monospaced: true)
                        }
                    }
                } else {
                    LabeledField(label: "Value", hint: "Stored in \(Brand.name)'s settings file. Do not put a secret here.") {
                        KitField(placeholder: "Value", text: $draft.value, monospaced: true)
                    }
                }
                HStack(alignment: .top, spacing: Space.md) {
                    LabeledField(label: "Scope") {
                        SegmentedPill(options: ["Global", "Organization", "Product", "Environment"].map { ($0, $0) }, selection: $scopeKind)
                    }
                    .fixedSize()
                    if scopeKind == "Product" || scopeKind == "Environment" {
                        LabeledField(label: "Product") {
                            Menu(model.product(productID)?.name ?? "Choose") {
                                ForEach(model.activeProducts.filter { !$0.isDemo }) { product in Button(product.name) { productID = product.id; environmentID = nil; applyScope() } }
                            }
                            .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
                        }
                    }
                    if scopeKind == "Environment", let product = model.product(productID) {
                        LabeledField(label: "Environment") {
                            Menu(product.environment(id: environmentID)?.name ?? "Choose") {
                                ForEach(product.environments) { environment in Button(environment.name) { environmentID = environment.id; applyScope() } }
                            }
                            .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
                        }
                    }
                }
                LabeledField(label: "May be used in", hint: draft.isSecret && draft.allowedTiers.contains(.production) && draft.allowedTiers.count > 1
                             ? "This secret would reach production and other environments. Use one secret per environment." : "A value is delivered only in the environments checked here.") {
                    HStack(spacing: Space.md) {
                        ForEach([EnvironmentTier.development, .staging, .production, .preview], id: \.self) { tier in
                            Toggle(tier.title, isOn: Binding(get: { draft.allowedTiers.contains(tier) },
                                                             set: { if $0 { draft.allowedTiers.insert(tier) } else { draft.allowedTiers.remove(tier) } }))
                                .toggleStyle(.checkbox).font(KitType.label.font)
                                .disabled(scopeKind == "Environment")
                        }
                    }
                }
                if draft.isSecret {
                    LabeledField(label: "Rotation reminder") {
                        SegmentedPill(options: [(0, "Off"), (30, "30 days"), (90, "90 days"), (180, "180 days")], selection: $draft.rotationDays)
                    }
                }
                LabeledField(label: "Note") { KitField(placeholder: "What it is for", text: $draft.note) }
                if let error { ErrorState(title: "Not saved", detail: error) }
            }
            .padding(.horizontal, Space.xl)
            SheetFooter(note: draft.isSecret ? "Readable only while this Mac is unlocked. Not synced to iCloud." : "") {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button(editing ? "Save" : "Add Variable") {
                    applyScope()
                    if (scopeKind == "Product" || scopeKind == "Environment") && model.product(productID) == nil {
                        error = "Choose a product for this scope."
                        return
                    }
                    guard !draft.allowedTiers.isEmpty else { error = "Check at least one environment."; return }
                    error = model.saveVariable(draft)
                    if error == nil {
                        model.sheet = nil
                        model.show(editing ? "Saved \(draft.key)" : "Added \(draft.key)")
                    }
                }
                .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            scopeKind = draft.scope.title == "Component" || draft.scope.title == "Profile" ? "Product" : draft.scope.title
            productID = draft.scope.productID ?? model.currentProduct?.id
            if case .environment(_, let environment) = draft.scope { environmentID = environment }
        }
    }
}

// MARK: Environment pieces

private func updateEnvironment(_ model: AppModel, _ productID: UUID, _ environmentID: UUID, _ change: (inout ProductEnvironment) -> Void) {
    model.update(productID) { product in
        if let index = product.environments.firstIndex(where: { $0.id == environmentID }) { change(&product.environments[index]) }
    }
}

struct TokenPicker: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    @Binding var key: String

    var body: some View {
        let keys = Array(Set(model.portfolio.variables.filter { $0.isSecret && ($0.scope.productID == nil || $0.scope.productID == productID) }.map(\.key))).sorted()
        LabeledField(label: "Bearer token", hint: keys.isEmpty ? "No secret variables yet. Add the token in this product's Secrets tab, then choose it here." : "The variable's value is sent as an Authorization header. It must be allowed in this environment.") {
            Menu(key.isEmpty ? "None" : key) {
                Button("None") { key = "" }
                Divider()
                ForEach(keys, id: \.self) { name in Button(name) { key = name } }
            }
            .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize().accessibilityLabel("Token variable: \(key.isEmpty ? "none" : key)")
        }
    }
}

struct ProbeSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    let environmentID: UUID
    @State private var kind: ProbeConfig.Kind = .release
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        let environment = model.product(productID)?.environment(id: environmentID)
        SheetPanel(width: 540) {
            SheetHeader(icon: .shield, title: "Add a Check to \(environment?.name ?? "Environment")",
                        message: "Pick what the site can tell you. A version URL or status endpoint proves which release is running; a health check only proves the URL answers.")
            VStack(alignment: .leading, spacing: Space.md) {
                SegmentedPill(options: [(.release, "Version URL"), (.companion, "Status endpoint"), (.health, "Health check")], selection: $kind, stretch: true)
                Text(kindHelp).kitType(.meta, Ink.text2).fixedSize(horizontal: false, vertical: true)
                LabeledField(label: "Name") { KitField(placeholder: defaultName, text: $name) }
                LabeledField(label: "URL", hint: urlHint) {
                    KitField(placeholder: urlPlaceholder, text: $url, icon: .link, monospaced: true)
                }
                if kind != .release { TokenPicker(productID: productID, key: $token) }
                if let error { ErrorState(title: "Not added", detail: error) }
            }
            .padding(.horizontal, Space.xl)
            SheetFooter(note: "Read-only GET requests. Redirects to another host are refused.") {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button("Add Check") {
                    if kind == .release { token = "" }
                    do {
                        _ = try URLPolicy.validate(url)
                        var probe = ProbeConfig()
                        probe.kind = kind
                        probe.name = name.isEmpty ? defaultName : name
                        probe.url = url.trimmingCharacters(in: .whitespaces)
                        probe.bearerVariableKey = token.isEmpty ? nil : token
                        updateEnvironment(model, productID, environmentID) { $0.probes.append(probe) }
                        model.sheet = nil
                        if let product = model.product(productID) { Task { await model.refresh(product) } }
                    } catch {
                        self.error = String(describing: error)
                    }
                }
                .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction).disabled(url.isEmpty)
            }
        }
    }

    private var defaultName: String {
        switch kind {
        case .release: "Version"
        case .companion: "Status endpoint"
        case .health: "Health check"
        }
    }

    private var kindHelp: String {
        switch kind {
        case .release: "For any website, static site, or WordPress site. Your build writes forgedeck-release.json (commit, version, build time; never secrets) into what it publishes, or your host sends an X-Release header. No plugin or token needed."
        case .companion: "For an app running the \(Brand.name) companion (Node, Python, or the WordPress plugin in Companions/). Adds health checks and can require a token."
        case .health: "Only checks that the URL answers with HTTP 200. It cannot tell which release is running."
        }
    }

    private var urlHint: String {
        switch kind {
        case .release: "A JSON or text file such as /forgedeck-release.json (on WordPress, /wp-content/forgedeck-release.json), or any page that sends X-Release. HTTPS except on localhost."
        case .companion: "Ends in /_forgedeck/v1/status (or /wp-json/forgedeck/v1/status on WordPress). HTTPS is required except on localhost."
        case .health: "HTTPS is required except on localhost."
        }
    }

    private var urlPlaceholder: String {
        switch kind {
        case .release: "https://example.com/forgedeck-release.json"
        case .companion: "https://example.com/_forgedeck/v1/status"
        case .health: "https://example.com"
        }
    }
}

struct MetricSourceSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    let environmentID: UUID
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var leads = true
    @State private var error: String?

    var body: some View {
        SheetPanel(width: 540) {
            SheetHeader(icon: .chart, title: "Add a Metrics Source",
                        message: "\(Brand.name) reads /_forgedeck/v1/metrics and, if enabled, /_forgedeck/v1/leads from an endpoint your app serves. Example packages are in Companions/.")
            VStack(alignment: .leading, spacing: Space.md) {
                LabeledField(label: "Name") { KitField(placeholder: "App metrics", text: $name) }
                LabeledField(label: "Base URL", hint: "The site root, or a URL ending in /v1. HTTPS is required except on localhost.") {
                    KitField(placeholder: "https://example.com", text: $url, icon: .link, monospaced: true)
                }
                TokenPicker(productID: productID, key: $token)
                Toggle("Also read lead events (ids, kinds, and times; contacts are masked on arrival)", isOn: $leads).toggleStyle(.checkbox).font(KitType.label.font)
                if let error { ErrorState(title: "Not added", detail: error) }
            }
            .padding(.horizontal, Space.xl)
            SheetFooter(note: "Counts by default. No unbounded queries.") {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button("Add Source") {
                    do {
                        _ = try URLPolicy.validate(url)
                        var source = MetricSource()
                        source.name = name.isEmpty ? "App metrics" : name
                        source.baseURL = url.trimmingCharacters(in: .whitespaces)
                        source.bearerVariableKey = token.isEmpty ? nil : token
                        source.leadsEnabled = leads
                        updateEnvironment(model, productID, environmentID) { $0.metricSources.append(source) }
                        model.sheet = nil
                        if let product = model.product(productID) { Task { await model.refresh(product) } }
                    } catch {
                        self.error = String(describing: error)
                    }
                }
                .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction).disabled(url.isEmpty)
            }
        }
    }
}

struct SSHHostSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    let environmentID: UUID
    @State private var alias = ""
    @State private var releasePath = ""
    @State private var error: String?

    var body: some View {
        let hosts = SSHConfig.load()
        SheetPanel(width: 540) {
            SheetHeader(icon: .infra, title: "Add an SSH Host", message: "Uses the system ssh with your config and agent. \(Brand.name) runs only fixed read-only commands and never accepts a host key.")
            VStack(alignment: .leading, spacing: Space.md) {
                LabeledField(label: "Host alias") {
                    HStack(spacing: Space.sm) {
                        KitField(placeholder: "my-server", text: $alias, monospaced: true)
                        if !hosts.isEmpty {
                            Menu("Choose") { ForEach(hosts) { host in Button(host.alias) { alias = host.alias } } }
                                .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
                        }
                    }
                }
                LabeledField(label: "Release file (optional)", hint: "A file your deploy writes with the commit, like /srv/app/forgedeck-release.json. Reading it gives Verified evidence of what is deployed.") {
                    KitField(placeholder: "/srv/app/forgedeck-release.json", text: $releasePath, monospaced: true)
                }
                if let error { ErrorState(title: "Not added", detail: error) }
            }
            .padding(.horizontal, Space.xl)
            SheetFooter(note: "StrictHostKeyChecking is always on.") {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button("Add Host") {
                    guard SSHConfig.isValidAlias(alias) else { error = "Use letters, digits, dots, dashes, and underscores."; return }
                    if !releasePath.isEmpty, SSHProbeCommand.release(path: releasePath) == nil {
                        error = "The release file must be an absolute path with only letters, digits, and / . _ -"
                        return
                    }
                    var host = SSHHostConfig()
                    host.alias = alias
                    host.label = alias
                    host.releaseFilePath = releasePath.isEmpty ? nil : releasePath
                    updateEnvironment(model, productID, environmentID) { $0.sshHosts.append(host) }
                    model.sheet = .doctor(.ssh(alias: alias))
                }
                .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction).disabled(alias.isEmpty)
            }
        }
    }
}

struct EnvironmentSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    @State private var tier: EnvironmentTier = .production
    @State private var name = ""
    @State private var domain = ""
    @State private var githubName = ""

    var body: some View {
        let product = model.product(productID)
        SheetPanel(width: 520, stripe: tier.isProduction ? Ink.prod : nil) {
            SheetHeader(icon: .globe, tone: tier.isProduction ? .prod : .accent, title: "Add Environment", message: "An environment maps \(product?.name ?? "this product") to a place it runs. Its secrets and checks are separate from every other environment.")
            VStack(alignment: .leading, spacing: Space.md) {
                SegmentedPill(options: [(.development, "Local"), (.staging, "Staging"), (.production, "Production"), (.preview, "Preview"), (.custom, "Custom")], selection: $tier, stretch: true)
                LabeledField(label: "Name") { KitField(placeholder: tier.title, text: $name) }
                LabeledField(label: "Domain (optional)") { KitField(placeholder: "app.example.com", text: $domain, monospaced: true) }
                if product?.hasRemote == true, tier != .development {
                    LabeledField(label: "GitHub environment (optional)", hint: "Deployment records for this name become Reported evidence. They never count as verified.") {
                        KitField(placeholder: tier.rawValue, text: $githubName, monospaced: true)
                    }
                }
            }
            .padding(.horizontal, Space.xl)
            SheetFooter {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button("Add Environment") {
                    var environment = ProductEnvironment(name: name.isEmpty ? tier.title : name, tier: tier)
                    if !domain.isEmpty { environment.domains = [domain] }
                    if !githubName.isEmpty { environment.githubEnvironmentName = githubName }
                    model.update(productID) { $0.environments.append(environment) }
                    model.sheet = nil
                    model.productTab = .environments
                }
                .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
                .disabled(product?.environments.contains { $0.tier == tier && tier != .custom && tier != .preview } ?? true)
            }
        }
    }
}

// MARK: Recipes and profiles

struct RecipeSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    let recipeID: UUID?
    @State private var recipe = ActionRecipe()
    @State private var commandLine = ""
    @State private var variables = ""
    @State private var error: String?

    var body: some View {
        let product = model.product(productID)
        SheetPanel(width: 580, stripe: recipe.safety == .productionCritical ? Ink.prod : nil) {
            SheetHeader(icon: .play, title: recipeID == nil ? "Add Recipe" : "Edit Recipe", message: "The program and each argument are passed as they are, never through a shell. Saving a recipe you wrote approves it.")
            VStack(alignment: .leading, spacing: Space.md) {
                LabeledField(label: "Label") { KitField(placeholder: "Run Tests", text: $recipe.label) }
                SegmentedPill(options: [(.local, "Run on this Mac"), (.ssh, "Read-only SSH probe"), (.openURL, "Open a link")], selection: $recipe.executor, stretch: true)
                switch recipe.executor {
                case .local:
                    LabeledField(label: "Commands", hint: "One command per line, run in order; the first failure stops the rest. Quote an argument that has spaces. No pipes, redirects, or && : this is not a shell.") {
                        TextEditor(text: $commandLine).font(KitType.mono.font).scrollContentBackground(.hidden).padding(Space.xs)
                            .frame(height: 76).background(Ink.field, in: RoundedRectangle(cornerRadius: Metric.controlRadius))
                    }
                    HStack(alignment: .top, spacing: Space.md) {
                        LabeledField(label: "Checkout") {
                            Menu(product?.checkout(id: recipe.checkoutID)?.name ?? product?.primaryCheckout?.name ?? "None") {
                                ForEach(product?.checkouts ?? []) { checkout in Button(checkout.name) { recipe.checkoutID = checkout.id } }
                            }
                            .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
                        }
                        LabeledField(label: "Subfolder") { KitField(placeholder: "optional", text: $recipe.workingSubdirectory, monospaced: true) }
                    }
                    Toggle("Run in a terminal window instead of capturing the output", isOn: $recipe.opensInTerminal).toggleStyle(.checkbox).font(KitType.label.font)
                    LabeledField(label: "Variables it may receive", hint: "Names, separated by commas. Each must be allowed in the recipe's environment.") {
                        KitField(placeholder: "DATABASE_URL, API_KEY", text: $variables, monospaced: true)
                    }
                case .ssh:
                    HStack(alignment: .top, spacing: Space.md) {
                        LabeledField(label: "Host") {
                            Menu(recipe.sshAlias ?? "Choose") {
                                ForEach(product?.environments.flatMap(\.sshHosts) ?? []) { host in Button(host.alias) { recipe.sshAlias = host.alias } }
                            }
                            .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
                        }
                        LabeledField(label: "Probe") {
                            Menu(SSHProbeCommand.find(recipe.executable)?.title ?? "Choose") {
                                ForEach(SSHProbeCommand.catalog) { command in Button(command.title) { recipe.executable = command.id } }
                            }
                            .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
                        }
                    }
                    Text("Only the fixed read-only probes can run over SSH. Arbitrary remote commands are not offered.").kitType(.label, Ink.text2)
                case .openURL:
                    LabeledField(label: "Link", hint: "A runbook or dashboard to open when automation is not the right tool.") {
                        KitField(placeholder: "https://…", text: Binding(get: { recipe.url ?? "" }, set: { recipe.url = $0 }), monospaced: true)
                    }
                }
                HStack(alignment: .top, spacing: Space.md) {
                    LabeledField(label: "Environment") {
                        Menu(product?.environment(id: recipe.environmentID)?.name ?? "None") {
                            Button("None") { recipe.environmentID = nil }
                            ForEach(product?.environments ?? []) { environment in Button(environment.name) { recipe.environmentID = environment.id } }
                        }
                        .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
                    }
                    LabeledField(label: "Safety", hint: "Remote write and production critical always ask for confirmation.") {
                        SegmentedPill(options: ActionSafety.allCases.map { ($0, $0.title) }, selection: $recipe.safety, compact: true)
                    }
                }
                if let error { ErrorState(title: "Not saved", detail: error) }
            }
            .padding(.horizontal, Space.xl)
            SheetFooter {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button("Save Recipe") { saveRecipe() }.buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction).disabled(recipe.label.isEmpty)
            }
        }
        .onAppear {
            if let existing = product?.recipes.first(where: { $0.id == recipeID }) {
                recipe = existing
                commandLine = existing.steps.map(ShellQuote.join).joined(separator: "\n")
                variables = existing.variableKeys.joined(separator: ", ")
            } else {
                recipe.checkoutID = product?.primaryCheckout?.id
                recipe.environmentID = product?.environment(tier: model.context)?.id
            }
        }
    }

    private func saveRecipe() {
        switch recipe.executor {
        case .local:
            var steps: [[String]] = []
            for line in commandLine.split(separator: "\n").map(String.init) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let words = CommandWords.split(line), !words.isEmpty else { error = "Check the quotes in: \(line)"; return }
                if words.contains(where: { ["|", "&&", "||", ";", ">", "<", ">>"].contains($0) }) {
                    error = "Pipes, redirects, and && are shell features. Put each command on its own line, or put them in a script."
                    return
                }
                steps.append(words)
            }
            guard !steps.isEmpty else { error = "Enter a program."; return }
            recipe.setSteps(steps)
            recipe.variableKeys = variables.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let bad = recipe.variableKeys.first(where: { !VariableResolver.isValidKey($0) }) { error = "\(bad) is not a variable name."; return }
        case .ssh:
            guard recipe.sshAlias != nil, SSHProbeCommand.find(recipe.executable) != nil else { error = "Choose a host and a probe."; return }
            recipe.safety = .readOnly
        case .openURL:
            do { _ = try URLPolicy.validate(recipe.url ?? "") } catch { self.error = String(describing: error); return }
            recipe.safety = .readOnly
        }
        if model.product(productID)?.environment(id: recipe.environmentID)?.tier.isProduction == true, recipe.executor == .local, recipe.safety < .remoteWrite {
            recipe.safety = .remoteWrite
        }
        recipe.isApproved = true
        recipe.isSuggested = false
        let saved = recipe
        model.update(productID) { product in
            if let index = product.recipes.firstIndex(where: { $0.id == saved.id }) { product.recipes[index] = saved } else { product.recipes.append(saved) }
        }
        model.sheet = nil
        model.recipeSaved(saved.id, productID: productID)
    }
}

enum CommandWords {
    /// Splits a command line into words with shell-like quoting, without running a shell.
    static func split(_ text: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if let open = quote {
                if character == open { quote = nil } else if character == "\\" && open == "\"" { escaped = true } else { current.append(character) }
                continue
            }
            switch character {
            case "'", "\"": quote = character; started = true
            case "\\": escaped = true; started = true
            case " ", "\t":
                if started || !current.isEmpty { words.append(current); current = ""; started = false }
            default: current.append(character)
            }
        }
        guard quote == nil, !escaped else { return nil }
        if started || !current.isEmpty { words.append(current) }
        return words
    }
}

struct ProfileSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    let profileID: UUID?
    var draft: TerminalProfile? = nil
    @State private var profile = TerminalProfile()
    @State private var programs = ""
    @State private var variables = ""
    @State private var error: String?

    var body: some View {
        let product = model.product(productID)
        let production = product?.environment(id: profile.environmentID)?.tier.isProduction == true
        SheetPanel(width: 560, stripe: production ? Ink.prod : nil) {
            SheetHeader(icon: .terminal, tone: production ? .prod : .accent, title: profileID != nil ? "Edit Terminal Profile" : draft != nil ? "Let Agents Use These Variables" : "Add Terminal Profile",
                        message: draft != nil
                            ? "An agent runs \(Brand.cliName) exec --profile \(profile.name.isEmpty ? "agent" : profile.name) -- <program>. The program gets these values in its environment; the agent sees only its output, redacted. Check the programs: each one, and anything it starts, can read the values."
                            : "`\(Brand.cliName) exec` starts only the programs listed here and gives them only the variables listed here, for one environment.")
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top, spacing: Space.md) {
                    LabeledField(label: "Name") { KitField(placeholder: "tests", text: $profile.name, monospaced: true) }
                    LabeledField(label: "Environment") {
                        Menu(product?.environment(id: profile.environmentID)?.name ?? "Choose") {
                            ForEach(product?.environments ?? []) { environment in Button(environment.name) { profile.environmentID = environment.id } }
                        }
                        .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
                    }
                    LabeledField(label: "Checkout") {
                        Menu(product?.checkout(id: profile.checkoutID)?.name ?? "Default") {
                            ForEach(product?.checkouts ?? []) { checkout in Button(checkout.name) { profile.checkoutID = checkout.id } }
                        }
                        .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize()
                    }
                }
                LabeledField(label: "Programs it may start", hint: "Names, separated by commas. A shell like sh or zsh would let any command read the variables: list one only if you mean it.") {
                    KitField(placeholder: "npm, node", text: $programs, monospaced: true)
                }
                LabeledField(label: "Variables it may receive", hint: "Names, separated by commas. A secret that is not allowed in the profile's environment is denied when the command runs.") {
                    KitField(placeholder: "DATABASE_URL, API_KEY", text: $variables, monospaced: true)
                }
                if production {
                    Text("Production: every run asks for Touch ID or your password and is written to the audit log.").kitType(.label, Ink.prod).fixedSize(horizontal: false, vertical: true)
                }
                if let error { ErrorState(title: "Not saved", detail: error) }
            }
            .padding(.horizontal, Space.xl)
            SheetFooter(note: "The program and anything it starts can read the variables it is given.") {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button("Save Profile") {
                    let names = programs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let keys = variables.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    guard !profile.name.isEmpty, !profile.name.contains(" ") else { error = "Give the profile a one-word name."; return }
                    guard profile.environmentID != nil else { error = "Choose the environment this profile is for."; return }
                    guard names.allSatisfy({ !$0.contains("/") && !$0.contains(" ") }) else { error = "List program names, not paths."; return }
                    if let bad = keys.first(where: { !VariableResolver.isValidKey($0) }) { error = "\(bad) is not a variable name."; return }
                    if product?.profiles.contains(where: { $0.name.lowercased() == profile.name.lowercased() && $0.id != profile.id }) == true { error = "Another profile has that name."; return }
                    profile.allowedExecutables = names
                    profile.variableAllowlist = keys
                    let saved = profile
                    model.update(productID) { product in
                        if let index = product.profiles.firstIndex(where: { $0.id == saved.id }) { product.profiles[index] = saved } else { product.profiles.append(saved) }
                    }
                    model.record("profile.save", product: product, detail: "profile=\(saved.name) programs=\(names.joined(separator: ",")) variables=\(keys.joined(separator: ","))")
                    if let product { model.rewriteContext(product) }
                    model.sheet = nil
                }
                .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            if let existing = product?.profiles.first(where: { $0.id == profileID }) {
                profile = existing
                programs = existing.allowedExecutables.joined(separator: ", ")
                variables = existing.variableAllowlist.joined(separator: ", ")
            } else if let draft {
                profile = draft
                programs = draft.allowedExecutables.joined(separator: ", ")
                variables = draft.variableAllowlist.joined(separator: ", ")
            } else {
                profile.environmentID = product?.environment(tier: .development)?.id ?? product?.environments.first?.id
                profile.checkoutID = product?.primaryCheckout?.id
            }
        }
    }
}

// MARK: Rename

/// Names a product, a group, or a new group for a product.
struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    let target: RenameTarget
    @State private var name = ""

    private var copy: (title: String, message: String, field: String, button: String, original: String) {
        switch target {
        case .product(let id):
            let product = model.product(id)
            return ("Rename \(product?.name ?? "Product")", "The name shown in \(Brand.name). Folders and repositories keep their names, and the CLI name stays \(product?.slug ?? "the same").",
                    "Display name", "Rename", product?.name ?? "")
        case .group(let group):
            let count = model.products.filter { $0.group == group }.count
            return ("Rename \(group)", "Renames the sidebar group for its \(count) product\(count == 1 ? "" : "s"). Using the name of another group merges the two.", "Group name", "Rename", group)
        case .newGroup(let id):
            return ("New Group", "Moves \(model.product(id)?.name ?? "the product") into a new sidebar group. Drag products onto a group to move more.", "Group name", "Move", "")
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let copy = copy
        SheetPanel(width: 440) {
            SheetHeader(icon: .pencil, tone: .accent, title: copy.title, message: copy.message)
            LabeledField(label: copy.field) { KitField(placeholder: copy.original.isEmpty ? "Clients" : copy.original, text: $name) }
                .padding(.horizontal, Space.xl)
            SheetFooter {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button(copy.button) { commit() }.buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || trimmed == copy.original)
            }
        }
        .onAppear { name = copy.original }
    }

    private func commit() {
        switch target {
        case .product(let id): model.renameProduct(id, to: trimmed)
        case .group(let group): model.renameGroup(group, to: trimmed)
        case .newGroup(let id): model.move(id, toGroup: trimmed)
        }
        model.sheet = nil
    }
}
