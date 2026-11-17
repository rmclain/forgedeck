import ForgeDeckKit
import SwiftUI

// Environments a repository proposes in .forgedeck/environments.json, usually written by an agent.
// The card says what the file proposes; the sheet is the review. Nothing is added without it.

extension AppModel {
    /// Proposals that would change something or have a problem. Ones already set up are left out.
    func environmentProposals(_ product: Product) -> [EnvironmentProposal] {
        let files = product.isDemo ? DemoFixtures.environmentProposals(for: product) : (environmentFiles[product.id] ?? [])
        return EnvironmentProposals.plan(product, files: files).filter { !$0.changes.isEmpty || !$0.problems.isEmpty }
    }

    func environmentFileErrors(_ product: Product) -> [String] {
        (environmentFiles[product.id] ?? []).compactMap { file in file.error.map { "\(file.checkoutName): \($0)" } }
    }

    /// Adds the chosen proposals. Only additions: nothing that exists is removed or replaced.
    func addProposedEnvironments(_ chosen: [EnvironmentProposal], to product: Product) {
        guard !product.isDemo else { return show("\(product.name) is a demo product. Its proposals are a fixture.", isError: true) }
        // Checked again against the product as it is now, in case it changed while the sheet was open.
        let current = self.product(product.id) ?? product
        let fresh = EnvironmentProposals.plan(current, files: environmentFiles[product.id] ?? [])
        let wanted = Set(chosen.map(\.id))
        let addable = fresh.filter { wanted.contains($0.id) && $0.isAddable }
        guard !addable.isEmpty else { return show("Nothing to add: the environments changed since the review.", isError: true) }
        update(product.id) { product in
            for proposal in addable {
                // Each one is planned against the product including the ones added before it.
                EnvironmentProposals.apply(EnvironmentProposals.check(proposal.entry, in: product, id: proposal.id), to: &product)
            }
        }
        for proposal in addable {
            record("environment.add", product: product, environment: proposal.name,
                   detail: "source=\(EnvironmentProposals.relativePath) tier=\(proposal.tier?.rawValue ?? "") changes=\(proposal.changes.count)")
        }
        show(addable.count == 1 ? "Added \(addable[0].name)" : "Added \(addable.count) environments")
        // Run the new checks at once. refresh reads the product as saved now.
        Task { await refresh(product, announce: false) }
    }
}

struct ProposedEnvironmentsCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let proposals = model.environmentProposals(product)
        let addable = proposals.filter(\.isAddable)
        let production = addable.contains(where: \.isProduction)
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Proposed environments", subtitle: "From \(EnvironmentProposals.relativePath) in the repository") {
                if product.isDemo { DemoBadge() }
                Button("Review…") { model.sheet = .environmentProposals(product.id) }
                    .buttonStyle(.kit(.secondary, compact: true))
                    .help("See each proposed environment and choose what to add. Nothing is added until you do.")
            }
            .padding(Space.lg)
            ForEach(proposals) { proposal in
                HStack(spacing: Space.sm) {
                    Icon(proposal.problems.isEmpty ? .globe : .alert, size: 12)
                        .foregroundStyle(proposal.problems.isEmpty ? (proposal.isProduction ? Ink.prod : Ink.text2) : Ink.warn)
                    Text(proposal.name).kitType(.labelMedium, proposal.isProduction ? Ink.prod : Ink.text)
                    Text(summary(proposal)).kitType(.label, Ink.text2).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                .hairlineAbove()
                .accessibilityElement(children: .combine)
            }
            if production {
                Text("Includes production. Review it before \(Brand.name) treats it as production.")
                    .kitType(.meta, Ink.text3).padding(.horizontal, Space.lg).padding(.vertical, Space.sm).hairlineAbove()
            }
        }
        .card()
    }

    private func summary(_ proposal: EnvironmentProposal) -> String {
        if !proposal.problems.isEmpty { return proposal.problems.count == 1 ? "1 problem to fix in the file" : "\(proposal.problems.count) problems to fix in the file" }
        if proposal.existingID == nil { return "New · " + proposal.changes.dropFirst().joined(separator: " · ") }
        return "Adds " + proposal.changes.joined(separator: " · ")
    }
}

struct EnvironmentProposalsSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    @State private var chosen: Set<String> = []
    @State private var loaded = false

    var body: some View {
        let product = model.product(productID)
        let proposals = product.map { model.environmentProposals($0) } ?? []
        let selected = proposals.filter { chosen.contains($0.id) && $0.isAddable }
        let production = selected.contains(where: \.isProduction)
        SheetPanel(width: 600, stripe: production ? Ink.prod : nil) {
            SheetHeader(icon: .globe, tone: production ? .prod : .accent, title: "Review Proposed Environments",
                        message: "\(product?.name ?? "This product")'s repository proposes these in \(EnvironmentProposals.relativePath). Adding one only adds: nothing that exists is removed or replaced.")
            let list = VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(proposals) { proposal in row(proposal) }
            }
            .padding(.horizontal, Space.xl)
            // A few proposals fit as they are; a long file scrolls.
            if proposals.count <= 4 { list } else { ScrollView { list }.frame(height: 420) }
            SheetFooter(note: production ? "Production checks become Verified only when the Version URL answers." : "Edit the file and refresh to change a proposal.") {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button(selected.count <= 1 ? "Add Environment" : "Add \(selected.count) Environments") {
                    model.sheet = nil
                    if let product { model.addProposedEnvironments(selected, to: product) }
                }
                .buttonStyle(.kit(production ? .production : .primary)).keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || product?.isDemo != false)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            chosen = Set(proposals.filter(\.isAddable).map(\.id))
        }
    }

    private func row(_ proposal: EnvironmentProposal) -> some View {
        let tone = proposal.isProduction ? Ink.prod : Ink.text
        return HStack(alignment: .top, spacing: Space.md) {
            Toggle("", isOn: Binding(get: { chosen.contains(proposal.id) }, set: { on in
                if on { chosen.insert(proposal.id) } else { chosen.remove(proposal.id) }
            }))
            .toggleStyle(.checkbox).labelsHidden().disabled(!proposal.isAddable)
            .accessibilityLabel("Add \(proposal.name)")
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    Text(proposal.name).kitType(.labelMedium, tone)
                    TagBadge(proposal.tier?.title ?? proposal.entry.tier)
                    if proposal.existingID != nil { Text("adds to the existing environment").kitType(.meta, Ink.text3) }
                }
                if proposal.problems.isEmpty {
                    ForEach(proposal.changes, id: \.self) { change in
                        Text("+ \(change)").kitType(.monoSmall, Ink.text2).lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    ForEach(proposal.problems, id: \.self) { problem in
                        Text(problem).kitType(.meta, Ink.warn).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note = proposal.entry.note, !note.isEmpty {
                    Text("Why: \(String(note.prefix(240)))").kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Metric.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Metric.controlRadius).stroke(proposal.isProduction && proposal.isAddable ? Ink.prod.opacity(0.5) : Ink.line, lineWidth: Metric.hairline))
    }
}
