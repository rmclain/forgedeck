import ForgeDeckKit
import SwiftUI

/// MCP servers per product, read from agent config files and product code on this Mac.
/// Nothing connects to a server and no credential is read, so a refresh always gives the same answer for the same files.
extension AppModel {
    /// Reads the agents' configs and scans every real checkout, off the main thread.
    /// `only` limits the code scan to one product's checkouts; configs are always read again.
    func refreshMCP(only product: Product? = nil) {
        guard !Runtime.isAutomated || agentHome != nil else { return }
        let home = agentHomeURL
        let checkouts = (product.map { [$0] } ?? activeProducts).filter { !$0.isDemo }.flatMap(\.checkouts).map(\.path)
        mcpScanning = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> ([MCPServerEntry], [String: MCPServerCode], Set<String>) in
                var entries = MCPInventory.configured(home: home)
                var code: [String: MCPServerCode] = [:]
                for path in Set(checkouts) where FileManager.default.fileExists(atPath: path) {
                    entries += MCPInventory.repositoryServers(checkout: path)
                    if let found = MCPInventory.scan(checkout: path) { code[path] = found }
                }
                return (entries, code, Set(checkouts))
            }.value
            mcpEntries = result.0
            // A partial scan replaces only the checkouts it read.
            mcpCode = mcpCode.filter { !result.2.contains($0.key) }.merging(result.1) { _, new in new }
            mcpCache.removeAll()
            mcpScanning = false
            mcpVersion += 1
        }
    }

    /// What ForgeDeck knows about a product's MCP servers. Demo products get labeled demo data.
    func mcpInfo(_ product: Product) -> MCPProductInfo {
        if product.isDemo { return DemoFixtures.mcp(for: product) ?? MCPProductInfo() }
        if let cached = mcpCache[product.id], cached.product == product { return cached.info }
        let paths = Set(product.checkouts.map(\.path))
        let info = MCPProductInfo(connections: MCPInventory.connections(for: product, entries: mcpEntries),
                                  code: mcpCode.filter { paths.contains($0.key) })
        mcpCache[product.id] = (product, info)
        return info
    }

    /// Configured servers that belong to no product, for the Toolbox list.
    var unmatchedMCPEntries: [MCPServerEntry] {
        let matched = Set(activeProducts.flatMap { mcpInfo($0).connections.map(\.entry.id) })
        return mcpEntries.filter { !matched.contains($0.id) }
    }
}

// MARK: Badge

/// "MCP" on product cards, headers, and sidebar rows. Drawn in the production color when a connection reaches production.
struct MCPBadge: View {
    @Environment(AppModel.self) private var model
    let product: Product
    var compact = false

    var body: some View {
        let _ = model.mcpVersion
        let info = model.mcpInfo(product)
        if !info.isEmpty {
            let production = info.reachesProduction
            let help = helpText(info)
            Button {
                model.open(product)
                model.productTab = .overview
            } label: {
                if compact {
                    Icon(.mcp, size: 10, weight: .semibold).foregroundStyle(production ? Ink.prod : Ink.accentText)
                } else {
                    HStack(spacing: Space.xs) {
                        Icon(.mcp, size: 10, weight: .semibold)
                        Text(compactTitle(info)).kitType(.metaMedium, production ? Ink.prod : Ink.accentText).lineLimit(1)
                    }
                    .foregroundStyle(production ? Ink.prod : Ink.accentText)
                    .padding(.horizontal, 6).padding(.vertical, 1) // grid: ok pill inset from the design
                    .background((production ? Ink.prod : Ink.accent).soft(), in: RoundedRectangle(cornerRadius: Metric.chipRadius))
                }
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(help)
            .accessibilityLabel(help)
        }
    }

    private func compactTitle(_ info: MCPProductInfo) -> String {
        info.reachesProduction ? "MCP · production" : info.serverNames.isEmpty ? "MCP server" : "MCP"
    }

    private func helpText(_ info: MCPProductInfo) -> String {
        var lines = info.connections.map { "\($0.entry.name): \($0.entry.whereTitle), \($0.reachTitle.lowercased())" }
        if let code = info.primaryCode, code.servesMCP { lines.append("Serves MCP: \(code.tools.count) tool\(code.tools.count == 1 ? "" : "s") in its code") }
        if info.connections.isEmpty { lines.append("No agent on this Mac is set up to use it") }
        return lines.joined(separator: "\n")
    }
}

// MARK: Product card

/// The MCP card on a product's Overview tab: connections, the tools in the code, and how to use them.
struct MCPCard: View {
    @Environment(AppModel.self) private var model
    let product: Product
    @State private var showAllTools = false
    @State private var showInstructions = false

    var body: some View {
        let _ = model.mcpVersion
        let info = model.mcpInfo(product)
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "MCP", subtitle: subtitle(info)) {
                if product.isDemo { DemoBadge() }
                IconButton(.sync, label: "Read the MCP configs and code again") { model.refreshMCP(only: product) }
                    .disabled(model.mcpScanning || product.isDemo)
            }
            .padding(Space.lg)
            ForEach(info.connections) { connection in connectionRow(connection) }
            if let code = info.primaryCode, code.servesMCP { codeSection(code) }
            usage(info)
        }
        .card()
    }

    private func subtitle(_ info: MCPProductInfo) -> String {
        let serves = info.servesMCP ? "Serves MCP" : nil
        let connected = info.connections.isEmpty ? "no agent is set up to use it" : "\(info.serverNames.count) connection\(info.serverNames.count == 1 ? "" : "s") on this Mac"
        return [serves, connected].compactMap { $0 }.joined(separator: " · ") + ". Read from local files only."
    }

    private func connectionRow(_ connection: MCPConnection) -> some View {
        let entry = connection.entry
        return HStack(alignment: .top, spacing: Space.md) {
            Icon(entry.transport == .stdio ? .terminal : .globe, size: 13).foregroundStyle(connection.isProduction ? Ink.prod : Ink.text2)
                .frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(entry.name).kitType(.mono, Ink.text)
                    TagBadge(connection.reachTitle, tone: connection.isProduction ? .prod : entry.reach == .internet ? .warn : .muted)
                    if product.isDemo { DemoBadge() }
                }
                Text([entry.whereTitle, entry.host ?? entry.package ?? entry.program, entry.transport.rawValue.uppercased()].compactMap { $0 }.joined(separator: " · "))
                    .kitType(.meta, Ink.text3).lineLimit(1)
                Text(connection.reason.sentence).kitType(.meta, Ink.text3)
            }
            Spacer(minLength: Space.sm)
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
        .background(connection.isProduction ? Ink.prod.soft(0.04) : .clear)
        .hairlineAbove()
        .accessibilityElement(children: .combine)
    }

    private func codeSection(_ code: MCPServerCode) -> some View {
        let shown = showAllTools ? code.tools : Array(code.tools.prefix(6))
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Text("In the code").kitType(.labelMedium)
                Text("\(code.language) · \(code.tools.count) tool\(code.tools.count == 1 ? "" : "s")"
                     + (code.readOnlyCount + code.writeCount > 0 ? " · \(code.readOnlyCount) read · \(code.writeCount) write" : "")
                     + (code.files.first.map { " · \($0)" } ?? ""))
                    .kitType(.meta, Ink.text3).lineLimit(1)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Space.sm, alignment: .topLeading)], alignment: .leading, spacing: Space.sm) {
                ForEach(shown) { tool in
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(tool.readOnly == true ? "READ" : tool.readOnly == false ? "WRITE" : "—")
                            .kitType(.badge, tool.readOnly == false ? Ink.warn : Ink.text3).frame(width: 40, alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(tool.name).kitType(.monoSmall, Ink.text)
                            if !tool.summary.isEmpty { Text(tool.summary).kitType(.meta, Ink.text3).lineLimit(2) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(tool.summary)
                }
            }
            if code.tools.count > 6 {
                Button(showAllTools ? "Show Fewer" : "Show All \(code.tools.count) Tools") { showAllTools.toggle() }.buttonStyle(.kit(.link))
            }
        }
        .padding(Space.lg)
        .hairlineAbove()
    }

    @ViewBuilder private func usage(_ info: MCPProductInfo) -> some View {
        let advice = MCPInventory.advice(info)
        let code = info.primaryCode
        let text = code?.instructions ?? code?.guide
        let source = code?.instructions != nil ? code?.instructionsFile : code?.guideFile
        if !advice.isEmpty || text != nil {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("How to use it").kitType(.labelMedium)
                ForEach(advice) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Icon(item.isWarning ? .alert : .check, size: 11).foregroundStyle(item.isWarning ? Ink.prod : Ink.ok)
                        Text(item.text).kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let text, let source {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack {
                            Text(code?.instructions != nil ? "The server's instructions to agents · \(source)" : "From \(source)").kitType(.meta, Ink.text3)
                            Spacer()
                            Button(showInstructions ? "Show Less" : "Show All") { showInstructions.toggle() }.buttonStyle(.kit(.link))
                            Button("Copy") { model.copy(text, message: "Copied the instructions") }.buttonStyle(.kit(.link))
                        }
                        Text(text).kitType(.monoSmall, Ink.text2).lineLimit(showInstructions ? nil : 8)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .padding(Space.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Ink.panel2, in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
                    }
                }
            }
            .padding(Space.lg)
            .hairlineAbove()
        }
    }
}

// MARK: Toolbox

/// Every MCP server configured on this Mac, grouped by the product it belongs to.
struct MCPSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.mcpVersion
        let products = model.activeProducts.filter { !model.mcpInfo($0).isEmpty }
        let unmatched = model.unmatchedMCPEntries
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Servers").kitType(.cardTitle)
                    Text("Read from Claude Code, Claude Desktop, Codex, Cursor, plugins, and each repository's .mcp.json, then matched to products by folder, address, plugin repository, or name. Nothing connects to a server.")
                        .kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.mcpScanning { ProgressView().controlSize(.small) }
            }
            VStack(spacing: 0) {
                ForEach(products) { product in
                    let info = model.mcpInfo(product)
                    HStack(spacing: Space.md) {
                        ProjectIcon(product, size: 20)
                        Text(product.name).kitType(.labelMedium).frame(width: 180, alignment: .leading).lineLimit(1)
                        Text(info.serverNames.isEmpty ? "Serves MCP · not connected" : info.serverNames.joined(separator: ", "))
                            .kitType(.mono, Ink.text2).lineLimit(1)
                        Spacer(minLength: Space.sm)
                        if product.isDemo { DemoBadge() }
                        MCPBadge(product: product)
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.sm).hairlineBelow()
                }
                ForEach(unmatched) { entry in
                    HStack(spacing: Space.md) {
                        Icon(.mcp, size: 14).foregroundStyle(Ink.text3).frame(width: 20)
                        Text("No product").kitType(.label, Ink.text3).frame(width: 180, alignment: .leading)
                        Text(entry.name).kitType(.mono, Ink.text2).lineLimit(1)
                        Text("\(entry.whereTitle) · \(entry.host ?? entry.package ?? entry.program ?? "")").kitType(.meta, Ink.text3).lineLimit(1)
                        Spacer(minLength: Space.sm)
                        TagBadge(entry.reach.title, tone: entry.reach == .internet ? .warn : .muted)
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.sm).hairlineBelow()
                }
                if products.isEmpty && unmatched.isEmpty {
                    Text(model.mcpScanning ? "Reading configs…" : "No MCP servers are configured on this Mac.").kitType(.label, Ink.text2).padding(Space.lg)
                }
            }
            .card()
        }
    }
}
