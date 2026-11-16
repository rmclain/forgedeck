# ForgeDeck product spec

This document says what ForgeDeck is, how it models a portfolio, and which screens exist today.
It maps each of the 12 screens the build contract asks for to the place it lives in the app.
It is an implementation record dated 2026-11-15. Where the app does less than the contract asks, it says so.

## What it is

ForgeDeck is a native macOS app (SwiftUI, macOS 26 or later) for one person who runs several software products.
It keeps a registry of products on this Mac and shows, for each one:

- where its code lives (local folders, GitHub repositories),
- what is deployed in staging and production, and how strong the evidence for that is,
- whether its health checks pass,
- lead and metric counts, when the product's own endpoint reports them,
- the variables and secrets its commands need, with secret values in the macOS Keychain.

It also opens a project folder in a terminal or editor in one click, and it ships a command line tool (`forgedeck`) that is the same binary as the app.

There is no account, no server, and no telemetry. All data stays in one folder on this Mac plus the Keychain.

## The model: a Product, not a repository

The registry is defined in `Sources/ForgeDeckKit/Domain/Models.swift`.

| Type | Holds | Notes |
| --- | --- | --- |
| `Portfolio` | organizations, products, connections, variables, settings | Schema version 2. Saved as `portfolio.json`. |
| `Organization` | name, tags | One is created by default ("My Portfolio"). The UI edits only the first one's name. |
| `Product` | slug, name, tagline, notes, group, tags, stack, links, favorite, lifecycle, icon hue and monogram, `isDemo` | Owns the lists below. |
| `Component` | name, kind (backend, frontend, site, plugin, mobile, worker, infrastructure, database, cli, other), stack | A product can have many. |
| `Repository` | provider, owner, name, default branch, web and clone URL, optional component | A product can have many. Only `provider == "github"` is refreshed. |
| `LocalCheckout` | name, path, bookmark, repository and component links, worktree flags, detected metadata | A product can have many, or none. |
| `ProductEnvironment` | name, tier (development, staging, production, preview, custom), domains, probes, SSH hosts, metric sources, GitHub environment name | The tier title for development is "Local". |
| `ProbeConfig` | kind (health or companion status), URL, bearer variable key, expected status, timeout | Belongs to one environment. |
| `SSHHostConfig` | alias, label, optional release file path | Belongs to one environment. |
| `MetricSource` | name, base URL, bearer variable key, leads on or off | Belongs to one environment. |
| `ActionRecipe` | label, executor (local, ssh, openURL), program and argument array, checkout, environment, variable keys, safety class, approval flag | Belongs to one product. |
| `TerminalProfile` | name, environment, checkout, allowed programs, allowed variable keys | Used by `forgedeck exec`. |
| `Connection` | provider, account identity, scopes, `CredentialReference` | Only a GitHub connection is ever created. |
| `VariableDefinition` | key, scope, secret flag, plain value or `CredentialReference`, allowed tiers | Lives on the portfolio, not on a product. |
| `CredentialReference` | origin (Keychain, 1Password CLI, environment variable, SSH agent), locator, rotation and expiry dates | Never a secret value. |

Observed facts are a separate type, `ObservationCache` (`Domain/Evidence.swift`): Git snapshots, remote snapshots, deployment observations, health samples, metric samples, lead events, activity events, incidents, session records, sync states, and commit comparisons. Clearing it never deletes a definition.

Consequences that are true in the code:

- A product can have several repositories and several checkouts. Importing two checkouts of one repository in one pass creates one product (`ImportPlanner.apply`).
- A product can have no checkout (GitHub-only, SSH-only, or manual).
- A linked Git worktree joins the product that owns its main checkout.
- Production is a separate environment with its own probes and its own secrets. A secret lists the tiers it may resolve into.

Model fields that exist but that nothing reads yet: `AppSettings.trustedExecutables`, `ProductEnvironment.dockerComposeProject`, `MetricSource.eventsEnabled`, `MetricSource.Kind.genericREST`, `SSHHostConfig.allowedProbeIDs` (shown as text, not enforced), `StoreLocation.logsDirectory`. `ProbeConfig.expectedProductID` is enforced by the connector but has no field in the UI.

## Evidence levels

Every remote fact carries a `Provenance`: when it was observed, its source, its level, and when it expires (default 900 seconds).

| Level | Meaning | Where it comes from |
| --- | --- | --- |
| Verified | The target itself said so | Local checkout, GitHub API for a branch head, a companion status endpoint, a release file read over SSH |
| Reported | A record says so; the target did not confirm | GitHub deployment records, companion metric counters |
| Stale | Was observed, now past its expiry, or a newer attempt failed | Computed by `Provenance.effectiveLevel` and `DriftAnalyzer.evidence` |
| Unknown | Nothing observed, or only failures | Shown with the reason (for example "Authentication required") |

Production is never inferred from `main`, a green CI run, or the newest release tag.

## Screens that exist

The window has a 236 pt sidebar, a 52 pt toolbar, and a content area. The sidebar lists nine pages plus Settings, then a Projects tree (Favorites, then one collapsible section per group). The contract's five sidebar groups (Home, Portfolio, Operate, Develop, System) were not built: the list is flat. All nine pages are always visible; there is no progressive disclosure of sidebar items.

### The contract's 12 required screens

| # | Contract screen | Where it lives | What is there | Gaps |
| --- | --- | --- | --- | --- |
| 1 | Command Center dashboard | Sidebar > Overview (`Features/Overview.swift`, `OverviewPage`) | Greeting with a one-sentence portfolio summary; five tiles (Active products, Healthy environments, Uncommitted codebases, Failing pipelines, New leads) that each navigate to a page; a "Needs attention" list of up to four templated insights; a product grid with All, Favorites, Recent, and group filters; an activity panel with category filter and a pause switch for polling | No separate "recently opened" list (the Recent filter covers it). Drift shows as insights and on the Deployments page, not as its own list. Tiles navigate to a page, not to a pre-filtered view. |
| 2 | All Products | Sidebar > Projects (`ProjectsPage`) | Search by name, tag, stack, repository; stack menu; filter chips All, Favorites, Local only, GitHub only, Production, Broken, Changed, Archived; product cards with status pill, Local / GitHub / Production strip, latest release line, headline number, and terminal, editor, dashboard buttons | Cards only, no table. No organization filter. No multi-select: a "Refresh Shown" button refreshes every product in the current result instead. |
| 3 | Product Overview | Click a product > Overview tab (`ProductPage`, `ProductOverviewTab`) | Header with icon, name, status pill, tagline, stack chips, checkout path, favorite, Editor, Dashboard, Refresh; toolbar primary action "Open Terminal"; cards for Local, Staging, Production; a trend card; health bars; SSH hosts; a deployment timeline | The environment selector is the global Local / Staging / Production picker in the toolbar, not one per product. Quick actions live in the Actions tab and the command palette. |
| 4 | Development & Git | Product > Development tab (`DevelopmentTab`), and Sidebar > Git & CI (`GitPage`) | Evidence chain Local, GitHub, Staging, Production; every checkout with branch, HEAD, staged, unstaged, untracked, conflicts, stashes, ahead and behind, last fetch, shallow flag; repositories with View on GitHub, Clone, Link Existing; open pull requests; CI runs; recent local commits | No diff viewer. Pull requests and runs are the newest 20 and 15 that GitHub returns. |
| 5 | Environments & Deployments | Product > Environments tab (`EnvironmentsTab`), and Sidebar > Deployments (`DeploymentsPage`) | Per environment: GitHub environment mapping, checks, metric sources, SSH hosts, with add and remove; the Deployments page shows what runs where with an evidence badge, a Mixed tag, and a Drift card | No per-service breakdown inside an environment beyond the optional component link on a probe. Change history is the list of deployment observations kept in the cache (up to 400). |
| 6 | Leads & Metrics | Sidebar > Leads & Metrics (`LeadsPage`), and Product > Metrics tab (same `LeadsContent`) | 24h, 7d, 30d, 90d window picker; funnel of event counts; "Reported by sources" counters with their own window; lead inbox with new, read, flagged, handled states; masked contacts | No conversion rates. No revenue calculation: a revenue figure appears only when a source reports `mrr_cents`, shown as reported. No bulk export. |
| 7 | Connections | Sidebar > Infrastructure > Connections (`ConnectionsList`, `GitHubConnectionCard`), and Product > Connections tab | GitHub card with account, Doctor, Connect, Reconnect, Disconnect; endpoint rows with Doctor; metrics source rows with last sync state; a "Not built yet" card naming the missing providers | No per-provider rate limit display outside the GitHub Doctor. Only GitHub has Connect, Reconnect, Disconnect. |
| 8 | Secrets & Variables | Sidebar > Secrets Vault (`SecretsPage`), and Product > Secrets tab (`VariablesPanel`) | Scope filter All, Global, Organization, Product, Production; rows with reveal, copy, edit or rotate, delete; Rotate and Expired tags; warnings for duplicates and cross-tier secrets; "What a process would receive" preview; access audit list | The Add Variable sheet offers Global, Organization, Product, and Environment scopes. Component and Profile scopes exist in the resolver but cannot be created in the UI. |
| 9 | Terminal and Tasks | Sidebar > Terminals & Actions (`TerminalsPage`), and Product > Actions tab (`ActionsTab`) | Installed terminals and editors with Make Default; recipes and profiles; recent sessions (app, product, safe command name, exit status); run log sheet with redacted output and Copy Output | No embedded terminal. Run output is not saved. |
| 10 | Activity & Alerts | Sidebar > Activity (`ActivityPage`), and Product > Activity tab | Alerts with Acknowledge and Snooze (1, 8, 24 hours), a Show resolved switch; one event feed with All, Revenue, Deploys, Alerts filter | No user-editable thresholds. No macOS notifications. |
| 11 | Add Product wizard | Toolbar "Add Product", Cmd+N, or drop folders on the window (`AddProductSheet`) | Four modes: Local Folder, GitHub Repository, Server / SSH, Manual; a review list before anything is saved; merge proposals; GitHub repository listing with paging up to 300 | One sheet, not a multi-step wizard. Environment mappings are not proposed for local folders beyond a "Local" environment. |
| 12 | Settings & Diagnostics | Cmd+, (`SettingsView`) | Tabs General, Launching, Privacy & Data, Command Line, Diagnostics: appearance, workspace name, menu bar switch, polling, shortcut list, preferred terminal, editor, AI agent, project folders, production authentication switch, reveal timeout, retention, export, import, clear cache, demo products, CLI install, toolchain check, integrity check, audit log link, version | No accent picker, no update channel, no trusted-executables editor, no log viewer. Shortcuts are listed, not editable. |

### Other screens

| Screen | Where | Notes |
| --- | --- | --- |
| Infrastructure | Sidebar > Infrastructure | Tabs Health, Connections, SSH, Docker. SSH lists hosts from `~/.ssh/config` with a fixed probe menu, Doctor, and Connect. Docker lists local containers, read-only. |
| Command palette | Cmd+K | Searches products, checkouts, approved recipes, SSH hosts, links, pages, environment switches. Never lists a secret value. |
| Menu bar extra | Menu bar hammer icon | Summary sentence, up to three alerts with Acknowledge, favorites with a terminal button, Open, Refresh, Quit. Can be turned off in Settings. |
| Production banner | Under the toolbar when the context is Production | Says previews and actions are aimed at live systems. |
| Offline banner | Under the toolbar when the Mac is offline | Says remote facts show their last known value. |
| Confirmation sheet | Before remote-write and production actions, and before deletes | Shows target, command, and variables; needs a one-second press and hold. |
| Connection Doctor | "Doctor" buttons, and the palette | Steps for GitHub, a status endpoint, an SSH host, or this Mac's tools. |

Screenshots of every page are in `screenshots/`, for example `screenshots/overview-light.png`, `screenshots/product-development-dark.png`, `screenshots/sheet-confirm-light.png`.

## Shortcuts

| Keys | Action |
| --- | --- |
| Cmd+K | Command palette |
| Cmd+N | Add Product |
| Cmd+O | Open the current product's first checkout in the preferred terminal |
| Cmd+Shift+O | Open it in the preferred editor |
| Cmd+Shift+R | Reveal it in Finder |
| Cmd+R | Refresh the current page |
| Cmd+1 to Cmd+8 | Overview, Projects, Deployments, Leads & Metrics, Infrastructure, Git & CI, Terminals & Actions, Secrets Vault |
| Cmd+Shift+A | Activity |
| Cmd+[ and Cmd+] | Back and Forward |
| Cmd+Shift+E | Switch between Production and Staging context |
| Cmd+, | Settings |
| Escape | Close a sheet or the palette |

Cmd+O acts only when a product page is open. With several checkouts it opens the first one; the palette lists "Open Terminal in <checkout>" for each. There is no global hotkey.

## First run and offline behavior

- First launch shows a welcome state with three buttons: Add Product, Add 3 Demo Products, Check This Mac's Tools.
- Nothing needs the network to add a local folder, read Git state, open a terminal, edit notes and links, or define variables.
- On launch the app reads local Git state first, then the network sources.
- When the Mac is offline (`NWPathMonitor`), a refresh reads Git only. Remote facts keep their last value and age, and turn Stale by their own expiry.
- A failed GitHub fetch keeps the last known head and records the problem. A failed metrics fetch keeps the old numbers with their old timestamps. Neither is shown as zero.
- A product with nothing connected has the badge "No signal" or "Not connected", never "Healthy".

## Demo data rules

- Demo products come from `Sources/ForgeDeckKit/Fixtures/DemoFixtures.swift`. There are eight; the first-run button adds three (Lumen, Parcelwise, Quillnote). Settings > Privacy & Data can add all eight or remove them.
- Every demo product has `isDemo == true`. Every fixture observation has source `fixture` and `isDemo == true`. The UI shows a Demo badge on cards, evidence badges, tiles, and activity rows.
- Demo products are never refreshed, polled, or alerted on. Their terminal, editor, link, clone, and action buttons are disabled or answer with a toast that says they are demo.
- Site links use `.example` domains. The fixture repository URLs use the invented owner `northwind-demo` on `github.com`; no request is ever sent to them.
- Demo products are left out of a configuration export.
- The demo revenue figures are fixture values labeled Demo. For real products, revenue appears only when the product's own metrics source reports `mrr_cents`.


## Words used in the app

- **Product**: one thing you build and run. It can hold several repositories (components), local
  checkouts, and environments. The app used to say "Projects" for the same list; it now says
  Products everywhere.
- **Group**: a collection of products, like "SaaS Products" or "Client Work". Groups are the
  sidebar sections and the filter chips. A product belongs to one group.
- **Component / checkout**: a repository inside a product, and a folder on this Mac that holds it.
