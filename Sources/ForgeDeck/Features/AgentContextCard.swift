import ForgeDeckKit
import SwiftUI

/// Which other products an AI agent should know about when it starts in this one.
struct AgentContextCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let candidates = model.activeProducts.filter { candidate in candidate.id != product.id && !product.contextLinks.contains { $0.productID == candidate.id } }
        let agent = model.portfolio.settings.aiAgentProgram
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Agent context", subtitle: "Related repositories \(AgentCatalog.name(agent)) can read when it starts here") {
                Menu("Link Product") {
                    ForEach(candidates) { candidate in Button(candidate.name) { model.link(candidate, to: product) } }
                }
                .menuStyle(.button).buttonStyle(.kit(.secondary, compact: true)).fixedSize().disabled(candidates.isEmpty || product.isDemo)
                Button("Copy Command") { model.copyAgentCommand(product) }.buttonStyle(.kit(.secondary, compact: true))
                    .disabled(product.isDemo || !product.hasLocal).help("Copies the agent command with its context flags, to paste in any terminal")
                Button { model.openAgent(product) } label: {
                    HStack(spacing: Space.xs) { Icon(.sparkle, size: 11); Text("Open \(AgentCatalog.name(agent))") }
                }
                .buttonStyle(.kit(.primary, compact: true)).disabled(product.isDemo || !product.hasLocal)
            }
            .padding(Space.lg)
            if product.contextLinks.isEmpty {
                Text("No related products yet. Link the ones this product talks to: its API, its plugin, a shared library. The agent then gets a short map of each and can read their real files. Nothing is loaded until it needs it.")
                    .kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
            }
            ForEach(product.contextLinks) { link in
                if let related = model.product(link.productID) { row(link, related) }
            }
            Text("How it stays cheap: the agent's prompt gets one line pointing at CONTEXT.md. That file is a map (a few thousand tokens at most). Packs and real files are read only when needed. Claude Code gets each related checkout with --add-dir; Codex and OpenCode get the pointer as their first prompt.")
                .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                .padding(Space.lg).hairlineAbove()
        }
        .card()
    }

    private func row(_ link: ContextLink, _ related: Product) -> some View {
        let builder = PackBuilder(location: model.contextLocation)
        let packs = related.checkouts.compactMap { checkout in builder.info(checkout).map { (checkout, $0) } }
        let stale = packs.contains { !$0.1.isCurrent(for: model.cache.git[$0.0.id]) }
        let graph = related.checkouts.contains { RepoBrief.graphExists($0.path) }
        let summary: String = related.checkouts.isEmpty ? "No local checkout: the brief links to GitHub"
            : packs.isEmpty ? "\(related.checkouts.count) checkout\(related.checkouts.count == 1 ? "" : "s"), no pack yet"
            : packs.allSatisfy({ !$0.1.packKept }) ? "Map only (the full pack was too large)\(stale ? ", stale" : ", current")"
            : "Pack ~\(packs.reduce(0) { $0 + $1.1.approxTokens } / 1_000)k tokens\(stale ? ", stale" : ", current") · built \(RelativeTime.short(packs.map(\.1.builtAt).max() ?? .now, now: model.now))"
        return HStack(spacing: Space.md) {
            ProjectIcon(related, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(related.name).kitType(.labelMedium)
                    if graph { TagBadge("graphify", tone: .accent).help("This checkout has a graphify graph. Its summary goes into the brief, and the agent can query it.") }
                    if related.isDemo { DemoBadge() }
                }
                Text(summary).kitType(.meta, stale ? Ink.warn : Ink.text3).lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            Toggle("Include repo map", isOn: Binding(get: { link.includePack }, set: { model.setPack($0, for: link, in: product) }))
                .toggleStyle(.checkbox).font(KitType.label.font)
                .help("Adds a ranked outline of the most-used files (about 1.5k tokens) and a pointer to the full compressed pack")
            Button(model.packing.contains(related.id) ? "Packing…" : packs.isEmpty ? "Build Pack" : "Rebuild") { model.buildPacks(for: related) }
                .buttonStyle(.kit(.secondary, compact: true))
                .disabled(model.packing.contains(related.id) || related.isDemo || related.checkouts.isEmpty)
                .help("Runs repomix --compress on this product's checkouts. Needs Node. The pack stays in ForgeDeck's data folder.")
            IconButton(.trash, label: "Unlink \(related.name)") { model.unlink(link, from: product) }
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
        .hairlineAbove()
    }
}
