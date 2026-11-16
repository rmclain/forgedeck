# ForgeDeck

A native macOS app in SwiftUI for managing a portfolio of software products. It runs on this Mac only.
Storage is JSON files plus the macOS Keychain. There is no server and no SwiftData.
The app binary is also the `forgedeck` command line tool.

## Layout

- `Package.swift` a Swift package with three targets. There is no Xcode project.
- `Sources/ForgeDeckKit/` domain, persistence, services, connectors, security, and CLI logic. No SwiftUI.
  - `Domain/` models and observed evidence. `Persistence/` the store, migration, export, audit log.
  - `Services/` process runner, Git, discovery, refresh engine, drift analysis, alerts, doctor, launcher.
  - `Connectors/` the connector contract, GitHub, HTTP probes and companion metrics, SSH, Docker.
  - `Security/` secret store, variable resolver, exec service, redactor.
  - `CLI/CLI.swift` the `forgedeck` commands. `Fixtures/DemoFixtures.swift` demo products.
- `Sources/ForgeDeck/` the app. Default actor isolation is `MainActor`.
  - `Main.swift` entry point (CLI or app), scenes, menus, window chrome.
  - `AppModel.swift` and `AppModel+Actions.swift` state and everything buttons call.
  - `DesignKit/` tokens, components, grid, window behavior, kit gallery.
  - `Shell/` sidebar, toolbar, palette, sheet host. `Features/` pages, product tabs, sheets, Settings.
  - `SelfTest.swift` and `Snapshot.swift` the self-test and screenshot modes.
- `Tests/ForgeDeckKitTests/` Swift Testing tests for the kit.
- `Companions/` optional endpoint packages (contract, Node, Python, WordPress) with their own tests.
- `build.sh` builds, signs, and installs `~/Applications/ForgeDeck.app`. `scripts/` and `tools/` hold test, lint, snapshot, package, and icon scripts.
- `Icon/AppIcon.icon` the app icon, an Icon Composer file. `build.sh` compiles it with `tools/make_icon.sh`.
- `docs/` implementation records. `design/KIT.md` the design kit spec.

## Build and check

- Build and install: `./build.sh`. Add `--open` to restart the app with the new build, `--link-cli` to link `~/.local/bin/forgedeck`. The build shows warnings; fix them.
- Kit tests: `swift test --scratch-path ~/Library/Developer/ForgeDeck/test-build`.
- Everything: `scripts/test.sh` (kit tests, acceptance walkthroughs, build, self-test, grid lint). `scripts/test.sh --unit` for the kit tests only.
- Acceptance walkthroughs against the local companion server: `scripts/acceptance.sh`. Needs `node`.
- Self-test (the app's real functions on a temporary data folder): `tools/selftest.sh`. Exit 0 when every check passes. It uses real Keychain items and deletes them.
- Lint: `scripts/lint.sh`. It prints `PASS lint`.
- After every UI change, take snapshots with demo data and look at them: `tools/snap.sh`.
  It writes `/tmp/ForgeDeck-shots/<name>-light.png` and `-dark.png` for every page, product tab, sheet, and Settings tab, then quits.
  `APP_SNAPSHOT_PAGES=overview,settings tools/snap.sh` limits the pages. `APP_SNAPSHOT_SIZE=1050x700` sets the window size. `APP_SEED=empty` shows the first-run state.
  For a new page, tab, or sheet, add a `Shot` to `Snapshot.swift`.
- The data folder comes from `FORGEDECK_HOME`. Snapshots and the self-test refuse to run without it. The scripts set it to a folder in `/tmp`.
- Never test against the real data in `~/Library/Application Support/ForgeDeck/`, and never write test secrets to the real vault.
- `APP_KIT_GALLERY=1` shows the design kit instead of the app. `APP_GRID=1` draws the grid and layout probes over the window.
- A change is done when the build has no errors, `swift test` and `tools/selftest.sh` pass, `scripts/lint.sh` passes, and you looked at the light and dark snapshots.

## Architecture rules

- Views never call a connector and never run a process. They call `AppModel`, and they read `AppModel.portfolio` and `AppModel.cache`.
- Connectors and services return `CacheUpdate` values through `RefreshEngine`. `ObservationCache.apply` is the one place that stores them and derives activity and alerts.
- A connector returns a `ConnectorResult` and never throws for an ordinary provider failure. It takes an `HTTPClient` or `ProcessRunning` so tests can script it.
- Every subprocess goes through `ProcessRunning` with an executable URL and an argument array. No shell strings. The two exceptions are the `.command` launch script and the copy-command fallback, both built with `ShellQuote`.
- Secrets only through `SecretStore` and `CredentialResolver`. A secret value is never written to `portfolio.json`, `cache.json`, the audit log, an export, a launch script, or an argument list. Variables hold a `CredentialReference`.
- Every remote fact carries a `Provenance`. Production is never inferred from `main`, a green CI run, or a release tag. With no evidence, show Unknown and the reason.
- Validate every URL with `URLPolicy.validate`. SSH runs only commands from `SSHProbeCommand.catalog`, always with `SSHInspector.options`.
- Demo data stays labeled: `isDemo` on products and `Provenance.isDemo` on observations. Demo products are never refreshed.
- The app is the only writer of `portfolio.json` and `cache.json`. The CLI reads them and appends to `audit.jsonl`.
- A schema change raises `Portfolio.currentSchemaVersion` and adds a step to `PortfolioMigrator` with a test.
- Record user-visible changes and grants with `AppModel.record` or an `AuditSink`. Details hold names, never values.
- Every new story gets a self-test check in `SelfTest.swift` or a kit test. Logic belongs in the kit, where it can be tested.

## Design rules

The look is a custom design kit in `Sources/ForgeDeck/DesignKit`, taken from the design file `ForgeDeck.dc.html`. See `design/KIT.md`.

- Colors come from `Ink` (`Ink.text`, `Ink.panel`, `Ink.accent`, `Ink.prod`, and so on). Use `Ink.tone(_:)` for status colors. Never hard-code a color in a view; `scripts/lint.sh` flags `Color(hex` and `Color(red` outside `DesignKit/`.
- Text uses `.kitType(_:_:)` with a `KitType` role. Tertiary text is `Ink.text3`.
- Icons come from `KitIcon` through `Icon(_:size:weight:)` or `IconButton`. Add a case to `KitIcon` for a new symbol.
- Spacing comes from `Space` (4 pt grid: `xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 20, `xxl` 24, `section` 32). Sizes and radii come from `Metric`. Durations come from `Motion`.
- A number off the grid needs a `// grid: ok <reason>` comment. No `.offset` or `.position`.
- Use the kit's components: `SurfaceCard`, `CardHeader`, `StatusPill`, `TagBadge`, `DemoBadge`, `SourceBadge`, `ConnectionState`, `MetricTile`, `ActionRow`, `ActivityRow`, `EmptyState`, `ErrorState`, `LoadingState`, `InspectorPanel`, `CopyableValue`, `KitField`, `LabeledField`, `SegmentedPill`, `FilterChip`, `EnvironmentPicker`, `SheetPanel`, `ConfirmationSheet`.
- Buttons use `.buttonStyle(.kit(...))`: `primary`, `secondary`, `production`, `ghost`, `icon`, `toolbar`, `link`. One primary button per page, chosen in `TopBar.primaryAction`.
- Window chrome is custom: hidden title bar, a 52 pt top bar, a 236 pt sidebar, sheets drawn inside the window by `SheetHost`. Add a sheet as a `SheetKind` case. The Settings window is the exception: a system `Settings` scene with a grouped `Form` per tab.
- Production is always drawn in `Ink.prod`: the picker, the banner, sheet stripes, palette tags. Remote-write and production actions go through `ConfirmationSheet` with press and hold (`requiresHold: true`). Local confirmations (a local write, a removal, moving to the Trash) are one click with a verb label like Run or Remove.
- Status is words first, color second. Every icon-only control has a `.help` and an accessibility label. Respect reduced motion.
- `CopyableValue` is never used for a secret. Secrets never appear in the palette, tooltips, or accessibility labels.
- Every action has a menu item or a palette command, and the main ones have a keyboard shortcut in `AppCommands`.

## Skills

The bama plugin has a skill for each step: `design-kit`, `layout-grid`, `ux-design`, `swift-swiftui`, `os-integrations`, `performance`, `build-and-verify`, `test-mac-app`, `agent-cli`, `app-icon`, `user-stories`, and `improve-loop`. Use them.

## Git

- Commit after each working change, with a message that says what the user can now do.
