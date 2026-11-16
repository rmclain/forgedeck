import AppKit
import ForgeDeckKit
import SwiftUI

extension AppModel {
    /// WordPress installs in the usual places and in the code folders from Settings.
    var wordPressSites: [WordPressSite] {
        let _ = linksVersion
        return InstallLinks.findWordPressSites(roots: InstallLinks.defaultSearchRoots(extra: portfolio.settings.projectRoots))
    }

    func addLink(_ link: InstallLink, to product: Product, create: Bool) {
        guard let checkout = product.checkout(id: link.checkoutID) else { return }
        do {
            if create { try InstallLinks.create(link, checkout: checkout) }
            update(product.id) { product in
                if !product.installLinks.contains(where: { $0.linkPath == link.linkPath }) { product.installLinks.append(link) }
            }
            record(create ? "link.create" : "link.adopt", product: product, detail: "path=\(abbreviate(link.linkPath))")
            show(create ? "Linked \(link.linkName) into \(link.siteName.isEmpty ? abbreviate(link.destinationFolder) : link.siteName)" : "Now tracking \(link.linkName) in \(link.siteName)")
        } catch {
            show(String(describing: error), isError: true)
        }
        linksVersion += 1
    }

    func relink(_ link: InstallLink, in product: Product) {
        guard let checkout = product.checkout(id: link.checkoutID) else { return }
        do {
            try InstallLinks.create(link, checkout: checkout)
            record("link.create", product: product, detail: "path=\(abbreviate(link.linkPath))")
            show("Linked \(link.linkName)")
        } catch {
            show(String(describing: error), isError: true)
        }
        linksVersion += 1
    }

    func unlink(_ link: InstallLink, in product: Product, forget: Bool) {
        guard let checkout = product.checkout(id: link.checkoutID) else { return }
        do {
            try InstallLinks.remove(link, checkout: checkout)
            if forget { update(product.id) { $0.installLinks.removeAll { $0.id == link.id } } }
            record("link.remove", product: product, detail: "path=\(abbreviate(link.linkPath))")
            show("Removed the link. \(checkout.name) was not touched.")
        } catch {
            show(String(describing: error), isError: true)
        }
        linksVersion += 1
    }

    func moveAside(_ link: InstallLink, in product: Product) {
        guard let checkout = product.checkout(id: link.checkoutID) else { return }
        let backupFolder = InstallLinks.backupFolder(for: link.destinationFolder)
        sheet = .confirm(ConfirmRequest(
            title: "Replace the copy of \(link.linkName) with a link?",
            message: "The folder in \(link.siteName.isEmpty ? "the destination" : link.siteName) is moved, not deleted. The site then loads \(checkout.name) directly.",
            checks: [.init(label: "Copy moves to", meta: abbreviate(backupFolder), ok: true),
                     .init(label: "Link points at", meta: abbreviate(InstallLinks.source(of: link, checkout: checkout)), ok: true)],
            footnote: "Deactivate the plugin first if the site is running.", confirmLabel: "Replace") { [weak self] in
            guard let self else { return }
            do {
                let backup = try InstallLinks.moveAsideAndLink(link, checkout: checkout, backupFolder: backupFolder)
                self.update(product.id) { product in
                    if !product.installLinks.contains(where: { $0.linkPath == link.linkPath }) { product.installLinks.append(link) }
                }
                self.record("link.replace-copy", product: product, detail: "path=\(abbreviate(link.linkPath)) backup=\(abbreviate(backup))")
                self.show("Linked. The old copy is in \(abbreviate(backup)).")
            } catch {
                self.show(String(describing: error), isError: true)
            }
            self.linksVersion += 1
        })
    }

    func linkIntoFolder(_ product: Product, checkout: LocalCheckout) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link Here"
        panel.message = "Choose the folder that should load \(checkout.name), like a site's wp-content/plugins. A link named \(checkout.name) is created inside it."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var link = InstallLink()
        link.checkoutID = checkout.id
        link.destinationFolder = folder.path
        link.linkName = (checkout.path as NSString).lastPathComponent
        let package = InstallLinks.package(at: checkout.path)
        link.kind = package?.kind ?? .folder
        link.siteName = folder.lastPathComponent
        addLink(link, to: product, create: true)
    }
}

struct InstallLinksCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let _ = model.linksVersion
        let sites = product.isDemo ? [] : model.wordPressSites
        let packages = product.checkouts.compactMap { checkout in InstallLinks.package(at: checkout.path).map { (checkout, $0) } }
        let adoptable = product.checkouts.flatMap { InstallLinks.existingLinks(into: $0, sites: sites) }
            .filter { found in !product.installLinks.contains { $0.linkPath == found.linkPath } }
        let suggestions = packages.flatMap { checkout, _ in InstallLinks.suggestions(for: checkout, existing: product.installLinks + adoptable, sites: sites) }
        if !product.installLinks.isEmpty || !packages.isEmpty || !adoptable.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Install links", subtitle: packages.first.map { "\($0.1.kind.title): \($0.1.name)\($0.1.version.map { " \($0)" } ?? "")" } ?? "Symlinks from a checkout into folders that load it") {
                    let open = suggestions.filter { !$0.hasCopy }
                    if !open.isEmpty {
                        Menu("Link into Site") {
                            ForEach(open) { suggestion in
                                Button(suggestion.site.name) { model.addLink(suggestion.link, to: product, create: true) }
                            }
                        }
                        .menuStyle(.button).buttonStyle(.kit(.primary, compact: true)).fixedSize()
                        .help("Local WordPress sites on this Mac that do not have this \(packages.first?.1.kind == .wordpressTheme ? "theme" : "plugin") yet")
                    }
                    if let checkout = product.primaryCheckout {
                        Button("Link into Folder…") { model.linkIntoFolder(product, checkout: checkout) }
                            .buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                    }
                }
                .padding(Space.lg)
                ForEach(product.installLinks) { link in row(link) }
                if product.installLinks.isEmpty && adoptable.isEmpty && !suggestions.contains(where: \.hasCopy) {
                    Text(sites.isEmpty ? "No local WordPress site was found in ~/Local Sites, ~/Sites, or your code folders. Use Link into Folder for another location."
                                       : "Not linked into any of the \(sites.count) local sites yet. Use Link into Site.")
                        .kitType(.label, Ink.text2).padding(.horizontal, Space.lg).padding(.bottom, Space.md)
                }
                ForEach(adoptable, id: \.linkPath) { link in
                    ActionRow(icon: .link, tone: .ok, title: "\(link.siteName) · \(link.linkName)", subtitle: "Already linked to this checkout by hand. \(abbreviate(link.linkPath))") {
                        Button("Track") { model.addLink(link, to: product, create: false) }.buttonStyle(.kit(.secondary, compact: true))
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
                }
                ForEach(suggestions.filter(\.hasCopy)) { suggestion in
                    let mine = packages.first { $0.0.id == suggestion.link.checkoutID }?.1.version
                    ActionRow(icon: .alert, tone: .warn, title: "\(suggestion.site.name) · \(suggestion.link.linkName)",
                              subtitle: "Has its own copy\(suggestion.copyVersion.map { ", version \($0)" } ?? "")\(mine.map { " (yours is \($0))" } ?? ""). Replace it with a link to stay in sync.") {
                        Button("Replace Copy with Link…") { model.moveAside(suggestion.link, in: product) }.buttonStyle(.kit(.secondary, compact: true))
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
                }
                Text("A symlink, not a Finder alias: WordPress follows symlinks, not aliases. Works with Local, which runs PHP on this Mac. Docker-based setups (wp-env, DDEV) cannot see links that point outside their mounted folders. A copy that is in the way is moved to wp-content/forgedeck-backups, never deleted.")
                    .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                    .padding(Space.lg).hairlineAbove()
            }
            .card()
        }
    }

    private func row(_ link: InstallLink) -> some View {
        let checkout = product.checkout(id: link.checkoutID)
        let state = checkout.map { InstallLinks.state(of: link, checkout: $0) } ?? .sourceMissing
        return ActionRow(icon: .link, tone: state.tone, title: "\(link.siteName.isEmpty ? (link.destinationFolder as NSString).lastPathComponent : link.siteName) · \(link.linkName)",
                         subtitle: detail(state, link)) {
            StatusPill(state.title, tone: state.tone)
            switch state {
            case .notLinked, .broken:
                Button("Link") { model.relink(link, in: product) }.buttonStyle(.kit(.secondary, compact: true))
            case .blockedByCopy:
                Button("Replace Copy…") { model.moveAside(link, in: product) }.buttonStyle(.kit(.secondary, compact: true))
            case .linked:
                Button("Unlink") { model.unlink(link, in: product, forget: false) }.buttonStyle(.kit(.secondary, compact: true))
                    .help("Removes the symlink only. The checkout is not touched.")
            default:
                EmptyView()
            }
            IconButton(.finder, label: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: FileManager.default.fileExists(atPath: link.linkPath) ? link.linkPath : link.destinationFolder)])
            }
            Menu {
                Button("Stop Tracking") { model.update(product.id) { $0.installLinks.removeAll { $0.id == link.id } } }
                if state == .linked { Button("Unlink and Stop Tracking") { model.unlink(link, in: product, forget: true) } }
            } label: { Icon(.more, size: 12) }
            .menuStyle(.button).buttonStyle(.kit(.icon)).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More for \(link.linkName)")
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.xs).hairlineAbove()
    }

    private func detail(_ state: InstallLinkState, _ link: InstallLink) -> String {
        switch state {
        case .linked: abbreviate(link.linkPath) + (link.sourceSubpath.isEmpty ? "" : " → \(link.sourceSubpath)/")
        case .notLinked: "Nothing at \(abbreviate(link.linkPath)) yet."
        case .broken(let target): "The link points at \(abbreviate(target)), which is gone."
        case .pointsElsewhere(let target): "The link points at \(abbreviate(target)), not this checkout. Left alone."
        case .blockedByCopy(let version): "A real folder is there\(version.map { ", version \($0)" } ?? ""). It is not linked."
        case .destinationMissing: "\(abbreviate(link.destinationFolder)) is gone. Was the site deleted?"
        case .sourceMissing: "The folder to link is missing from the checkout."
        }
    }
}
