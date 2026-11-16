import AppKit
import ForgeDeckKit
import IOKit.pwr_mgt
import SwiftUI

/// Screenshot mode for agents.
///   FORGEDECK_HOME=/tmp/fd APP_SEED=demo APP_SNAPSHOT=/tmp/shots ForgeDeck
/// writes <page>-light.png and <page>-dark.png for every page, tab, sheet, and Settings tab, then quits.
/// APP_SNAPSHOT_PAGES=overview,product-overview limits the pages. APP_SNAPSHOT_SIZE=1050x700 sets the window size.
enum Snapshot {
    struct Shot {
        var name: String
        var wait: Double = 0.7
        var prepare: @MainActor (AppModel) -> Void
    }

    static func shots(_ model: AppModel) -> [Shot] {
        let lumen = model.products.first { $0.slug == "lumen" } ?? model.products.first
        var shots: [Shot] = [
            Shot(name: "overview") { $0.route = .overview },
            Shot(name: "projects") { $0.route = .projects },
        ]
        if let product = lumen {
            for tab in ProductTab.allCases {
                shots.append(Shot(name: "product-\(tab.rawValue.lowercased())") { $0.route = .product(product.id); $0.productTab = tab })
            }
        }
        if let orbit = model.products.first(where: { $0.slug == "orbit-crm" }) {
            shots.append(Shot(name: "product-unknown-production") { $0.route = .product(orbit.id); $0.productTab = .development })
        }
        shots += [
            Shot(name: "deployments") { $0.route = .deployments },
            Shot(name: "leads") { $0.route = .leads },
            Shot(name: "infrastructure-health") { $0.route = .infrastructure; $0.infraTab = .health },
            Shot(name: "infrastructure-connections") { $0.route = .infrastructure; $0.infraTab = .connections },
            Shot(name: "git") { $0.route = .git },
            Shot(name: "terminals") { $0.route = .terminals },
            Shot(name: "product-mcp") { model in
                if let lumen = model.products.first(where: { $0.slug == "lumen" }) { model.route = .product(lumen.id); model.productTab = .overview }
            },
            Shot(name: "toolbox") { model in
                // Skills are read from a folder inside the snapshot data, so the picture is the same on every Mac.
                model.agentHome = model.store.location.directory.appending(path: "snapshot-home")
                model.route = .toolbox
            },
            Shot(name: "sheet-skills") { model in
                model.agentHome = model.store.location.directory.appending(path: "snapshot-home")
                model.sheet = .skills(SkillPlan(repository: "anthropics/skills", commit: "9f2c41e0b7d3", folder: model.store.location.directory.appending(path: "none"), skills: [
                    FoundSkill(name: "frontend-design", summary: "Create distinctive, production-grade frontend interfaces that avoid generic AI aesthetics.", sources: ["skills/frontend-design"], recommended: true),
                    FoundSkill(name: "pdf", summary: "Read, fill, merge, and split PDF files.", sources: ["skills/pdf"], recommended: true),
                    FoundSkill(name: "skill-creator", summary: "Guide for creating and testing new skills.", sources: ["skills/skill-creator"], recommended: true),
                    FoundSkill(name: "template", summary: "A starting point for a new skill.", sources: ["template"], recommended: false),
                ]))
            },
            Shot(name: "secrets") { $0.route = .secrets },
            Shot(name: "activity") { $0.route = .activity },
            Shot(name: "production-context") { $0.route = .overview; $0.context = .production },
            Shot(name: "palette") { $0.context = .staging; $0.route = .overview; $0.paletteOpen = true },
            Shot(name: "sheet-add-product") { $0.paletteOpen = false; $0.sheet = .addProduct },
            Shot(name: "sheet-variable") { $0.sheet = .variable(VariableDraft()) },
            Shot(name: "sheet-confirm") {
                $0.sheet = .confirm(ConfirmRequest(title: "Run \"Migrate database\"", message: "Production critical action for Lumen in Production.",
                                                   checks: [.init(label: "Target", meta: "this Mac", ok: true), .init(label: "Command", meta: "npm run migrate", ok: true),
                                                            .init(label: "Variables", meta: "DATABASE_URL", ok: false)],
                                                   footnote: "This is written to the audit log.", isProduction: true, confirmLabel: "Hold to Run", requiresHold: true) {})
            },
            Shot(name: "sheet-confirm-local") {
                $0.sheet = .confirm(ConfirmRequest(title: "Update the graph (code only)?", message: "graphify will write in lumen. Writes graphify-out/ in the repository.",
                                                   checks: [.init(label: "Folder", meta: "~/code/lumen", ok: true)], confirmLabel: "Run") {})
            },
            Shot(name: "sheet-rename-group") { $0.sheet = .rename(.group("SaaS Products")) },
            Shot(name: "sheet-rename-product") { model in
                if let product = model.products.first { model.sheet = .rename(.product(product.id)) }
            },
            Shot(name: "sheet-remove-product") { model in
                if let product = model.products.first { model.confirmRemove(product) }
            },
            Shot(name: "toast") { $0.sheet = nil; $0.show("Opened lumen in Terminal") },
            // Needs a real GitHub product in the data folder; skipped with demo data.
            Shot(name: "sheet-ci", wait: 12) { model in
                model.toast = nil
                if let product = model.products.first(where: { !$0.isDemo && model.ciRepository($0) != nil }) {
                    model.sheet = .ciFailure(productID: product.id, runID: nil)
                }
            },
            Shot(name: "usage-panel", wait: 1.2) { model in
                model.toast = nil
                model.route = .overview
                model.usagePanelVisible = true
                model.refreshUsage()
            },
            Shot(name: "terminal-dock") { model in
                model.usagePanelVisible = false
                model.toast = nil
                model.route = .overview
                guard model.terminals.sessions.isEmpty else { return }
                let folder = model.store.location.directory.path
                // A fixed, harmless script, so the picture is the same on every Mac.
                let script = "print -P '%F{green}~/code/lumen%f on %F{magenta}main%f'; print 'npm run dev'; print; print '  ▲ Next.js 15 ready on http://localhost:3000'; print '  ✓ Compiled /dashboard in 412 ms'; sleep 600"
                if let launch = TerminalLaunch.command(["/bin/zsh", "-f", "-c", script], kind: .recipe, title: "Start Dev Server", in: folder),
                   let lumen = model.products.first(where: { $0.slug == "lumen" }) {
                    model.terminals.open(launch, productID: lumen.id, checkoutID: lumen.primaryCheckout?.id)
                }
                if let shell = TerminalLaunch.command(["/bin/zsh", "-f"], kind: .shell, title: "Beacon", in: folder),
                   let beacon = model.products.first(where: { $0.slug == "beacon" }) {
                    model.terminals.open(shell, productID: beacon.id, checkoutID: nil)
                }
                if let first = model.terminals.sessions.first { model.terminals.selectedID = first.id }
            },
            // On Beacon's page the dock shows only Beacon's shell; Lumen's dev server is under All Terminals.
            Shot(name: "terminal-dock-product") { model in
                model.toast = nil
                if let beacon = model.products.first(where: { $0.slug == "beacon" }) { model.route = .product(beacon.id) }
                model.terminals.isVisible = true
            },
            // A product with no terminal of its own: the dock says so instead of showing another product's.
            Shot(name: "terminal-dock-empty") { model in
                model.toast = nil
                if let other = model.products.first(where: { $0.slug != "beacon" && $0.slug != "lumen" }) { model.route = .product(other.id) }
                model.terminals.isVisible = true
            },
        ]
        return shots
    }

    static func seed(_ model: AppModel) {
        guard Runtime.environment["APP_SEED"] == "demo", model.products.isEmpty else { return }
        DemoFixtures.install(count: 8, into: &model.portfolio, cache: &model.cache)
        // Variables, a recipe, and a profile, so those screens show their populated state.
        guard let lumen = model.portfolio.products.firstIndex(where: { $0.slug == "lumen" }) else { return }
        let product = model.portfolio.products[lumen]
        func variable(_ key: String, _ scope: VariableScope, secret: Bool, tiers: [EnvironmentTier], value: String = "", rotation: Int? = nil) {
            var definition = VariableDefinition()
            definition.key = key
            definition.scope = scope
            definition.isSecret = secret
            definition.allowedTiers = tiers
            if secret {
                var reference = CredentialReference.keychain()
                reference.rotationIntervalDays = rotation
                reference.createdAt = Date.now.addingTimeInterval(-86_400 * 80)
                definition.credential = reference
                try? model.keychain.write("demo-value-not-a-real-secret", locator: reference.locator)
            } else {
                definition.plainValue = value
            }
            model.portfolio.variables.append(definition)
        }
        let development = product.environment(tier: .development)!, production = product.environment(tier: .production)!
        variable("LOG_LEVEL", .global, secret: false, tiers: [.development, .staging, .production], value: "info")
        variable("LOG_LEVEL", .environment(product: product.id, environment: development.id), secret: false, tiers: [.development], value: "debug")
        variable("DATABASE_URL", .environment(product: product.id, environment: development.id), secret: true, tiers: [.development])
        variable("DATABASE_URL", .environment(product: product.id, environment: production.id), secret: true, tiers: [.production], rotation: 90)
        variable("STRIPE_SECRET_KEY", .environment(product: product.id, environment: production.id), secret: true, tiers: [.production], rotation: 30)
        variable("POSTHOG_KEY", .product(product.id), secret: true, tiers: [.development, .staging])
        var recipe = ActionRecipe()
        recipe.label = "Run Tests"
        recipe.executable = "pnpm"
        recipe.arguments = ["test"]
        recipe.checkoutID = product.primaryCheckout?.id
        recipe.environmentID = development.id
        recipe.safety = .localWrite
        recipe.isApproved = true
        var suggested = ActionRecipe()
        suggested.label = "Start Dev Server"
        suggested.executable = "pnpm"
        suggested.arguments = ["run", "dev"]
        suggested.environmentID = development.id
        suggested.safety = .localWrite
        suggested.isSuggested = true
        suggested.opensInTerminal = true
        var migrate = ActionRecipe()
        migrate.label = "Migrate database"
        migrate.executable = "pnpm"
        migrate.arguments = ["run", "migrate"]
        migrate.environmentID = production.id
        migrate.variableKeys = ["DATABASE_URL"]
        migrate.safety = .productionCritical
        migrate.isApproved = true
        if let beacon = model.portfolio.products.first(where: { $0.slug == "beacon" }),
           let parcelwise = model.portfolio.products.first(where: { $0.slug == "parcelwise" }) {
            model.portfolio.products[lumen].contextLinks = [ContextLink(productID: beacon.id, includePack: true, note: "Shares the status API"),
                                                            ContextLink(productID: parcelwise.id)]
        }
        var profile = TerminalProfile()
        profile.name = "tests"
        profile.environmentID = development.id
        profile.allowedExecutables = ["pnpm", "node"]
        profile.variableAllowlist = ["DATABASE_URL", "LOG_LEVEL"]
        var mobile = ActionRecipe()
        mobile.label = "Build and Run on iPhone 17 Pro Simulator"
        mobile.setSteps([["npm", "run", "build:app"], ["npx", "cap", "run", "ios", "--target", "2F36B191-186F-4F24-8FE5-D91A35997D87", "--no-sync"]])
        mobile.environmentID = development.id
        mobile.safety = .localWrite
        mobile.isSuggested = true
        mobile.opensInTerminal = true
        model.portfolio.products[lumen].recipes = [recipe, suggested, mobile, migrate]
        model.portfolio.products[lumen].profiles = [profile]
    }

    static func runIfRequested(model: AppModel, openSettings: OpenSettingsAction) {
        let env = Runtime.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty else { return }
        guard StoreLocation.isOverridden() else {
            print("SNAPSHOT refused: set FORGEDECK_HOME to a temporary folder")
            NSApp.terminate(nil)
            return
        }
        seed(model)
        let only = env["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        Task {
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.2))
            if let size = env["APP_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
               let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                try? await Task.sleep(for: .seconds(0.5))
            }
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                model.context = .staging
                model.sheet = nil
                model.paletteOpen = false
                for shot in shots(model) where only?.contains(shot.name) ?? true {
                    shot.prepare(model)
                    try? await Task.sleep(for: .seconds(shot.wait))
                    capture(to: "\(dir)/\(shot.name)-\(mode).png")
                }
                model.sheet = nil
                model.paletteOpen = false
                model.toast = nil
                model.terminals.terminateAll()
                model.terminals.sessions = []
                model.terminals.isVisible = false
            }
            if only == nil || only?.contains("settings") == true {
                let main = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
                openSettings()
                try? await Task.sleep(for: .seconds(1))
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    for tab in SettingsTab.allCases {
                        SettingsState.shared.tab = tab
                        try? await Task.sleep(for: .seconds(0.7))
                        let settings = NSApp.windows.first { $0.isVisible && $0 !== main && $0.identifier?.rawValue.contains("Settings") == true }
                            ?? NSApp.windows.first { $0.isVisible && $0 !== main && $0.canBecomeKey && $0.title == tab.title }
                        capture(to: "\(dir)/settings-\(tab.rawValue)-\(mode).png", window: settings)
                    }
                }
            }
            print("SNAPSHOT done \(dir)")
            NSApp.terminate(nil)
        }
    }

    private static func capture(to path: String, window: NSWindow? = nil) {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window = window ?? NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            print("SNAPSHOT no window")
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let size = window.contentView?.bounds.size ?? .zero
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: size)
        try? FileManager.default.removeItem(atPath: path)
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, materials are blank)")
        }
    }
}
