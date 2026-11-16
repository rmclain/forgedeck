import ForgeDeckKit
import SwiftUI

// Renaming products and groups, moving products between groups, removing them, and Play.

extension AppModel {
    // MARK: Names and groups

    func renameProduct(_ id: UUID, to name: String) {
        guard let old = product(id)?.name, portfolio.rename(id, to: name) else { return }
        save()
        record("product.rename", product: product(id), detail: "from=\(old)")
        show("Renamed to \(name.trimmingCharacters(in: .whitespaces))")
    }

    func renameGroup(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        let moved = portfolio.renameGroup(old, to: name)
        guard moved > 0 else { return }
        if collapsedGroups.remove(old) != nil { collapsedGroups.insert(name) }
        save()
        record("group.rename", detail: "from=\(old) to=\(name) products=\(moved)")
        show("Renamed the group to \(name)")
    }

    func move(_ productID: UUID, toGroup group: String) {
        guard portfolio.move(productID, toGroup: group), let product = product(productID) else { return }
        collapsedGroups.remove(product.group)
        save()
        record("product.group", product: product, detail: "group=\(product.group)")
        show("Moved \(product.name) to \(product.group)")
    }

    /// Asks first. Removing takes the product out of ForgeDeck; folders, repositories, and servers stay as they are.
    func confirmRemove(_ product: Product) {
        let scoped = portfolio.variables.filter { $0.scope.productID == product.id }.count
        var checks: [ConfirmRequest.Check] = product.checkouts.map { .init(label: "Kept on disk", meta: $0.path, ok: true) }
        if scoped > 0 { checks.append(.init(label: "Secrets scoped to it", meta: "\(scoped) deleted from the Keychain", ok: false)) }
        sheet = .confirm(ConfirmRequest(
            title: "Remove \(product.name) from \(Brand.name)",
            message: "Its folders, repositories, and servers are not touched. \(Brand.name) forgets the product, its recipes, and its cached observations. Add the folder again any time.",
            checks: checks,
            confirmLabel: "Hold to Remove",
            icon: .trash) { [weak self] in self?.remove(product) })
    }

    // MARK: Play

    /// Launch options, worked out once per version of the product. Menus ask for them on every render.
    func playOptions(_ product: Product) -> [PlayOption] {
        if let cached = playCache[product.id], cached.product == product { return cached.options }
        let options = PlayPlanner.options(for: product, localSites: localSites)
        playCache[product.id] = (product, options)
        return options
    }

    /// Launches what the product builds: the simulator, the desktop app, the dev server and its page, or the site.
    /// A recipe that is not approved yet opens for review first, and runs as soon as it is saved.
    func play(_ product: Product, option wanted: PlayOption? = nil) {
        guard !product.isDemo else { return show("\(product.name) is a demo product. There is nothing to launch.", isError: true) }
        guard let option = wanted ?? playOptions(product).first else {
            return show("\(Brand.name) found nothing to launch in \(product.name). Add a recipe in its Actions tab.", isError: true)
        }
        var recipeID = option.recipeID
        if recipeID == nil, let suggestion = option.suggestion {
            update(product.id) { $0.recipes.append(suggestion) }
            recipeID = suggestion.id
        }
        guard let recipeID else {
            if let url = option.url { openLink(url) }
            record("product.play", product: product, detail: "open=\(option.title)")
            return
        }
        guard let current = self.product(product.id), let recipe = current.recipes.first(where: { $0.id == recipeID }) else { return }
        guard recipe.isApproved else {
            pendingPlay = (product.id, recipe.id, option.url)
            sheet = .recipe(productID: product.id, recipeID: recipe.id)
            show("Check the command, then Save to approve it. Play runs it right after.")
            return
        }
        run(recipe, in: current)
        record("product.play", product: current, detail: "recipe=\(recipe.label)")
        if let url = option.url { openWhenUp(url, label: recipe.label) }
    }

    /// Called after a recipe is saved. Runs it when Play was waiting for the approval.
    func recipeSaved(_ recipeID: UUID, productID: UUID) {
        guard let pending = pendingPlay, pending.recipeID == recipeID, pending.productID == productID else { return }
        pendingPlay = nil
        guard let product = product(productID), let recipe = product.recipes.first(where: { $0.id == recipeID }), recipe.isApproved else { return }
        run(recipe, in: product)
        record("product.play", product: product, detail: "recipe=\(recipe.label)")
        if let url = pending.url { openWhenUp(url, label: recipe.label) }
    }

    /// Opens a dev server's page once it answers. Gives up quietly after two minutes.
    func openWhenUp(_ url: String, label: String) {
        guard let address = URL(string: url) else { return }
        Task {
            if await DevServerWaiter.waitUntilUp(address, timeout: 120) {
                openLink(url)
            } else {
                show("\(label) did not answer at \(url) within two minutes. Open it yourself once it is ready.", isError: true)
            }
        }
    }
}

enum DevServerWaiter {
    /// Polls once a second. Any HTTP response counts: a 404 still means the server is up.
    static func waitUntilUp(_ url: URL, timeout: TimeInterval) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline, !Task.isCancelled {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            if let (_, response) = try? await session.data(for: request), response is HTTPURLResponse { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }
}
