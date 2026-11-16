# Toolbox

Command-line tools that save AI tokens or check repositories. ForgeDeck detects them, opens
installs in your terminal, and runs a few fixed actions against a checkout. It never installs
anything by itself. The catalog is `Sources/ForgeDeckKit/Services/Toolbox.swift`.

| Tool | Category | Installed by | Actions in ForgeDeck | Status on this Mac (2026-11-15) |
| --- | --- | --- | --- | --- |
| Repomix | Save tokens | npx (pinned 1.19.0), or Homebrew | Token count by folder | runs with npx, tested |
| graphify | Save tokens | uv or pipx (`graphifyy`) | Most connected nodes; Update the graph (writes graphify-out/, asks first) | installed, tested |
| ast-grep | Save tokens | Homebrew | none: listed for agents in CONTEXT.md | not installed |
| ripgrep | Save tokens | Homebrew | List TODO and FIXME | installed, tested |
| Gitleaks | Repository health | Homebrew | Scan history; scan working folder (findings redacted) | not installed |
| OSV-Scanner | Repository health | Homebrew | Scan dependencies (sends package names and versions to osv.dev) | not installed |
| scc | Repository health | Homebrew | Count code | not installed |
| difftastic | Git | Homebrew | Show uncommitted changes | not installed |
| git-cliff | Git | Homebrew | Draft notes since the last tag | not installed |
| ccusage | AI usage | npx (pinned 20.0.51) | Usage by day; current 5-hour block (reads ~/.claude locally) | not run during development |
| Serena | Save tokens | its own Quick Start | none: an MCP server, set up separately | not set up |

Flags for tools that are not installed come from their documentation and were not run here.

## How it fits together

- **Toolbox page** (sidebar, ⌘9): every tool with its status, what it is for, an install button
  that opens the command in your terminal, and its actions against a product you choose.
- **Product > Actions > Tools**: the installed tools' actions, per checkout.
- **Agent context**: installed tools with an agent hint (graphify, ast-grep, ripgrep) are listed
  in each `CONTEXT.md`, so an agent searches by structure instead of reading whole files.

## Rules

- Actions are argument arrays with the checkout path as one argument. No shell.
- Output is shown in the run log with terminal colors removed and secrets redacted. It is not saved.
- An action that writes asks for confirmation first. Only `graphify update` writes.
- Installs and runs are recorded in the audit log.
