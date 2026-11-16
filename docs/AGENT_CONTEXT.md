# Agent context across repositories

When an AI coding agent starts in one product, ForgeDeck can tell it about the other products
it works with: an API, a plugin, a shared library. This page covers how that works, what it
costs in tokens, and why it is built this way.

## How to use it

1. Open a product, go to **Development > Agent context**, and use **Link Product** to add the
   repositories it depends on. A note per link is optional.
2. Optional: check **Include repo map** and press **Build Pack** for a related product. This runs
   `repomix --compress` (pinned to version 1.19.0, through `npx`, so Node must be installed) on
   that product's checkouts.
3. Press **Open claude** (or your agent from Settings > Launching), or from any terminal run:

   ```
   forgedeck agent <product>            # writes CONTEXT.md and starts the agent in the checkout
   forgedeck agent <product> --print    # shows the command instead
   forgedeck pack <product> --related   # builds packs and maps for every linked product
   forgedeck context <product> --write  # writes CONTEXT.md and prints its path
   ```

The plain Terminal button stays a plain shell. Context goes with the agent launch.

## What the agent gets

| Layer | What | Cost to the agent |
| --- | --- | --- |
| Pointer | One line in the system prompt naming `CONTEXT.md` | about 60 tokens |
| Map | `CONTEXT.md`: a brief per product (stack, components, Git state, top-level tree), a ranked repo map when built, and graphify's summary when a graph exists | about 1–3k tokens, read once |
| Live files | Claude Code gets each related checkout with `--add-dir` and reads real files when needed | only what it opens |
| Pack | The full compressed pack, offered by path | only if it chooses to open it |

Measured on this Mac on 2026-11-15:

| Repository | Full compressed pack | Repo map | Notes |
| --- | --- | --- | --- |
| ForgeDeck (whole repo) | about 153k tokens | about 1.5k tokens | map covers the 11 most-used files |
| a Capacitor game | 17 MB (not kept) | about 1.5k tokens | tracked JSON data made the pack useless; the map was kept |

`CONTEXT.md` for ForgeDeck linked to the game repo came to about 2.1k tokens. A Claude Code
session started with the generated flags read it and named the game's central file
(`assets/js/fishing.js`) from the map alone.

## Why this order

The most token-efficient context is the context the agent never loads. Preloading a whole
compressed repository costs tens of thousands of tokens every session and goes stale with the
next commit. So ForgeDeck front-loads only a small map and lets the agent fetch the rest.

The repo map follows the idea behind aider's repo map: extract declarations, rank files by how
many other files reference their names, and keep the top ones under a fixed token budget (1,500
here, 10 lines per file, types first). ForgeDeck builds it from repomix's `--compress` output,
so it needs no parser of its own. Names declared in many files, and very common names, do not
count as references. Data, markup, and earlier pack files never enter the map.

## graphify

ForgeDeck never builds a graph. When a checkout already has `graphify-out/`, the brief includes
the report's summary and community list (36 lines at most) and tells the agent how to query it
with `graphify query`. A graph answers structural questions more cheaply than reading files.

## Agents

Choose the agent and its model in Settings > Launching. A model left on Default uses the agent's
own setting. Antigravity's list comes from `agy models`; Claude Code offers opus, sonnet, and
haiku; any other name can be typed. `forgedeck agent <product> --agent <name> --model <model>`
overrides both for one run. The catalog is `Sources/ForgeDeckKit/Services/AgentLaunch.swift`.

| Agent | Related folders | First message | Model |
| --- | --- | --- | --- |
| Claude Code (`claude`) | `--add-dir` | positional; the CONTEXT.md pointer goes in `--append-system-prompt` | `--model` |
| Codex (`codex`) | none: reachable by path | positional | `--model` |
| OpenCode (`opencode`) | none | `--prompt`, then the folder | `--model` |
| Gemini CLI (`gemini`) | `--include-directories` | `--prompt-interactive` | `--model` |
| Antigravity (`agy`) | `--add-dir` | `--prompt-interactive` | `--model` |

Agents without a system-prompt flag get the pointer at the start of their first message. On
2026-11-15, agy accepted `--add-dir` and `--model gemini-3.8-flash-low` and answered a one-line
prompt. Gemini CLI accepted its flags but was not signed in on this Mac: run `gemini` once to
log in.

## Safety

- Nothing is written into any repository. Context and packs live in
  `~/Library/Application Support/ForgeDeck/context/`, 0600 files in 0700 folders.
- repomix runs its own secret scan. ForgeDeck adds ignore rules (`.env*`, keys, `wp-config.php`,
  `.npmrc`, credentials, graphify caches, earlier packs) and redacts the map and any kept pack.
- Packs run only when you press Build Pack or run `forgedeck pack`. repomix is a third-party
  tool fetched by `npx` on first use, pinned to one version.
- ForgeDeck sends nothing anywhere. The agent decides what to read, and its provider sees what
  it reads, as in any session.
- A pack goes stale when the checkout moves to another commit or has uncommitted changes. The
  brief says so. Rebuild it from the card or with `forgedeck pack`.

## Other tools worth knowing

These were not integrated. They are listed for comparison, and the savings figures are the
projects' own claims.

- **Serena** (oraios/serena): an MCP server with language-server symbol tools (find a symbol,
  find references). It suits deep work inside one large repository.
- **claude-context** (zilliztech/claude-context): semantic code search over a vector index. It
  needs an embedding provider and a Milvus or Zilliz endpoint.
- **aider's repo map**: the ranking idea used here, with tree-sitter parsing.
