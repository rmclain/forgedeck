import ForgeDeckKit
import SwiftUI

// The Memory tab: rules and key facts per product. Every agent session ForgeDeck starts reads them in its prompt,
// and adds what it learns through .forgedeck/memory.json, which lands here within a second while it runs.
// The person adds, edits, and deletes items; nothing here leaves this Mac.

extension AppModel {
    /// Shows the product's Memory tab with the cursor in the add field.
    func newMemory(_ product: Product) {
        route = .product(product.id)
        productTab = .memory
        focusMemoryField = true
    }

    @discardableResult
    func addMemory(_ text: String, kind: MemoryNote.Kind, to product: Product) -> Bool {
        guard !product.isDemo, let note = ProductMemory.make(text, kind: kind) else { return false }
        let current = self.product(product.id)?.memory ?? []
        guard !ProductMemory.contains(note.text, in: current) else {
            show("\(product.name)'s memory already has that.", isError: true)
            return false
        }
        guard current.count < ProductMemory.maxItems else {
            show("\(product.name)'s memory is full (\(ProductMemory.maxItems) items). Delete some first.", isError: true)
            return false
        }
        update(product.id) { $0.memory = ($0.memory ?? []) + [note] }
        record("memory.add", product: product, detail: "kind=\(kind.rawValue) by=person")
        rewriteContext(product)
        return true
    }

    func updateMemory(_ id: UUID, in product: Product, _ change: (inout MemoryNote) -> Void) {
        update(product.id) { product in
            guard let index = product.memory?.firstIndex(where: { $0.id == id }) else { return }
            change(&product.memory![index])
        }
        record("memory.edit", product: product)
        rewriteContext(product)
    }

    func deleteMemory(_ note: MemoryNote, from product: Product) {
        update(product.id) { $0.memory?.removeAll { $0.id == note.id } }
        record("memory.delete", product: product, detail: "kind=\(note.kind.rawValue)")
        rewriteContext(product)
        show("Deleted from \(product.name)'s memory.")
    }

    /// Moves what an agent wrote in .forgedeck/memory.json into the memory, then empties the file.
    func applyMemoryFiles(_ inboxes: [ProductMemory.Inbox], to productID: UUID) {
        let inboxes = inboxes.filter { !$0.entries.isEmpty }
        guard !inboxes.isEmpty, let product = product(productID), !product.isDemo else { return }
        let program = portfolio.settings.aiAgentProgram
        let result = ProductMemory.merge(inboxes.flatMap(\.entries), into: product.memory ?? [], by: program)
        if !result.added.isEmpty {
            update(productID) { $0.memory = result.notes }
            record("memory.add", product: product, detail: "count=\(result.added.count) by=agent")
            rewriteContext(product)
        }
        for inbox in inboxes { ProductMemory.empty(inbox) }
        let agent = AgentCatalog.name(program)
        if result.leftOut > 0 {
            show("\(product.name)'s memory is full, so \(result.leftOut) item\(result.leftOut == 1 ? "" : "s") from \(agent) were left out. Delete some in Memory.", isError: true)
        } else if !result.added.isEmpty {
            show(result.added.count == 1 ? "\(agent) added to \(product.name)'s memory: \u{201C}\(result.added[0].text.prefix(60))\u{201D}"
                                         : "\(agent) added \(result.added.count) items to \(product.name)'s memory.")
        }
    }
}

struct MemoryTab: View {
    @Environment(AppModel.self) private var model
    let product: Product
    @State private var draft = ""
    @State private var kind = MemoryNote.Kind.rule
    @State private var editingID: UUID?
    @State private var editText = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        let notes = ProductMemory.sorted(product.memory ?? [])
        let agent = AgentCatalog.name(model.portfolio.settings.aiAgentProgram)
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Memory", subtitle: "Rules and key facts for \(product.name). Every \(agent) session started from \(Brand.name) reads them first, and adds what it learns.") {
                    if product.isDemo { DemoBadge() }
                }
                .padding(Space.lg)
                HStack(spacing: Space.sm) {
                    SegmentedPill(options: MemoryNote.Kind.allCases.map { ($0, $0.title) }, selection: $kind, compact: true)
                        .fixedSize()
                        .help("Rule: something to always or never do. Note: a fact worth knowing.")
                    KitField(placeholder: kind == .rule ? "Always or never… One sentence." : "A key fact: where something lives, a decision and why.",
                             text: $draft, icon: .plus)
                        .focused($addFocused)
                        .onSubmit(add)
                    Button("Add") { add() }.buttonStyle(.kit(.secondary, compact: true))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || product.isDemo)
                }
                .disabled(product.isDemo)
                .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
                if notes.isEmpty {
                    Text("Nothing saved yet. Add a rule you keep repeating, or let \(agent) add what it learns while it works.")
                        .kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.lg).padding(.vertical, Space.md).hairlineAbove()
                }
                ForEach(notes) { note in
                    if editingID == note.id { editor(note) } else { row(note) }
                }
            }
            .card()
            Text("Agents add items by writing \(ProductMemory.relativePath) in the product's folder. They appear here within a second while a session runs, or on the next refresh. "
                 + "\(Brand.name) keeps up to \(ProductMemory.maxItems) items; secrets are removed before anything is saved.")
                .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.xs)
        }
        .onChange(of: model.focusMemoryField) { _, wanted in
            if wanted { addFocused = true; model.focusMemoryField = false }
        }
        .onAppear {
            if model.focusMemoryField { addFocused = true; model.focusMemoryField = false }
        }
    }

    private func add() {
        if model.addMemory(draft, kind: kind, to: product) { draft = "" }
    }

    private func row(_ note: MemoryNote) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            TagBadge(note.kind.title, tone: note.kind == .rule ? .accent : .muted)
                .frame(width: 44, alignment: .leading) // grid: ok fixed badge column so the text lines up
            VStack(alignment: .leading, spacing: 2) {
                Text(note.text).kitType(.labelMedium).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text(meta(note)).kitType(.meta, Ink.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if !product.isDemo { startEditing(note) } }
            Menu {
                Button("Edit") { startEditing(note) }
                Button(note.kind == .rule ? "Make It a Note" : "Make It a Rule") {
                    model.updateMemory(note.id, in: product) { $0.kind = note.kind == .rule ? .note : .rule }
                }
                Divider()
                Button("Delete", role: .destructive) { model.deleteMemory(note, from: product) }
            } label: { Icon(.more, size: 13) }
                .menuStyle(.button).buttonStyle(.kit(.icon)).menuIndicator(.hidden).fixedSize()
                .disabled(product.isDemo)
                .help("Edit, change, or delete this item").accessibilityLabel("More for this \(note.kind.title.lowercased())")
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
        .hairlineAbove()
    }

    private func meta(_ note: MemoryNote) -> String {
        let by = note.addedBy.map { "Added by \(AgentCatalog.name($0))" } ?? "Added by you"
        return "\(by) \(note.createdAt.formatted(.relative(presentation: .named)))"
    }

    private func startEditing(_ note: MemoryNote) {
        editText = note.text
        editingID = note.id
    }

    private func editor(_ note: MemoryNote) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            KitField(placeholder: "One sentence", text: $editText)
                .onSubmit { save(note) }
            HStack {
                Spacer()
                Button("Cancel") { editingID = nil }.buttonStyle(.kit(.ghost, compact: true)).keyboardShortcut(.cancelAction)
                Button("Save") { save(note) }
                    .buttonStyle(.kit(.secondary, compact: true))
                    .disabled(ProductMemory.clean(editText).isEmpty)
            }
        }
        .padding(Space.lg)
        .hairlineAbove()
    }

    private func save(_ note: MemoryNote) {
        let text = ProductMemory.clean(editText)
        guard !text.isEmpty else { return }
        if text != note.text { model.updateMemory(note.id, in: product) { $0.text = text } }
        editingID = nil
    }
}
