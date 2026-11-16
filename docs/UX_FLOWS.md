# ForgeDeck UX flows

This document walks through the main flows step by step, as they are built on 2026-11-15.
Button labels, sheet titles, and messages are quoted from the code.
Where a flow has a rough edge, the step says so.

## Conventions used by every flow

- Sheets are drawn inside the window over a scrim. Escape or a click on the scrim closes them. Cancel is the Escape key; the primary button is Return.
- Results are reported by a toast at the bottom of the window (2.6 seconds, 4.5 seconds for errors).
- The toolbar has one primary button that changes with the page: "Open Terminal" on a product with a real checkout, "Refresh" on Deployments, Git & CI, Infrastructure, Leads & Metrics, and Activity, "Add Variable" on Secrets Vault, and "Add Product" elsewhere.
- The Local / Staging / Production picker in the toolbar sets the context for variable previews and new recipes. Production is drawn in its own color and shows a banner under the toolbar.
- Demo products show a Demo badge. Their launch, link, refresh, and action controls are disabled or answer with a toast.

## 1. First run

1. Launch the app. The Overview page shows "Welcome to ForgeDeck" with three buttons: "Add Product" (Cmd+N), "Add 3 Demo Products", and "Check This Mac's Tools". The text also says a project folder can be dropped on the window.
2. The sidebar shows the nine pages, Settings, a "Projects" header with "No products yet", and a footer that reads "Nothing to sync".
3. "Check This Mac's Tools" opens the Connection Doctor for the toolchain: `git`, `ssh`, `gh`, `docker`, `op`, installed terminals, editors, and AI agents.
4. "Add 3 Demo Products" adds Lumen, Parcelwise, and Quillnote from fixtures. The Overview fills with tiles, a "Needs attention" list, product cards, and an activity panel, all marked Demo. The footer reads "Demo data" and "Fixtures, not live".
5. Quit and relaunch. The products are still there (`portfolio.json` and `cache.json`).
6. Remove the demo products in Settings > Privacy & Data > Demo products > Remove.

No account, sign-in, or network is needed for any of this.

## 2. Add a product

Open the sheet with the toolbar button, Cmd+N, the plus in the sidebar, the command palette, or by dropping folders on the window. The sheet is titled "Add Product" and says "Everything is read-only until you approve it. Nothing is saved before you press Add."

A segmented control picks one of four modes. A "Sidebar group" field at the bottom applies to all modes (blank means "Products").

### Local Folder

1. Press "Choose Folders…" and pick one or more folders, or drop folders on the window (the sheet opens and scans them).
2. The scan runs in the background with a "Stop" button. It skips hidden folders, dependency and build folders, and symlinks. It stops at depth 4, 20,000 directories, or 500 results, and says so when it hits a limit.
3. A review list shows each project found: name, "Worktree" or "No Git" tags, up to three stack chips, the path, and what would happen:
   - "New product",
   - "Adds a checkout to <product>" when the repository or the main worktree already belongs to a product,
   - "Already in <product>: refreshes metadata" when this exact folder is already registered.
4. Untick anything you do not want. Press "Add N".
5. One product added: its page opens. Several: the Projects page opens. Git state is read right away.

What an import creates: a product named after the WordPress plugin, the repository, or the folder; a "Local" environment; a component; a repository entry when a remote was found; and unapproved recipe suggestions for detected test, dev server, and Compose commands.

The "Project folders" list in Settings > Launching is stored, but this sheet does not offer those folders yet. You pick folders each time.

### GitHub Repository

1. Type a repository as `owner/repo`, an HTTPS URL, or an SSH URL. The hint under the field shows how it was parsed.
2. Or list repositories: leave "Organization" blank for your own account, or type an organization, and press "List Repositories". Listing your own account needs a connected token; the note says "Connect GitHub first to list your repositories." A "Connect GitHub…" link opens the token sheet. Listing reads up to 300 repositories, 100 per page.
3. Filter the list, tick repositories. Ones already in a product are tagged "Already added" and cannot be ticked.
4. Press "Add Repository" or "Add N". A repository that already belongs to a product is not duplicated: that product is returned.
5. The product has no checkout. Its Development tab shows the repository with "View on GitHub", "Clone…", and "Link Existing…".

Cloning is a separate step: "Clone…" opens a folder picker ("Clone Here"). The clone goes into `<chosen folder>/<repository name>`. If anything already exists there, the clone is refused and nothing is overwritten.

### Server / SSH

1. Type a host alias or choose one from the "Choose" menu, which lists hosts from `~/.ssh/config`.
2. Optionally name the product. Pick "Staging", "Production", or "Other".
3. Press "Add Server". The product gets one environment with that host and one infrastructure component.
4. The sheet reminds you to run the Connection Doctor afterwards. Nothing is contacted when the product is added.

### Manual

1. Type a name. Press "Add Product".
2. The product starts in the Idea lifecycle with nothing connected. Add folders, repositories, and environments later from its tabs.

## 3. One-click terminal

Ways to open the first checkout of a product in the preferred terminal:

- the toolbar "Open Terminal" button on a product page,
- Cmd+O on a product page,
- the terminal icon on a product card,
- right-click a product > "Open in Terminal",
- the command palette ("Open Terminal in <checkout>" or "Open Terminal · <product>"),
- the terminal button next to a favorite in the menu bar popover,
- `forgedeck open <product>` in a shell.

What happens:

1. The app checks that the folder exists. If not: "The folder no longer exists at <path>."
2. It asks Launch Services to open the folder URL with the terminal app. No path is typed into a shell or an AppleScript, and no Automation permission is asked for.
3. On success the toast reads "Opened <checkout> in <app>", a session record is saved, and an `open.terminal` audit event is written.
4. If the app is not installed or refuses, the toast gives the reason and says "The command was copied instead." The clipboard then holds `cd -- '<path>'`, safely quoted.

For a product with several checkouts, the Development tab and the Git & CI page have a terminal button per checkout. The "more" menu on a checkout offers every installed terminal, "Copy cd Command", and "Remove from <product>". Ghostty, Warp, and Zed are labeled "(not verified on this Mac)".

Editor (Cmd+Shift+O), Reveal in Finder (Cmd+Shift+R), and "Open with <agent>" work the same way. The AI agent starts in the folder through a launch script in Terminal or iTerm2. Nothing is sent to the agent by ForgeDeck.

## 4. Reading the evidence chain

Open a product > Development. The first card is "Source of truth": "Each stage shows what was observed, not what is assumed".

1. Four stages: Local, GitHub, Staging, Production.
2. Each stage shows a headline (a version, a short commit, or the honest gap such as "Authentication required"), an evidence badge (Verified, Reported, Stale, Unknown), the source, and when it was seen. Hover the badge for the full explanation.
3. Tags mark "Uncommitted work" on Local and "Mixed revisions" when instances report different commits.
4. Below the stages, one sentence per pair says how they relate: "Local is 1 commit ahead of GitHub.", "GitHub and Production are on abc1234 (reported, not verified).", or "... differ. Not enough history to count commits: fetch the repository in a local checkout."

How to read it:

- Local is Verified when the folder exists and is a Git repository.
- GitHub is Verified for the default branch head for 15 minutes after a fetch, then Stale.
- Staging and Production are Verified only from a status endpoint or a release file over SSH. A GitHub deployment record gives Reported. A green CI run gives nothing.
- If a newer check failed (for example the token was rejected), the last good value is shown as Stale with the reason.
- With no evidence at all the stage says Unknown, or "Not configured" when nothing is connected. It never says "In sync".

The same facts appear as a three-cell strip on every product card, on the product Overview cards, on the Deployments page, and in `forgedeck status <product>`.

## 5. Add an environment and a status endpoint

1. Product > Environments > "Add Environment". Pick Local, Staging, Production, Preview, or Custom. Optionally name it, give a domain, and (when the product has a repository and the tier is not Local) a GitHub environment name. A second Local, Staging, or Production environment cannot be added.
2. On the environment's card, open its add menu and choose "Add Health Check or Status Endpoint…".
3. The sheet "Add a Check to <environment>" explains the difference: a status endpoint follows the ForgeDeck contract and proves which release is running; a health check only proves the URL answers.
4. Pick the kind, name it, and enter the URL. HTTPS is required except on localhost. A URL with embedded credentials is refused.
5. If the endpoint needs a token, choose a secret variable under "Bearer token". The list shows secret variables that are global or scoped to this product. Add the secret first if the list is empty (flow 6).
6. Press "Add Check". The product refreshes at once.
7. Press "Doctor" on the row to see Address, DNS, TLS, Authentication, Capability, and Last good response, step by step.

The same menu adds a metrics source ("Add Metrics Source…": base URL, token, and a switch for lead events) and an SSH host ("Add SSH Host…": alias and an optional release file path). Adding an SSH host opens its Doctor straight away.

Removing an environment asks for hold-to-confirm and says "Nothing on any server changes."

## 6. Add a secret

1. Open the sheet from Secrets Vault > "Add Variable", a product's Secrets tab > "Add Variable", the toolbar on the vault page, or the palette ("Add Variable or Secret").
2. Enter a name (letters, digits, underscores; must not start with a digit). Choose "Secret" or "Plain".
3. For a secret, choose where it is stored:
   - "Keychain": paste the value.
   - "1Password CLI": enter an `op://vault/item/field` reference. The hint says when `op` is not installed.
   - "Environment variable": enter the name of a variable in ForgeDeck's own environment.
4. Choose the scope: Global, Organization, Product, or Environment. Product and Environment ask for a product; Environment asks for the environment too.
5. Under "May be used in", tick the tiers. Environment scope sets this to that environment's tier and locks it. A secret ticked for Production and another tier shows the hint "Use one secret per environment."
6. Optionally set a rotation reminder (30, 90, or 180 days) and a note.
7. Press "Add Variable". The footer reminds: "Readable only while this Mac is unlocked. Not synced to iCloud."

In the list, each row has reveal, copy, edit or rotate, and delete. Reveal and copy of a production secret ask for Touch ID or the password. A revealed value hides again after the reveal timeout. Copy clears the clipboard after the same time. Delete asks for hold-to-confirm and removes the Keychain item.

To rotate: press the pencil, enter a new value, and save. Leaving the value empty keeps the current one.

The "What a process would receive" panel previews, for a chosen product and tier, each key with its state: Inherited, Overridden, Direct, Missing, Expired, Blocked, or Not granted. It shows names and sources, never values.

A plain value that looks like a token is refused with "That value looks like a token. Mark the variable as a secret."

## 7. Terminal profile and `forgedeck exec`

1. Product > Actions > "Add Profile".
2. Give it a one-word name (for example `tests`), choose the environment, and optionally a checkout.
3. "Programs it may start": program names separated by commas, such as `npm, node`. Paths are refused. The hint warns that listing a shell lets any command read the variables.
4. "Variables it may receive": variable names separated by commas.
5. A profile for a production environment shows a production-colored stripe and the line "Production: every run asks for Touch ID or your password and is written to the audit log."
6. Press "Save Profile".
7. Install the CLI once: Settings > Command Line > "Install in ~/.local/bin". Add `~/.local/bin` to `PATH` yourself if needed.
8. In a terminal:

   ```sh
   forgedeck env list my-product --environment development --profile tests
   forgedeck exec --product my-product --environment development --profile tests -- npm test
   ```

9. `exec` prints one line on stderr naming what it granted, for example `forgedeck: npm receives DATABASE_URL (Local)`, then runs the program in the profile's checkout folder and returns its exit code.
10. If a rule fails, it prints `denied: <reason>` and exits with 77. Nothing runs and no secret is read. Examples: the program is not in the profile, the profile belongs to another environment, a variable is not allowed in this environment, a variable is missing.

## 8. Recipe approval and run

1. Product > Actions. Commands detected at import appear under "Action recipes" tagged "Suggested" with an "Approve" button. Review the command, then approve it.
2. Or press "Add Recipe". Choose "Run on this Mac", "Read-only SSH probe", or "Open a link".
   - Run on this Mac: type the command as you would in a terminal, without pipes, redirects, or `&&`. Choose the checkout, an optional subfolder, whether to run in a terminal window, and the variables it may receive.
   - Read-only SSH probe: choose one of the product's hosts and one of the five fixed probes.
   - Open a link: an HTTPS URL to a runbook or dashboard.
3. Choose the environment and the safety class. Saving a recipe you wrote approves it. A local recipe aimed at a production environment is raised to "Remote write" or higher.
4. Press "Run" or "Run in Terminal" on the row, or run it from the palette ("Run <label>"; production recipes carry a Prod tag there).
5. Read-only and Local write recipes outside production run at once.
6. Remote write, Production critical, and any production-environment recipe open a confirmation sheet titled `Run "<label>"` with three rows: Target, Command, Variables. The footnote says "This is written to the audit log." Press and hold "Hold to Run" for one second. Releasing early cancels.
7. A captured run opens a log sheet: "Running for <product>…", then "Finished with exit code N." Output is redacted. "Stop" cancels, "Copy Output" copies the redacted text. Output is not saved.
8. A terminal run opens a terminal window through a launch script and reports "Started "<label>" in a terminal".
9. If a variable the recipe names is blocked or missing for its environment, the log shows "Denied: <key> is blocked in <environment>." and the exit code is 77.

The session appears under Terminals & Actions > Recent sessions with its exit status.

## 9. Alerts: acknowledge and snooze

1. An alert opens when a rule fires (see ARCHITECTURE.md, "Alert rules"). The toolbar bell shows a red dot, the Activity sidebar item shows a count, the menu bar icon becomes a filled hammer, and the Overview lists it under "Needs attention".
2. Open Activity. The "Alerts" card lists open incidents with product and detail.
3. Press "Acknowledge" to mark it seen. It stays open, tagged "Acknowledged", and no longer counts as needing attention.
4. Or choose a snooze of 1, 8, or 24 hours. It is tagged "Snoozed" and returns to the count when the time is up.
5. The incident resolves on its own when the condition clears, and one recovery event enters the feed. "Show resolved" lists past incidents.
6. The arrow on a row opens the product's Development tab.
7. The menu bar popover shows up to three alerts with an "Acknowledge" button each.

An alert is raised once per rule and subject. Three failed health checks in a row open one alert; a fourth failure adds nothing; the next success closes it once.

## 10. Connection Doctor

Open it from a "Doctor" button (GitHub card, a check row, an SSH host row), from the palette ("Run Toolchain Doctor"), from first run, or with `forgedeck doctor`.

The sheet is titled "Connection Doctor" and says "Each step shows what was checked. No secret is displayed." Each step is pass, warn, fail, or skipped, with one line of detail. "Run Again" repeats it.

| Target | Steps |
| --- | --- |
| GitHub | DNS for api.github.com; Authentication ("Signed in as <login>", or a warning that no token is stored); Permissions (fine-grained, classic scopes, or a warning when the token can write); Rate limit |
| Status endpoint or health check | Address (URL policy); DNS; TLS; Authentication (rejected token, missing token, or missing scope); Capability (the release and health it reports, or why not); Last good response |
| SSH host | Host alias (found in `~/.ssh/config` or not); DNS for the resolved host name; Host key (present in `known_hosts` or not); Authentication; Read-only probe (`uptime`) |
| This Mac | `git`, `ssh`, `gh`, `docker`, `op`; Terminals; Editors; AI agents |

For SSH, a host key that is not in `known_hosts` fails the Host key step with "Connect once in a terminal and check the fingerprint. ForgeDeck never accepts a host key for you." Authentication is then skipped.

`forgedeck doctor` prints the same toolchain steps plus Data, Integrity, and Credentials. `--product <slug>` adds a line per checkout and per evidence stage. `--ssh <alias>` adds the SSH steps. It exits with 1 when any step fails.
