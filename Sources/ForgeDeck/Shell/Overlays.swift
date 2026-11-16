import ForgeDeckKit
import SwiftUI

// MARK: Command palette

struct PaletteCommand: Identifiable {
    let id: String
    var label: String
    var group: String
    var icon: KitIcon
    var kbd = ""
    var isProduction = false
    var run: @MainActor () -> Void
}

extension AppModel {
    /// Everything the palette can find. Names and places only: never a secret value.
    func paletteCommands(openSettings: @escaping @MainActor () -> Void) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        let current = currentProduct
        if let product = current {
            if product.hasLocal, !product.isDemo {
                for checkout in product.checkouts {
                    commands.append(PaletteCommand(id: "term-\(checkout.id)", label: "Open Terminal in \(checkout.name)", group: "Local", icon: .terminal,
                                                   kbd: checkout.id == product.primaryCheckout?.id ? "⌘O" : "") { self.openTerminal(product, checkout: checkout) })
                }
                commands.append(PaletteCommand(id: "edit-\(product.id)", label: "Open \(product.name) in Editor", group: "Local", icon: .code, kbd: "⌘⇧O") { self.openEditor(product) })
                commands.append(PaletteCommand(id: "agent-\(product.id)", label: "Open \(product.name) with \(AgentCatalog.name(portfolio.settings.aiAgentProgram))", group: "Local", icon: .sparkle, kbd: "⌘⌥O") { self.openAgent(product) })
            }
            for recipe in product.recipes where recipe.isApproved && !product.isDemo {
                let production = product.environment(id: recipe.environmentID)?.tier.isProduction == true || recipe.safety == .productionCritical
                commands.append(PaletteCommand(id: "recipe-\(recipe.id)", label: "Run \(recipe.label)", group: "Actions", icon: .play, isProduction: production) { self.run(recipe, in: product) })
            }
            for environment in product.environments where !product.isDemo {
                for host in environment.sshHosts {
                    commands.append(PaletteCommand(id: "ssh-\(host.id)", label: "SSH into \(host.alias)", group: "Servers", icon: .terminal,
                                                   isProduction: environment.tier.isProduction) { self.openSSH(alias: host.alias, product: product) })
                }
            }
            for link in product.links where !product.isDemo {
                commands.append(PaletteCommand(id: "link-\(link.id)", label: "Open \(link.label) · \(product.name)", group: "Links", icon: .external) { self.openLink(link.url) })
            }
            if !product.isDemo, product.repositories.contains(where: { $0.provider == "github" }) {
                commands.append(PaletteCommand(id: "ci-\(product.id)", label: "Show Last CI Failure · \(product.name)", group: "CI", icon: .error) {
                    self.paletteOpen = false
                    self.sheet = .ciFailure(productID: product.id, runID: nil)
                })
            }
            if !product.isDemo {
                for (index, option) in playOptions(product).enumerated() {
                    commands.append(PaletteCommand(id: "play-\(option.id)", label: "Play: \(option.title) · \(product.name)", group: "Play", icon: .play,
                                                   kbd: index == 0 ? "⌘⇧P" : "") { self.play(product, option: option) })
                }
            }
            commands.append(PaletteCommand(id: "rename-\(product.id)", label: "Rename \(product.name)…", group: "Product", icon: .pencil) {
                self.paletteOpen = false
                self.sheet = .rename(.product(product.id))
            })
            commands.append(PaletteCommand(id: "regroup-\(product.id)", label: "Rename Group \(product.group)…", group: "Product", icon: .pencil) {
                self.paletteOpen = false
                self.sheet = .rename(.group(product.group))
            })
            commands.append(PaletteCommand(id: "remove-\(product.id)", label: "Remove \(product.name) from \(Brand.name)…", group: "Product", icon: .trash) {
                self.paletteOpen = false
                self.confirmRemove(product)
            })
            commands.append(PaletteCommand(id: "refresh-\(product.id)", label: "Refresh \(product.name)", group: "Product", icon: .sync, kbd: "⌘R") { Task { await self.refresh(product) } })
            if !product.isDemo, let checkout = product.primaryCheckout {
                for spec in Toolbox.catalog where Toolbox.status(spec).isUsable {
                    for action in spec.actions where action.scope == .checkout {
                        commands.append(PaletteCommand(id: "tool-\(product.id)-\(action.id)", label: "\(spec.name): \(action.label) · \(product.name)", group: "Tools", icon: .bolt) {
                            self.paletteOpen = false
                            self.runTool(action, of: spec, product: product, checkout: checkout)
                        })
                    }
                }
            }
        }
        for product in activeProducts where product.id != current?.id {
            commands.append(PaletteCommand(id: "open-\(product.id)", label: "Open \(product.name)", group: "Products", icon: .projects) { self.open(product) })
        }
        for product in activeProducts where product.id != current?.id && product.hasLocal && !product.isDemo {
            commands.append(PaletteCommand(id: "term-\(product.id)", label: "Open Terminal · \(product.name)", group: "Local", icon: .terminal) { self.openTerminal(product) })
        }
        for route in Route.primary where route != self.route {
            commands.append(PaletteCommand(id: "go-\(route.key)", label: "Go to \(route.title)", group: "Navigate", icon: route.icon) { self.go(route) })
        }
        commands.append(PaletteCommand(id: "add", label: "Add Product", group: Brand.name, icon: .plus, kbd: "⌘N") { self.paletteOpen = false; self.sheet = .addProduct })
        commands.append(PaletteCommand(id: "add-variable", label: "Add Variable or Secret", group: Brand.name, icon: .key) { self.paletteOpen = false; self.sheet = .variable(VariableDraft()) })
        for repository in AgentSkills.catalog {
            commands.append(PaletteCommand(id: "skills-\(repository.id)", label: "Add Skills from \(repository.name)…", group: "Agent Skills", icon: .sparkle) {
                self.paletteOpen = false
                self.lookUpSkills(repository.id)
            })
        }
        commands.append(PaletteCommand(id: "refresh-all", label: "Refresh Everything", group: Brand.name, icon: .sync) { Task { await self.refreshAll() } })
        for tier in [EnvironmentTier.development, .staging, .production] where tier != context {
            commands.append(PaletteCommand(id: "ctx-\(tier.rawValue)", label: "Switch to \(tier.title)", group: "Environment", icon: .globe,
                                           kbd: tier == .production || context == .production ? "⌘⇧E" : "", isProduction: tier.isProduction) { self.context = tier })
        }
        commands.append(PaletteCommand(id: "doctor", label: "Run Toolchain Doctor", group: Brand.name, icon: .stethoscope) { self.paletteOpen = false; self.sheet = .doctor(.toolchain) })
        commands.append(PaletteCommand(id: "settings", label: "Settings", group: Brand.name, icon: .settings, kbd: "⌘,") { openSettings() })
        return commands
    }
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var matches: [PaletteCommand] {
        let all = model.paletteCommands { openSettings() }
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return all }
        return all.filter { command in
            let haystack = (command.label + " " + command.group).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private func run(_ command: PaletteCommand) {
        model.paletteOpen = false
        command.run()
    }

    var body: some View {
        let commands = matches
        ZStack(alignment: .top) {
            Ink.scrim.ignoresSafeArea().onTapGesture { model.paletteOpen = false }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: Space.md) {
                    Icon(.search, size: 16).foregroundStyle(Ink.text3)
                    TextField("Search projects, servers, actions, links…", text: $query)
                        .textFieldStyle(.plain).font(KitType.paletteInput.font).foregroundStyle(Ink.text)
                        .focused($focused)
                        .onSubmit { if commands.indices.contains(selected) { run(commands[selected]) } }
                        .onKeyPress(.downArrow) { selected = min(commands.count - 1, selected + 1); return .handled }
                        .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
                        .onKeyPress(.escape) { model.paletteOpen = false; return .handled }
                        .accessibilityLabel("Command palette search")
                    Text("esc").kitType(.meta, Ink.text3).padding(.horizontal, Space.xs).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.line, lineWidth: Metric.hairline))
                }
                .padding(.horizontal, Space.lg).frame(height: 52)
                .hairlineBelow()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                Button { run(command) } label: {
                                    HStack(spacing: Space.md) {
                                        ToneIcon(icon: command.icon, tone: command.isProduction ? .prod : .muted)
                                        Text(command.label).kitType(.paletteRow).lineLimit(1)
                                        if command.isProduction { TagBadge("Prod", tone: .prod) }
                                        Spacer(minLength: Space.sm)
                                        Text(command.group).kitType(.label, Ink.text3)
                                        Text(command.kbd).kitType(.meta, Ink.text3).frame(minWidth: 32, alignment: .trailing)
                                    }
                                    .padding(.horizontal, Space.sm).frame(height: 40)
                                    .background(index == selected ? Ink.accent.soft(0.14) : .clear, in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { if $0 { selected = index } }
                                .id(index)
                            }
                            if commands.isEmpty {
                                Text("No matches for “\(query)”. Try a product, host, or action name.").kitType(.body, Ink.text2).padding(Space.section)
                            }
                        }
                        .padding(Space.sm)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selected) { _, value in proxy.scrollTo(value) }
                }
                HStack(spacing: Space.lg) {
                    Text(Brand.name).kitType(.meta, Ink.text3)
                    Spacer()
                    Text("↑↓ Navigate").kitType(.meta, Ink.text3)
                    Text("↵ Run").kitType(.meta, Ink.text3)
                    Text("Secrets never appear here").kitType(.meta, Ink.text3)
                }
                .padding(.horizontal, Space.lg).frame(height: 36)
                .background(Ink.panel2)
                .hairlineAbove(Ink.line)
            }
            .frame(width: 640)
            .background { ZStack { VisualEffect(material: .popover, blending: .withinWindow); Ink.popover } }
            .clipShape(RoundedRectangle(cornerRadius: Metric.sheetRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metric.sheetRadius, style: .continuous).strokeBorder(Ink.lineStrong, lineWidth: Metric.hairline))
            .shadow(color: .black.opacity(0.3), radius: 40, y: 24)
            .padding(.top, 108)
        }
        .onChange(of: query) { selected = 0 }
        .onAppear { focused = true }
        .transition(.opacity)
    }
}

// MARK: Sheets

/// A sheet drawn inside the window, as the design has it: scrim, panel, Escape closes.
struct SheetPanel<Content: View>: View {
    @Environment(AppModel.self) private var model
    var width: CGFloat = 520
    var stripe: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if let stripe { stripe.frame(height: 4) }
            content
        }
        .frame(width: width)
        .background { ZStack { VisualEffect(material: .popover, blending: .withinWindow); Ink.popover } }
        .clipShape(RoundedRectangle(cornerRadius: Metric.sheetRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metric.sheetRadius, style: .continuous).strokeBorder(Ink.lineStrong, lineWidth: Metric.hairline))
        .shadow(color: .black.opacity(0.28), radius: 40, y: 24)
        .onExitCommand { model.sheet = nil }
    }
}

struct SheetHeader: View {
    let icon: KitIcon
    var tone: Tone = .accent
    let title: String
    var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.tone(tone).soft(0.14)) // grid: ok icon tile radius from the design
                .frame(width: 40, height: 40)
                .overlay { Icon(icon, size: 18).foregroundStyle(Ink.tone(tone)) }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).kitType(.cardTitle).accessibilityAddTraits(.isHeader)
                if let message { Text(message).font(.system(size: 12.5)).foregroundStyle(Ink.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl).padding(.top, Space.xl).padding(.bottom, Space.lg)
    }
}

struct SheetFooter<Actions: View>: View {
    var note = ""
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(note).kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            actions
        }
        .padding(.horizontal, Space.xl).padding(.top, Space.lg).padding(.bottom, Space.xl)
    }
}

struct SheetHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let sheet = model.sheet {
            ZStack(alignment: .top) {
                Ink.scrim.ignoresSafeArea().onTapGesture { model.sheet = nil }.accessibilityHidden(true)
                Group {
                    switch sheet {
                    case .addProduct: AddProductSheet()
                    case .confirm(let request): ConfirmationSheet(request: request)
                    case .variable(let draft): VariableSheet(draft: draft)
                    case .probe(let productID, let environmentID): ProbeSheet(productID: productID, environmentID: environmentID)
                    case .metricSource(let productID, let environmentID): MetricSourceSheet(productID: productID, environmentID: environmentID)
                    case .sshHost(let productID, let environmentID): SSHHostSheet(productID: productID, environmentID: environmentID)
                    case .environment(let productID): EnvironmentSheet(productID: productID)
                    case .recipe(let productID, let recipeID): RecipeSheet(productID: productID, recipeID: recipeID)
                    case .profile(let productID, let profileID): ProfileSheet(productID: productID, profileID: profileID)
                    case .connectGitHub: GitHubSheet()
                    case .doctor(let target): DoctorSheet(target: target)
                    case .runLog(let id): RunLogSheet(logID: id)
                    case .ciFailure(let productID, let runID): CIFailureSheet(productID: productID, runID: runID)
                    case .rename(let target): RenameSheet(target: target)
                    case .update(let release): UpdateSheet(release: release)
                    case .skills(let plan): SkillsSheet(plan: plan)
                    case .releaseChannel(let product): ReleaseChannelSheet(productID: product)
                    }
                }
                .id(sheet.id)
                .padding(.top, 72)
            }
            .transition(.opacity)
        }
    }
}

/// Confirmation with the exact target. Remote writes and production need a press and hold; everything else is one click.
struct ConfirmationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: ConfirmRequest
    @State private var progress = 0.0
    @State private var done = false

    private func finish() {
        guard !done else { return }
        done = true
        model.sheet = nil
        Task { await request.action() }
    }

    var body: some View {
        let tone: Tone = request.isProduction ? .prod : .accent
        SheetPanel(width: 480, stripe: Ink.tone(tone)) {
            SheetHeader(icon: request.icon ?? (request.isProduction ? .globe : .play), tone: tone, title: request.title, message: request.message)
            if !request.checks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(request.checks.enumerated()), id: \.element.id) { index, check in
                        HStack(spacing: Space.sm) {
                            Circle().fill((check.ok ? Ink.ok : Ink.warn).soft(0.16)).frame(width: 20, height: 20)
                                .overlay { Image(systemName: check.ok ? "checkmark" : "exclamationmark").font(.system(size: 9, weight: .bold)).foregroundStyle(check.ok ? Ink.ok : Ink.warn) }
                            Text(check.label).font(.system(size: 12.5)).foregroundStyle(Ink.text)
                            Spacer(minLength: Space.sm)
                            Text(check.meta).kitType(.monoSmall, Ink.text2).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                        .overlay(alignment: .top) { if index > 0 { Ink.line2.frame(height: Metric.hairline) } }
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous)) // grid: ok list radius from the design
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line, lineWidth: Metric.hairline)) // grid: ok list radius from the design
                .padding(.horizontal, Space.xl)
            }
            SheetFooter(note: request.footnote) {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                if request.requiresHold {
                    holdButton(tone)
                } else {
                    Button(request.confirmLabel) { finish() }
                        .buttonStyle(.kit(request.isProduction ? .production : .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Fills while pressed; lifting early empties it. The system long press, so window dragging cannot take the mouse.
    private func holdButton(_ tone: Tone) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous).fill(Ink.tone(tone).opacity(0.72))
            GeometryReader { proxy in
                Rectangle().fill(Ink.tone(tone)).frame(width: proxy.size.width * progress)
            }
            Text(progress > 0 ? "Keep holding…" : request.confirmLabel)
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(request.isProduction ? Ink.onProd : Ink.onAccent)
                .frame(maxWidth: .infinity)
        }
        .frame(width: 168, height: Metric.buttonHeight)
        .clipShape(RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 1, maximumDistance: 40) {
            finish()
        } onPressingChanged: { pressing in
            if pressing {
                withAnimation(reduceMotion ? nil : .linear(duration: 1)) { progress = 1 }
            } else if !done {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { progress = 0 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(request.confirmLabel)
        .accessibilityHint("Press and hold for one second, or use the Confirm action.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Confirm") { finish() }
        .help("Press and hold for one second")
    }
}

struct DoctorSheet: View {
    @Environment(AppModel.self) private var model
    let target: DoctorTarget

    private var title: String {
        switch target {
        case .github: "GitHub connection"
        case .probe: "Status endpoint"
        case .ssh(let alias): "SSH host \(alias)"
        case .toolchain: "Tools on this Mac"
        }
    }

    var body: some View {
        SheetPanel(width: 540) {
            SheetHeader(icon: .stethoscope, title: "Connection Doctor", message: "\(title). Each step shows what was checked. No secret is displayed.")
            VStack(alignment: .leading, spacing: Space.md) {
                if let steps = model.doctorSteps[target.id] {
                    ForEach(steps) { DoctorStepRow(step: $0) }
                } else {
                    LoadingState(rows: 4, label: "Running checks")
                }
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous)) // grid: ok list radius from the design
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line, lineWidth: Metric.hairline)) // grid: ok list radius from the design
            .padding(.horizontal, Space.xl)
            SheetFooter(note: "Read-only checks") {
                Button("Run Again") { model.runDoctor(target) }.buttonStyle(.kit(.secondary))
                Button("Done") { model.sheet = nil }.buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { if model.doctorSteps[target.id] == nil { model.runDoctor(target) } }
    }
}

struct RunLogSheet: View {
    @Environment(AppModel.self) private var model
    let logID: UUID

    var body: some View {
        let log = model.runLogs.first { $0.id == logID }
        SheetPanel(width: 640) {
            SheetHeader(icon: .play, tone: log?.exitCode == nil ? .accent : log?.exitCode == 0 ? .ok : .err,
                        title: log?.title ?? "Action",
                        message: log.map { $0.isRunning ? "Running for \($0.productName)…" : "Finished with exit code \($0.exitCode ?? -1)." } ?? "")
            ScrollView {
                Text(log?.output.isEmpty == false ? log!.output : (log?.isRunning == true ? "Waiting for output…" : "No output."))
                    .kitType(.monoSmall, Ink.text2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Space.md)
            }
            .frame(height: 280)
            .background(Ink.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous)) // grid: ok list radius from the design
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line, lineWidth: Metric.hairline)) // grid: ok list radius from the design
            .padding(.horizontal, Space.xl)
            SheetFooter(note: "Known secret values and token shapes are redacted. Output is not saved.") {
                if log?.isRunning == true { Button("Stop") { model.cancelRun(logID) }.buttonStyle(.kit(.secondary)) }
                if let output = log?.output, !output.isEmpty { Button("Copy Output") { model.copy(output, message: "Copied the redacted output") }.buttonStyle(.kit(.secondary)) }
                Button("Done") { model.sheet = nil }.buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct GitHubSheet: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var error: String?
    @State private var working = false

    private func finish(_ result: String?) {
        working = false
        error = result
        if result == nil { model.sheet = nil }
    }

    var body: some View {
        SheetPanel(width: 520) {
            SheetHeader(icon: .branch, title: model.githubConnection == nil ? "Connect GitHub" : "Reconnect GitHub",
                        message: "\(Brand.name) only reads: repositories, branches, pull requests, workflow runs, deployments. Use a fine-grained token with read-only access. The token is stored in the macOS Keychain.")
            VStack(alignment: .leading, spacing: Space.md) {
                LabeledField(label: "Personal access token", hint: "Create one at github.com/settings/personal-access-tokens with Contents, Metadata, Pull requests, Actions, and Deployments set to Read-only.") {
                    KitField(placeholder: "github_pat_…", text: $token, icon: .key, secure: true, monospaced: true)
                }
                if let error { ErrorState(title: "Could not connect", detail: error) }
            }
            .padding(.horizontal, Space.xl)
            SheetFooter(note: ExecutableLocator.find("gh") == nil ? "" : "The GitHub CLI is installed.") {
                if ExecutableLocator.find("gh") != nil {
                    Button("Use gh CLI Token") {
                        working = true
                        Task { finish(await model.importGitHubCLIToken()) }
                    }
                    .buttonStyle(.kit(.secondary))
                    .help("Reads the token with `gh auth token` and stores it in the Keychain. That token often has write scopes.")
                }
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button(working ? "Checking…" : "Connect") {
                    working = true
                    Task { finish(await model.connectGitHub(token: token)) }
                }
                .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction).disabled(working || token.isEmpty)
            }
        }
    }
}
