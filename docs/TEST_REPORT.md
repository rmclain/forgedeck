# ForgeDeck test report

This report lists the test commands, the counts from 2026-11-15, what each layer covers, the bugs the tests found, and what is not covered.
Machine: macOS 27.0.1, Xcode 27.2, Swift 6.4.2.

## Results

| Layer | Command | Result |
| --- | --- | --- |
| Kit tests | `swift test --scratch-path ~/Library/Developer/ForgeDeck/test-build` | 353 tests in 45 suites pass |
| Acceptance walkthroughs | `scripts/acceptance.sh` | 5 pass (part of the 353 when `FORGEDECK_ACCEPTANCE=1`) |
| Live GitHub read | `FORGEDECK_LIVE_GITHUB=1 swift test --scratch-path ~/Library/Developer/ForgeDeck/test-build --filter LiveGitHub` | 1 pass (part of the 353 when the variable is set) |
| In-app self-test | `tools/selftest.sh` | `SELFTEST PASS 35 checks` |
| Lint | `scripts/lint.sh` | PASS |
| Snapshots | `tools/snap.sh` | 62 PNGs |
| Companion: Node | `cd Companions/node && npm test` | 68 pass |
| Companion: Python | `cd Companions/python && .venv/bin/python -m pytest` | 82 pass |
| Companion: WordPress | `cd Companions/wordpress/forgedeck-companion && php tests/run-tests.php && php tests/run-rest-tests.php` | 31 pass |

The 353 break down as 346 unit tests, 5 acceptance walkthroughs, 1 live public GitHub read, and 1 discovery performance test. Without the two environment variables, the 6 gated tests are skipped by their suite condition.

A parameterized test counts once, whatever its number of arguments.

## One command

`scripts/test.sh` runs, in order: the kit tests, `scripts/acceptance.sh`, `./build.sh` followed by `tools/selftest.sh`, and `tools/grid-lint.sh`. `scripts/test.sh --unit` runs the kit tests only.

It does not run the live GitHub test, the full `scripts/lint.sh` (only the grid part), the snapshots, or the companion suites.

## Kit tests by file

All in `Tests/ForgeDeckKitTests`, written with Swift Testing. `TestSupport.swift` holds helpers: temporary folders, a `TestRepo` that drives real `git`, a scripted process runner, and a mock app opener.

| File | Suites | Tests | Covers |
| --- | --- | --- | --- |
| `DomainTests.swift` | `ModelTests`, `ImportPlannerTests`, `VariableResolverTests`, `DemoFixtureTests` | 36 | Slugs, monograms, lookups, evidence ordering, provenance expiry; import planning, merge, idempotent re-scan; scope precedence, tier blocking, allowlists; demo labeling and determinism |
| `PersistenceTests.swift` | `PortfolioStoreTests`, `IntegrityTests`, `CacheMaintenanceTests`, `AuditLogTests` | 25 | Round trips, file modes, migration v1 to v2, newer-schema refusal, corrupt files; integrity problems and repair; pruning and bounds; audit append, read, redaction |
| `GitServiceTests.swift` | `GitSnapshotTests`, `GitCompareTests`, `GitCloneTests`, `RepositoryURLTests` | 31 | Real repositories: clean, staged, unstaged, untracked, conflicts, detached HEAD, stashes, worktrees, shallow clones, missing folders, hostile paths; compare results; clone refusal and success against a local bare repository; URL parsing |
| `DiscoveryTests.swift` | `DiscoveryScanTests`, `DiscoverySecretTests`, `DiscoveryMetadataTests` | 24 | Skipped folders, symlink loops, limits, cancellation; secret-file refusal, remote URL redaction; stack and command detection per ecosystem |
| `EvidenceTests.swift` | `EvidenceTruthTests`, `RemoteCacheTests`, `RuntimeProbeFlowTests`, `StatusPresentationTests` | 26 | Fake-green scenarios, Reported versus Verified, Stale and Unknown, mixed rollouts; remote fetch failures; probe results becoming evidence; badges and headline |
| `ConnectorTests.swift` | `GitHubConnectorTests`, `HTTPFailureTests`, `URLPolicyTests`, `HTTPProbeTests`, `SSHTests`, `DockerTests` | 64 | Scripted HTTP for GitHub (statuses, rate limits, paging, ETags, partial results); URL policy; health and companion status parsing and rejection; SSH arguments, classification, catalog, release files, config parsing; Docker parsing and failures |
| `MetricsTests.swift` | `MetricsConnectorTests`, `MetricsCacheTests`, `MetricMathTests` | 25 | Metrics parsing, windows, paging, repeating cursors, malformed events, masking; stale-not-zero; daily counts, time zones, late arrivals, dedupe |
| `AlertTests.swift` | `HealthAlertTests`, `PortfolioAlertTests` | 14 | Three-failure rule, one incident and one recovery, offline, per-probe incidents, acknowledge and snooze; pipeline, credential, and auth alerts; no alerts for demo or archived products |
| `SecurityTests.swift` | `SecretsNeverPersistedTests`, `PortfolioExporterTests`, `ExecServiceTests`, `RedactorTests`, `SecretStoreTests` | 52 | No secret in portfolio, cache, export, audit, arguments, launch text, agent context; export and import; every exec rule; redaction patterns; memory and real Keychain round trips; credential origins |
| `LauncherTests.swift` | `ShellQuoteTests`, `LaunchScriptTests`, `TerminalLauncherTests` | 18 | Quoting of hostile names, generated scripts run by a real shell, launch outcomes with a mock opener, script sweep, link scheme check |
| `CLITests.swift` | `CLIBasicsTests`, `CLIReadCommandTests`, `CLIExecTests`, `CLIOpenTests` | 31 | Help, version, usage errors, invocation detection; list, status, env, actions, context output in text and JSON; exec grants, denials, forged flags; open |
| `AcceptanceTests.swift` | `AcceptanceWalkthroughs`, `LiveGitHub`, `DiscoveryPerformance` | 7 | See below |

### Acceptance walkthroughs

Gated by `FORGEDECK_ACCEPTANCE=1`, serialized, and need `node`. Each starts `Companions/node/example-server.js` on a random local port and uses real HTTP.

| Test | Walkthrough |
| --- | --- |
| `leadsAreCountedOnceAndGoStaleNotZero` | 8 |
| `threeFailuresMakeOneAlertAndOneRecovery` | 10 |
| `localGitHubAndProductionStayDistinct` | 5 and 6 |
| `rotatingATokenChangesTheConnection` | 7, last part |
| `aStagingBuildIsNotRecordedAsProduction` | The environment guard |

### Live and performance

- `LiveGitHub.aPublicRepositoryReportsItsDefaultBranchHead` reads `apple/swift-argument-parser` from the real GitHub API with no token. It also passes when GitHub answers with a rate limit, because that is a typed outcome.
- `DiscoveryPerformance.threeHundredRepositoriesScanQuickly` builds 300 fake repositories, each with a `node_modules` tree, and requires the scan to finish in under 5 seconds and the planner in under 2. Measured today: about 1.3 seconds for the scan.

## In-app self-test

`tools/selftest.sh` starts the installed binary with `--selftest` and `FORGEDECK_HOME=/tmp/ForgeDeck-selftest-home`. The self-test refuses to run unless `FORGEDECK_HOME` is set. It exercises `AppModel`, the functions the buttons call, and prints `PASS` or `FAIL` per check, then `SELFTEST PASS 35 checks`.

With `APP_SELFTEST_KEYCHAIN=1` (the script's default) it uses the real Keychain and starts the same binary as `forgedeck exec` in a child process.

| Group | Checks |
| --- | --- |
| Demo and persistence | 6 |
| Local import of a repository at `it's a repo dir` | 6 |
| GitHub URL and SSH host products | 2 |
| Scoped secrets saved, not in files, resolved, not in the export | 5 |
| Real Keychain and real `exec`: items exist, development token delivered, names not values on stderr, production denied, blocked secret denied, unlisted program denied, `env list` without values, audit has grant and denials and no value, files have no value, rotation picked up, items deleted | 14 |
| Palette lists no secret; demo removal | 2 |

The self-test does not click anything and does not look at pixels.

## Lint

`scripts/lint.sh` checks:

- `tools/grid-lint.sh`: paddings, spacings, sizes, and corner radii in `Sources` are 0, 1, 2, or a multiple of 4, or carry a `// grid: ok <reason>` comment; no `.offset(` or `.position(`. Token files are skipped.
- No `Color(hex` or `Color(red` in the app outside `DesignKit/`.
- No `"sh", "-c"`, `/bin/sh`, `/bin/bash`, or `sh -c` in `Sources` (the self-test file is excluded, because it passes `sh -c env` as an argument that must be denied).
- No `StrictHostKeyChecking=no` in `Sources`.

`tools/check-layout.swift` can check the `*-layout.json` probe files that a snapshot run writes. It is not part of `scripts/lint.sh`.

## Snapshots

`tools/snap.sh` starts the app with `APP_SNAPSHOT`, a fresh data folder, and the eight demo products plus sample variables, recipes, and a profile. It writes one PNG per page and mode: 26 main-window shots and 5 Settings tabs, each in light and dark, 62 files.

This session had no Screen Recording permission, so `screencapture` failed and the fallback renderer was used. Materials (sidebar vibrancy, sheet backgrounds) render flat in these files.

`scripts/snapshot.sh` runs three passes: default size, 1050×700, and an empty-data pass over seven pages. Its header comment says the output goes to `docs/screenshots-raw`; the script writes to `/tmp/ForgeDeck-shots`, `/tmp/ForgeDeck-shots-compact`, and `/tmp/ForgeDeck-shots-empty`.

## Manual checks

| Check | Result |
| --- | --- |
| `forgedeck open` on a repository at `/private/tmp/ForgeDeck-selftest-home/it's a repo dir`, Terminal.app | A new zsh process had exactly that working directory (`lsof`) |
| The same with iTerm2 | Worked once iTerm2 was running. The first cold launch did not open the folder |
| `forgedeck doctor --ssh localhost` | Reported the host key missing from `known_hosts` and did not continue |
| `forgedeck doctor --ssh` with a host that does not resolve | Reported the DNS failure |
| Permission prompts | None. No feature requests Automation, Accessibility, or Full Disk Access |

## Bugs found by the tests and fixed

Nine in the kit:

| # | Bug | Guard now |
| --- | --- | --- |
| 1 | `exec` allowlist could be bypassed by giving a path whose last component matched an allowed name | The program must be a bare name: `aLookalikeProgramAtAnotherPathIsDenied`, `programsOutsideTheAllowlistAreDenied` |
| 2 | The caller's `PATH` chose which binary an allowed name resolved to | Lookup ignores the caller's environment: `theCallersPathDoesNotChooseTheBinary` |
| 3 | CLI name check was too loose when deciding between CLI and app mode | Exact name or a known command: `invocationDetection`, `launchingTheAppBinaryIsNotACLICall` |
| 4 | The GitHub auth alert used one shared subject, so one product's success resolved another's failure | Subject is the repository id: `anAuthFailureOnOneProductIsNotResolvedByAnother` |
| 5 | An export made while demo products had variables contained variables scoped to products that were left out | Those variables are dropped: `anExportMadeWhileDemoProductsHaveVariablesCanBeImported` |
| 6 | Any host starting with `127.` counted as loopback, so `http://127.evil.example` was allowed | Literal four-octet address only: `aHostNameThatStartsWith127IsNotLoopback` |
| 7 | An empty slug matched a product | `emptySlugMatchesNoProduct` |
| 8 | A repository URL ending in `.git/` kept the suffix | `dotGitFollowedByASlashIsStillStripped` |
| 9 | An owner starting with a dash was accepted and could be read as an option | `aLeadingDashIsNeverAnOwner` |

Three more outside that list:

| Bug | Fix |
| --- | --- |
| `SystemProcessRunner` could hang when a child left a background process holding the output pipe open | After the child exits, the pipes are drained without blocking (`SystemProcessRunner.drain`) |
| The `exec` output redactor spun at end of file | The readability handler removes itself when it reads empty data (`ChildProcess.run`) |
| A SwiftUI invalidation loop in the menu bar extra's `isInserted` binding | The setter returns early when the value is unchanged (`Main.swift`) |

The mapping from each kit bug to a test is by test name and subject.

## Not covered

- **UI automation.** There is no XCUITest target. No test clicks a button, types in a field, or drives an open or save panel. The clone button, Link Folder, Export, Import, and Add Folder paths through panels are untested end to end.
- **Pixels.** Snapshots are produced for a person to look at. Nothing compares them or scans them for secrets.
- **Accessibility.** No VoiceOver run, no automated accessibility audit.
- **Live services.** GitHub with a token, private repositories, the deployments API on a real repository, a real status endpoint over public HTTPS, a real TLS failure, a real redirect.
- **SSH past the host-key gate.** Probes, authentication failures, and release-file reads on a real host.
- **Docker with a running daemon.**
- **1Password CLI.**
- **Touch ID.** The production grant path runs with a fixed authorizer in tests.
- **Ghostty, Warp, Zed.**
- **The app target's own logic** beyond what the self-test calls. `AppModel` has no unit tests; the test target depends on the kit only.
- **Offline behavior of the app** (the network monitor and the Git-only refresh path).
- **Polling over time.** The loop and its interval are not tested.
- **Two processes.** The CLI reading while the app writes; two app instances.
- **Performance** beyond discovery: startup time, scrolling, memory, and refresh with many products were not profiled.
- **Larger and smaller windows** than 1440×900 and 1050×700.
- **The WordPress plugin inside WordPress**, its settings page, and WooCommerce counts.
- **Notarized build on another Mac.**
