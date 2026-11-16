# ForgeDeck architecture

This document describes the code as it is on 2026-11-15: the targets and folders, how data flows from a connector to a view, the storage files, the concurrency approach, the connector contract, and packaging.
It also records why storage is JSON files and not SwiftData.

## Targets

`Package.swift` (swift-tools-version 6.2, macOS 26) defines three targets. There is no Xcode project.

| Target | Kind | Path | Rule |
| --- | --- | --- | --- |
| `ForgeDeckKit` | library | `Sources/ForgeDeckKit` | Domain, persistence, services, connectors, security, CLI logic. No SwiftUI. Imports Foundation, Security, LocalAuthentication, and AppKit (only in `TerminalLauncher.swift`, for `NSWorkspace`). |
| `ForgeDeck` | executable | `Sources/ForgeDeck` | The app and the CLI entry point. Default actor isolation is `MainActor`. |
| `ForgeDeckKitTests` | test | `Tests/ForgeDeckKitTests` | Swift Testing. Tests the kit only. |

## Folder layout

```text
Sources/ForgeDeckKit/            about 6,700 lines
  Domain/Models.swift            Portfolio, Product, environments, recipes, profiles, variables, settings
  Domain/Evidence.swift          Provenance, snapshots, observations, incidents, ObservationCache
  Persistence/PortfolioStore.swift   StoreLocation, migrator, integrity checker, store, export/import, audit log
  Services/ProcessRunner.swift   ProcessRequest, SystemProcessRunner, ExecutableLocator, ShellQuote
  Services/GitService.swift      snapshot, compare, fetch, clone, RepositoryURL
  Services/ProjectDiscovery.swift    scan, metadata detection, ImportPlanner
  Services/RefreshEngine.swift   CacheUpdate, ObservationCache.apply, RefreshEngine
  Services/DriftAnalyzer.swift   evidence, chain, relations, ProductStatus, PortfolioPulse
  Services/AlertEngine.swift     incident rules, RelativeTime
  Services/ConnectionDoctor.swift    step-by-step diagnosis
  Services/TerminalLauncher.swift    KnownApps, launcher, launch script, AgentPrograms
  Connectors/ConnectorCore.swift ConnectorResult, protocols, URLPolicy, HTTP client, failure mapping, mock client
  Connectors/GitHubConnector.swift   REST reads, ETagCache
  Connectors/RuntimeProbe.swift  HTTP health, companion status, companion metrics and leads, MetricMath
  Connectors/SSHInspector.swift  ssh config parser, fixed probe catalog, release file
  Connectors/DockerInspector.swift   docker ps and bounded logs
  Security/SecretStore.swift     Keychain store, memory store, CredentialResolver, Authorizing
  Security/VariableResolver.swift    scope precedence and tier blocking
  Security/ExecService.swift     exec rules, ExecPlan
  Security/Redactor.swift        token patterns, masking
  CLI/CLI.swift                  the forgedeck commands, ChildProcess, LineBuffer
  Fixtures/DemoFixtures.swift    eight demo products and their fixture cache

Sources/ForgeDeck/               about 7,800 lines
  Main.swift                     entry point: CLI or app, scenes, menus, window chrome
  AppModel.swift                 @Observable state, navigation, refresh, polling
  AppModel+Actions.swift         launching, adding, secrets, GitHub, doctor, recipes, alerts, data
  DesignKit/                     Tokens, Components, Grid, WindowBehavior, KitGallery
  Shell/RootView.swift           sidebar, top bar, environment picker, banners, drop import
  Shell/Overlays.swift           command palette, sheet host, confirmation, doctor, run log, GitHub sheets
  Features/Overview.swift        Overview, product card, activity panel, first run, Projects
  Features/Pages.swift           Deployments, Leads, Infrastructure, Git, Terminals, Secrets, Activity
  Features/ProductPage.swift     product header, Overview and Development tabs
  Features/ProductTabs.swift     Environments, Connections, Secrets, Actions, Activity, Settings tabs
  Features/Sheets.swift          Add Product, variable, probe, metrics source, SSH host, environment, recipe, profile
  Features/SettingsView.swift    Settings tabs and the menu bar popover
  SelfTest.swift                 --selftest checks
  Snapshot.swift                 APP_SNAPSHOT screenshot mode

Tests/ForgeDeckKitTests/         about 6,500 lines, 12 files plus TestSupport.swift
Companions/                      contract, node, python, wordpress (separate test suites)
scripts/                         build, test, acceptance, lint, snapshot, package, doctor
tools/                           selftest, snap, grid-lint, check-layout, icon tools
Icon/AppIcon.icon                Icon Composer source
Info.plist.in                    bundle id com.forgedeck.app, version 0.1
build.sh                         build, sign, install
```

The contract's suggested tree (one folder per feature, `config/sample-projects.json`, separate `DomainTests/`, `UITests/`) was not followed. Features are grouped in a few files, and all tests are in one target.

No SwiftData import or model remains in the app.

## Data flow

```text
connector or service        produces            applied by                   read by
---------------------       ---------           ----------                   -------
GitService.snapshot     ->  CacheUpdate.git
GitHubConnector.snapshot->  CacheUpdate.remote
HTTPProbeConnector      ->  CacheUpdate.probe        ObservationCache.apply      DriftAnalyzer
SSHInspector.release    ->  CacheUpdate.deployment   (one place, main actor)  -> ProductStatus     -> views
CompanionMetrics        ->  CacheUpdate.metrics        records samples           PortfolioPulse
CompanionMetrics.events ->  CacheUpdate.leads          derives activity          MetricMath
GitService.compare      ->  CacheUpdate.comparison     runs AlertEngine
```

Step by step:

1. `AppModel.refresh(_:)` calls `RefreshEngine` methods for one product: `refreshGit`, then (when online) `refreshRemote`, `refreshProbes`, and `refreshMetrics` concurrently, then `refreshComparisons`.
2. Each engine method returns `[CacheUpdate]`. A `CacheUpdate` is a `Sendable` enum value. It carries a `ConnectorResult`, so a failure travels the same path as a success.
3. `AppModel.apply` calls `ObservationCache.apply(_:portfolio:now:)` on the main actor. This is the only place that mutates observations during a refresh. Two refreshes that finish at the same time are applied one after the other.
4. `apply` does more than store:
   - a successful remote snapshot updates `remotes`, derives commit, pull request, and failed-run activity (nothing on the first fetch), and turns GitHub deployment records into Reported `DeploymentObservation`s for environments mapped by name;
   - a failed remote fetch keeps the previous head and records the problem;
   - a probe result appends a health sample (max 90 per probe), records a deployment observation for companion probes, announces a release change once, and calls `AlertEngine.evaluateHealth`;
   - metrics replace the sample for the same source, key, and window, and set one point per day for 24h samples;
   - leads are merged by id; the first sync of a source is quiet, later new events enter the activity feed;
   - at the end `AlertEngine.evaluate` runs the portfolio-wide rules.
5. Views never read a connector. They read `AppModel.portfolio` and `AppModel.cache`, usually through `DriftAnalyzer.chain`, `DriftAnalyzer.evidence`, `ProductStatus.badge`, `ProductStatus.cells`, `PortfolioPulse`, and `MetricMath`. These are pure functions of the portfolio, the cache, and `now`.
6. `AppModel.save()` writes both files, debounced by 300 ms.

Exceptions to "everything goes through the cache": Docker container status (`AppModel.dockerContainers`), SSH probe output (`sshProbeOutput`), Doctor steps (`doctorSteps`), and run logs are held in memory on the model and are not persisted.

The CLI follows the same read path without the app: it loads `portfolio.json` and `cache.json` and calls the same pure functions (`CLI.statusReport`).

## Storage

Default folder: `~/Library/Application Support/ForgeDeck`. `FORGEDECK_HOME` overrides it (`StoreLocation.resolve`). The folder is created with mode 0700.

| File | Content | Format | Writer | Mode |
| --- | --- | --- | --- | --- |
| `portfolio.json` | Definitions: organizations, products, connections, variable metadata, settings | Pretty JSON, sorted keys, ISO 8601 dates, `schemaVersion` | The app only | 0600 |
| `cache.json` | `ObservationCache` | Compact JSON | The app only | 0600 |
| `audit.jsonl` | One `AuditEvent` per line | JSON Lines | App and CLI, `O_APPEND` | 0600 |
| `launch/run-XXXXXXXX.command` | Launch scripts for commands run in a terminal | zsh, mode 0700 | App | Swept after one day |

Writes to the two JSON files are atomic (`Data.write(options: .atomic)`). No file holds a secret value.

### Migration

`PortfolioMigrator.migrate` works on the raw JSON before decoding, one version at a time.

- A document without `schemaVersion` is treated as version 1.
- Version 1 to 2: lifecycle `"retired"` becomes `"archived"`, and each product gains empty `profiles` and `recipes` arrays if missing.
- A document with a version above 2 is refused with `StoreError.newerSchema`. The app then shows an error state and does not save (`AppModel.saveNow` returns early when `loadError` is set), so the file is not overwritten.
- A corrupt `portfolio.json` throws `StoreError.corrupt`. A corrupt `cache.json` loads as an empty cache.

After decoding, `IntegrityChecker.repair` clears dangling references, makes slugs unique, drops variables scoped to a missing product, and removes any plain value on a secret variable. Loading repairs instead of refusing.

`cache.json` has its own `schemaVersion` field (1) but no migrator. A cache that fails to decode is discarded.

### Bounds and retention

| Collection | Bound |
| --- | --- |
| Health samples | 90 per probe |
| Activity events | 600 |
| Lead events | 2,000 |
| Deployment observations | 400 |
| Session records | 200 |
| ETag cache (memory only) | 400 entries |

`ObservationCache.prune` runs at launch and drops activity, leads, points, and resolved incidents older than the retention setting (30, 90, or 365 days; default 90).

### Export and import

`PortfolioExporter.export` writes a `forgedeck-export` document (export version 1): the portfolio without demo products, without bookmarks, with every secret's plain value cleared, and with plain values that look like tokens withheld. It lists credential placeholders by variable key. `validate` migrates and integrity-checks an import; `merge` adds products that are not already present by id or slug.

### Why JSON files and not SwiftData

The contract allowed SwiftData "if it meets migration and background concurrency requirements cleanly". JSON files were chosen for these reasons:

- The CLI and the tests read the same files without launching the app or opening a model container.
- There is one writer for definitions and observations: the app. The CLI only appends audit lines.
- Migration is explicit and testable on raw JSON (`schemaVersion1MigratesToCurrent`, `aNewerSchemaIsRefused`).
- The data is small: a portfolio of tens of products and a bounded cache.
- The files are easy to inspect, back up, and diff.

Costs of this choice: the whole file is rewritten on each save; there is no query engine; and if the app saves while the CLI reads, the CLI sees either the old or the new file (atomic rename), never a partial one. If two copies of the app ran on the same folder, the last save would win. Nothing prevents that.

File bookmarks: each `LocalCheckout` stores a plain (not security-scoped) bookmark made at import. `ImportPlanner.recoverPath` resolves it when a folder is missing. The app is not sandboxed, so security-scoped bookmarks are not needed.

## Concurrency

- The app target sets `.defaultIsolation(MainActor.self)`. `AppModel` is `@Observable` and main-actor isolated. All mutation of `portfolio` and `cache` happens there.
- Kit types are `Sendable` value types. Connectors and services are structs with `async` methods and no shared mutable state.
- The few reference types guard their state: `ETagCache` is an actor; `MockHTTPClient`, `MemorySecretStore`, `MemoryAuditSink`, `CapturedOutput`, `LineBuffer`, and the process output box use `NSLock`.
- `AppModel.refreshAll` runs one task per product in a `TaskGroup`. Inside one product, the GitHub, probe, and metrics reads run as `async let`. A `refreshing` set stops a second refresh of the same product from starting.
- Polling: one long-lived task sleeps for the polling interval (minimum 60 seconds, default 300) and calls `refreshAll` when polling is on. A second task updates `now` every 30 seconds so relative times and staleness re-render.
- Subprocesses: `SystemProcessRunner` wraps `Process` in a checked continuation with a timeout timer, a byte cap, and cancellation that terminates the child. Pipes are drained without blocking after exit, so a grandchild that keeps a pipe open cannot hang the caller.
- Network: `URLSessionHTTPClient` uses an ephemeral session with no cookies and no cache. Nothing blocks the main thread.
- Discovery scans run in `Task.detached` and check `Task.isCancelled` per directory. Two smaller paths call `ProjectDiscovery.inspect` (file reads for one folder) on the main actor: Link Folder and the post-clone import.
- The CLI runs in `Task.detached` and the process calls `dispatchMain()`; SwiftUI is never started.
- Test and snapshot runs (`Runtime.isAutomated`) do not start polling, the network monitor, or the audit log, and use an in-memory secret store unless the self-test asks for the real Keychain.

## The connector contract

Defined in `Connectors/ConnectorCore.swift`.

```swift
public enum ConnectorResult<Value: Sendable>: Sendable {
    case success(Value)
    case partial(Value, missing: [String])
    case failure(ObservationProblem, detail: String, retryAfter: TimeInterval?)
}

public protocol Connector: Sendable {
    static var provider: ProviderKind { get }
    static var capabilities: [ConnectorCapability] { get }
}
public protocol RepositoryProvider: Connector {
    func snapshot(owner: String, name: String, environments: [String]) async -> ConnectorResult<RemoteSnapshot>
}
public protocol RuntimeProbe: Connector {
    func status(_ probe: ProbeConfig, bearer: String?, expectedTier: EnvironmentTier) async -> ProbeOutcome
}
public protocol MetricProvider: Connector {
    func metrics(_ source: MetricSource, productID: UUID, window: String, bearer: String?) async -> ConnectorResult<[MetricSample]>
    func events(_ source: MetricSource, productID: UUID, bearer: String?, maxPages: Int) async -> ConnectorResult<[LeadEvent]>
}
```

Rules a connector follows:

- It never throws for an ordinary provider failure. It returns `.failure` with an `ObservationProblem`: `notConfigured`, `unauthorized`, `forbidden`, `notFound`, `rateLimited`, `unavailable`, `malformed`, `unsupported`, `offline`, `tlsFailure`, `timeout`, `hostKeyUnknown`, `hostKeyChanged`, `cancelled`.
- `HTTPFailure.problem(status:headers:)` and `HTTPFailure.problem(for:)` give one mapping from HTTP statuses and `URLError` codes to problems, with `retryAfter` from `Retry-After` or `X-RateLimit-Reset`.
- It takes an `HTTPClient` or a `ProcessRunning`, so tests script every answer (`MockHTTPClient`, fake runners in `TestSupport.swift`).
- It attaches a `Provenance` to what it returns.
- It validates URLs with `URLPolicy.validate` before any request.

What the contract's suggested protocols became:

| Contract | In the code |
| --- | --- |
| `RepositoryProvider` | Protocol; `GitHubConnector` conforms |
| `DeploymentProvider` | Not a protocol. GitHub deployment records are part of `RemoteSnapshot` and are turned into Reported observations in `ObservationCache.apply` |
| `RuntimeProbe` | Protocol; `HTTPProbeConnector` conforms |
| `MetricProvider` | Protocol; `CompanionMetricsConnector` conforms |
| `LogProvider` | Not a protocol. `DockerInspector.logs` exists and is not called by the app |
| `ConnectionVerifier` | `ConnectionDoctor` (a struct, not a protocol) |
| `CommandExecutor` | `ProcessRunning` plus `TerminalLauncher` and `ExecService` |

`SSHInspector` and `DockerInspector` are plain structs that do not conform to `Connector`. `RefreshEngine` constructs the concrete connectors directly; there is no registry.

### Adding a connector without touching views

1. Write a struct that conforms to one of the capability protocols, taking an `HTTPClient` or `ProcessRunning` in its initializer.
2. Return domain values the cache already knows: `RemoteSnapshot`, `ProbeOutcome`, `DeploymentObservation`, `[MetricSample]`, `[LeadEvent]`.
3. Add a call in `RefreshEngine` that wraps the result in an existing `CacheUpdate` case.
4. Add tests with `MockHTTPClient` for the happy path and each `ObservationProblem`.

Views read the cache, so a new source of the same kind of fact shows up with no view change. This holds for a second runtime probe, a second metrics source, or another source of deployment observations.

Limits of that promise: a provider with a new kind of configuration needs a new field in `Models.swift` and a sheet to edit it. A second repository host needs `RefreshEngine.refreshRemote` to stop filtering on `provider == "github"`, and the chain's "GitHub" stage title is fixed. A new kind of fact needs a new `CacheUpdate` case and a view.

## Evidence and drift

`DriftAnalyzer.evidence(environment:product:cache:now:)` picks the best current evidence for an environment:

1. Take observations with a commit or version, no problem, and deploy state `nil` or `success`.
2. Keep the newest per source.
3. If a failure from the same source is newer than that observation, demote it to at most Stale and carry the failure's problem.
4. Choose the highest level; ties go to the newest.
5. With no good observation, return Unknown with the newest failure's problem, or `notConfigured` when nothing is connected.

`DriftAnalyzer.chain` builds the four stages Local, GitHub, Staging, Production from the first checkout, the first repository, and the staging and production environments. `relations` compares Local to GitHub, GitHub to Production, and Staging to Production. Two equal commits are "In sync". Two different commits use a stored `RevisionComparison` if `git rev-list --left-right --count` could compute one in the local checkout; otherwise the answer is "Not enough history", never a guessed number.

A product with several repositories or checkouts shows only the first of each in the chain. All checkouts are listed in the Development tab and on the Git & CI page.

## Alert rules

`AlertEngine` keeps at most one open incident per rule and subject, so a condition that stays true raises one alert and a recovery is reported once.

| Rule | Opens when | Resolves when |
| --- | --- | --- |
| `healthFailing` | 3 samples in a row fail and none is `offline` | The next sample passes |
| `pipelineBroken` | The newest completed run on the default branch failed | It succeeded |
| `authFailure` | GitHub answered unauthorized for a repository | The next fetch has no problem |
| `deployFailed` | The newest deployment record for a mapped environment is `failure` or `error` | It is `success` |
| `leadIngestStalled` | A metrics source has a problem other than offline and its last success is over an hour before the last attempt | The source answers again |
| `productionDrift` | Staging is measurably ahead of production | They are on the same commit |
| `secretExpiring` | A product-scoped credential expires within 7 days, or its rotation reminder is due | Otherwise |

Demo and archived products raise no alerts. Alerts appear in the app and in the menu bar extra. No macOS user notification is posted.

## Packaging

- `./build.sh` runs `swift build -c release` with the scratch path `~/Library/Developer/ForgeDeck/build`, assembles `~/Applications/ForgeDeck.app` (binary, `Info.plist` from `Info.plist.in` with a timestamp build number, `Assets.car`, `AppIcon.icns`), and signs it with the first Apple Development identity or ad hoc.
- The app binary is also the CLI. `CLI.isInvocation` returns true when the process name is `forgedeck` or the first argument is a CLI command, `--help`, `-h`, or `--version`.
- There is no entitlements file. The app is not sandboxed. `build.sh` does not enable the hardened runtime; `scripts/package.sh` does for non-ad-hoc identities.
- No helper, XPC service, login item, or listener port exists.

See `RELEASE.md` for commands and `SECURITY_MODEL.md` for the trust model.
