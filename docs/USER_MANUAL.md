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

- Add a **status endpoint**: Environments tab > the environment's add menu > "Add Health Check or Status Endpoint…" > "Status endpoint". Your app must serve the companion `/status` route (see `Companions/`).
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


## Agent context for related repositories

Link related products under Development > Agent context, then start your agent from there or with `forgedeck agent <product>`. See [AGENT_CONTEXT.md](AGENT_CONTEXT.md) for what the agent receives and what it costs.

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
