# ForgeDeck design kit

This is the spec of the design kit as it exists in `Sources/ForgeDeck/DesignKit/Tokens.swift` and `Components.swift` on 2026-11-15.
It lists the tokens with their light and dark values as written in the code, the type roles, metrics, icon rules, and each component with its purpose and states.
The kit follows the Claude Design file `ForgeDeck.dc.html`. Deviations from that file are listed at the end.

## Feel

**Quiet. Dense. Honest.**

- Quiet: neutral surfaces, hairline borders, one teal accent, soft shadows. Production is the only loud color, and only where an action could reach a live system.
- Dense: 11 to 13 pt text, 28 pt controls and rows, 12 pt card radius. Large type only for the page title (22 pt) and metric values (25 pt).
- Honest: a status is a word first and a color second. Unknown and Stale have their own look. Sample data carries a Demo badge.

## Layers

`Tokens.swift` has three layers. Views read layers 2 and 3 only.

| Layer | Type | Holds |
| --- | --- | --- |
| 1 | `Palette` (private) | Raw values: hex colors, an OKLCH to sRGB converter, a light/dark dynamic color helper |
| 2 | `Ink` | Named colors with a meaning, each with a light and a dark value |
| 3 | `KitType`, `Metric`, `Motion`, `Space`, `KitIcon` | Scales: type, sizes, durations, spacing, icons |

`scripts/lint.sh` fails when a view outside `DesignKit/` uses `Color(hex` or `Color(red`.

## Color tokens (`Ink`)

`ink` is `#1D1D1F`. `snow` is `#F2F2F4`. A percentage is an alpha on that color. OKLCH values are lightness, chroma, hue, converted to sRGB by `Palette.oklch`.

### Surfaces

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `window` | `#FBFBFC` | `#1C1C1E` | Content background |
| `sidebarTint` | `#EAECEF` at 60% | `#2A2A2E` at 50% | Tint over the sidebar vibrancy material |
| `toolbar` | `#FBFBFC` at 92% | `#1E1E20` at 92% | Top bar |
| `panel` | white | `#242427` | Cards, selected segment, list wells |
| `panel2` | `#F5F5F7` | `#2B2B2F` | Palette footer, empty-state tile gradient end |
| `popover` | `#FBFBFD` at 90% | `#26262A` at 90% | Sheets and the palette, over a popover material |
| `scrim` | `#18181C` at 16% | black at 38% | Behind sheets and the palette |
| `toast` | ink | snow | Toast background (inverted) |

### Controls and lines

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `field` | black at 5% | white at 7% | Text fields, segmented control track |
| `chip` | black at 4.5% | white at 7% | Chips, muted badges, muted icon tiles, skeletons |
| `button` | white | white at 8% | Secondary and icon button fill |
| `buttonLine` | black at 11% | white at 9% | Secondary button border |
| `line` | black at 7.5% | white at 8% | Card borders, dividers |
| `line2` | black at 5% | white at 5% | Lighter dividers inside cards |
| `lineStrong` | black at 15% | white at 17% | Hovered borders, sheet outline |
| `hover` | black at 4% | white at 5% | Row and ghost button hover |
| `selection` | black at 7.5% | white at 9% | Selected row, selected filter chip |
| `shadow` | black at 5% | black at 30% | Card and button shadow |
| `shadowLarge` | black at 10% | black at 40% | Lifted card, empty-state tile |

### Text

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `text` | ink | snow | Primary text |
| `text2` | ink at 68% | snow at 70% | Secondary text |
| `text3` | ink at 58% | snow at 56% | Tertiary text, labels, placeholders, muted tone |
| `onAccent` | white | `#04201C` | Text on an accent fill |
| `onProd` | white | `#1E0A02` | Text on a production fill |
| `onToast` | white | ink | Text on a toast |

### Accent and status

| Token | Light (OKLCH) | Dark (OKLCH) | Use |
| --- | --- | --- | --- |
| `accent` | 0.57, 0.11, 178 | 0.76, 0.12, 175 | Primary button fill, selected tab underline, tint |
| `accentText` | 0.47, 0.10, 178 | 0.80, 0.12, 175 | Accent-colored text and icons on a plain surface |
| `ok` | 0.52, 0.14, 155 | 0.75, 0.15, 155 | Healthy, verified, passed |
| `warn` | 0.56, 0.13, 68 | 0.80, 0.14, 75 | Stale, degraded, uncommitted, needs sign-in |
| `err` | 0.55, 0.20, 25 | 0.72, 0.18, 25 | Failing, conflicted, denied |
| `prod` | 0.56, 0.19, 36 | 0.70, 0.17, 40 | Production: picker, banner, stripes, confirm button, tags |

### Gradients

| Token | Value | Use |
| --- | --- | --- |
| `iconGradient(hue:)` | OKLCH 0.72, 0.12, hue to OKLCH 0.48, 0.13, hue + 32 | Product icon, top leading to bottom trailing |
| `brandGradient` | OKLCH 0.72, 0.12, 175 to OKLCH 0.45, 0.10, 200 | Workspace tile in the sidebar |

### Tones

`Tone` is defined in the kit library (`ok`, `warn`, `err`, `accent`, `muted`, `prod`). `Ink.tone(_:)` maps it to a color:

| Tone | Color |
| --- | --- |
| `ok` | `Ink.ok` |
| `warn` | `Ink.warn` |
| `err` | `Ink.err` |
| `accent` | `Ink.accentText` |
| `muted` | `Ink.text3` |
| `prod` | `Ink.prod` |

`Color.soft(_ amount: Double = 0.13)` is the tone at low opacity, used as the fill behind a toned label or icon.

## Type roles (`KitType`)

All roles use the system font. Apply with `.kitType(role, color)`; the default color is `Ink.text`.

| Role | Size | Weight | Design | Tracking | Use |
| --- | --- | --- | --- | --- | --- |
| `pageTitle`, `productTitle` | 22 | semibold | default | -0.4 | Page and product titles |
| `cardTitle` | 15 | semibold | default | 0 | Sheet titles, section titles on a page |
| `section` | 13 | semibold | default | 0 | Card headers, toolbar title |
| `body` | 13 | regular | default | 0 | Body text, sidebar rows |
| `bodyMedium` | 13 | medium | default | 0 | Selected sidebar row, tab labels |
| `bodyStrong` | 14 | semibold | default | 0 | Product card name |
| `label` | 12 | regular | default | 0 | Row values, hints |
| `labelMedium` | 12 | medium | default | 0 | Row titles, field labels, segmented options |
| `labelStrong` | 12 | semibold | default | 0 | Banner titles |
| `meta` | 11 | regular | default | 0 | Captions, timestamps, keyboard hints |
| `metaMedium` | 11 | medium | default | 0 | Status pill text |
| `metaStrong` | 11 | semibold | default | 0 | Counts, deltas |
| `metric` | 25 | semibold | default | -0.6 | Metric tile value |
| `metricSmall` | 17 | semibold | default | 0 | Smaller figures |
| `mono` | 12 | regular | monospaced | 0 | Paths, commands, variable names |
| `monoSmall` | 11 | regular | monospaced | 0 | Commits, URLs, copyable values |
| `monoTitle` | 17 | semibold | monospaced | 0 | Large commit or version |
| `badge` | 10 | bold | default | 0.4 | Uppercase tags |
| `paletteInput` | 16 | regular | default | 0 | Palette search field |
| `paletteRow` | 13.5 | regular | default | 0 | Palette rows |

A few views set a font size directly where the design has an in-between size (10.5, 11.5, 12.5 pt). These are the button label, toast text, sheet message, and small counters.

## Spacing (`Space`)

Defined in `Grid.swift`. Everything sits on a 4 pt grid.

| Token | Points |
| --- | --- |
| `xs` | 4 |
| `sm` | 8 |
| `md` | 12 |
| `lg` | 16 |
| `xl` | 20 |
| `xxl` | 24 |
| `section` | 32 |
| `margin` | 20 |

Rules, checked by `tools/grid-lint.sh`:

- Paddings, spacings, widths, heights, and corner radii are 0, 1, 2, or a multiple of 4.
- A value off the grid needs a comment on the same line: `// grid: ok <reason>`. The kit uses this for sizes taken from the design, such as 5, 6, and 7 pt insets on pills and chips.
- No `.offset(` and no `.position(`.
- `.gridArea(name, inset:)` and `.gridProbe(name, area:)` mark views for the layout checker. `APP_GRID=1` draws the grid and the probes.

## Metrics (`Metric`)

| Token | Points | Use |
| --- | --- | --- |
| `sidebarWidth` | 236 | Sidebar |
| `toolbarHeight` | 52 | Top bar, and the drag strip above the sidebar |
| `rowHeight` | 28 | Sidebar and list rows |
| `controlHeight` | 28 | Fields |
| `buttonHeight` | 28 | Buttons |
| `cardRadius` | 12 | Cards |
| `controlRadius` | 7 | Buttons, fields, segmented track |
| `chipRadius` | 5 | Chips, pills, selected segment |
| `rowRadius` | 6 | Rows, icon and toolbar buttons |
| `tileRadius` | 8 | Icon tiles, list wells, palette rows |
| `sheetRadius` | 14 | Sheets and the palette |
| `iconButtonWidth` | 30 | Icon and toolbar buttons |
| `pagePadding` | 28 | Horizontal page margin |
| `activityWidth` | 340 | Activity panel on the Overview |
| `hairline` | 1 | Borders and dividers |

Window: default size 1440 by 900, minimum 1000 by 640 (`Main.swift`). Compact button height is 24, icon button height 26.

## Motion (`Motion`)

| Token | Curve | Duration | Use |
| --- | --- | --- | --- |
| `hover` | ease out | 0.12 s | Hover fills, card lift |
| `select` | ease out | 0.15 s | Selection changes |
| `pop` | ease out | 0.18 s | Overlays |
| `toast` | ease out | 0.22 s | Toast in and out |

`SurfaceCard` and `LoadingState` read `accessibilityReduceMotion`: the card lift is not animated and the skeleton does not pulse when it is on.

## Icons (`KitIcon`)

- Every icon is a case of `KitIcon`, whose raw value is an SF Symbol name. A view never writes a symbol name for a kit icon; it writes `Icon(.terminal)` or `IconButton(.terminal, label: ...)`.
- `Icon` defaults to 14 pt, regular weight, and is hidden from accessibility. The label belongs to the control around it.
- Sizes in use: 9 to 10 pt inside badges and strips, 12 to 13 pt in buttons, 14 pt in the sidebar, 15 pt in the toolbar, 16 to 18 pt in sheet headers and the palette, 26 pt in an empty state.
- An icon-only control always has a `.help` text and an accessibility label (`IconButton` requires `label`).
- A toned icon sits in a `ToneIcon` tile: a rounded square filled with the tone at 14% (or `Ink.chip` for muted).
- A few status glyphs are written as raw symbols inside components: `checkmark.seal.fill`, `doc.text`, `clock`, `questionmark.circle` in `SourceBadge`; `checkmark`, `exclamationmark`, `xmark`, `minus` in `DoctorStepRow`, the confirmation checks, and the toast. The menu bar icon is `hammer` or `hammer.fill`.

The set (55 cases): overview, projects, deploy, infra, secrets, activity, settings, terminal, code, external, laptop, branch, globe, lead, purchase, alert, error, key, check, play, chart, link, shield, touchID, search, bolt, bell, plus, chevronRight, chevronLeft, chevronUpDown, sync, star, starFill, finder, copy, eye, eyeSlash, trash, clock, pullRequest, commit, docker, leads, stethoscope, sparkle, question, wifiOff, archive, pencil, more, download, info, hammer, xmark.

## Components

Defined in `DesignKit/Components.swift` unless a file is named.

### Surfaces

**`SurfaceCard`**. The standard card. Panel fill, hairline border, 12 pt radius, soft shadow, 16 pt padding by default.
States: rest; with `lifts: true`, hover gives a stronger border and a larger shadow.

**`.card()`**. The same look as a modifier, for containers that manage their own padding.

**`.hairlineBelow()`, `.hairlineAbove()`**. One-point dividers on an edge.

**`CardHeader`**. Title (`section`), optional subtitle (`meta`), optional trailing content.

**`InspectorPanel`**. A titled card with a divider under the header, for details beside or below a list.

**`VisualEffect`**. An `NSVisualEffectView` wrapper for the sidebar and popover materials.

### Labels and badges

**`Dot`**. A small filled circle, 6 pt by default. Decorative: hidden from accessibility.

**`StatusPill`**. A status in words with a colored dot on a soft fill. Built from a label and a `Tone`, or from a `StatusBadge`.
States: regular and `large`. VoiceOver reads "Status: <label>".

**`TagBadge`**. A small uppercase label such as PROD or DEMO.
States: muted (chip fill), toned (soft fill), `filled` (solid accent or production fill).

**`DemoBadge`**. `TagBadge("Demo")` with a tooltip that says the data comes from a fixture. Shown wherever a demo value appears.

**`Chip`**. A neutral label on a chip fill, for stack names and counts.

**`Kbd`**. A keyboard hint in `meta` text. Hidden from accessibility.

**`SourceBadge`**. How strong the evidence is, with an icon and the level name.
States: Verified (ok, seal), Reported (accent, document), Stale (warn, clock), Unknown (muted, question mark). Optional Demo badge. The tooltip and the accessibility hint explain the level, the source, and when it was seen.

**`ConnectionState`**. A connection's state as a dot and words.
States: Connected, Authentication required, Offline, Not connected, Failing, Checking…, Stale. `kind(for:)` maps an `ObservationProblem` to a state.

### Product identity

**`ProjectIcon`**. A rounded square with a hue gradient and a monogram. Sizes from 16 to 56 pt; below 20 pt it shows one letter. Decorative.

**`SyncStrip`** (`Features/Overview.swift`). Three cells, Local, GitHub, Production, each with an icon, a dot, and a short value.

**`ProductCard`** (`Features/Overview.swift`). A lifting card with icon, name, status pill, tagline, headline number, stack chips, the sync strip, a release line, and terminal, editor, and dashboard buttons. Click opens the product; right-click opens the product menu.

### Buttons

**`KitButtonStyle`**, used as `.buttonStyle(.kit(kind, compact:))`.

| Kind | Look | Use |
| --- | --- | --- |
| `primary` | Accent fill, `onAccent` text | The one main action |
| `secondary` | Button fill, border, soft shadow | Everything else |
| `production` | Production fill, `onProd` text, semibold | Actions that reach production |
| `ghost` | No fill until hover | Low-emphasis actions |
| `icon` | 30 by 26, button fill, border | Icon-only buttons in rows |
| `toolbar` | 30 by 28, no fill until hover | Icon-only buttons in the top bar |
| `link` | Accent text, no fill | Inline links |

States: rest, hover (border or fill change; primary and production brighten), pressed (darker), disabled (45% opacity). `compact` is 24 pt high with 11.5 pt text.

**`IconButton`**. A button showing one `KitIcon`, with a required label used for the tooltip and VoiceOver.

**`RowButtonStyle`**. A full-width row that highlights on hover and when selected. The selection dims when the window is inactive.

### Pickers and fields

**`SegmentedPill`**. A segmented control on a field-colored track; the selected segment is a raised panel.
States: `compact`, `stretch` (segments share the width).

**`FilterChip`**. A text chip that toggles a filter. States: rest, hover, selected.

**`EnvironmentPicker`** (`Shell/RootView.swift`). Local, Staging, Production with a dot each. The selected Production segment is filled with `Ink.prod`, so it cannot be missed.

**`KitField`**. A text field on a field fill, with an optional leading icon.
States: plain, `secure`, `monospaced`.

**`LabeledField`**. A label above a control, with an optional hint below.

### Values

**`KeyValueRow`**. A key on the left, a value on the right, middle-truncated. Optional monospaced value and tone.

**`CopyableValue`**. A value with a copy button that shows a check for 1.4 seconds after copying. Never used for secrets.

### Charts

**`Sparkline`**. A smoothed line with an optional soft fill. A missing point leaves a gap: no value is not zero. A single point draws as a dot.

**`TrendChart`**. A 148 pt chart with dashed guides and day labels, drawing a `Sparkline`.

**`HealthBars`**. One bar per health check, oldest first, 30 by default.
Bar states: not yet sampled (line color), passed (ok), passed but slower than 800 ms (warn), failed (err). VoiceOver reads how many of the recent checks passed.

**`MetricTile`**. A card with a label, a large value, a sub-line with a tone dot, an optional delta pill, a spark line, and an optional Demo badge.
States: clickable (lifts on hover) when it has an action, otherwise static. A dash stands for "no source connected".

### Rows

**`ToneIcon`**. A 26 pt rounded tile with a toned icon.

**`ActivityRow`**. One feed event: tone icon, title, product, detail, optional Demo badge, compact relative time. The icon and tone come from the event kind.

**`ActionRow`**. Icon tile, title, optional subtitle, trailing content. Optional monospaced title.

**`DoctorStepRow`**. One diagnosis step. States: pass (check), warn (exclamation mark), fail (cross), skipped (minus).

### States

**`EmptyState`**. An icon tile, a title, a message, and an optional primary button with a keyboard hint and a side hint.
States: full (with two decorative rings) and `compact` (inside a card).

**`ErrorState`**. A red-tinted row with an alert icon, a title, a detail, and an optional retry button with a custom label.

**`LoadingState`**. Skeleton rows that pulse. Does not animate with reduced motion. Has an accessibility label.

### Overlays

**`ToastView`**. An inverted rounded panel with a status circle and up to two lines of text.
States: success (accent circle with a check), error (red circle with an exclamation mark).

**`SheetPanel`, `SheetHeader`, `SheetFooter`, `SheetHost`** (`Shell/Overlays.swift`). Sheets are drawn inside the window: a scrim, a panel on a popover material with a 14 pt radius, an optional 4 pt colored stripe at the top (production color for production contexts). Escape and a click on the scrim close them.

**`ConfirmationSheet`** (`Shell/Overlays.swift`). The confirmation for remote-write and production actions and for deletes: a toned stripe, a header, a list of checks (label, value, ok or warning), a footnote, Cancel, and a press-and-hold button.
States of the hold button: rest (label), holding ("Keep holding…" with a fill that grows for one second), released early (resets). VoiceOver gets a "Confirm" action.

**`CommandPalette`** (`Shell/Overlays.swift`). A 640 pt panel with a search field, a scrolling list of commands with group and shortcut, and a footer. Production commands carry a Prod tag and a production-toned icon.
States: results, no matches, selected row (soft accent fill), hover moves the selection.

### Page structure

**`Page`, `PageHeader`** (`Shell/RootView.swift`). A scrolling page with 28 pt side margins, and a header with a 22 pt title, an optional subtitle, and trailing controls.

**`ProductionBanner`, `OfflineBanner`** (`Shell/RootView.swift`). 32 pt strips under the top bar, tinted with the production or warning color.

## Window chrome

- The main window hides the title bar (`.windowStyle(.hiddenTitleBar)`, full-size content view) and positions the traffic lights at the design's coordinates (`WindowChrome`).
- The top bar and the strip above the sidebar drag the window; a double click zooms it (`WindowDragArea`).
- The sidebar is a vibrancy material with `Ink.sidebarTint` over it.
- The main window disables focus rings (`focusEffectDisabled()`).
- The Settings window is a system `Settings` scene with a tab view and grouped forms. It is not custom chrome.
- `noInitialFocus()` and `fitsContent(max:)` (`WindowBehavior.swift`) open a window with nothing focused and size a form to its content. Only Settings uses them.

## Kit gallery

`APP_KIT_GALLERY=1 ~/Applications/ForgeDeck.app/Contents/MacOS/ForgeDeck` shows the buttons, status pills, evidence badges, connection states, pickers, a field, metric tiles, the error, loading, and empty states, a copyable value, and a toast on one page (`KitGallery.swift`).

## Deviations from the design file

| Design | Kit | Why |
| --- | --- | --- |
| Tertiary text at 46% ink | `text3` at 58% ink (56% snow in dark) | 11 pt labels reach 4.5:1 contrast |
| Free spacing values | Snapped to the 4 pt grid, with marked exceptions | One grid, checked by lint |
| MRR figures on every product | A revenue figure only when a product's own metrics source reports `mrr_cents` | No invented business numbers |
| "Promote to Production" button | User-written recipes behind hold-to-confirm | No guessed deploy command |
| Sidebar with the design's pages | Three more pages in the same style: Leads & Metrics, Git & CI, Terminals & Actions | Screens the contract requires |

## Known gaps

- Snapshots in this session were taken with a fallback renderer, so the sidebar and sheet materials look flat in `docs/screenshots/`. The kit itself uses real materials.
- The comment on `text3` in `Tokens.swift` says it was raised so 11 pt labels pass 4.5:1. No contrast measurement is recorded for the accent, status, and production colors on their soft fills.
- There is no accent picker. The accent is fixed in `Tokens.swift`.
- Text does not scale with the system text size setting: sizes are fixed points.
