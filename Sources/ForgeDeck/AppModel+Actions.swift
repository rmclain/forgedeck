import AppKit
import ForgeDeckKit
import SwiftUI

// What buttons, menus, the command palette, and the menu bar call.

extension AppModel {
    // MARK: Launching

    private func report(_ outcome: LaunchOutcome, success: String) {
        switch outcome {
        case .opened:
            show(success)
        case .failed(let reason, let copyCommand):
            if let copyCommand {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyCommand, forType: .string)
                show("\(reason) The command was copied instead.", isError: true)
            } else {
                show(reason, isError: true)
            }
        }
    }

    private func session(_ app: String, product: Product, checkout: LocalCheckout?, command: String) {
        var record = SessionRecord()
        record.app = app
        record.productID = product.id
        record.checkoutID = checkout?.id
        record.environmentID = product.environment(tier: context)?.id
        record.commandIdentifier = command
        cache.sessions.append(record)
        if cache.sessions.count > ObservationCache.maxSessions { cache.sessions.removeFirst() }
        update(product.id) { $0.lastOpenedAt = .now }
    }

    /// The checkout a one-click action uses: the one asked for, or the first.
    func checkout(for product: Product, _ wanted: LocalCheckout? = nil) -> LocalCheckout? {
        guard !product.isDemo else {
            show("\(product.name) is a demo product. It has no folder on this Mac.", isError: true)
            return nil
        }
        guard let checkout = wanted ?? product.primaryCheckout else {
            show("\(product.name) has no local checkout. Clone it or link a folder first.", isError: true)
            return nil
        }
        return checkout
    }

    var terminalsInApp: Bool { portfolio.settings.terminalPlacement != "external" }

    /// One click: a shell in the checkout, inside ForgeDeck or in the preferred terminal app.
    func openTerminal(_ product: Product, checkout wanted: LocalCheckout? = nil, bundleID: String? = nil) {
        guard bundleID == nil, terminalsInApp else { return openExternalTerminal(product, checkout: wanted, bundleID: bundleID) }
        guard let checkout = checkout(for: product, wanted) else { return }
        guard FileManager.default.fileExists(atPath: checkout.path) else { return show("The folder no longer exists at \(checkout.path).", isError: true) }
        let title = product.checkouts.count > 1 ? "\(product.name) · \(checkout.name)" : product.name
        terminals.open(TerminalLaunch.shell(in: checkout.path, title: title), productID: product.id, checkoutID: checkout.id)
        session("ForgeDeck", product: product, checkout: checkout, command: "open-terminal")
        record("open.terminal", product: product, detail: "app=ForgeDeck checkout=\(checkout.name)")
    }

    /// A command in an in-app terminal. Returns false when the program is missing.
    @discardableResult
    func runInTerminal(_ argv: [String], kind: TerminalSessionKind, title: String, product: Product?, checkout: LocalCheckout?, directory: String, banner: String? = nil) -> Bool {
        guard var launch = TerminalLaunch.command(argv, kind: kind, title: title, in: directory) else {
            show("\(argv.first ?? "The program") is not installed.", isError: true)
            return false
        }
        launch.banner = banner
        terminals.open(launch, productID: product?.id, checkoutID: checkout?.id)
        return true
    }

    func openExternalTerminal(_ product: Product, checkout wanted: LocalCheckout? = nil, bundleID: String? = nil) {
        guard let checkout = checkout(for: product, wanted) else { return }
        let app = bundleID ?? portfolio.settings.preferredTerminalBundleID
        Task {
            let outcome = await launcher.openFolder(checkout.path, appBundleID: app)
            if case .opened(let name) = outcome {
                session(name, product: product, checkout: checkout, command: "open-terminal")
                record("open.terminal", product: product, detail: "app=\(name) checkout=\(checkout.name)")
            }
            report(outcome, success: "Opened \(checkout.name) in \(KnownApps.descriptor(bundleID: app)?.name ?? "the terminal")")
        }
    }

    /// Opens the checkout in the preferred editor, in a window of its own. VS Code-family editors get the folder
    /// through their own command line tool, which focuses the window that already has it open.
    func openEditor(_ product: Product, checkout wanted: LocalCheckout? = nil) {
        guard let checkout = checkout(for: product, wanted) else { return }
        guard FileManager.default.fileExists(atPath: checkout.path) else { return show("The folder no longer exists at \(checkout.path).", isError: true) }
        let bundleID = portfolio.settings.preferredEditorBundleID
        let name = KnownApps.descriptor(bundleID: bundleID)?.name ?? "the editor"
        let target = EditorTarget.resolve(folder: checkout.path, bundleID: bundleID, appURL: launcher.opener.applicationURL(bundleID: bundleID))
        Task {
            if let cli = target.cli {
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = (ExecutableLocator.searchPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
                let request = ProcessRequest(executable: cli, arguments: [target.path], workingDirectory: URL(fileURLWithPath: checkout.path), environment: environment, timeout: 30)
                if let result = try? await SystemProcessRunner().run(request), result.ok {
                    session(name, product: product, checkout: checkout, command: "open-editor")
                    return show("Opened \(checkout.name) in \(name)")
                }
            }
            let outcome = await launcher.openFolder(checkout.path, appBundleID: bundleID, item: target.path)
            if case .opened(let app) = outcome { session(app, product: product, checkout: checkout, command: "open-editor") }
            report(outcome, success: "Opened \(checkout.name) in \(name)")
        }
    }

    func reveal(_ product: Product, checkout wanted: LocalCheckout? = nil) {
        guard let checkout = checkout(for: product, wanted) else { return }
        guard FileManager.default.fileExists(atPath: checkout.path) else {
            show("The folder no longer exists at \(checkout.path).", isError: true)
            return
        }
        launcher.opener.reveal(URL(fileURLWithPath: checkout.path))
    }

    func openLink(_ text: String) {
        Task {
            let outcome = await launcher.openURL(text)
            if !outcome.didOpen { report(outcome, success: "") }
        }
    }

    func openDashboard(_ product: Product) {
        guard !product.isDemo else {
            show("\(product.name) is a demo product. Its links go nowhere.", isError: true)
            return
        }
        let link = product.links.first { $0.kind == .dashboard || $0.kind == .admin } ?? product.links.first
        if let link {
            openLink(link.url)
        } else if let repo = product.repositories.first {
            openLink(repo.webURL)
        } else {
            show("\(product.name) has no dashboard link. Add one in its Settings tab.", isError: true)
        }
    }

    /// Starts an AI coding agent in the checkout. Nothing is sent anywhere: the agent starts in the folder.
    func openAgent(_ product: Product, checkout wanted: LocalCheckout? = nil) {
        guard let checkout = checkout(for: product, wanted) else { return }
        let program = portfolio.settings.aiAgentProgram
        guard let url = ExecutableLocator.find(program) else {
            show("\(program) is not installed. Choose another agent in Settings.", isError: true)
            return
        }
        let bundle: AgentContextBundle
        do {
            bundle = try AgentContextBundle.write(for: product, checkout: checkout, portfolio: portfolio, cache: cache, location: contextLocation, mcp: mcpInfo(product))
        } catch {
            return show("Could not write the context file: \(error.localizedDescription)", isError: true)
        }
        if terminalsInApp {
            if runInTerminal(bundle.command(program: url, model: portfolio.settings.model(for: program)), kind: .agent, title: "\(AgentCatalog.name(program)) · \(product.name)", product: product, checkout: checkout, directory: checkout.path,
                            banner: bundle.banner(product: product.name, program: program)) {
                session(program, product: product, checkout: checkout, command: "ai-agent")
                record("agent.start", product: product, detail: "agent=\(program) related=\(bundle.relatedNames.joined(separator: ",")) app=ForgeDeck")
            }
            return
        }
        Task {
            let outcome = await launcher.run(command: bundle.command(program: url, model: portfolio.settings.model(for: program)), in: checkout.path, terminalBundleID: terminalForCommands)
            if outcome.didOpen {
                session(program, product: product, checkout: checkout, command: "ai-agent")
                record("agent.start", product: product, detail: "agent=\(program) related=\(bundle.relatedNames.joined(separator: ","))")
            }
            report(outcome, success: bundle.relatedNames.isEmpty ? "Started \(program) in \(checkout.name)"
                                                                 : "Started \(program) with context for \(bundle.relatedNames.joined(separator: ", "))")
        }
    }

    var contextLocation: ContextLocation { ContextLocation(store: store.location) }

    /// Rewrites the product's CONTEXT.md, so an agent that is already running can read a new profile or link.
    func rewriteContext(_ product: Product) {
        guard !product.isDemo, product.hasLocal, let current = self.product(product.id) else { return }
        _ = try? AgentContextBundle.write(for: current, portfolio: portfolio, cache: cache, location: contextLocation, mcp: mcpInfo(current))
    }

    /// Adds Capacitor or Xcode recipes for the product's checkouts, naming a simulator and an emulator on this Mac.
    func suggestMobileRecipes(_ product: Product) {
        Task {
            let devices = await MobileDevices.detect()
            MobileDevices.cached = devices
            var added = 0
            update(product.id) { product in
                for checkout in product.checkouts { added += MobileRecipes.add(to: &product, checkout: checkout, devices: devices) }
            }
            show(added == 0 ? "No new mobile recipes: \(product.name) has them, or has no Capacitor or Xcode project."
                            : "Added \(added) suggested recipe\(added == 1 ? "" : "s"). Review and approve them before they run.")
        }
    }

    func link(_ related: Product, to product: Product) {
        guard related.id != product.id, !product.contextLinks.contains(where: { $0.productID == related.id }) else { return }
        update(product.id) { $0.contextLinks.append(ContextLink(productID: related.id)) }
    }

    func unlink(_ link: ContextLink, from product: Product) {
        update(product.id) { $0.contextLinks.removeAll { $0.id == link.id } }
    }

    func setPack(_ include: Bool, for link: ContextLink, in product: Product) {
        update(product.id) { product in
            if let index = product.contextLinks.firstIndex(where: { $0.id == link.id }) { product.contextLinks[index].includePack = include }
        }
    }

    /// Runs repomix on a related product's checkouts. Started only by the user: it runs a third-party tool.
    func buildPacks(for related: Product) {
        guard !related.isDemo else { return show("\(related.name) is a demo product. It has no code to pack.", isError: true) }
        guard !related.checkouts.isEmpty else { return show("\(related.name) has no local checkout to pack.", isError: true) }
        packing.insert(related.id)
        Task {
            defer { packing.remove(related.id) }
            let builder = PackBuilder(location: contextLocation)
            for checkout in related.checkouts {
                do {
                    let info = try await builder.build(checkout, git: cache.git[checkout.id])
                    record("context.pack", product: related, detail: "checkout=\(checkout.name) bytes=\(info.bytes)")
                    show(info.packKept ? "Packed \(checkout.name): ~\(max(1, info.approxTokens / 1_000))k tokens, map ~\(RepoMap.defaultBudgetTokens / 1_000)k"
                                       : "Mapped \(checkout.name). The full pack was \(info.bytes / 1_000_000) MB, too large to keep.")
                } catch {
                    show(String(describing: error), isError: true)
                }
            }
            now = .now
        }
    }

    func copyAgentCommand(_ product: Product) {
        guard let checkout = checkout(for: product), let url = ExecutableLocator.find(portfolio.settings.aiAgentProgram) else {
            return show("\(portfolio.settings.aiAgentProgram) is not installed.", isError: true)
        }
        do {
            let bundle = try AgentContextBundle.write(for: product, checkout: checkout, portfolio: portfolio, cache: cache, location: contextLocation, mcp: mcpInfo(product))
            copy(TerminalLauncher.copyCommand(directory: checkout.path, command: bundle.command(program: url, model: portfolio.settings.model(for: portfolio.settings.aiAgentProgram))), message: "Copied the agent command")
        } catch {
            show("Could not write the context file: \(error.localizedDescription)", isError: true)
        }
    }

    /// The preferred terminal when it can run a command file, otherwise Terminal.
    var terminalForCommands: String {
        let preferred = portfolio.settings.preferredTerminalBundleID
        return KnownApps.descriptor(bundleID: preferred)?.runsCommandFile == true ? preferred : "com.apple.Terminal"
    }

    func openSSH(alias: String, product: Product?) {
        guard SSHConfig.isValidAlias(alias) else {
            show("\"\(alias)\" is not a valid host alias.", isError: true)
            return
        }
        if terminalsInApp {
            if runInTerminal(["/usr/bin/ssh", "--", alias], kind: .ssh, title: "ssh \(alias)", product: product, checkout: nil, directory: NSHomeDirectory()) {
                record("open.ssh", product: product, detail: "host=\(alias) app=ForgeDeck")
            }
            return
        }
        Task {
            let outcome = await launcher.run(command: ["/usr/bin/ssh", "--", alias], in: NSHomeDirectory(), terminalBundleID: terminalForCommands)
            if outcome.didOpen { record("open.ssh", product: product, detail: "host=\(alias)") }
            report(outcome, success: "Opened an SSH session to \(alias)")
        }
    }

    // MARK: Adding products

    func addManual(name: String, group: String) -> Product {
        var product = Product(name: name, group: group.isEmpty ? "Products" : group)
        product.slug = Slug.unique(name, taken: Set(portfolio.products.map(\.slug)))
        product.lifecycle = .idea
        portfolio.products.append(product)
        save()
        record("product.add", product: product, detail: "kind=manual")
        return product
    }

    func addRepository(_ url: RepositoryURL, original: String, group: String, to existing: UUID? = nil) -> Product {
        var repo = Repository()
        repo.provider = url.provider
        repo.owner = url.owner
        repo.name = url.name
        repo.webURL = url.webURL
        repo.cloneURL = original.contains("@") || original.contains("://") ? Redactor().redact(original) : "git@\(url.host):\(url.owner)/\(url.name).git"
        if let existing, let index = portfolio.products.firstIndex(where: { $0.id == existing }) {
            if !portfolio.products[index].repositories.contains(where: { ImportPlannerBridge.same($0, url) }) {
                portfolio.products[index].repositories.append(repo)
            }
            save()
            return portfolio.products[index]
        }
        if let owner = portfolio.products.first(where: { $0.repositories.contains { ImportPlannerBridge.same($0, url) } }) { return owner }
        var product = Product(name: url.name, group: group.isEmpty ? "Products" : group)
        product.slug = Slug.unique(url.name, taken: Set(portfolio.products.map(\.slug)))
        product.repositories = [repo]
        product.links = [ProductLink(label: "Repository", url: url.webURL, kind: .repository)]
        portfolio.products.append(product)
        save()
        record("product.add", product: product, detail: "kind=github")
        return product
    }

    func addServer(alias: String, name: String, group: String, tier: EnvironmentTier) -> Product {
        var product = Product(name: name.isEmpty ? alias : name, group: group.isEmpty ? "Products" : group)
        product.slug = Slug.unique(product.name, taken: Set(portfolio.products.map(\.slug)))
        var environment = ProductEnvironment(name: tier.title, tier: tier)
        var host = SSHHostConfig()
        host.alias = alias
        host.label = alias
        environment.sshHosts = [host]
        product.environments = [environment]
        product.components = [Component(name: alias, kind: .infrastructure)]
        portfolio.products.append(product)
        save()
        record("product.add", product: product, detail: "kind=ssh")
        return product
    }

    func applyImport(_ proposals: [ImportProposal], group: String) -> [UUID] {
        let touched = ImportPlanner.apply(proposals, to: &portfolio, group: group.isEmpty ? "Products" : group)
        save()
        Task { await refreshLocal() }
        return touched
    }

    func remove(_ product: Product) {
        // Credentials scoped to the product go with it.
        for variable in portfolio.variables where variable.scope.productID == product.id {
            if let credential = variable.credential, credential.origin == .keychain { try? keychain.delete(credential.locator) }
        }
        portfolio.variables.removeAll { $0.scope.productID == product.id }
        cache.remove(product: product)
        portfolio.products.removeAll { $0.id == product.id }
        if case .product(let id) = route, id == product.id { route = .projects }
        save()
        record("product.remove", detail: "slug=\(product.slug)")
        show("Removed \(product.name)")
    }

    func clone(_ repository: Repository, in product: Product) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Clone Here"
        panel.message = "Choose the folder that will hold \(repository.name). Nothing is overwritten."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        Task {
            show("Cloning \(repository.fullName)…")
            do {
                let destination = try await engine.git.clone(url: repository.cloneURL, into: parent, name: repository.name)
                if let project = ProjectDiscovery().inspect(destination) {
                    _ = applyImport([ImportProposal(project: project, action: .addCheckout(productID: product.id))], group: product.group)
                }
                record("repository.clone", product: product, detail: "repo=\(repository.fullName)")
                show("Cloned \(repository.name)")
                if let current = self.product(product.id) { await refresh(current, announce: false) }
            } catch {
                show(String(describing: error), isError: true)
            }
        }
    }

    // MARK: Secrets and variables

    func resolved(for product: Product, tier: EnvironmentTier, profile: TerminalProfile? = nil) -> [ResolvedVariable] {
        guard let environment = product.environment(tier: tier) else { return [] }
        let context = ResolutionContext(product: product, environment: environment, profile: profile,
                                        allowlist: profile.map { Set($0.variableAllowlist) })
        return VariableResolver.resolve(portfolio.variables, context: context, now: now)
    }

    /// Saves a variable. A secret value goes to the Keychain and is not kept anywhere else.
    func saveVariable(_ draft: VariableDraft) -> String? {
        let key = draft.key.trimmingCharacters(in: .whitespaces)
        guard VariableResolver.isValidKey(key) else { return "Use letters, digits, and underscores. Start with a letter." }
        var definition = portfolio.variables.first { $0.id == draft.existingID } ?? VariableDefinition()
        definition.key = key
        definition.scope = draft.scope
        definition.isSecret = draft.isSecret
        definition.allowedTiers = EnvironmentTier.allCases.filter(draft.allowedTiers.contains)
        definition.note = draft.note
        definition.updatedAt = .now
        if draft.isSecret {
            definition.plainValue = nil
            var reference = definition.credential ?? CredentialReference.keychain()
            reference.origin = draft.origin
            reference.rotationIntervalDays = draft.rotationDays > 0 ? draft.rotationDays : nil
            switch draft.origin {
            case .keychain:
                if UUID(uuidString: reference.locator) == nil { reference.locator = reference.id.uuidString }
                if !draft.value.isEmpty {
                    do { try keychain.write(draft.value, locator: reference.locator) } catch { return String(describing: error) }
                    reference.rotatedAt = draft.existingID == nil ? nil : .now
                } else if draft.existingID == nil {
                    return "Enter the secret value."
                }
            case .onePassword:
                guard draft.locator.hasPrefix("op://") else { return "A 1Password reference starts with op://" }
                reference.locator = draft.locator
            case .environmentReference:
                guard VariableResolver.isValidKey(draft.locator) else { return "Enter the name of an environment variable." }
                reference.locator = draft.locator
            case .sshAgent:
                return "SSH keys stay with the SSH agent. Add the host under an environment instead."
            }
            definition.credential = reference
        } else {
            if Redactor.looksLikeSecret(draft.value) { return "That value looks like a token. Mark the variable as a secret." }
            definition.credential = nil
            definition.plainValue = draft.value
        }
        if let index = portfolio.variables.firstIndex(where: { $0.id == definition.id }) {
            portfolio.variables[index] = definition
        } else {
            portfolio.variables.append(definition)
        }
        save()
        record(draft.existingID == nil ? "variable.add" : (draft.isSecret && !draft.value.isEmpty ? "variable.rotate" : "variable.edit"),
               product: product(draft.scope.productID), detail: "key=\(key) scope=\(draft.scope.title) secret=\(draft.isSecret)")
        return nil
    }

    func deleteVariable(_ variable: VariableDefinition) {
        if let credential = variable.credential, credential.origin == .keychain { try? keychain.delete(credential.locator) }
        portfolio.variables.removeAll { $0.id == variable.id }
        revealed[variable.id] = nil
        save()
        record("variable.delete", product: product(variable.scope.productID), detail: "key=\(variable.key)")
        show("Deleted \(variable.key)")
    }

    /// Shows a secret for a short time. Production values ask for Touch ID or the password first.
    func reveal(_ variable: VariableDefinition, copyOnly: Bool = false) {
        guard let credential = variable.credential else { return }
        Task {
            let production = variable.allowedTiers.contains(.production)
            if production, portfolio.settings.requireAuthForProductionSecrets, !Runtime.isAutomated {
                guard await DeviceOwnerAuthorizer().confirm(reason: "\(copyOnly ? "copy" : "reveal") the production secret \(variable.key)") else {
                    record("secret.\(copyOnly ? "copy" : "reveal")", product: product(variable.scope.productID), detail: "key=\(variable.key)", outcome: "denied")
                    show("Authentication was cancelled. The secret stays hidden.", isError: true)
                    return
                }
            }
            do {
                let value = try await credentials.value(for: credential)
                record("secret.\(copyOnly ? "copy" : "reveal")", product: product(variable.scope.productID), detail: "key=\(variable.key)")
                if copyOnly {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    show("Copied \(variable.key). The clipboard is cleared in \(portfolio.settings.revealTimeoutSeconds) seconds.")
                    let count = NSPasteboard.general.changeCount
                    try? await Task.sleep(for: .seconds(portfolio.settings.revealTimeoutSeconds))
                    if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
                } else {
                    revealed[variable.id] = value
                    try? await Task.sleep(for: .seconds(portfolio.settings.revealTimeoutSeconds))
                    revealed[variable.id] = nil
                }
            } catch {
                show(String(describing: error), isError: true)
            }
        }
    }

    // MARK: GitHub

    var githubConnection: ForgeDeckKit.Connection? { portfolio.connection(provider: .github) }

    func connectGitHub(token: String) async -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Paste a token." }
        switch await GitHubConnector(token: trimmed).viewer() {
        case .success(let viewer), .partial(let viewer, _):
            var connection = githubConnection ?? ForgeDeckKit.Connection()
            connection.provider = .github
            connection.displayName = "GitHub"
            connection.accountIdentity = viewer.login
            connection.scopes = viewer.scopes
            var reference = connection.credential ?? CredentialReference.keychain()
            reference.rotatedAt = connection.credential == nil ? nil : .now
            do { try keychain.write(trimmed, locator: reference.locator) } catch { return String(describing: error) }
            connection.credential = reference
            portfolio.connections.removeAll { $0.provider == .github }
            portfolio.connections.append(connection)
            save()
            record("connection.connect", detail: "provider=github account=\(viewer.login)")
            show("Connected to GitHub as \(viewer.login)")
            Task { await refreshAll(announce: false) }
            return nil
        case .failure(let problem, let detail, _):
            return problem == .unauthorized ? "GitHub rejected that token." : detail
        }
    }

    /// Reads the token the GitHub CLI already holds. Runs only when the user asks.
    func importGitHubCLIToken() async -> String? {
        guard let gh = ExecutableLocator.find("gh") else { return "The GitHub CLI (gh) is not installed." }
        guard let result = try? await SystemProcessRunner().run(ProcessRequest(executable: gh, arguments: ["auth", "token"], timeout: 10)), result.ok else {
            return "gh is not signed in. Run `gh auth login` in a terminal."
        }
        return await connectGitHub(token: result.stdout)
    }

    func disconnectGitHub() {
        if let credential = githubConnection?.credential { try? keychain.delete(credential.locator) }
        portfolio.connections.removeAll { $0.provider == .github }
        save()
        record("connection.disconnect", detail: "provider=github")
        show("Disconnected GitHub. The token was deleted from the Keychain.")
    }

    // MARK: Doctor

    func runDoctor(_ target: DoctorTarget) {
        doctorSteps[target.id] = nil
        Task {
            let doctor = ConnectionDoctor()
            switch target {
            case .github:
                doctorSteps[target.id] = await doctor.diagnoseGitHub(token: await engine.githubToken(portfolio))
            case .toolchain:
                doctorSteps[target.id] = await doctor.toolchain()
            case .ssh(let alias):
                doctorSteps[target.id] = await doctor.diagnoseSSH(alias: alias)
            case .probe(let productID, let environmentID, let probeID):
                guard let product = product(productID), let environment = product.environment(id: environmentID),
                      let probe = environment.probes.first(where: { $0.id == probeID }) else { return }
                let token = await engine.bearer(key: probe.bearerVariableKey, product: product, environment: environment, portfolio: portfolio)
                let lastGood = cache.health[probe.id]?.last(where: \.ok)?.at
                doctorSteps[target.id] = await doctor.diagnose(probe: probe, bearer: token, tokenConfigured: probe.bearerVariableKey != nil,
                                                               tier: environment.tier, lastGood: lastGood)
            }
        }
    }

    func runSSHProbe(alias: String, commandID: String) {
        guard let command = SSHProbeCommand.find(commandID) else { return }
        Task {
            sshProbeOutput[alias] = nil
            sshProbeOutput[alias] = await SSHInspector().probe(alias: alias, command: command)
        }
    }

    // MARK: Actions

    /// Runs an approved recipe. Remote and production recipes ask first, with the exact target.
    func run(_ recipe: ActionRecipe, in product: Product) {
        guard !product.isArchived else { return show("\(product.name) is archived. Actions are disabled.", isError: true) }
        guard !product.isDemo else { return show("\(product.name) is a demo product. Its actions do not run.", isError: true) }
        guard recipe.isApproved else { return show("Approve \"\(recipe.label)\" before running it.", isError: true) }
        let environment = product.environment(id: recipe.environmentID)
        let production = environment?.tier.isProduction == true || recipe.safety == .productionCritical
        if recipe.safety >= .remoteWrite || production {
            let target = recipe.executor == .ssh ? "host \(recipe.sshAlias ?? "?")" : recipe.executor == .openURL ? (recipe.url ?? "") : "this Mac"
            sheet = .confirm(ConfirmRequest(
                title: "Run \"\(recipe.label)\"",
                message: "\(recipe.safety.title) action for \(product.name)\(environment.map { " in \($0.name)" } ?? "").",
                checks: [.init(label: "Target", meta: target, ok: true),
                         .init(label: recipe.steps.count > 1 ? "Steps" : "Command", meta: recipe.steps.map { $0.joined(separator: " ") }.joined(separator: " → "), ok: true),
                         .init(label: "Variables", meta: recipe.variableKeys.isEmpty ? "none" : recipe.variableKeys.joined(separator: ", "), ok: recipe.variableKeys.isEmpty)],
                footnote: "This is written to the audit log.",
                isProduction: production,
                confirmLabel: "Hold to Run",
                requiresHold: true,
                action: { [weak self] in self?.execute(recipe, in: product) }))
        } else {
            execute(recipe, in: product)
        }
    }

    private func execute(_ recipe: ActionRecipe, in product: Product) {
        switch recipe.executor {
        case .openURL:
            if let url = recipe.url { openLink(url) }
        case .ssh:
            guard let alias = recipe.sshAlias, let command = SSHProbeCommand.find(recipe.executable) else {
                return show("This SSH action has no host or uses a command that is not in the read-only list.", isError: true)
            }
            let log = startLog(recipe.label, product: product)
            runLogs[log].task = Task {
                let result = await SSHInspector().probe(alias: alias, command: command)
                finishLog(runLogs[log].id, output: result.ok ? result.output : result.detail, exit: result.ok ? 0 : 1, recipe: recipe, product: product)
            }
            sheet = .runLog(runLogs[log].id)
        case .local:
            guard let checkout = product.checkout(id: recipe.checkoutID) ?? product.primaryCheckout else {
                return show("\(product.name) has no local checkout to run this in.", isError: true)
            }
            let base = URL(fileURLWithPath: checkout.path, isDirectory: true)
            let directory = recipe.workingSubdirectory.isEmpty ? base : base.appending(path: recipe.workingSubdirectory, directoryHint: .isDirectory)
            if recipe.opensInTerminal {
                var resolved: [[String]] = []
                for step in recipe.steps {
                    guard let name = step.first, let program = ExecutableLocator.find(name) else {
                        return show("\(step.first ?? "A program") is not installed.", isError: true)
                    }
                    resolved.append([program.path] + step.dropFirst())
                }
                if terminalsInApp {
                    // The same quoted script an external terminal would run, started in a PTY.
                    do {
                        let script = try launcher.writeScript(commands: resolved, in: directory.path)
                        if runInTerminal(["/bin/zsh", script.path], kind: .recipe, title: recipe.label, product: product, checkout: checkout, directory: directory.path) {
                            session("ForgeDeck", product: product, checkout: checkout, command: recipe.label)
                            record("recipe.run", product: product, environment: product.environment(id: recipe.environmentID)?.name, detail: "recipe=\(recipe.label) mode=in-app")
                        }
                    } catch {
                        show("Could not prepare the recipe: \(error.localizedDescription)", isError: true)
                    }
                    return
                }
                Task {
                    let outcome = await launcher.run(commands: resolved, in: directory.path, terminalBundleID: terminalForCommands)
                    if outcome.didOpen {
                        session("terminal", product: product, checkout: checkout, command: recipe.label)
                        record("recipe.run", product: product, environment: product.environment(id: recipe.environmentID)?.name, detail: "recipe=\(recipe.label) mode=terminal")
                    }
                    report(outcome, success: "Started \"\(recipe.label)\" in a terminal")
                }
                return
            }
            let log = startLog(recipe.label, product: product)
            let logID = runLogs[log].id
            runLogs[log].task = Task {
                guard let program = ExecutableLocator.find(recipe.executable) else {
                    finishLog(logID, output: "\(recipe.executable) is not installed.", exit: 127, recipe: recipe, product: product)
                    return
                }
                var environment = ProcessInfo.processInfo.environment
                // An app opened from Finder has a short PATH. Tools like npm need node next to them.
                environment["PATH"] = ([program.deletingLastPathComponent().path] + ExecutableLocator.searchPaths
                                       + ["\(NSHomeDirectory())/.local/bin", environment["PATH"] ?? ""]).joined(separator: ":")
                var secrets: [String] = []
                if !recipe.variableKeys.isEmpty, let target = product.environment(id: recipe.environmentID) ?? product.environment(tier: .development) {
                    let context = ResolutionContext(product: product, environment: target, allowlist: Set(recipe.variableKeys))
                    for variable in VariableResolver.resolve(portfolio.variables, context: context) where recipe.variableKeys.contains(variable.key) {
                        guard variable.state.delivers, let definition = variable.winner else {
                            finishLog(logID, output: "Denied: \(variable.key) is \(variable.state.title.lowercased()) in \(target.name). \(variable.note)", exit: 77, recipe: recipe, product: product)
                            return
                        }
                        if definition.isSecret, let reference = definition.credential {
                            // A production secret needs the person at this Mac, the same as `forgedeck exec`.
                            if target.tier.isProduction, portfolio.settings.requireAuthForProductionSecrets, secrets.isEmpty,
                               !(await DeviceOwnerAuthorizer().confirm(reason: "give \(recipe.label) the production secret \(variable.key) for \(product.name)")) {
                                finishLog(logID, output: "Authentication was cancelled. Nothing ran.", exit: 77, recipe: recipe, product: product)
                                return
                            }
                            guard let value = try? await credentials.value(for: reference) else {
                                finishLog(logID, output: "The secret \(variable.key) could not be read.", exit: 77, recipe: recipe, product: product)
                                return
                            }
                            environment[variable.key] = value
                            secrets.append(value)
                        } else {
                            environment[variable.key] = definition.plainValue ?? ""
                        }
                    }
                }
                // Each step runs in turn; the first failure stops the recipe.
                var transcript = ""
                var code: Int32 = 0
                for (index, step) in recipe.steps.enumerated() {
                    if Task.isCancelled { break }
                    let executable = index == 0 ? program : ExecutableLocator.find(step.first ?? "")
                    guard let executable else {
                        transcript += "\(step.first ?? "A program") is not installed.\n"
                        code = 127
                        break
                    }
                    if recipe.steps.count > 1 { transcript += "▸ \(step.joined(separator: " "))\n" }
                    do {
                        let result = try await SystemProcessRunner().run(ProcessRequest(executable: executable, arguments: Array(step.dropFirst()), workingDirectory: directory,
                                                                                        environment: environment, timeout: recipe.timeoutSeconds, maxOutputBytes: 400_000))
                        transcript += Redactor(knownValues: secrets).redact(result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr))
                        transcript += (result.timedOut ? "\nStopped: the step ran longer than its time limit." : "") + (result.truncated ? "\nOutput was cut at 400 KB." : "") + "\n"
                        code = result.timedOut ? 124 : result.exitCode
                    } catch {
                        transcript += String(describing: error) + "\n"
                        code = 126
                    }
                    if code != 0 { break }
                }
                finishLog(logID, output: transcript, exit: code, recipe: recipe, product: product)
            }
            sheet = .runLog(logID)
        }
    }

    private func startLog(_ title: String, product: Product) -> Int {
        runLogs.append(RunLog(title: title, productName: product.name))
        if runLogs.count > 20 { runLogs.removeFirst() }
        return runLogs.count - 1
    }

    private func finishLog(_ id: UUID, output: String, exit: Int32, recipe: ActionRecipe, product: Product) {
        guard let index = runLogs.firstIndex(where: { $0.id == id }) else { return }
        runLogs[index].output = output
        runLogs[index].exitCode = exit
        runLogs[index].isRunning = false
        var session = SessionRecord()
        session.app = Brand.name
        session.productID = product.id
        session.checkoutID = recipe.checkoutID
        session.environmentID = recipe.environmentID
        session.commandIdentifier = recipe.label
        session.exitStatus = exit
        cache.sessions.append(session)
        save()
        record("recipe.run", product: product, environment: product.environment(id: recipe.environmentID)?.name,
               detail: "recipe=\(recipe.label) exit=\(exit)", outcome: exit == 0 ? "ok" : "failed")
    }

    func cancelRun(_ id: UUID) {
        guard let index = runLogs.firstIndex(where: { $0.id == id }) else { return }
        runLogs[index].task?.cancel()
    }

    // MARK: Alerts and leads

    func acknowledge(_ incident: Incident) {
        AlertEngine.acknowledge(incident.id, cache: &cache)
        save()
    }

    func snooze(_ incident: Incident, hours: Double) {
        AlertEngine.snooze(incident.id, for: hours * 3_600, cache: &cache)
        save()
        show("Snoozed for \(Int(hours)) hour\(hours == 1 ? "" : "s")")
    }

    func setLead(_ lead: LeadEvent, _ state: LeadState) {
        guard let index = cache.leads.firstIndex(where: { $0.id == lead.id }) else { return }
        cache.leads[index].state = state
        save()
    }

    // MARK: Data

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "forgedeck-export.json"
        panel.message = "Secrets are not exported. Each credential becomes a placeholder to fill in again."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PortfolioExporter.export(portfolio).write(to: url, options: .atomic)
            record("data.export")
            show("Exported the configuration without secrets")
        } catch {
            show("Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a \(Brand.name) export file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let export = try PortfolioExporter.validate(Data(contentsOf: url))
            let report = PortfolioExporter.merge(export, into: &portfolio)
            save()
            record("data.import", detail: "products=\(report.productsAdded)")
            show("Imported \(report.productsAdded) product\(report.productsAdded == 1 ? "" : "s"), skipped \(report.productsSkipped) already here"
                + (report.credentialsToReenter.isEmpty ? "" : ". Enter \(report.credentialsToReenter.count) credentials again."))
        } catch {
            show(String(describing: error), isError: true)
        }
    }

    func clearCache() {
        let demo = portfolio.products.filter(\.isDemo)
        cache = ObservationCache()
        if !demo.isEmpty {
            // Demo observations are fixtures, not a cache of anything real: put them back.
            portfolio.products.removeAll(where: \.isDemo)
            DemoFixtures.install(count: 8, into: &portfolio, cache: &cache)
            portfolio.products.removeAll { product in product.isDemo && !demo.contains { $0.id == product.id } }
        }
        save()
        record("data.clear-cache")
        show("Cleared cached observations. Products and settings are untouched.")
        Task { await refreshAll(announce: false) }
    }

    /// Links ~/.local/bin/forgedeck to this app's binary. Runs only from the Settings button.
    func installCLI() {
        guard let binary = Bundle.main.executableURL else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory)
        let link = directory.appending(path: Brand.cliName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try FileManager.default.removeItem(at: link)
            } else if FileManager.default.fileExists(atPath: link.path) {
                return show("\(link.path) exists and is not a link. It was left alone.", isError: true)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == Substring(directory.path) }
            show(onPath ? "Installed \(Brand.cliName) in ~/.local/bin" : "Installed. Add ~/.local/bin to your PATH to use \(Brand.cliName).")
        } catch {
            show("Could not install the CLI: \(error.localizedDescription)", isError: true)
        }
    }

    var cliInstalledPath: String? {
        let link = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/\(Brand.cliName)").path
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil ? link : nil
    }
}

enum ImportPlannerBridge {
    static func same(_ repo: Repository, _ url: RepositoryURL) -> Bool {
        repo.owner.lowercased() == url.owner.lowercased() && repo.name.lowercased() == url.name.lowercased()
    }
}
