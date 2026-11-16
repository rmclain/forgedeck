import Foundation

extension DemoFixtures {
    /// Demo MCP servers for Lumen, so the MCP card and badges can be seen without real config files.
    /// Callers label everything from a demo product as Demo.
    public static func mcp(for product: Product) -> MCPProductInfo? {
        guard product.isDemo, product.slug == "lumen", let checkout = product.primaryCheckout else { return nil }
        let production = MCPServerEntry(name: "lumen-prod", client: .claudeCode, transport: .http, host: "lumen.example")
        let local = MCPServerEntry(name: "lumen", client: .claudeCode, projectPath: checkout.path, transport: .http, host: "localhost:3000")
        let tools = [
            MCPTool(name: "get_overview", summary: "Start here: projects, event names, and the metrics each dashboard uses.", readOnly: true),
            MCPTool(name: "query_events", summary: "Count events by day, filtered by name and property.", readOnly: true),
            MCPTool(name: "list_dashboards", summary: "Dashboards with their charts and owners.", readOnly: true),
            MCPTool(name: "create_dashboard", summary: "Creates a dashboard from a list of charts.", readOnly: false),
            MCPTool(name: "delete_dashboard", summary: "Deletes a dashboard and its charts.", readOnly: false),
        ]
        let instructions = """
        Lumen analytics. You act as the signed-in workspace member.

        WORKFLOW
        1. Call get_overview once: projects, event names, and saved metrics.
        2. Query with query_events before proposing a dashboard. Name the events you used.
        3. create_dashboard only when the user asks for one; show the charts first.

        RULES
        - Never delete a dashboard unless the user names it and asks.
        - Event counts are sampled above 1M a day; say so when it matters.
        """
        let code = MCPServerCode(language: "TypeScript", files: ["src/mcp/server.ts"], tools: tools, instructions: instructions,
                                 instructionsFile: "src/mcp/instructions.ts", servesMCP: true)
        return MCPProductInfo(connections: [MCPConnection(entry: local, reason: .projectConfig),
                                            MCPConnection(entry: production, reason: .domain(.production), tier: .production)],
                              code: [checkout.path: code])
    }
}
