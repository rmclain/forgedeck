import ForgeDeckKit
import SwiftUI

// Set Up Leads: ForgeDeck makes the companion token in the Keychain, then the agent finds what the product collects
// (leads, signups, purchases), asks which ones to track, and sets up the check. The agent never sees the token;
// the prompt carries only its SHA-256 for the server.

extension AppModel {
    /// The token variable for an environment, when one exists in that environment's own scope.
    func leadsToken(_ product: Product, environment: ProductEnvironment) -> VariableDefinition? {
        let key = LeadsSetup.tokenVariable(for: environment.tier)
        return portfolio.variables.first { $0.key == key && $0.scope == .environment(product: product.id, environment: environment.id) }
    }

    func setUpLeads(_ product: Product) {
        guard !product.isDemo else { return show("\(product.name) is a demo product. Its leads come from a fixture.", isError: true) }
        guard product.hasLocal else { return show("\(product.name) has no folder on this Mac for the agent to work in.", isError: true) }
        guard LeadsSetup.target(in: product) != nil else {
            sheet = .environment(productID: product.id)
            return show("Add the environment leads come from first, usually Production.")
        }
        sheet = .leadsSetup(product.id)
    }

    /// Makes the token when needed, then starts the agent.
    func startLeadsSetup(_ product: Product, environmentID: UUID, newToken: Bool) {
        guard let product = self.product(product.id), let environment = product.environment(id: environmentID),
              let checkout = product.primaryCheckout else { return }
        let key = LeadsSetup.tokenVariable(for: environment.tier)
        let existing = leadsToken(product, environment: environment)
        var hash: String?
        if existing == nil || newToken {
            let token = LeadsSetup.generateToken()
            var draft = VariableDraft()
            draft.existingID = existing?.id
            draft.key = key
            draft.scope = .environment(product: product.id, environment: environment.id)
            draft.isSecret = true
            draft.value = token
            draft.allowedTiers = [environment.tier]
            draft.note = "\(Brand.name) companion token (\(LeadsSetup.scopes.joined(separator: ", "))). Only its SHA-256 goes on the server."
            if let error = saveVariable(draft) { return show("Could not save the token: \(error)", isError: true) }
            hash = LeadsSetup.hash(token)
        }
        let site = localSites.first { $0.contains(checkout.path) }
        let prompt = LeadsSetup.prompt(for: product, environment: environment, checkout: checkout, tokenVariable: key, tokenHash: hash,
                                       cli: cliCommand, localSite: site)
        startSetupAgent(product, checkout: checkout, prompt: prompt, title: "Set Up Leads", audit: "leads.setup")
    }
}

struct LeadsSetupSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    @State private var environmentID: UUID?
    @State private var newToken = false

    var body: some View {
        let product = model.product(productID)
        let environments = product?.environments ?? []
        let environment = environments.first { $0.id == environmentID } ?? product.flatMap(LeadsSetup.target)
        let existing = product.flatMap { product in environment.flatMap { model.leadsToken(product, environment: $0) } }
        let agent = AgentCatalog.name(model.portfolio.settings.aiAgentProgram)
        SheetPanel(width: 560) {
            SheetHeader(icon: .leads, tone: .accent, title: "Set Up Leads",
                        message: "\(agent) looks at what \(product?.name ?? "the product") collects (leads, signups, purchases, bookings), tells you, and asks which ones \(Brand.name) should see. It builds the check only after you say yes, in a change you review.")
            VStack(alignment: .leading, spacing: Space.lg) {
                if environments.count > 1, let environment {
                    LabeledField(label: "Leads come from") {
                        SegmentedPill(options: environments.map { ($0.id, $0.name) },
                                      selection: Binding(get: { environment.id }, set: { environmentID = $0 }))
                    }
                }
                if let environment {
                    let key = LeadsSetup.tokenVariable(for: environment.tier)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.sm) {
                            Icon(.key, size: 12).foregroundStyle(Ink.text2)
                            Text(key).kitType(.monoSmall, Ink.text)
                            TagBadge(existing == nil || newToken ? "New token" : "Exists")
                        }
                        Text(existing == nil || newToken
                             ? "\(Brand.name) makes a token for \(environment.name) and keeps it in the Keychain. \(agent) gets only its SHA-256 to put on the server."
                             : "The token in the Keychain is used. \(agent) never sees it. If the server does not have its hash yet, make a new one.")
                            .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                        if existing != nil {
                            Toggle("Make a new token (the server needs the new hash)", isOn: $newToken).toggleStyle(.checkbox).kitType(.label, Ink.text2)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.xl)
            SheetFooter(note: "Nothing is deployed. Leads show up after you review the metrics source it proposes.") {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button("Start \(agent)") {
                    model.sheet = nil
                    if let product, let environment { model.startLeadsSetup(product, environmentID: environment.id, newToken: newToken) }
                }
                .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
                .disabled(product?.isDemo != false || environment == nil)
            }
        }
    }
}
