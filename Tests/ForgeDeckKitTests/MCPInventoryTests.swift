import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct MCPInventoryTests {
    private let claudeJSON = #"""
    {
      "mcpServers": {
        "orders-prod": {"type": "http", "url": "https://www.shop-example.com/wp-json/orders/mcp", "headers": {"Authorization": "Basic c2VjcmV0"}},
        "home-mcp": {"type": "http", "url": "http://192.168.1.20:9583/private_TOKENVALUE"},
        "rea": {"command": "npx", "args": ["-y", "rea-agents", "mcp"], "env": {"API_KEY": "sk-secret"}}
      },
      "projects": {
        "/code/orders": {"mcpServers": {"orders": {"type": "http", "url": "http://localhost:10003/wp-json/orders/mcp?key=abc"}}},
        "/code/other": {"mcpServers": {"coolify": {"command": "/code/other/bin/coolify-mcp"}}}
      }
    }
    """#

    private func product(slug: String, checkout: String, domains: [String] = [], repository: (String, String)? = nil) -> Product {
        var product = Product()
        product.slug = slug
        product.name = slug
        var local = LocalCheckout()
        local.path = checkout
        product.checkouts = [local]
        if !domains.isEmpty {
            var environment = ProductEnvironment()
            environment.tier = .production
            environment.domains = domains
            product.environments = [environment]
        }
        if let repository {
            var repo = Repository()
            repo.owner = repository.0
            repo.name = repository.1
            product.repositories = [repo]
        }
        return product
    }

    @Test func claudeCodeConfigKeepsHostsAndDropsSecrets() throws {
        let entries = MCPInventory.parseClaudeCode(Data(claudeJSON.utf8))
        #expect(entries.map(\.name) == ["home-mcp", "orders-prod", "rea", "orders", "coolify"])
        let prod = try #require(entries.first { $0.name == "orders-prod" })
        #expect(prod.host == "www.shop-example.com" && prod.transport == .http && prod.projectPath == nil)
        let local = try #require(entries.first { $0.name == "orders" })
        #expect(local.host == "localhost:10003" && local.projectPath == "/code/orders" && local.reach == .thisMac)
        #expect(entries.first { $0.name == "home-mcp" }?.reach == .homeNetwork)
        let rea = try #require(entries.first { $0.name == "rea" })
        #expect(rea.program == "npx" && rea.package == "rea-agents" && rea.isUnpinned)
        // Nothing a person could read contains a credential or the URL path.
        let visible = entries.map { "\($0.name) \($0.host ?? "") \($0.program ?? "") \($0.package ?? "") \($0.whereTitle)" }.joined()
        for secret in ["c2VjcmV0", "sk-secret", "TOKENVALUE", "key=abc", "wp-json"] { #expect(!visible.contains(secret), "\(secret)") }
    }

    @Test func productsMatchByProjectAddressNameAndPlugin() throws {
        var entries = MCPInventory.parseClaudeCode(Data(claudeJSON.utf8))
        let plugin = MCPInventory.parsePlugins(
            installed: Data(#"{"version":2,"plugins":{"netctl@net-plugins":[{"installPath":"/p/netctl"}]}}"#.utf8),
            marketplaces: Data(#"{"net-plugins":{"source":{"source":"github","repo":"example-org/netctl-mcp"}}}"#.utf8)) { path in
                path == "/p/netctl/.mcp.json" ? Data(#"{"mcpServers":{"netctl":{"command":"uvx","args":["netctl-mcp@1.2.0"]}}}"#.utf8) : nil
            }
        entries += plugin

        let cme = MCPInventory.connections(for: product(slug: "orders", checkout: "/code/orders"), entries: entries)
        #expect(Set(cme.map(\.entry.name)) == ["orders", "orders-prod"])
        #expect(cme.first { $0.entry.name == "orders" }?.reason == .projectConfig)
        let prod = try #require(cme.first { $0.entry.name == "orders-prod" })
        #expect(prod.isProduction && prod.reachTitle == "Production (by name)")

        let withDomain = MCPInventory.connections(for: product(slug: "shop", checkout: "/code/x", domains: ["shop-example.com"]), entries: entries)
        #expect(withDomain.first { $0.entry.name == "orders-prod" }?.reason == .domain(.production))

        let ha = MCPInventory.connections(for: product(slug: "home-mcp", checkout: "/code/home-mcp"), entries: entries)
        #expect(ha.map(\.entry.name) == ["home-mcp"] && ha[0].reason == .named && !ha[0].isProduction)

        let netctl = MCPInventory.connections(for: product(slug: "netctl", checkout: "/code/netctl-mcp", repository: ("example-org", "netctl-mcp")), entries: entries)
        #expect(netctl.map(\.entry.name) == ["netctl"])
        #expect(netctl.first?.entry.isUnpinned == false)

        let coolify = MCPInventory.connections(for: product(slug: "other", checkout: "/code/other"), entries: entries)
        #expect(coolify.map(\.entry.name) == ["coolify"])

        #expect(MCPInventory.connections(for: product(slug: "recipes", checkout: "/code/recipes"), entries: entries).isEmpty)
        // Every local server shares localhost: only the same port ties one to a product.
        #expect(MCPInventory.connections(for: product(slug: "site", checkout: "/code/s", domains: ["localhost"]), entries: entries).isEmpty)
        #expect(MCPInventory.connections(for: product(slug: "site", checkout: "/code/s", domains: ["http://localhost:10003"]), entries: entries).map(\.entry.name) == ["orders"])
    }

    @Test func aBareToolDecoratorCountsOnlyInMCPCode() {
        #expect(MCPInventory.extractTools("from langchain.tools import tool\n@tool\ndef search(q):\n    pass\n", language: "Python").isEmpty)
        #expect(MCPInventory.extractTools("from fastmcp import tool\n@tool()\ndef search(q):\n    pass\n", language: "Python").map(\.name) == ["search"])
    }

    @Test func uvxFlagValuesAreNotThePackage() {
        let entry = MCPInventory.entry(name: "netctl", client: .claudePlugin, projectPath: nil, type: nil, url: nil, command: "uvx",
                                       args: ["--python-preference", "system", "netctl-mcp==1.2.0"], cwd: nil)
        #expect(entry.package == "netctl-mcp==1.2.0" && !entry.isUnpinned)
    }

    @Test func codexTablesSkipTheirEnv() {
        let toml = """
        model = "gpt-5"
        [mcp_servers.rea]
        command = "npx"
        args = ["-y", "rea-agents@6.8.0", "mcp"]
        [mcp_servers.rea.env]
        TOKEN = "secret-value"
        [mcp_servers.docs]
        url = "https://docs.example.com/mcp"
        [profiles.x]
        command = "nope"
        """
        let entries = MCPInventory.parseCodex(toml)
        #expect(entries.map(\.name) == ["rea", "docs"])
        #expect(entries[0].package == "rea-agents@6.8.0" && !entries[0].isUnpinned)
        #expect(entries[1].host == "docs.example.com" && entries[1].reach == .internet)
    }

    @Test func reachComesFromTheHost() {
        #expect(MCPInventory.reach(ofHost: "localhost:8080") == .thisMac)
        #expect(MCPInventory.reach(ofHost: "shop.local") == .thisMac)
        #expect(MCPInventory.reach(ofHost: "10.0.0.4") == .homeNetwork)
        #expect(MCPInventory.reach(ofHost: "172.20.1.1") == .homeNetwork)
        #expect(MCPInventory.reach(ofHost: "172.40.1.1") == .internet)
        #expect(MCPInventory.reach(ofHost: "mcp.vercel.com") == .internet)
    }

    @Test func phpAbilitiesAndHeredocInstructionsAreRead() throws {
        let root = try makeTempDir("mcp-php")
        defer { removeTemp(root) }
        let abilities = """
        <?php
        return array(
            'get-reference' => array(
                'label'       => 'Get CME authoring reference',
                'description' => 'Start here. The authoring guide plus every allowed value.',
                'readonly'    => true,
                'run'         => array( __CLASS__, 'reference' ),
            ),
            'publish-activity' => array(
                'label'       => 'Publish an activity',
                'description' => 'Publishes when no blocking checks are open.',
                'run'         => array( __CLASS__, 'publish' ),
            ),
        );
        """
        let guide = "<?php\n/** The MCP server's `instructions`. */\nfinal class Guide { public static function text(): string {\n return <<<'TXT'\nWORKFLOW\n" + String(repeating: "1. Call get-reference once before anything else, then read before you write.\n", count: 4) + "TXT;\n } }\n"
        try FileManager.default.createDirectory(at: root.appending(path: "includes/Mcp"), withIntermediateDirectories: true)
        try abilities.write(to: root.appending(path: "includes/Mcp/Abilities.php"), atomically: true, encoding: .utf8)
        try guide.write(to: root.appending(path: "includes/Mcp/Guide.php"), atomically: true, encoding: .utf8)
        let code = try #require(MCPInventory.scan(checkout: root.path))
        #expect(code.servesMCP && code.language == "PHP")
        #expect(code.tools.map(\.name) == ["get-reference", "publish-activity"])
        #expect(code.tools.map(\.readOnly) == [true, false])
        #expect(code.tools[0].summary == "Start here.")
        #expect(code.instructions?.hasPrefix("WORKFLOW") == true && code.instructionsFile == "includes/Mcp/Guide.php")
        #expect(code.writeCount == 1 && code.readOnlyCount == 1)
    }

    @Test func pythonAndTypeScriptToolsAreRead() throws {
        let root = try makeTempDir("mcp-py")
        defer { removeTemp(root) }
        try "[project]\ndependencies = [\"fastmcp>=2.0\", \"httpx\"]\n".write(to: root.appending(path: "pyproject.toml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "src/tools"), withIntermediateDirectories: true)
        let python = """
        @mcp.tool(annotations={"readOnlyHint": True})
        async def ha_get_state(entity_id: str) -> dict:
            \"\"\"Read one entity's state. Returns attributes too.\"\"\"

        @tool(
            name="ha_restart",
            description="Restart Home Assistant.",
            annotations={"readOnlyHint": False},
        )
        @with_backup(
            "restart",
        )
        @log_calls
        def restart() -> None:
            pass
        """
        try python.write(to: root.appending(path: "src/tools/state.py"), atomically: true, encoding: .utf8)
        let ts = #"server.registerTool("search_docs", { title: "Search", description: "Find docs.", annotations: { readOnlyHint: true } }, run)"#
        try ts.write(to: root.appending(path: "src/server.ts"), atomically: true, encoding: .utf8)
        try "# How to use\nRead first.\n".write(to: root.appending(path: "MCP.md"), atomically: true, encoding: .utf8)
        let code = try #require(MCPInventory.scan(checkout: root.path))
        #expect(Set(code.tools.map(\.name)) == ["ha_get_state", "ha_restart", "search_docs"], "\(code.tools.map(\.name)) files=\(code.files)")
        let state = try #require(code.tools.first { $0.name == "ha_get_state" })
        #expect(state.readOnly == true && state.summary == "Read one entity's state.")
        #expect(code.tools.first { $0.name == "ha_restart" }?.summary == "Restart Home Assistant.")
        #expect(code.guideFile == "MCP.md")
    }

    @Test func aRepositoryWithoutMCPIsNil() throws {
        let root = try makeTempDir("mcp-none")
        defer { removeTemp(root) }
        try #"{"dependencies":{"react":"19"}}"#.write(to: root.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try "export function tool() {}".write(to: root.appending(path: "index.ts"), atomically: true, encoding: .utf8)
        #expect(MCPInventory.scan(checkout: root.path) == nil)
    }

    @Test func adviceNamesProductionRisks() {
        let entries = MCPInventory.parseClaudeCode(Data(claudeJSON.utf8))
        let connections = MCPInventory.connections(for: product(slug: "orders", checkout: "/code/orders"), entries: entries)
        let code = MCPServerCode(language: "PHP", files: [], tools: [MCPTool(name: "a", summary: "", readOnly: true), MCPTool(name: "b", summary: "", readOnly: false)],
                                 instructions: "x", servesMCP: true)
        let info = MCPProductInfo(connections: connections, code: ["/code/orders": code])
        let advice = MCPInventory.advice(info)
        #expect(advice.contains { $0.isWarning && $0.text.contains("every Claude Code project") })
        #expect(advice.contains { $0.text.contains("Try a change with orders (this Mac)") })
        #expect(advice.contains { $0.text.contains("1 of 2 tools change data") })
        #expect(info.reachesProduction && info.badgeTitle == "MCP · 2 connections")
        let context = MCPInventory.contextSection(info) ?? ""
        #expect(context.contains("orders-prod") && context.contains("Writes change production") && !context.contains("wp-json"))
    }
}
