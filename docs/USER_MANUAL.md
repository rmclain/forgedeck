# ForgeDeck user manual

This guide is for the person using the app. It is organized by task: getting started, daily use, secrets, the command line, and troubleshooting.
It describes version 0.1 as built on 2026-11-15. Things the app does not do yet are named where you would look for them.

## Getting started

### Install

1. In the repository, run `./build.sh --open`. This builds the app, installs it at `~/Applications/ForgeDeck.app`, and opens it.
2. Optional: run `./build.sh --link-cli`, or use Settings > Command Line > "Install in ~/.local/bin", to get the `forgedeck` command.

ForgeDeck needs macOS 26 or later. It asks for no Automation, Accessibility, or Full Disk Access permission. It has no account and sends no telemetry.

### Look around with demo data

On first launch press "Add 3 Demo Products". Everything marked **Demo** comes from a fixture and connects to nothing. Demo products cannot be opened in a terminal, refreshed, or acted on. Remove them in Settings > Privacy & Data > Demo products > Remove.

### Where your data is

| What | Where |
| --- | --- |
| Products, environments, variable names, settings | `~/Library/Application Support/ForgeDeck/portfolio.json` |
| Observed state (Git, deployments, health, leads, alerts) | `~/Library/Application Support/ForgeDeck/cache.json` |
| Audit log | `~/Library/Application Support/ForgeDeck/audit.jsonl` |
| Secret values | The macOS Keychain, service `com.forgedeck.vault` |

Settings > Privacy & Data shows the folder and opens it in Finder.

## The window

- **Sidebar.** Nine pages, Settings, then your products grouped under Favorites and your own groups. The dot beside a product repeats its status. The footer shows the sync state; click it to refresh.
- **Toolbar.** Back and forward, the page title, the search field (Cmd+K), the Local / Staging / Production picker, a health-check summary, the alert bell, and one primary button for the page.
- **Environment picker.** Sets what variable previews and new recipes are aimed at. In Production the picker turns to the production color and a banner appears. Cmd+Shift+E switches between Production and Staging.
- **Command palette (Cmd+K).** Type to find products, checkouts, approved actions, SSH hosts, links, and pages. Arrow keys move, Return runs, Escape closes. Secrets never appear in it.

## Add a product

Press Cmd+N or the "Add Product" button, or drop folders on the window.

| Mode | Use it for | What you do |
| --- | --- | --- |
| Local Folder | Code on this Mac | "Choose Folders…", review the list, press "Add N" |
| GitHub Repository | A repository without a checkout | Type `owner/repo` or a URL, or list repositories and tick some |
| Server / SSH | A host you reach over SSH | Type or choose an alias from `~/.ssh/config`, say whether it is Staging, Production, or Other |
| Manual | An idea with nothing connected | Type a name |

Notes:

- The local scan reads project metadata only. It never opens `.env` files, key files, `.npmrc`, or `wp-config.php`.
- If a folder's repository already belongs to a product, the review list says "Adds a checkout to <product>" instead of creating a duplicate.
- Scanning the same folder again says "Already in <product>: refreshes metadata". Your name, tagline, tags, and group are kept.
- To clone a GitHub-only product: Development tab > Repositories > "Clone…", then choose the parent folder. An existing folder is never overwritten.
- To attach more folders to a product: Development tab > "Link Folder…".

## Open a project

| To | Do |
| --- | --- |
| Open the terminal at the first checkout | Cmd+O on the product page, the "Open Terminal" toolbar button, or the terminal icon on a card |
| Open another checkout | Development tab, terminal icon on that checkout's row |
| Use a different terminal once | The "more" menu on the checkout row |
| Open the editor | Cmd+Shift+O |
| Reveal in Finder | Cmd+Shift+R |
| Start an AI agent in the folder | Development tab, sparkle icon on the checkout row |
| Copy a safe `cd` line | The "more" menu > "Copy cd Command" |

Choose the default terminal, editor, and AI agent in Settings > Launching. Terminal.app and iTerm2 are tested. Ghostty, Warp, and Zed are listed when installed and marked "not verified".

If the terminal could not be opened, the toast says why and a safe `cd` command is on your clipboard.

## Read what is deployed

Open a product > Development. The "Source of truth" card shows four stages: Local, GitHub, Staging, Production.

| Badge | Meaning | What to do |
| --- | --- | --- |
| Verified | The target itself reported it | Nothing |
| Reported | A CI or provider record says so; the running system did not confirm | Add a status endpoint to verify |
| Stale | It was true when last seen; that is past its expiry, or a newer check failed | Refresh (Cmd+R); read the reason |
| Unknown | Nothing observed, or only failures | Connect a source, or fix the stated problem |

ForgeDeck never shows production as current because `main` moved or CI is green. To get Verified evidence for an environment, do one of these:

- Add a **version URL** (simplest, any website or WordPress site): Environments tab > the environment's add menu > "Add Version, Status, or Health Check…" > "Version URL". Have your build write `forgedeck-release.json` (commit, version, build time; never secrets, see `Companions/contract/deployment-fingerprint.md`) into what it publishes, for example the static site's output folder or `wp-content/` on WordPress, and give its URL. A page that sends an `X-Release` or `X-Commit-Sha` header works too. No plugin, no token.
- Add a **status endpoint**: the same menu > "Status endpoint". Your app must serve the companion `/status` route (see `Companions/`). It adds health checks and can require a token.
- Add an **SSH host with a release file**: "Add SSH Host…" and give the path of a file your deploy writes, such as `/srv/app/forgedeck-release.json`.

To get Reported evidence from GitHub deployment records, give the environment a GitHub environment name when you add it.

The sentences under the chain compare stages. "Not enough history to count commits" means one of the commits is not in your local checkout. Press the Fetch button on the checkout, then refresh.

## Health checks and alerts

- Add a health check from the same menu as a status endpoint. It passes when the URL answers with HTTP 200.
- Checks run on the polling interval (Settings > General, default 5 minutes) and on Cmd+R.
- Three failures in a row open one alert. The next pass closes it. An offline Mac does not count as a failure.
- Alerts show on the bell, in the Activity page, in "Needs attention" on the Overview, and in the menu bar popover.
- On an alert, press "Acknowledge", or snooze it for 1, 8, or 24 hours.
- Other alerts: failed pipeline on the default branch, GitHub token rejected, failed deployment record, a metrics source that stopped answering for over an hour, production measurably behind staging, a secret that expires within 7 days or whose rotation reminder is due.

ForgeDeck does not post macOS notifications.

## Leads and metrics

Numbers appear only when a product's own endpoint reports them.

1. Serve the companion `/metrics` route (and optionally `/leads`) from your app. Example packages are in `Companions/`.
2. Environments tab > add menu > "Add Metrics Source…". Enter the site root, or a URL ending in `/v1`. Choose a bearer token variable if the endpoint needs one.
3. Open Leads & Metrics, or the product's Metrics tab.

The page shows a funnel of event counts for the chosen window, the counters each source reports with their age, and a lead inbox where you can mark events read, flagged, or handled. Contacts are masked when they arrive; ForgeDeck never stores the full value.

If a source stops answering, its numbers stay and turn Stale. They do not drop to zero.

### Let your agent set up leads

Choose **Set Up Leads…** on a product (right-click menu, Product menu, the palette, or the empty Metrics tab). Pick the environment leads come from, usually Production, and press Start.

1. ForgeDeck makes a token for that environment and keeps it in the Keychain as `FORGEDECK_TOKEN_PRODUCTION` (or the environment's tier). The agent never sees it; its prompt carries only the token's SHA-256, which is what the server stores.
2. The agent looks first and changes nothing. It finds what the product collects (contact and quote forms, signups and trials, WooCommerce, Stripe, or other orders, subscriptions, bookings) and where each is stored. It shows you a short table.
3. It asks which ones ForgeDeck should see and whether to set up the check now, and waits for your answer.
4. With your yes, it adds the companion routes to the product in a change you review, tests them locally, and proposes the metrics source in `.forgedeck/environments.json` (`metricsURL` and `metricsToken`, the variable's name). It does not deploy.
5. Once it is live, press Review… on Proposed environments. ForgeDeck reads counts and leads from then on.

`forgedeck leads <product>` shows each source, when it last answered, its counters, and the newest lead, so an agent can confirm leads are coming in. Contacts are never sent: only ids, kinds, times, and a source name. If an existing token's hash never reached the server, open Set Up Leads again and tick Make a new token.

Revenue is shown only when a source reports a counter named `mrr_cents`. ForgeDeck does not calculate revenue. There is no Stripe, WooCommerce, or analytics connector yet.

## Secrets and variables

### Add one

Secrets Vault > "Add Variable" (or a product's Secrets tab).

1. Name it, for example `DATABASE_URL`.
2. Choose Secret or Plain. A secret's value goes to the Keychain. A plain value is saved in `portfolio.json`.
3. Choose the scope: Global, Organization, Product, or Environment.
4. Tick the environments it may be used in. Keep one secret per environment: a production secret should list Production only.
5. Optionally set a rotation reminder.

### Use, reveal, rotate, delete

| To | Do |
| --- | --- |
| See what a process would get | The "What a process would receive" panel: pick a product and a tier |
| Reveal a value | The eye icon. It hides again after the reveal timeout |
| Copy a value | The copy icon. The clipboard is cleared after the reveal timeout |
| Rotate | The pencil icon, enter a new value, Save |
| Delete | The trash icon, then press and hold to confirm. The Keychain item is deleted too |

Revealing or copying a production secret asks for Touch ID or your password. You can turn that off in Settings > Privacy & Data, but it is on by default.

States in the preview: **Inherited** (from a wider scope), **Overridden** (a narrower scope replaced a wider one), **Direct** (defined at the environment), **Blocked** (defined, but not allowed in this tier), **Expired**, **Missing**, **Not granted** (the profile does not list it).

## Actions

Product > Actions.

- **Recipes** are reviewed commands. Detected ones (tests, dev server, Compose) arrive as "Suggested"; press "Approve" after reading the command. Add your own with "Add Recipe".
- A recipe is a program and its arguments, not a shell line. Pipes, redirects, and `&&` are refused; put them in a script and run the script.
- "Run" captures the output in a sheet, redacted. "Run in Terminal" opens a terminal window; that mode passes no variables.
- Recipes marked Remote write or Production critical, and any recipe aimed at a production environment, ask you to press and hold for one second after showing the target, command, and variables.
- SSH recipes can only use the five built-in read-only probes.

## Command line

Install the command once (Settings > Command Line, or `./build.sh --link-cli`). It is a link at `~/.local/bin/forgedeck` to the app's own binary. Your shell profile is not changed; add `~/.local/bin` to `PATH` yourself if it is not there.

`<product>` is the slug shown by `forgedeck list` (right-click a product > "Copy CLI Name"). The first 8 or more characters of a product id also work.

### Commands

| Command | What it does |
| --- | --- |
| `forgedeck list [--json]` | One line per product: slug, status, name |
| `forgedeck status <product> [--json]` | Checkouts, the four evidence stages, the relations between them, open incidents |
| `forgedeck open <product> [--checkout <name>] [--terminal <name>] [--editor]` | Opens a checkout in the preferred terminal, a named app, or the preferred editor |
| `forgedeck doctor [--product <product>] [--ssh <host-alias>] [--json]` | Checks data, integrity, tools, and credential references; optionally a product's folders and evidence, or an SSH host |
| `forgedeck env list <product> --environment <name> [--profile <name>] [--json]` | Variable names, states, and scopes for an environment. Never values |
| `forgedeck actions list <product> [--json]` | Recipes with their safety class and approval state |
| `forgedeck exec --product <product> --environment <name> --profile <name> -- <program> [args...]` | Starts a program with the variables its profile grants |
| `forgedeck context <product>` | Prints a short project description without secrets, for an AI agent |
| `forgedeck help`, `forgedeck version` | Help text, version |

`--environment` accepts the environment's name, its tier (`development`, `staging`, `production`, `preview`, `custom`), or `local`.

`--terminal` matches the start of an app name: `term`, `iterm`, `ghostty`, `warp`, `visual`, `cursor`, `xcode`, `zed`.

### Examples

```sh
forgedeck list
forgedeck status my-app
forgedeck status my-app --json | jq '.stages[] | {stage, commit, evidence}'
forgedeck open my-app
forgedeck open my-app --checkout api --terminal iterm
forgedeck open my-app --editor
forgedeck doctor
forgedeck doctor --product my-app
forgedeck doctor --ssh my-server
forgedeck env list my-app --environment development --profile tests
forgedeck actions list my-app --json
forgedeck exec --product my-app --environment development --profile tests -- npm test
forgedeck context my-app > /tmp/my-app-context.md
```

### `exec` in detail

Before `exec` can run anything you need a terminal profile: product > Actions > "Add Profile". The profile names one environment, the programs it may start, and the variables it may receive.

- The program must be a bare name that the profile lists. A path such as `/bin/sh` is refused.
- The program is found in `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/bin`, in that order. Your shell's `PATH` is not used to find it.
- A profile made for one environment cannot be used with another.
- A variable that is not allowed in the environment's tier stops the run.
- Production secrets ask for Touch ID or your password.
- `exec` prints the names of what it granted on stderr, runs the program in the profile's checkout folder, and exits with the program's exit code.
- Values are passed through the program's environment in memory. They are not printed or written to a file. The program and anything it starts can read them, so grant only what it needs, and think twice before listing a shell.
- When stdout is not a terminal (a pipe or a file), the program's output is redacted for the granted values and common token shapes.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | OK |
| 1 | Failed: unknown product, missing folder, a failed doctor step, unreadable data |
| 64 | Wrong usage: unknown command, missing flag |
| 77 | Denied by a rule: `exec` did not run and no secret was read |
| other | For `exec`, the exit code of the program it started |

### JSON output

`--json` output uses stable keys; keys are only added. Secret values never appear in any output.

## Settings

| Tab | What is there |
| --- | --- |
| General | Appearance (Match the Mac, Light, Dark), workspace name, menu bar switch, background checks and interval, shortcut list |
| Launching | Preferred terminal, editor, AI agent; project folders |
| Privacy & Data | Production authentication switch, reveal timeout, how long observations are kept, data folder, Export, Import, Clear Cache, demo products |
| Command Line | Install the `forgedeck` link, examples |
| Diagnostics | Tools on this Mac, integrity check, schema version, audit log, version |

- **Export** writes your products, environments, and variable names. Every credential becomes a placeholder to enter again. Demo products are left out.
- **Import** adds products that are not already present. Existing ones are kept as they are.
- **Clear Cache** removes observed state. Products and settings are untouched.
- **Updates** are manual: rebuild with `./build.sh`.

## Troubleshooting

### macOS asks to allow Keychain access after a rebuild

**Why:** Keychain items remember which app created them. A rebuild signed differently is a different app to the Keychain. Ad hoc signing (when no Apple Development certificate is found) gives every build a new signature.

**Fix:** Allow the access, or choose "Always Allow". To stop the prompts, sign every build with the same identity: keep an Apple Development certificate in your login keychain (Xcode > Settings > Accounts), or set `SIGN_IDENTITY` when running `./build.sh`. If a secret can no longer be read, edit the variable and enter the value again.

### `forgedeck: command not found`

**Why:** The link is missing, or `~/.local/bin` is not on your `PATH`.

**Fix:** Settings > Command Line > "Install in ~/.local/bin" (or `./build.sh --link-cli`). Then add this to your shell profile and open a new terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

You can also call the binary directly: `~/Applications/ForgeDeck.app/Contents/MacOS/ForgeDeck list`. After moving or deleting the app, reinstall the link.

### A folder moved

**Symptom:** The checkout shows "Folder missing".

**Fix:** Press "Find It" on the checkout row. ForgeDeck tries the bookmark it saved when the folder was added. If that fails, use "Link Folder…" to add the folder at its new place, then remove the old checkout from the "more" menu. Removing a checkout never touches the folder.

### Evidence is Stale

**Why:** An observation expires 15 minutes after it was made, or a newer check failed.

**Fix:** Press Cmd+R. If it stays Stale, hover the badge or open the Development tab for the reason, then run "Doctor" on the endpoint. Common reasons: the Mac is offline, the token was rotated on the server, the endpoint now reports a different environment. Background checks can be turned on and their interval set in Settings > General.

### GitHub says "Rate limited"

**Why:** Without a token GitHub allows few requests per hour. With a token the limit is much higher.

**Fix:** Connect a token: Infrastructure > Connections > GitHub > "Connect". Use a fine-grained token with read-only access to Contents, Metadata, Pull requests, Actions, and Deployments. The GitHub Doctor shows how many requests are left. The last known head stays on screen while you wait. You can also lengthen the polling interval.

### SSH says "Unknown host key"

**Why:** The host is not in your `known_hosts`. ForgeDeck never accepts a host key for you.

**Fix:** Connect once in a terminal (`ssh my-server`), check the fingerprint with the server's owner, and accept it there. Then run the Doctor again. If the message is "Host key changed", stop: verify the new fingerprint before you update `known_hosts` yourself.

### A terminal did not open the folder

**Fix:** The toast says why, and a `cd` command is on your clipboard. With iTerm2, the first launch from a cold start may not open the folder; try again once iTerm2 is running. For Ghostty and Warp, which are not verified, use "Copy cd Command".

### A status endpoint is rejected as "Malformed response"

**Why:** The endpoint answered, but not with what ForgeDeck expects. The detail says which: the body is not the status contract, it reports another environment than the one you added it to, or it has no commit and no version.

**Fix:** Run "Doctor" on the check and read the Capability step. Make sure the server's configured environment matches (`production`, `staging`, `development`).

### `exec` says "denied"

Read the reason after `denied:`. The usual ones:

| Message | Fix |
| --- | --- |
| The profile does not allow "x" | Add the program name to the profile, or run an allowed one |
| Profile "x" belongs to another environment | Use the profile's own environment, or make a profile for this one |
| Denied: KEY may not be used in this environment | The variable is not ticked for this tier. Add a separate variable for it |
| Missing: KEY | Define the variable, or remove it from the profile |
| Authentication was cancelled or failed | Run it again and confirm with Touch ID or your password |
| x was not found on this Mac | Install the program in one of the searched folders |

### ForgeDeck could not read its data

**Symptom:** An error state instead of the pages, naming the data folder.

**Why:** `portfolio.json` is damaged or was written by a newer version. ForgeDeck does not overwrite it in this state.

**Fix:** Restore the file from a backup, or move it aside to start empty. `forgedeck doctor` prints the same error.


## Releases: plugins and packages

For something you ship rather than host, such as a WordPress plugin or an npm or PyPI package, the question is which version is out. The Releases card on the product's Overview shows:

- **In the code**: the plugin header `Version:`, the `Stable tag:` in readme.txt, and the version in package.json or pyproject.toml, read from the primary checkout on refresh.
- **Published**: each registry you track ("Track a Registry…", or "Track" on a suggestion) and the latest GitHub release. Registry lookups are public, read-only requests that send only the package name. They are Reported evidence: the registry says what it publishes.
- **Findings** in words: not released yet, the registry is ahead of your checkout, or readme.txt's Stable tag does not match the plugin header (WordPress.org installs the Stable tag).

Detected packages are only suggestions. Nothing is looked up until you track it, because a private package can share a name with an unrelated public one. A new published version appears in Activity.

## Agent context for related repositories

Link related products under Development > Agent context, then start your agent from there or with `forgedeck agent <product>`. See [AGENT_CONTEXT.md](AGENT_CONTEXT.md) for what the agent receives and what it costs.

In the in-app terminal, the agent starts under a short header that shows the context file, the related products, and where the pointer went (Claude Code gets it in its system prompt, which is otherwise invisible).

CONTEXT.md also lists the product's **variable names** per environment (never values) and the exact `forgedeck exec` line for each terminal profile. An agent that needs a secret runs the command through a profile: the program gets the value in its environment, the agent sees only the redacted output, and a production secret still asks you for Touch ID. Variables never reach the agent's prompt on their own.

If an agent reports that `forgedeck exec` was refused with "no profile", open the product's Secrets tab. Under "What a process would receive", pick the environment and press **Create Agent Profile…**. It opens a profile filled in with the variables delivered there and the programs the project uses (never a shell). Review it and press Save Profile. Saving rewrites CONTEXT.md, so a running agent can read it again and use the profile. No shell runs, so `$NAME` in an argument stays literal: the program has to read the value from its environment.

## Forge Remote: work on any product from your phone

Settings › Forge Remote › **Turn on Forge Remote** starts Claude Code's Remote Control server (`claude remote-control`) in a terminal named Forge Remote. It runs in a folder of its own, `remote/` in the data folder, which holds:

- `CLAUDE.md`, a few lines every session loads: one product per session, no deploys or pushes unless asked, and "read nothing until asked; use the forgedeck skill".
- `.claude/skills/forgedeck/SKILL.md`, the forgedeck skill. A session loads only its one-line description up front. When you name a product, it reads the skill, finds the product with `forgedeck list`, and reads only what the task needs: `forgedeck context <slug> --write` for code work, `status --json` for what is deployed, `ci --brief` for a failing build, `links` for dashboards.
- `.claude/settings.json`, which makes every product folder and the context folder working directories, so a session can `cd` into any product.

ForgeDeck rewrites these files when products change. On your phone, open the Claude app (or claude.ai/code), pick the session, and name a product. The session reads that product's CONTEXT.md and works in its folder.

**Switching products.** Every session you start from the app begins in the Forge Session folder with empty context, so start a new session for each product. A session asked to switch suggests exactly that, or `/clear`. If you continue in the same session anyway, it re-reads the new context and treats earlier work as belonging to the other product.

- **Approvals** (Ask before every change, Edit files without asking, Plan only, Auto) apply to every session. Prompts come to your phone. Modes that skip every question are not offered. Changing approvals or the session name restarts Forge Remote, which ends open sessions.
- **Keep this Mac awake while it runs** prevents idle sleep. Closing the lid still sleeps the Mac.
- Forge Remote runs while ForgeDeck is open and starts again when ForgeDeck opens. If it stops on its own, ForgeDeck restarts it, at most three times in ten minutes.
- The first time, Claude Code may ask in the Forge Remote terminal whether to trust the folder. Answer it at the Mac.
- Production secrets need Touch ID at this Mac, so a remote session cannot use them.
- Only Claude Code has Remote Control. Other agents still start from product pages.

### The forgedeck skill everywhere

Settings › Command Line › Agent skill › **Install** puts the same skill in `~/.claude/skills/forgedeck`, so any Claude Code session on this Mac can find a product and its context when you mention it, without loading anything first. It never replaces a `forgedeck` skill that ForgeDeck did not write, and Remove deletes only its own copy.

## Let a repository propose its environments

An agent (or you) can describe where a product runs in `.forgedeck/environments.json` in its folder:

```json
{"environments": [{"tier": "production", "name": "Production", "domains": ["example.com"],
  "versionURL": "https://example.com/forgedeck-release.json", "healthURL": "https://example.com/health",
  "github": "production", "note": "Deploys from .github/workflows/deploy.yml"}]}
```

Tiers are production, staging, development (or local), preview, and custom. Domains are host names only. URLs must be https, except on localhost. `forgedeck env check <product>` prints what ForgeDeck would add and every problem, and changes nothing.

On refresh, the product's Overview shows **Proposed environments**. **Review…** lists each one with what it adds; production is drawn in red. Tick the ones you want and press Add. A proposal for an environment that exists (same name, or the same production, staging, or local tier) only adds missing domains, a Version URL, a health check, or the GitHub environment name. Nothing is removed or replaced. Proposals with problems cannot be added until the file is fixed. The card disappears once everything in the file is set up.

The forgedeck skill has the steps, so you can ask an agent, even from your phone through Forge Remote, to "set up production for this plugin". It reads the repository's deploy files, writes the file, runs `env check`, and asks you to review it. A product with no production environment says so in its CONTEXT.md.

## Organizing products

- **Rename**: right-click a product in the sidebar › Rename…, or use the palette. The display name changes; the CLI name stays the same.
- **Groups**: right-click a group header › Rename Group…. Renaming onto another group's name merges the two. Drag a product onto a group to move it, or right-click › Move to Group › New Group….
- **Remove**: right-click › Remove from ForgeDeck…. The folders, repositories, and servers are not touched. Secrets scoped to the product are deleted from the Keychain, and the sheet says how many.

## Editor

Open in Editor (⌘⇧O) opens the current product's checkout. Cursor, VS Code, VSCodium, Windsurf and Zed get it through their own command line tool, so it opens in its own window, or the window that already has it comes forward. A single `.code-workspace` file at the top is opened instead of the folder. Xcode gets the `.xcworkspace`, `.xcodeproj`, or `Package.swift`.

## Play

Play (⌘⇧P, in the product header, the right-click menu, and the palette) launches what the product builds, best option first:

1. Mobile: a "Build and Run on … Simulator/Emulator" recipe.
2. Desktop: `./build.sh --open`, `npx tauri dev`, `swift run`, or an Electron start script.
3. Web: the Start Dev Server recipe, then the page opens in the browser once the server answers. The address comes from the Local environment's domain, the script's `--port`, `vite.config`, or the framework's default.
4. Site: a WordPress plugin or theme inside a Local site opens that site's admin. Local's `sites.json` is only read.

A recipe that is not approved opens for review first. Saving approves it, and Play runs it right away.

### Set up how a product runs

When Play has nothing to launch, or launches the wrong thing, choose **Set Up Run with Claude Code…** from the Play menu (also in the right-click menu, the palette, and Product › Set Up Run…). With nothing to launch yet, the button itself says **Set Up Run**.

ForgeDeck starts your agent (Settings › Agents) in the product's folder with a prompt that says what ForgeDeck already knows: the folder, the stack, the files at the top (package.json, compose files, Makefile, and so on), the Local site, and the commands already saved. The agent works out what the product is and how people use it, installs what it needs, tries the commands, and writes them to `.forgedeck/run.json`:

```json
{"commands": [
  {"label": "Start Dev Server", "kind": "web", "steps": [["npm", "install"], ["npm", "run", "dev"]], "url": "http://localhost:5173"},
  {"label": "Start with Docker", "kind": "web", "steps": [["docker", "compose", "up", "--build"]], "url": "http://localhost:8080"},
  {"label": "Run Tests", "steps": [["npm", "test"]]}
]}
```

- `kind` web, desktop, mobile, or site puts the command on Play. Without it, the command is an action (tests, builds, seeding) in the Actions tab.
- Each step is a program and its arguments. Shell strings, absolute program paths, folders outside the checkout, pages that are not on this Mac, and anything that deploys, publishes, or pushes are refused.
- `forgedeck run check <product>` shows what would be saved and every problem. Nothing changes.

When the agent finishes, choose **Review Run Setup…** in the Play menu, or press Review… on the Run setup card in Overview. Saving approves the commands you tick. A command with the same name as a saved one replaces it. What run setup saves comes first in Play, in the order the agent proposed.

## Toolbox and agent skills

The Toolbox lists command-line tools that save AI tokens or check repositories. **Install with Homebrew** (or uv) runs in the background; the card shows Installing… and a failed install opens its output. Tools that run against a repository appear on each product's Overview tab, in the Tools card, with a checkout picker when the product has more than one.

**Agent Skills** are folders with a `SKILL.md` that Claude Code and other agents load when a task needs them. The Toolbox lists popular skill repositories (Anthropic, Impeccable, Superpowers, Vercel, HyperFrames, OpenAI, Trail of Bits, Hugging Face), and **Add a skill repository** takes any public GitHub `owner/repo` or link.

- **Add a skill repository** also takes the command a skill's page tells you to run, like `npx skills add vercel-labs/agent-skills --skill react-best-practices -a claude-code`. ForgeDeck reads it instead of running npx: the repository, a `@tag` or commit, a `/tree/` link, `--skill` names (ticked in the sheet), and `-a` agents (Claude Code, or the shared agents folder for the others). Skills always install for your user, like `-g`.
- **Add Skills…** makes a shallow clone of the repository and lists every skill in it. Skills inside a `skills/` folder are ticked; templates and examples are not. Nothing in the repository runs.
- Choose where they go: Claude Code (`~/.claude/skills`) and the shared agents folder (`~/.agents/skills`, ticked when it exists). When a repository has one copy per agent, each folder gets the copy written for it.
- Each skill ForgeDeck adds gets a `.forgedeck-skill.json` receipt with the repository and commit. **Update…** replaces only those; the old copy goes to the Trash. A folder you added some other way is never replaced. The sheet marks it "Yours, kept".
- **Remove…** moves the skills ForgeDeck added from that repository to the Trash.
- Skills are instructions your agents follow, and some include scripts the agent may run. Add only repositories you trust.

## MCP servers

ForgeDeck shows which products have an MCP server, read only from files on this Mac. It never connects to a server, reads no credential, and runs no AI, so the same files always give the same answer.

- **Connections** come from Claude Code (`~/.claude.json`, every project and per project), Claude Code plugins, Claude Desktop, Codex, Cursor, and each checkout's `.mcp.json`. A server belongs to a product when it is set up for the product's checkout, runs a program from it, comes from a plugin built from the product's repository, has the product's domain as its address, names the product in its address, or is named after it. Local addresses (localhost, `.local`) match only with the same port.
- **In the code**: an MCP SDK dependency, `server.json`, or registered tools (WordPress abilities, FastMCP `@tool`, TypeScript `registerTool`). Tools marked read-only or as writes are told apart. When the server's instructions are one block of text in the code, they are shown; text built at run time is not guessed at. `MCP.md` or `docs/MCP.md` in the repository is shown as the guide.
- **Badge**: products with MCP get an MCP badge in the sidebar, on cards, and in the header. It turns the production color when a connection reaches production: its address is the production domain, or it is on the internet and named prod.
- **MCP card** on the Overview tab: each connection (where it is set up, the host, what it reaches, and why it matched), the tools, and **How to use it**: practices that follow from the facts, and the server's own instructions.
- Only hosts are shown. Headers, env values, and URL paths are never read into ForgeDeck's display, since some servers keep a token in the path.
- The agent's `CONTEXT.md` lists the product's MCP servers and warns when writes change production.
- The Toolbox lists every configured server, including the ones that belong to no product. The refresh button there, Refresh Everything, and ⌘R on a product page read the files again.
