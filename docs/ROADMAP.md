# ForgeDeck roadmap

This document tracks the contract's milestones M0 to M6 with honest marks, gives an Implemented / Partial / Planned table by feature area, and lists blockers, remaining risks, and next steps.
It reflects the code and test results of 2026-11-15.

Marks: `[x]` done and verified, `[~]` partly done or done but not exercised live, `[ ]` not done.

## Milestones

### M0: Research, brief, skeleton, design system

- [x] Machine inspected: macOS 27.0.1, Xcode 27.2, Swift 6.4.2, Apple Development signing identity, no Developer ID
- [x] BAMA plugin 1.0.0 skills used: `new-mac-app` template, `design-kit` conventions, `agent-cli` idea (the app binary is the CLI)
- [x] Swift package with `ForgeDeckKit`, `ForgeDeck`, and a test target
- [x] `build.sh`, `scripts/test.sh`, `tools/snap.sh`, `tools/selftest.sh`, `scripts/lint.sh`
- [x] Domain models, JSON storage with a versioned schema
- [x] Design kit: tokens, type roles, icons, components (`Sources/ForgeDeck/DesignKit`, `design/KIT.md`)
- [x] Main shell: sidebar, toolbar, environment picker, command palette, sheets, toast
- [x] Checked-in demo fixtures, all marked Demo
- [x] App launches to a first-run state in light and dark
- [~] Docs written first: these docs were written after the implementation, as records
- [ ] `docs/BRIEF.md`, research notes, and a user-story backlog as separate files

### M1: Project catalog and local launcher

- [x] Product hierarchy: components, repositories, checkouts, environments
- [x] Local folder discovery with limits, cancellation, symlink safety, secret-file refusal
- [x] Import review with merge and refresh proposals; idempotent re-scan
- [x] Favorites, groups, search, filters
- [x] Product page with nine tabs
- [x] Terminal.app and iTerm2 launch through Launch Services, verified with a path containing spaces and an apostrophe
- [~] iTerm2 cold launch: the first attempt did not open the folder
- [~] Ghostty, Warp, Zed: listed when installed, labeled not verified; not installed here
- [x] Editor, Finder, link launch
- [x] Command palette
- [x] Settings with five tabs
- [x] Schema migration (v1 to v2) and integrity repair
- [x] Safe export and import with credential placeholders
- [x] Honest Git state, including detached HEAD, conflicts, stashes, shallow clones, worktrees
- [~] Project roots: stored in Settings, not offered by the Add Product sheet, never watched
- [ ] Drag and drop of anything other than folders onto the window

### M2: GitHub, Git drift, CI, deployed-version truth

- [x] GitHub connector: head, pull requests, runs, deployments, latest release, paging, ETags, typed failures
- [x] Token in the Keychain, pasted or imported from `gh auth token`
- [x] Evidence model with Verified, Reported, Stale, Unknown and a source and time on every fact
- [x] Local, GitHub, Staging, Production chain with measured comparisons or "Not enough history"
- [x] Generic runtime probe (health and companion status)
- [x] Offline caches: last known values with age
- [x] Tests for fake-green scenarios (`EvidenceTruthTests`)
- [~] GitHub exercised live only without a token, on one public repository
- [ ] OAuth device flow
- [ ] `retryAfter` honored by the refresh loop

### M3: Vault, variable scopes, connections, CLI

- [x] Keychain storage with references in the portfolio
- [x] Scope precedence and tier blocking
- [x] Terminal profiles with program and variable allowlists
- [x] `forgedeck` CLI: list, status, open, doctor, env list, actions list, exec, context, help, version
- [x] Real child process receives only granted variables (self-test with the real Keychain)
- [x] Denials: wrong environment, blocked tier, unlisted program, missing variable
- [x] Audit log for grants, denials, reveals, copies, and changes
- [x] Connection Doctor for GitHub, endpoints, SSH, and the toolchain
- [~] Production grants: implemented with device-owner authentication, not exercised with a real Touch ID prompt
- [~] 1Password references: implemented, `op` not installed
- [~] Component and Profile variable scopes: in the resolver, not creatable in the UI
- [ ] Caller authentication for the CLI (XPC or signed helper)
- [ ] `forgedeck shell`
- [ ] Shell completion
- [ ] Integrity protection for `portfolio.json`

### M4: Metrics, leads, health, monitoring

- [x] Versioned companion contract with JSON Schemas and examples
- [x] Metrics and leads adapter with paging, dedupe, masking
- [x] Health samples, history bars, three-failure alert rule
- [x] Alert engine with one incident per rule and subject, acknowledge, snooze
- [x] Bounded cache and retention
- [x] Menu bar extra with summary, alerts, favorites
- [x] Node, Python, and WordPress companion packages with tests
- [x] One test endpoint feeding live data: the local Node example server, in the acceptance tests
- [~] WordPress plugin: PHP tests pass standalone; never run inside a real WordPress
- [x] Lead contact field: the app reads the contract's masked `label` (and masks a raw `contact` if one is sent)
- [~] Revenue: shown only when a source reports `mrr_cents`; no revenue model
- [ ] `/manifest` and `/events` consumed by the app
- [ ] Request signing on the client
- [ ] Metric definitions with targets, units, and custom names
- [ ] macOS user notifications
- [ ] Morning Brief

### M5: Lifecycle and managed integrations

- [x] SSH inspector with fixed read-only probes and release-file reading
- [x] Docker inspector: CLI detection, context, container list
- [x] Action recipes with safety classes, approval, hold-to-confirm, redacted run log
- [x] Deployment history from stored observations
- [x] Lifecycle states Idea, Active, Maintenance, Archived; archived products are not polled and cannot run actions
- [~] SSH: exercised up to the host-key gate only
- [~] Docker: no running daemon here; logs are in the kit but not on a screen
- [~] Production actions: user-written recipes behind hold-to-confirm; no provider deploy, rollback, or dry-run support
- [ ] Per-component environment inspector
- [ ] User-created dashboards
- [ ] Stripe, WooCommerce direct, analytics, error tracking, deploy providers

### M6: Fit and finish, performance, security review, packaging

- [x] 353 kit tests in 45 suites pass
- [x] Self-test: 35 checks pass
- [x] Lint passes
- [x] 62 snapshots in light and dark, at two sizes
- [x] Discovery performance: 300 repositories in about 1.3 seconds
- [x] App installed at `~/Applications/ForgeDeck.app`
- [x] `scripts/package.sh` makes a signed zip with the hardened runtime
- [x] Security check report in SECURITY_MODEL.md
- [x] User manual, test report, release notes
- [~] Snapshots used the fallback renderer; materials render flat
- [~] Accessibility: labels and traits are in the code; VoiceOver and full keyboard navigation were not walked through
- [ ] Notarization
- [ ] XCUITest target
- [ ] Startup and scroll profiling
- [ ] Auto-update

## Implemented / Partial / Planned

| Area | Status | Notes |
| --- | --- | --- |
| Product registry (products, components, repositories, checkouts, environments) | Implemented | JSON storage, schema 2, migration from 1 |
| Local folder discovery and import review | Implemented | |
| Watched project roots | Planned | Roots are stored; scanning is on demand |
| Local Git state | Implemented | Exercised on real repositories |
| Git compare between stages | Implemented | Uses the local object database only |
| Terminal.app launch | Implemented | Exercised |
| iTerm2 launch | Partial | Cold launch needs a second attempt |
| Ghostty, Warp, Zed launch | Partial | Not installed; not exercised |
| Embedded PTY terminal | Planned | Not built |
| Editor, Finder, link launch | Implemented | |
| AI agent launch | Implemented | Starts the program in the folder; passes nothing |
| Command palette | Implemented | |
| Global hotkey | Planned | Not built |
| Menu bar extra | Implemented | |
| GitHub read (public, no token) | Implemented | Exercised on one repository |
| GitHub read with a token | Partial | Not exercised against a live account |
| GitHub OAuth device flow | Planned | Token paste or `gh auth token` import instead |
| GitLab, Bitbucket | Planned | Not built |
| Evidence model and chain | Implemented | |
| HTTP health and companion status | Implemented | Exercised against the local example server |
| Companion metrics and leads | Partial | Works against the example server; `label` field mismatch; no `/manifest`, `/events`, or signing |
| SSH Doctor and probes | Partial | Exercised to the host-key gate |
| Release file over SSH | Partial | Unit tests only |
| Docker | Partial | Detection exercised; no daemon; logs not surfaced |
| Keychain vault | Implemented | Exercised with real items |
| 1Password references | Partial | `op` not installed |
| Variable scopes and tier blocking | Implemented | Component and Profile scopes not creatable in the UI |
| `forgedeck` CLI | Implemented | No shell completion, no `shell` command |
| `forgedeck exec` | Implemented | Exercised with a real child process |
| Production secret authentication | Partial | Needs a person to exercise |
| MCP adapter | Planned | Not built |
| Action recipes | Implemented | Local, fixed SSH probes, open link |
| Provider deploy, rollback, dry run | Planned | Not built |
| Alerts | Implemented | In-app and menu bar |
| macOS notifications | Planned | Not built |
| Morning Brief | Planned | Not built |
| Leads inbox | Implemented | States new, read, flagged, handled |
| Revenue | Partial | Reported `mrr_cents` only |
| Stripe, WooCommerce direct, Plausible, PostHog, Sentry | Planned | Not built |
| Vercel, Cloudflare, Fly, Railway, Render | Planned | Not built |
| Generic SQL | Planned | Not built |
| Export and import | Implemented | |
| Cloud sync | Planned | Not built |
| Multi-select batch UI | Partial | "Refresh Shown" batch action instead |
| Settings | Partial | No accent picker, update channel, trusted-executables editor, or log viewer |
| Accessibility | Partial | Labels in code; not audited with VoiceOver |
| XCUITest UI tests | Planned | The self-test and snapshots stand in |
| Packaging | Partial | Signed zip; no notarization |
| Auto-update | Planned | Manual rebuild |
| Companion: Node | Implemented | 68 tests |
| Companion: Python | Implemented | 82 tests |
| Companion: WordPress | Partial | 31 tests; never run in a real WordPress; settings page and WooCommerce counts untested |

## Blocker log

| Blocker | Effect | What would clear it |
| --- | --- | --- |
| No Developer ID certificate on this Mac | No notarization. The zip is blocked by Gatekeeper on other Macs | A Developer ID Application identity and a `notarytool` keychain profile in `NOTARY_PROFILE` |
| No Screen Recording permission in this session | Snapshots use the fallback renderer: sidebar vibrancy and sheet materials render flat | Grant Screen Recording to the terminal that runs `tools/snap.sh` and capture again |
| Live credentials not used without consent | GitHub with a token, private repositories, the deployments API, and any real production endpoint were not exercised | The owner connecting a read-only token and pointing a product at a real endpoint |
| Ghostty and Warp not installed | Their launch path is untested | Install them and run the launch check |
| `op` not installed | 1Password references untested | Install and sign in to the 1Password CLI |
| No trusted SSH test host | Probes, authentication failures, and release-file reads untested on a real host | A host already in `known_hosts`, reachable with the agent's key |
| No running Docker daemon | Container list untested live | Start Docker |
| Touch ID needs a person | Production grant path untested with the real prompt | A manual run of a production `exec` |
| No real WordPress site used | Plugin untested in WordPress | A disposable local WordPress |

## Remaining risks

1. **Same-user attacker.** The CLI does not authenticate its caller, `portfolio.json` is not integrity-protected, and the program search path for `exec` includes user-writable folders. Development secrets can be obtained by a same-user process that can run an allowed program in a writable checkout or edit the registry. Details in SECURITY_MODEL.md.
2. **Keychain accessibility attribute.** Items are added without the data-protection keychain flag, so the intended "when unlocked, this device only" class may not apply. Unverified.
3. **Ad hoc rebuilds.** A rebuild with another signature is a different app to the Keychain, so macOS asks again before it may read existing items. How `forgedeck exec` behaves when that prompt cannot be shown was not tested.
4. **Contract drift.** The app and the companion packages disagree on the masked lead field name, and the app cannot talk to a companion that requires signing.
5. **Single-writer assumption.** Two app instances on the same data folder would overwrite each other.
6. **First-of-each chain.** A product with several repositories shows only the first in the evidence chain, which can hide drift in the others.
7. **iTerm2 cold launch.** The app reports "Opened" when Launch Services accepts the request, even if iTerm2 does not open the folder on its first start.
8. **Unverified UI states.** Empty, error, and loading states of most pages were not captured.
9. **Unused model fields.** `trustedExecutables`, `allowedProbeIDs`, `dockerComposeProject`, `eventsEnabled`, and `genericREST` exist but do nothing. A reader of the JSON could assume they are enforced.
10. **Rate limits.** A rate-limited GitHub answer is shown correctly, but polling does not back off.

## Next steps, in priority order

1. Decide the same-user boundary: either sign or MAC `portfolio.json`, restrict `exec` program lookup to system folders plus an explicit per-profile path, or document the current model as final.
2. Use the data-protection keychain (`kSecUseDataProtectionKeychain`) with a keychain access group, and verify the accessibility class.
3. Fix the lead `label` versus `contact` mismatch, and read `/manifest` to check product id and capabilities before trusting a status endpoint.
4. Add `expectedProductID` to the probe sheet.
5. Enforce `allowedProbeIDs`, or remove the field.
6. Get a Developer ID, then notarize with `scripts/package.sh`.
7. Exercise GitHub with a fine-grained read-only token against a private repository, with consent.
8. Exercise SSH probes and a release file against a trusted test host.
9. Make iTerm2 cold launch reliable, or detect the miss and say so.
10. Offer the saved project folders in the Add Product sheet.
11. Honor `retryAfter` in the polling loop.
12. Capture snapshots with Screen Recording permission, and add empty, error, and loading states to the set.
13. Run a VoiceOver and keyboard pass; add an XCUITest smoke test.
14. Show per-repository chains for products with several repositories.
15. macOS notifications for new incidents, with the same one-per-incident rule.
16. Client-side request signing for companions.
17. Remove the unused model fields, or wire them up.
18. Then the larger items: OAuth device flow, an MCP adapter with read-only tools, Stripe as a metrics source, a deploy-provider connector chosen from real use.
