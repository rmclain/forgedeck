# ForgeDeck integrations

This document lists each connector: what it can do, how it authenticates, what it calls, which evidence level it yields, how it fails, and whether it was exercised.
It also summarizes the companion contract and points to the deployment-fingerprint recipe.
Status is as of 2026-11-15.

## Status key

| Status | Meaning |
| --- | --- |
| Real, exercised | Built, and run against a real target on this Mac today |
| Implemented, not exercised live | Built and covered by unit tests with scripted responses, but not run against a live account or host |
| Not built | No code |

## Summary

| Connector | Code | Status |
| --- | --- | --- |
| Local Git | `Services/GitService.swift` | Real, exercised |
| Project discovery | `Services/ProjectDiscovery.swift` | Real, exercised |
| Terminal and editor launch (Terminal.app, iTerm2) | `Services/TerminalLauncher.swift` | Real, exercised |
| Terminal and editor launch (Ghostty, Warp, Zed) | same | Implemented, not exercised live (not installed) |
| Keychain | `Security/SecretStore.swift` | Real, exercised |
| `forgedeck exec` | `Security/ExecService.swift`, `CLI/CLI.swift` | Real, exercised |
| GitHub REST, no token, public repository | `Connectors/GitHubConnector.swift` | Real, exercised (one public repository) |
| GitHub REST with a token (private repositories, listing, deployments) | same | Implemented, not exercised live |
| HTTP health check | `Connectors/RuntimeProbe.swift` | Real, exercised against the local Node example server |
| Companion status | same | Real, exercised against the local Node example server |
| Companion metrics and leads | same | Real, exercised against the local Node example server |
| SSH Doctor up to the host-key gate | `Services/ConnectionDoctor.swift`, `Connectors/SSHInspector.swift` | Real, exercised |
| SSH probes and release file on a trusted host | `Connectors/SSHInspector.swift` | Implemented, not exercised live |
| Docker CLI detection | `Connectors/DockerInspector.swift` | Real, exercised |
| Docker container list with a running daemon | same | Implemented, not exercised live |
| 1Password CLI references | `Security/SecretStore.swift` | Implemented, not exercised live (`op` not installed) |
| Touch ID for production secrets | `Security/SecretStore.swift` (`DeviceOwnerAuthorizer`) | Implemented, not exercised (needs a person) |
| Stripe, WooCommerce direct, Plausible, PostHog, Sentry | none | Not built |
| Vercel, Cloudflare, Fly, Railway, Render | none | Not built |
| GitLab, Bitbucket | none | Not built (URLs parse; nothing is fetched) |
| Generic SQL, generic webhook receiver | none | Not built |
| OAuth device flow | none | Not built (token paste or `gh auth token` import instead) |
| MCP adapter | none | Not built |

No production system, real private repository, DNS record, or remote data was touched.

## Local Git

| | |
| --- | --- |
| Capability | Branch, HEAD, detached state, upstream, ahead and behind, staged, unstaged, untracked, conflicted, stashes, shallow flag, worktree flag and list, remotes, last fetch time, eight recent commits; compare two commits; fetch; clone |
| Auth | None. Uses the system `git` and the user's own Git credentials for fetch and clone |
| Commands | `rev-parse --is-inside-work-tree`, `status --porcelain=v2 --branch --untracked-files=normal`, `stash list`, `rev-parse --is-shallow-repository`, `remote -v`, `worktree list --porcelain`, `rev-parse --git-dir --git-common-dir`, `log -n 8`, `cat-file -e`, `rev-list --left-right --count`, `fetch --quiet --prune --no-tags`, `clone -- <url> <destination>` |
| Environment | `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, `GIT_PAGER=cat`, `LC_ALL=C` |
| Evidence | Verified, source "Local checkout" |
| Failure | Missing folder: "Folder missing", with a "Find It" button that tries the stored bookmark. Not a repository: stated, the folder can still be opened. A commit that was never fetched, or a shallow boundary: "Not enough history". Clone into an existing path: refused, nothing overwritten |
| Writes | Only `fetch` (user-started) and `clone` (user-started, into a new folder) |

Fetch is never automatic. Polling reads local state only; the "Fetch" button on a checkout runs `git fetch`.

## Project discovery

| | |
| --- | --- |
| Capability | Finds Git repositories, linked worktrees, and folders with project markers under folders the user picks |
| Reads | `.git` (folder or pointer file), `.git/config`, `package.json`, `composer.json`, `pyproject.toml` or `requirements.txt`, `Cargo.toml`, `go.mod`, `Gemfile`, `Package.swift`, Xcode project presence, top-level PHP plugin headers, `wp-content` or `wp-includes` presence, `Dockerfile`, Compose files, a README |
| Detects | Stack labels, package manager, dev and test commands, dev URL, Compose services, WordPress plugin name, a suggested component kind |
| Never reads | `.env` files, key files, `.npmrc`, `wp-config.php`, and the other names in `ProjectDiscovery.isSecretBearing` |
| Limits | Depth 4, 20,000 directories, 500 results, cancellable |
| Performance | 300 repositories scanned in about 1.3 seconds (`threeHundredRepositoriesScanQuickly`) |

Project folders saved in Settings are stored only. Nothing watches them, and scanning happens when the user asks.

## Terminal and editor launch

| | |
| --- | --- |
| Capability | Open a folder in a terminal or editor; run an approved command in a terminal window; open a web link; reveal in Finder |
| Mechanism | `NSWorkspace.open(_:withApplicationAt:)` with the folder URL. For a command: a `.command` script with a quoted `cd` and `exec` line, opened with the terminal app |
| Permissions | None requested. No Apple Events, so no Automation prompt |
| Known apps | Terminals: Terminal, iTerm2, Ghostty, Warp. Editors: Visual Studio Code, Cursor, Xcode, Zed |
| Command files | Only Terminal and iTerm2 are marked as able to run a `.command` file. For other terminals a command falls back to Terminal.app |
| Failure | Not installed, missing folder, or the app refuses: nothing is reported as opened, and a safe `cd` line is copied to the clipboard when one applies |

Exercised today: `forgedeck open` opened a repository at `/private/tmp/ForgeDeck-selftest-home/it's a repo dir` in Terminal.app, and a new zsh process had exactly that working directory (checked with `lsof`). The same worked in iTerm2 once iTerm2 was already running. On a cold launch of iTerm2 the folder did not open; a second click did. Ghostty, Warp, and Zed are not installed here and are labeled "not verified" in the app.

AI agents: `claude`, `codex`, and `opencode` are detected by name. "Open with <agent>" starts the program in the checkout through a launch script. ForgeDeck passes nothing to it. `forgedeck context <product>` prints a short description without secrets that a person can hand to an agent.

## GitHub

| | |
| --- | --- |
| Capability | Repository default branch and head commit, open pull requests, workflow runs, deployment records with the newest status per environment, latest release tag, account identity, repository listing |
| Auth | None for public repositories. Otherwise a personal access token pasted into the "Connect GitHub" sheet, or imported once from `gh auth token` when the user presses "Use gh CLI Token". Stored in the Keychain. Sent as `Authorization: Bearer` to `https://api.github.com` only |
| Recommended token | Fine-grained, read-only: Contents, Metadata, Pull requests, Actions, Deployments |
| Headers | `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`, `User-Agent: ForgeDeck`, `If-None-Match` when an ETag is cached |

Endpoints called:

| Endpoint | Used for | Required |
| --- | --- | --- |
| `GET /user` | Account login, scopes, rate limit (connect and Doctor) | For connect |
| `GET /user/repos`, `GET /orgs/{org}/repos` (`per_page=100`, `sort=pushed`) | Listing in Add Product, up to 300 | Optional |
| `GET /repos/{owner}/{repo}` | Default branch | Yes |
| `GET /repos/{owner}/{repo}/branches/{branch}` | Head commit, message, date | Yes |
| `GET /repos/{owner}/{repo}/pulls?state=open&per_page=20` | Open pull requests | Optional part |
| `GET /repos/{owner}/{repo}/actions/runs?per_page=15` | Workflow runs | Optional part |
| `GET /repos/{owner}/{repo}/deployments?per_page=15` | Deployment records | Optional part |
| `GET /repos/{owner}/{repo}/deployments/{id}/statuses?per_page=1` | Newest status, once per environment | Optional part |
| `GET /repos/{owner}/{repo}/releases/latest` | Latest release tag | Optional part; 404 is normal |

Evidence:

- Branch head: Verified, source "GitHub API", for 15 minutes, then Stale.
- Deployment record for an environment mapped by GitHub environment name: **Reported**, source "Deployment record". It never counts as Verified. A record whose state is not `success` is not treated as the running version.
- A workflow run is shown as CI state. It is never deployment evidence.

Failure semantics:

- 401 gives `unauthorized` and opens an "Authentication failed" alert for the repository; 403 gives `forbidden`, or `rateLimited` when `X-RateLimit-Remaining` is 0 or `Retry-After` is present; 404 `notFound`; 429 `rateLimited`; 5xx `unavailable`.
- When an optional part fails, the result is `partial` and names the missing parts. The head is still shown.
- When the fetch fails, the last known head is kept with the problem attached. A first fetch that fails is Unknown, not empty.
- A 304 reuses the cached body.
- `retryAfter` is computed from the headers. The refresh loop does not yet use it to delay the next attempt.

Not built: OAuth device flow, GitHub App auth, several GitHub accounts, GraphQL, webhooks, check-run detail, GitHub Enterprise host configuration in the UI (the connector takes a base URL, the app always uses the default).

## HTTP health check

| | |
| --- | --- |
| Capability | One `GET` to a URL; pass when the status equals the expected status (default 200); latency |
| Auth | Optional bearer token taken from a variable that resolves in the environment's tier |
| Evidence | A health sample only. It says nothing about which release runs |
| Failure | Status mismatch, timeout (default 8 seconds), offline, TLS failure, DNS failure. A missing or disallowed token variable on a failing check is reported as `unauthorized` |
| Alert | Three failures in a row that are not `offline` open one "Health check failing" incident; the next pass closes it |

## Companion status endpoint

| | |
| --- | --- |
| Capability | Running commit, version, deploy time, health state and failing checks, per-instance commits |
| Auth | Bearer token from a variable, as above |
| Endpoint | The URL the user enters, normally `https://<host>/_forgedeck/v1/status` (WordPress: `/wp-json/forgedeck/v1/status`) |
| Evidence | **Verified**, source "Runtime status endpoint", when the answer has a commit or a version |
| Checks on the answer | Schema major must be `1`. The declared `environment` must equal the environment's tier (`development` also accepts `local` and `dev`). When `expectedProductID` is set on the probe, the declared product must match |
| Mixed rollout | More than one distinct commit in `instances` is reported as "Mixed revisions" |
| Failure | Wrong environment or product, a body that is not the contract, or no commit and no version: `malformed`, never Verified. Wrong schema major: `unsupported`. HTTP and transport failures as for GitHub |

An unhealthy target that reports its release is still Verified for the release; its health is shown separately.

`expectedProductID` is enforced by the connector and set in the acceptance tests. The probe sheet has no field for it yet.

## Companion metrics and leads

| | |
| --- | --- |
| Capability | Counters for a window; lead events with paging |
| Auth | Bearer token from a variable |
| Endpoints | `GET <base>/_forgedeck/v1/metrics?window=24h|7d|30d` and `GET <base>/_forgedeck/v1/leads?limit=100&cursor=...`, up to five pages per refresh. A base URL that already ends in `/v1` is used as it is |
| Evidence | **Reported**, source "Metrics API". The observation time is when this Mac received the answer, not the server's clock |
| Dedupe | A lead's id is `<source id>:<remote id>`. Reading a page twice never counts an event twice |
| Privacy | Contact text is masked on arrival. The full value is not stored |
| Failure | The old numbers stay with their old timestamps and show as Stale, never zero. A source that keeps failing for over an hour after its last success opens a "Lead source stalled" incident, unless the Mac is offline. Malformed events are skipped and the result is `partial`. A repeating cursor stops the paging |

Gaps against the contract in `Companions/contract/README.md`:

- The app reads `/metrics` and `/leads`. It does not call `/manifest` or `/events`.
- The app does not send the optional HMAC signature headers. A companion that requires signing will answer 401.
- The contract's opt-in masked field on a lead is named `label`. The app reads `label` as it arrives, and masks a raw `contact` field itself if a source sends one.
- The 90d window is in the contract and in the Leads page picker (which counts stored lead events), but the refresh requests only 24h, 7d, and 30d counters.
- The contract allows the environment value `test`. The app has no matching tier and rejects it.

## SSH

| | |
| --- | --- |
| Capability | List hosts from `~/.ssh/config`; resolve an alias (`ssh -G`); check `known_hosts` (`ssh-keygen -F`); run one of five fixed read-only probes; read a release file; open an interactive session in the terminal |
| Auth | The system `ssh`, the user's config, and the SSH agent. No key is read or stored |
| Probes | `uptime`, `df -h /`, `free -m 2>/dev/null \|\| vm_stat`, `docker ps --format ...`, `uname -srm` |
| Release file | `cat -- '<path>'`. Accepts the JSON written by the fingerprint recipe (`commit_sha`, `sha`, or `commit`; `version`; `deployed_at` or `built_at`) or a bare commit |
| Evidence | A release file with a commit or version: **Verified**, source "SSH inspection". Probe output: shown in the UI, not stored |
| Failure | `hostKeyUnknown`, `hostKeyChanged`, `unauthorized` (key refused), `unavailable` (DNS, refused, unreachable), `timeout`, `unsupported` (command not found). A changed host key is never OK |

Exercised: `forgedeck doctor --ssh localhost` reported that the host key is missing from `known_hosts` and refused to continue. A host name that does not resolve reported the DNS failure. Probes and release-file reads on a trusted host were not run.

## Docker

| | |
| --- | --- |
| Capability | Detect the CLI; current context (`docker context show`); list containers (`docker ps --all --no-trunc --format '{{json .}}'`); bounded logs (`docker logs --tail N -- <name>`, at most 1,000 lines and 400 KB, redacted) |
| Auth | The local Docker CLI and daemon |
| Evidence | Shown in Infrastructure > Docker. Not stored, not tied to a product |
| Failure | CLI missing: `notConfigured`. Daemon not running: "Docker is installed but the daemon is not running." Permission denied: `forbidden` |

The container list is shown in the app. The log reader exists in the kit and is tested, but no screen calls it. Compose is not managed; a detected Compose file only produces a suggested "Docker Compose Up" recipe.

## Keychain, 1Password, environment references

See SECURITY_MODEL.md. In short: Keychain is exercised, including by the self-test with real items; 1Password references call `op read` and are untested live; an environment reference reads a variable from ForgeDeck's own environment.

## The companion contract

Source: `Companions/contract/README.md`, with JSON Schemas and examples beside it.

A companion is a small read-only HTTP API that a product you own serves, so ForgeDeck can read the deployed commit, health, and a few aggregate counters from the running system.

| Route | Scope | Purpose |
| --- | --- | --- |
| `GET /_forgedeck/v1/manifest` | `status:read` | Product id, schema version, enabled capabilities, environment |
| `GET /_forgedeck/v1/status` | `status:read` | Release fingerprint, health, report time |
| `GET /_forgedeck/v1/metrics?window=` | `metrics:read` | Allow-listed counters for 24h, 7d, 30d, 90d |
| `GET /_forgedeck/v1/leads` | `leads:read` | Optional. Redacted lead events, paged |
| `GET /_forgedeck/v1/events` | `events:read` | Optional. Change, incident, and business events, paged |

Main rules of the contract:

- `GET` only. No admin or mutation routes.
- Default deny: 503 until a token is configured; each capability is off until enabled; a disabled route answers 404.
- Bearer tokens are stored server-side as SHA-256 hashes, scoped per capability, revocable, optionally expiring.
- Optional HMAC request signing with a 300 second window and a replay cache.
- HTTPS required outside loopback. 60 requests per minute per token.
- Lead items carry ids, kinds, times, source, title, and value. No contact fields, except an opt-in masked `label`.
- `product_id` and `environment` come from server configuration only.
- Versioning: the major version is in the path; clients must ignore unknown properties.

Packages:

| Package | Path | Tests | Notes |
| --- | --- | --- | --- |
| Node | `Companions/node` | 68 pass | Dependency-free middleware and a local example server (`example-server.js`) with test controls |
| Python | `Companions/python` | 82 pass | FastAPI router |
| WordPress | `Companions/wordpress/forgedeck-companion` | 31 pass | Standalone PHP tests. The plugin was never run inside a real WordPress. Its settings page and WooCommerce counts are untested |

ForgeDeck never installs a companion. The rollout and rollback steps are in `Companions/README.md`.

## Deployment fingerprint

`Companions/contract/deployment-fingerprint.md` is the recipe for CI to write a `forgedeck-release.json` file with the commit, version, build id, and build time, so that `/status` (or a release file read over SSH) reports the artifact that is actually running. It covers GitHub Actions, a Dockerfile, recording the deploy time, WordPress, multi-instance deployments, and how to verify the result.

In ForgeDeck, the fingerprint arrives by one of two paths:

1. a companion status endpoint added to an environment (Verified, source "Runtime status endpoint"), or
2. an SSH host with a release file path (Verified, source "SSH inspection").

Both were built. Path 1 was exercised against the local example server. Path 2 was exercised only with a fake process runner in unit tests.
