# ForgeDeck acceptance walkthroughs

This document records how each of the build contract's 12 acceptance walkthroughs was executed on 2026-11-15, the result, and what was not covered.
It names the automated test, the self-test check, or the manual command for each.
Caveats are stated exactly. A walkthrough covered by tests is not described as a manual run.

## How the evidence was produced

| Layer | Command | Result today |
| --- | --- | --- |
| Unit tests | `swift test --scratch-path ~/Library/Developer/ForgeDeck/test-build` | 353 tests in 45 suites pass |
| Acceptance walkthroughs | `scripts/acceptance.sh` (sets `FORGEDECK_ACCEPTANCE=1`, needs `node`) | 5 tests in `AcceptanceWalkthroughs` pass |
| Live GitHub read | `FORGEDECK_LIVE_GITHUB=1 swift test ... --filter LiveGitHub` | 1 test passes |
| In-app self-test | `tools/selftest.sh` | `SELFTEST PASS 35 checks` |
| Lint | `scripts/lint.sh` | PASS |
| Snapshots | `tools/snap.sh`, and again with `APP_SNAPSHOT_SIZE=1050x700` | 62 PNGs per run |
| Manual | `forgedeck open`, `forgedeck doctor --ssh` | See walkthroughs 2 and 9 |

The acceptance tests start `Companions/node/example-server.js` on a random local port and talk to it over real HTTP on `127.0.0.1`. They use real temporary Git repositories. GitHub is a scripted `MockHTTPClient` in those tests. Secrets are in a `MemorySecretStore` there; the real Keychain is used by the self-test and by `keychainRoundTrip`.

The self-test runs the installed app binary with `--selftest` on the data folder `/tmp/ForgeDeck-selftest-home`. It calls the same `AppModel` functions the buttons call. It does not click buttons.

## Summary

| # | Walkthrough | Result | Main caveat |
| --- | --- | --- | --- |
| 1 | First use | Pass | "Restart" is a reload from disk inside the self-test, not a quit and relaunch |
| 2 | Local repo | Pass | The terminal was opened with `forgedeck open`; the working directory was read with `lsof`, not by typing `pwd` |
| 3 | Multiple codebases | Pass by tests and demo data | No manual run with four real repositories |
| 4 | GitHub-only | Pass by tests | The UI clone button's folder picker was not driven by automation |
| 5 | Live vs local | Pass | GitHub's answer is scripted; production and local are real |
| 6 | Production unknown | Pass | Same test as 5 |
| 7 | Secrets | Pass | Touch ID was not exercised; the production case tested is denial |
| 8 | Leads | Pass | Verified in the model and cache, not by looking at the sidebar badge |
| 9 | SSH | Partial | Stopped at the host-key gate, as designed. No trusted host was probed |
| 10 | Incidents | Pass | In-app alerts only; no macOS notifications exist |
| 11 | UI | Partial | Fallback-rendered snapshots at two sizes; no large display, no VoiceOver |
| 12 | Release | Partial | Built, installed, packaged; not notarized |

## 1. First use

**Contract:** Launch offline. Add three demo products. The dashboard is elegant, projects remain saved across restart, and fixture values are marked Demo.

**Executed by:**

- Self-test checks: "first launch has no products", "Add 3 Demo Products adds three", "every demo product is marked Demo", "demo evidence comes from fixtures", "adding the demo twice does not duplicate", "products survive a restart", "removing the demo leaves real products".
- Unit tests in `DemoFixtureTests`: `everyDemoProductIsMarkedDemo`, `everyFixtureObservationCarriesDemoProvenance`, `demoChainIsLabelledAsFixture`, `fixturesAreDeterministic`, `installingTwiceAddsNothingTheSecondTime`, `removeClearsDemoProductsAndTheirCachedData`, `refreshEngineNeverContactsAnythingForDemoProducts`.
- Snapshots: `screenshots/overview-light.png`, `screenshots/overview-dark.png`.

**Result:** Pass.

**Caveats:**

- "Survive a restart" is checked by saving and then loading `portfolio.json` again through `PortfolioStore` in the same process. The app was not quit and relaunched by automation.
- Self-test and snapshot runs make no network requests (`Runtime.isAutomated` skips polling and the network monitor). A launch with networking switched off at the system level is not part of the recorded evidence. The offline path itself (Git only, remote facts kept) is in `AppModel.refresh` and is not driven by an automated test.
- The snapshot run seeds all eight demo products, not three.

## 2. Local repo

**Contract:** Add a real local test repo. Open it in Terminal with one click; check `pwd`; return to ForgeDeck and see exact branch and dirty state. Repeat using a path containing spaces and apostrophes.

**Executed by:**

- Self-test, on a real repository created at `/tmp/ForgeDeck-selftest-home/it's a repo dir`: "a local folder imports as one product", "the branch is read from the checkout", "an untracked file shows as uncommitted work", "a detected test command becomes an unapproved suggestion", "scanning again refreshes instead of duplicating", "the launch script quotes the apostrophe".
- Manual: `forgedeck open <product>` opened that repository in Terminal.app. A new zsh process had exactly `/private/tmp/ForgeDeck-selftest-home/it's a repo dir` as its working directory, verified with `lsof`.
- Manual: the same in iTerm2, once iTerm2 was already running.
- Unit tests: `GitSnapshotTests` (`cleanRepository`, `stagedUnstagedAndUntrackedAreCountedSeparately`, `detachedHead`, `mergeConflictIsReported`, `hostilePathCharactersAreJustAPath`, and others), `ShellQuoteTests`, `LaunchScriptTests`, `TerminalLauncherTests`, `CLIOpenTests`.

**Result:** Pass.

**Caveats:**

- The launch was started from the CLI, which calls the same `TerminalLauncher.openFolder` as the app's buttons. A click on the app's "Open Terminal" button was not driven by automation.
- The working directory was read from the process with `lsof`. Nobody typed `pwd`.
- On a cold launch of iTerm2 the folder did not open. A second attempt, with iTerm2 running, did. The app reports "Opened" in both cases because Launch Services accepted the request. This is a known defect in the iTerm2 path.
- The path with spaces and an apostrophe was the only path used. There was no separate first run with a plain path; plain paths are covered by the Git unit tests.
- Ghostty and Warp are not installed and were not tried.

## 3. Multiple codebases

**Contract:** Add one SaaS with a frontend repo, backend repo, WordPress plugin, and optional mobile app. Change each checkout independently, with one product-level dashboard and per-component details.

**Executed by:**

- Unit tests in `ImportPlannerTests`: `twoCheckoutsOfOneRepositoryBecomeOneProduct`, `repositoryThatBelongsToAProductProposesAddCheckout`, `linkedWorktreeFollowsItsMainCheckout`, `rescanProposesRefreshAndIsIdempotent`, `rescanKeepsUserEditedFields`, `slugsStayUniqueAcrossImports`.
- Unit test in `ModelTests`: `oneProductHoldsSeveralRepositoriesAndCheckouts`.
- Metadata detection per stack in `DiscoveryMetadataTests`: `nextJSPackageWithScripts`, `fastAPIProject`, `wordPressPluginHeader`, `swiftPackage`, and others.
- The demo product "Lumen" with four components (Web app, API, Ingest worker, Marketing site), shown in `screenshots/product-overview-light.png` and `screenshots/product-development-light.png`.

**Result:** Pass at the model and planner level.

**Caveats:**

- This was **not** a manual run with four real repositories. No frontend, backend, WordPress plugin, and mobile checkouts were created, linked to one product, and changed one by one in the running app.
- Lumen has four components but one fixture repository and one fixture checkout.
- The product-level evidence chain uses the first checkout and the first repository. Other checkouts appear in the Development tab and the Git & CI page with their own state, but they do not get their own chain.
- Deployment observations can carry a component id, but the UI does not break an environment down by component.

## 4. GitHub-only

**Contract:** Add a GitHub URL with no checkout. See remote status and an explicit `Clone` option. Clone to a user-selected folder without overwriting anything; link to existing product.

**Executed by:**

- Self-test: "a GitHub URL adds a product with no checkout".
- Unit tests in `GitCloneTests`, against a local bare repository: `cloneFromALocalBareRepositoryWorks`, `cloneIntoAnExistingFolderIsRefusedAndLeavesItUntouched`, `anExistingFileAlsoBlocksTheClone`, `invalidOrOptionLookingURLsAreRejectedBeforeGitRuns`, `cloneArgumentsEndOptionParsingBeforeTheURL`, `aFailedCloneReportsARedactedReason`.
- Unit tests in `RepositoryURLTests` and `GitHubConnectorTests` (scripted responses): `snapshotHappyPath`, `forbiddenRunsGiveAPartialResult`, `repositoriesArePagedUntilAShortPage`, and others.
- Live read: `LiveGitHub.aPublicRepositoryReportsItsDefaultBranchHead` read `apple/swift-argument-parser` from the real GitHub API without a token.

**Result:** Pass by tests.

**Caveats:**

- The UI "Clone…" button opens an `NSOpenPanel` folder picker. That picker was not driven by automation, so the button-to-clone-to-linked-checkout path in the running app was not exercised end to end. The pieces it calls (`GitService.clone`, `ProjectDiscovery.inspect`, `ImportPlanner.apply` with `addCheckout`) are each tested.
- No clone from the real GitHub was made. The clone tests use a local bare repository.
- The live test accepts a typed rate-limit failure as a valid outcome, so a pass proves either a successful read or correct rate-limit handling.
- GitHub with a token (private repositories, listing your own repositories, the deployments API) was not exercised against a live account.

## 5. Live vs local

**Contract:** Simulate production reporting SHA A, GitHub `main` reporting SHA B, and local checkout at SHA C with uncommitted work. All three statuses must stay distinct and traceable with evidence and timestamps.

**Executed by:**

- `AcceptanceWalkthroughs.localGitHubAndProductionStayDistinct`: a real Git repository with commits A, B, C and an uncommitted file; the local companion server reporting A as production; a scripted GitHub answer reporting B with a green CI run. The test asserts Local is C and dirty with source "Local checkout", GitHub is B with source "GitHub API", Production is A, Verified, with source "Runtime status endpoint" and an observation time, and that Local is 1 ahead of GitHub and GitHub is 1 ahead of Production.
- Unit tests in `EvidenceTruthTests`: `aNewGitHubHeadDoesNotMoveProduction`, `greenCIWithAFailedDeployOpensAnIncidentAndKeepsTheRunningVersion`, `stagingAndProductionDifferWithoutAMeasuredCount`, `instancesOnTwoRevisionsAreAMixedRollout`, `aRecordAloneIsReportedNotVerified`, `localGitHubAndProductionStayDistinct`.
- `forgedeck status` output for the same model: `CLITests.statusJSONDecodesIntoAStatusReport`, `statusPlainTextShowsEachStageWithItsEvidence`.

**Result:** Pass.

**Caveats:**

- GitHub's side is a `MockHTTPClient`, not the GitHub API.
- The chain was asserted on `DriftAnalyzer.chain`, the function the Development tab renders. The rendered tab was inspected only with demo data in snapshots.

## 6. Production unknown

**Contract:** Remove production runtime permission and deployment record. Show `Unknown` / `Authentication required`, never `In sync`.

**Executed by:**

- The second half of `AcceptanceWalkthroughs.localGitHubAndProductionStayDistinct`: the token variable is removed. With an earlier good observation, production becomes Stale with problem `unauthorized`. With no earlier observation, it is Unknown with problem `unauthorized`, the Production cell reads "Authentication required", the badge is not "Healthy", and no relation is "In sync".
- Unit tests: `noEvidenceIsUnknown`, `onlyAFailureIsUnknownWithItsReason`, `aNewerUnauthorizedFailureDemotesVerifiedToStale`, `inSyncNeedsTheSameCommit`, `badgesNeverSayHealthyWithoutASignal`, `aRevokedTokenAfterAGoodAnswerIsStaleWithTheReason`.
- Snapshot: `screenshots/product-unknown-production-light.png` (demo product Orbit CRM, whose fixture has only a rejected-token failure for production).

**Result:** Pass.

**Caveats:** None beyond those of walkthrough 5.

## 7. Secrets

**Contract:** Save two scoped test tokens in Keychain. `forgedeck exec` with a development-only profile injects its permitted token into a controlled test process. The production token is denied. Neither value appears in app database, action logs, shell arguments, or exported configs. Rotate a token and verify dependent connection behavior.

**Executed by:**

- Self-test with the real Keychain and the real CLI (the app binary started as a child process with `exec`). Checks: "a development secret saves", "a production secret saves", "a production-only secret saves to the Keychain", "each secret is a Keychain item", "forgedeck exec gives the child the development token", "exec names what it granted, not the value", "a development profile cannot be pointed at production", "a production secret is denied in development", "a program the profile does not list is denied", "env list shows names without values", "the audit log records the grant and the denials", "the audit log holds no secret value", "no secret value is in the saved files", "the saved files hold no secret value", "the export holds no secret value", "rotating a secret saves", "the next run receives the rotated value", "deleting the variables removes their Keychain items".
- `AcceptanceWalkthroughs.rotatingATokenChangesTheConnection`: a status endpoint is Verified; the stored token is replaced by one the server does not know and the endpoint becomes Unknown with `unauthorized`; the right token is restored and it is Verified again.
- Unit tests: `ExecServiceTests` and `SecretsNeverPersistedTests` in `SecurityTests.swift`, and `CLIExecTests`. See SECURITY_MODEL.md, "Security check report".

**Result:** Pass.

**Caveats:**

- The controlled test process is `awk`, which prints the length of each variable it received. That proves delivery without printing a value.
- The production case exercised is denial (a development profile forged onto production; a production-only secret asked for in development). A granted production run needs Touch ID or the account password, which needs a person. Tests cover it with a fixed authorizer (`productionWithAuthenticationIsGrantedAndAuditedByNameOnly`).
- "Shell arguments" is checked on the planned argument array and the launch script text (`planArgumentsAndLaunchTextHoldNoSecretValue`). The process table was not inspected with `ps` during the run.
- The Keychain items were created and deleted by the self-test. They were written by a build signed with the Apple Development identity.

## 8. Leads

**Contract:** Use local test API returning 12 new leads, 9 signups and later an additional event. Verify total, last 24-hour window, badge updates, event dedupe, source and freshness. Remove API connectivity; see `Stale` rather than 0.

**Executed by:**

- `AcceptanceWalkthroughs.leadsAreCountedOnceAndGoStaleNotZero` against the local Node example server: 12 leads and 9 signups in the 24h window, source label `example-in-memory`, evidence level Reported; the first sync adds no activity events; after `POST /__test/add-lead` the counter is 13, the stored lead count grows by exactly one, one lead event enters the activity feed, and the 24-hour count grows by one; reading the same pages again changes nothing; after the server is stopped and an hour passes, the counter is still 13, the level is Stale, and the sync state records a problem and the last success.
- Unit tests in `MetricsTests.swift`: `eventsFollowNextCursorAcrossPages`, `aCursorThatRepeatsDoesNotLoopForever`, `aFailedRefreshKeepsTheOldNumbersAsStaleNotZero`, `anOfflineMacDoesNotRaiseAStallIncident`, `countFiltersByKindAndProductAndDedupesByID`, `dailyCountsUseTheCalendarsTimeZone`, `aLateArrivalLandsOnItsOwnDay`, `contactsAreMaskedOnArrival`.

**Result:** Pass.

**Caveats:**

- "Badge updates" was verified on the data the sidebar badge is computed from (new lead events in the cache). The badge on screen was not observed changing.
- The server was really stopped. The hour was simulated by passing a later `now` to `apply` and to `effectiveLevel`.
- The Leads page was inspected with demo data only (`screenshots/leads-light.png`).

## 9. SSH

**Contract:** Link a test SSH config alias. Observe proper host verification and useful diagnostics for unknown host or auth failure. No implicit remote mutation.

**Executed by:**

- Manual: `forgedeck doctor --ssh localhost` reported that the host key is missing from `known_hosts` and refused to continue to authentication.
- Manual: a host name that does not resolve reported the DNS failure.
- Self-test: "an SSH host adds a product with a production environment" (alias `test-host`; nothing is contacted).
- Unit tests in `SSHTests`, with a fake process runner: `argumentsAlwaysCheckHostKeysAndNeverPrompt`, `aChangedHostKeyIsNeverOKAndNeverVerified`, `stderrClassification` (unknown key, changed key, permission denied, DNS, timeout, refused, command not found), `anInvalidAliasNeverReachesSSH`, `theProbeCatalogIsFixed`, `releasePathsAreLimitedToPlainAbsolutePaths`, `aReleaseFileBecomesAVerifiedObservation`, `configParsing`, `resolvedHostAndKnownHostLookup`.
- Lint: no `StrictHostKeyChecking=no` in the sources.

**Result:** Partial. Host verification and the unknown-host and DNS diagnostics were observed for real. Everything past the host-key gate was not.

**Caveats:**

- No host was trusted for the test, so no probe ran on a real host and no real authentication failure was produced. Authentication-failure wording is covered by `stderrClassification` on sample stderr text only.
- Reading a release file over SSH was not run against a real host.
- "No implicit remote mutation" rests on the fixed catalog of five read-only commands plus `cat` on a validated path. The "Connect" button opens an interactive session the user controls.

## 10. Incidents

**Contract:** Simulate three consecutive HTTP health failures then recovery. Create exactly one alert/recovery sequence, not repeated duplicate notifications.

**Executed by:**

- `AcceptanceWalkthroughs.threeFailuresMakeOneAlertAndOneRecovery` against the local example server: after one good check and two failures there is no incident; the third failure opens exactly one; two more failures add nothing; the badge reads "Unhealthy"; after the server is healthy again, two checks leave zero open incidents, still one alert event, exactly one recovery event, and the badge reads "Healthy".
- Unit tests in `HealthAlertTests`: `threeConsecutiveFailuresOpenExactlyOneIncident`, `furtherFailuresAddNothing`, `recoveryResolvesTheIncidentAndIsReportedOnce`, `aSecondOutageIsItsOwnIncident`, `twoFailuresThenASuccessOpenNothing`, `anOfflineMacOpensNoIncident`, `eachProbeHasItsOwnIncident`, `acknowledgeAndSnoozeChangeNeedsAttention`.

**Result:** Pass.

**Caveats:**

- "Notifications" here means in-app alerts and activity events. The app posts no macOS user notifications.
- Health was switched with the example server's test control. The checks were triggered by calling the refresh engine in a loop, not by waiting for the polling timer.

## 11. UI

**Contract:** Inspect every required screen in light and dark, smallest supported window and large Mac display. Fix clipping, contrast, disabled states, confusing labels, and fake interactivity.

**Executed by:**

- `tools/snap.sh`: 62 PNGs, light and dark, of every sidebar page, all nine product tabs, the unknown-production product, the production context, the command palette, the Add Product, variable, and confirmation sheets, the toast, and the five Settings tabs. Default window size 1440×900.
- The same again at 1050×700 with `APP_SNAPSHOT_SIZE=1050x700`.
- `scripts/lint.sh`: grid lint PASS (spacing on the 4 pt grid), no raw colors outside the design kit.
- Provisions in the code for contrast and narrow windows: tertiary text is raised above the design's value so 11 pt labels reach 4.5:1; the toolbar and the product header each have a compact variant chosen with `ViewThatFits`; the Overview and the product Overview stack their columns when narrow.

**Result:** Partial.

**Caveats:**

- This session had no Screen Recording permission. Captures used the template's fallback renderer (`cacheDisplay`), so the sidebar vibrancy material renders flat and sheet materials are not true to life. Colors of solid surfaces, text, and layout are as drawn.
- Inspected at 1440×900 and 1050×700 only. Not inspected on a large external display or in full screen.
- The code's minimum window size is 1000×640 (`Main.swift`). The smallest size captured was 1050×700.
- VoiceOver was not run. Accessibility labels, hints, and traits are in the code (status pills, evidence badges, tiles, the hold-to-confirm "Confirm" action), but nobody listened to them.
- Keyboard navigation was not walked through beyond the shortcuts and the palette's arrow keys. The app calls `focusEffectDisabled()` on the main window, so focus rings are not shown there.
- Populated states were captured for every screen. Empty, loading, and error states exist as components and in the first-run view, but are not in the 62-file set.
- No XCUITest target exists. The self-test and snapshots stand in for UI tests.
- The Infrastructure SSH and Docker tabs are not in the snapshot set (Health and Connections are).

## 12. Release

**Contract:** Run the documented build/test commands from a clean checkout; install and open the `.app`; provide a reproducible release build process and a candid feature/completion matrix.

**Executed by:**

- `./build.sh`: release build, signed with the Apple Development identity, installed at `~/Applications/ForgeDeck.app`.
- `swift test`, `scripts/acceptance.sh`, `tools/selftest.sh`, `scripts/lint.sh`: results in the table at the top.
- `scripts/package.sh`: `dist/ForgeDeck-0.1.zip` exists. The script signs with the hardened runtime for a real identity and prints "notarized: no" when there is no Developer ID identity and `NOTARY_PROFILE`.
- Companion suites: Node 68 pass, Python 82 pass, WordPress PHP 31 pass.
- The feature and completion matrix is in ROADMAP.md.

**Result:** Partial.

**Caveats:**

- Not notarized. This Mac has an Apple Development identity and no Developer ID. The zip runs on this Mac; Gatekeeper on another Mac will block it.
- The commands were run in the working tree. A build from a fresh clone on another machine was not done.
- The self-test launches the installed app and passes, which shows the bundle starts. Opening the app by hand and using it is not recorded here beyond the manual commands in walkthroughs 2 and 9.
- `build.sh` does not enable the hardened runtime. `scripts/package.sh` does.
