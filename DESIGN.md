---
name: ForgeDeck website
description: The public site for ForgeDeck, drawn as a cyanotype shop drawing of the app.
colors:
  sheet: "#0e3361"
  sheet-deep: "#0a2850"
  ink: "#eef4fb"
  ink-2: "#bfd2e8"
  ink-3: "#8fb0d4"
  line: "rgba(238, 244, 251, 0.82)"
  hair: "rgba(238, 244, 251, 0.28)"
  grid: "rgba(238, 244, 251, 0.055)"
  grid-major: "rgba(238, 244, 251, 0.1)"
  approved: "#1f7a4c"
  approved-hi: "#186a40"
  prod: "#f08a6c"
  stamp-white: "#ffffff"
typography:
  display:
    fontFamily: "Barlow Condensed, Barlow, system-ui, sans-serif"
    fontSize: "clamp(3rem, 6vw, 5.5rem)"
    fontWeight: 600
    lineHeight: 0.95
    letterSpacing: "0.02em"
  headline:
    fontFamily: "Barlow Condensed, Barlow, system-ui, sans-serif"
    fontSize: "clamp(1.375rem, 2.2vw, 2rem)"
    fontWeight: 600
    lineHeight: 0.95
    letterSpacing: "0.04em"
  title:
    fontFamily: "Barlow Condensed, Barlow, system-ui, sans-serif"
    fontSize: "clamp(1.75rem, 2.8vw, 2.5rem)"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.01em"
  lede:
    fontFamily: "Barlow, system-ui, sans-serif"
    fontSize: "1.125rem"
    fontWeight: 400
    lineHeight: 1.55
  body:
    fontFamily: "Barlow, system-ui, sans-serif"
    fontSize: "1.0625rem"
    fontWeight: 400
    lineHeight: 1.55
  label:
    fontFamily: "Barlow Condensed, Barlow, system-ui, sans-serif"
    fontSize: "1rem"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "0.05em"
  mono:
    fontFamily: "ui-monospace, SF Mono, Menlo, monospace"
    fontSize: "0.9375rem"
    fontWeight: 500
    lineHeight: 1.3
rounded:
  none: "0px"
  icon: "7px"
  balloon: "50%"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
  xxl: "48px"
  section: "56px"
  gutter: "clamp(16px, 3vw, 40px)"
components:
  stamp-download:
    backgroundColor: "{colors.approved}"
    textColor: "{colors.stamp-white}"
    rounded: "{rounded.none}"
    padding: "8px 18px 8px 10px"
    height: "60px"
  stamp-download-hover:
    backgroundColor: "{colors.approved-hi}"
    textColor: "{colors.stamp-white}"
  stamp-download-small:
    backgroundColor: "{colors.approved}"
    textColor: "{colors.stamp-white}"
    rounded: "{rounded.none}"
    padding: "0 16px"
    height: "42px"
  nav-link:
    textColor: "{colors.ink-2}"
    typography: "{typography.label}"
    padding: "6px 0"
  nav-link-hover:
    textColor: "{colors.ink}"
  reversed-tag:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.sheet}"
    typography: "{typography.label}"
    rounded: "{rounded.none}"
    padding: "5px 8px"
  reversed-tag-production:
    backgroundColor: "{colors.prod}"
    textColor: "{colors.sheet-deep}"
  title-block:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.none}"
    padding: "9px 12px"
  drawing-table:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    rounded: "{rounded.none}"
    padding: "12px 14px"
  balloon:
    backgroundColor: "{colors.sheet}"
    textColor: "{colors.ink}"
    rounded: "{rounded.balloon}"
    size: "40px"
  balloon-hover:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.sheet}"
  detail-letter:
    textColor: "{colors.ink}"
    rounded: "{rounded.balloon}"
    size: "52px"
  step-number:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.sheet}"
    rounded: "{rounded.none}"
    size: "36px"
  launch-mode:
    textColor: "{colors.ink-3}"
    padding: "22px 20px 24px"
  launch-mode-active:
    backgroundColor: "{colors.sheet-deep}"
    textColor: "{colors.ink}"
---

# Design System: ForgeDeck website

Scope: this file governs the public website in `site/` only. The macOS app has its own design kit (`Sources/ForgeDeck/DesignKit`, specified in `design/KIT.md`); nothing here applies to the app, and nothing in the kit applies here.

## Overview

**Creative North Star: "The Cyanotype Shop Drawing"**

The site is one engineering print. A Prussian-blue sheet carries white drafting linework: a faint 20 px grid with a 100 px major grid, a ruled border with an outer hairline frame, a margin band of zone numbers (8 to 1) and letters (H to A), a title block, a parts list, lettered details, general notes, and a revision table. The app screenshot is the specimen. It is the drawn part, and dimensioned leaders with numbered balloons point at it. Everything on the page is something a real print would carry, and each section takes its name and form from one: Parts list, Detail A, Section C–C, General notes, Assembly, Revisions, Sheet 1 of 1.

The world has one blue scheme and no light variant, by decision (`color-scheme: dark`). Linework and lettering are near-white ink. There are only two colored marks. A green "approved" stamp is the download action, and vermilion marks Production and nothing else. Rank comes from weight, case, and reversal (ink fill with sheet-colored type), not from a ladder of sizes. Notes are set in a condensed drafting sans in capitals. Prose stays in the regular-width Barlow so it reads as text, not as annotation.

Motion is a draftsman's motion. The leaders draw in once (stroke-dashoffset, 900 ms, staggered 120 ms) and the balloons stamp in after them. Hovering a balloon reverses it and shows its "SEE DETAIL" reference. With reduced motion, everything is shown already drawn.

**Key Characteristics:**
- One sheet: a grid-paper field inside a 1.5 px ruled border, a hairline outline 6 px outside it, and zone references in an 18 px margin band.
- Two-tier ink: ruled lines at 82% (`line`) and hairlines at 28% (`hair`).
- One note size (1rem) for condensed capitals, ranked by weight, case, letter-spacing, and reversal.
- Square corners everywhere. The only round forms are drafting circles: balloons, detail letters, and evidence marks.
- Green only on the download stamp. Vermilion only on Production.
- Evidence states are drawn marks next to their word: filled (Verified), hollow (Reported), struck through (Stale), dashed (Unknown).

## Colors

The palette is a cyanotype: one blue sheet, white ink at a few strengths, and two stamped colors.

### Primary
- **Approval Stamp Green** (`approved`): the fill of the download stamp, and of that alone. It is the app's own accent, carried onto the print as an inspector's approval. Its text and inner rule are pure white (`stamp-white`), with an outer green ring offset 3 px.
- **Approval Stamp Green, Lifted** (`approved-hi`): the stamp's hover fill and ring.

### Secondary
- **Production Vermilion** (`prod`): marks Production only. It fills the Production station's reversed tag (with `sheet-deep` text) and strokes its evidence mark. Vermilion never stands for "error" or "emphasis" in general.

### Neutral
- **Prussian Sheet** (`sheet`): the print surface. It also backs the title block, the tables, and the balloons, and it is the type color inside ink reversals.
- **Deep Sheet** (`sheet-deep`): the page behind the sheet, the active launch-mode panel, and the type color on vermilion.
- **Drafting White** (`ink`): headings, body text, leaders, balloon rings, and reversal fills.
- **Second Ink** (`ink-2`): navigation, captions, evidence lines, table headers, and secondary notes.
- **Third Ink** (`ink-3`): zone references, title-block field keys, inactive launch modes, and footer fine print. It is the faintest ink allowed for text.
- **Ruled Line** (`line`): borders, the title rule under the drawing name, table frames, and the chain line.
- **Hairline** (`hair`): cell dividers, section rules, and dashed construction lines.
- **Grid** (`grid`, `grid-major`): the 20 px and 100 px paper grid. Never used for text or for borders.

### Named Rules
**The Two Stamps Rule.** The sheet is monochrome ink on blue. Green appears once per screen, as the approval stamp on Download. Vermilion appears only where Production is named. Any other colored element is off-world.

**The Reversal Rule.** To promote a label, reverse it (an `ink` fill with `sheet` type) or draw a rule around it. Do not use a new color or a bigger size.

## Typography

**Display Font:** Barlow Condensed 500/600/700 (falling back to Barlow, then system-ui), self-hosted woff2
**Body Font:** Barlow 400/500/600 (falling back to system-ui), self-hosted woff2
**Label/Mono Font:** ui-monospace, SF Mono, Menlo, for literal values only (commands, versions, branch names)

**Character:** The condensed face is the draftsman's lettering: uppercase, tracked, and tight. The regular-width Barlow is the spec writer's prose. Both are cut from the same family, so they share a skeleton and differ only in voice.

### Hierarchy
- **Display** (Condensed 600, clamp 3rem to 5.5rem, 0.95, uppercase): the drawing title, once.
- **Headline** (Condensed 600, clamp 1.375rem to 2rem, uppercase, 0.04em): the drawing's descriptive subtitle, set under a 2 px ruled line.
- **Title** (Condensed 700, clamp 1.75rem to 2.5rem, 1.0, uppercase): section headings, named after the print part they represent ("Detail B · Play", "General notes").
- **Lede** (Barlow 400, 1.125rem, max 62ch): the opening paragraph of a section. The hero hook runs a step larger (1.1875rem/1.45).
- **Body** (Barlow 400, 1.0625rem/1.55): prose, notes, and steps. Supporting prose in specs and legends uses 1rem.
- **Label** (Condensed 600–700, 1rem, uppercase, 0.03–0.12em): every note, key, tag, table header, caption, and nav item.
- **Mono** (500, 0.9375rem in stations, 0.9em inline): literal values.

### Named Rules
**The One Note Size Rule.** Condensed annotation in HTML is 1rem (`--note`). Rank inside the notes comes from weight (500/600/700), case, tracking, ink strength, and reversal. Sheet furniture is the only exception: zone references (0.75rem) and the lettering inside the specimen SVG (17–22 px in drawing units).

**The Lettering vs. Prose Rule.** Anything a draftsman would letter on a print is condensed capitals. Anything a reader reads as a sentence is regular-width Barlow in sentence case.

## Layout

The sheet is a single bounded print, at most 1600 px wide with a 12 px margin from the page (8 px under 720 px). Its inner padding is `gutter`, with 26 px at the top to clear the zone band. Inside it, a top strip holds the mark and the nav. The first viewport is a two-column grid (`minmax(280px, 4fr) 8fr`): the title copy sits left, and the right column holds the specimen with the title block below it, right-aligned at up to 560 px wide. Every later section is separated by a hairline rule and 56 px of vertical padding.

Details use plain grids: four equal stations on one ruled line for the evidence chain, four launch-mode cells inside a dashed frame, a 7fr/5fr section view with its spec list, two-column numbered notes (`columns: 2 380px`), and two-column assembly steps. Prose measures are capped at 62–70ch, and notes at 22–36ch.

Responsive behavior: at 960 px the first viewport stacks (copy, specimen, title block at full width) and Detail C goes to one column. At 860 px the chain turns vertical along a left-hand rule and the modes go to two columns. At 720 px the side zone columns drop, alternate top zones are hidden, and the inner frame becomes a single top rule. At 640 px the specimen labels hide (the balloons stay), the title block re-flows to two columns, and the nav keeps only GitHub. At 480 px the modes go to one column.

Spacing is set by hand on a 4 px base rather than taken from a strict scale. The recurring steps are 8, 12, 16, 24, 28, 48, and 56 px.

## Elevation & Depth

The print is flat. Depth comes only from drafting conventions: line weight (1.5–2 px ruled lines against 1 px hairlines), reversal, and the sheet sitting on the slightly darker `sheet-deep` page. The specimen leaders have a 7 px `sheet`-colored casing under the 2.4 px ink stroke, so they read as crossing over the screenshot.

### Shadow Vocabulary
- **Struck-forward frame** (`box-shadow: inset 0 0 0 2px var(--ink)`): the active or hovered launch mode, which reads as a heavier ruled box. This is the only box-shadow in the system.

### Named Rules
**The Ink-Only Depth Rule.** No drop shadows, blurs, or glows. When something has to come forward, give it a heavier rule, reverse it, or deepen its ground.

## Shapes

Corners are square. Containers are ruled rectangles: the sheet, the title block, the tables, the section-view frame, and the stamp. Circles are drafting symbols, never decoration. They are balloons (r 20 in drawing units), detail letters (52 px, 2 px ring), evidence marks (40 px, 26 px in the legend), and the stamp's double seal ring. Dashed lines mean construction or uncertainty: the legend rule, the launch-mode frame, and the Unknown mark. The app icon's 7 px tile radius belongs to the icon, not to the sheet.

## Components

### Buttons
- **Shape:** square-cornered (0px), a ruled stamp.
- **Primary (Download stamp):** an `approved` fill with white condensed type. The 40 px seal (two concentric rings and a check) sits left, then two lines: a 1rem small line tracked 0.12em ("APPROVED · REV 0.3") and a 1.25rem bold action line. It has a 2 px white inner border, a 2 px green outline offset 3 px, and a minimum height of 60 px. It appears in the title block, with a 42 px small variant (download glyph plus "Download") in the footer title block.
- **Hover / Focus:** the fill and ring shift to `approved-hi` over 160 ms on `--ease`. Focus uses the global 2 px ink outline offset 3 px.
- **Links:** ink text with a 1 px underline offset 0.2em, thickening to 2 px on hover.

### Chips
- **Reversed tag:** a 1rem condensed caps label on an `ink` fill with `sheet` type, padded 4–5 px by 8 px. It names stations and the title-block title. On the Production station it is a vermilion fill with `sheet-deep` type.
- **Outlined key:** the same label inside a 1.5 px `currentColor` rule, used for launch-mode keys. It reverses when the mode is struck forward.

### Cards / Containers
- **Title block:** a ruled grid (1.4fr 0.6fr 1fr) with a 1.5 px outer `line` and 1 px `hair` cell dividers. Each cell pairs an `ink-3` key with an ink value, all in 1rem condensed caps.
- **Drawing tables (parts list, revisions):** a 1.5 px outer `line` on a `sheet` fill, `ink-2` headers above a 1.5 px rule, and `hair` row dividers. The newest revision row is tinted 6% ink.
- **Launch modes:** cells inside a dashed hairline frame. At rest they are `ink-3`. The active or hovered one is struck forward to `ink` on `sheet-deep` with the inset 2 px frame. While another mode is hovered, the default one recedes.

### Navigation
1rem condensed caps tracked 0.06em in `ink-2`, with 22 px gaps. Hover turns it `ink` and underlined. Under 640 px only the GitHub link stays.

### Balloon callout (signature)
A numbered circle (`sheet` fill, 2.2 px ink ring, bold condensed numeral) with a label and a leader that ends in a filled arrowhead pointing at a part of the specimen. The whole callout links to its detail section. On hover or focus the balloon reverses and a "SEE DETAIL X" line fades in. On first view the leaders draw in and the balloons stamp after them. Reduced motion shows the finished drawing.

### Evidence marks (signature)
A 40 px circle drawn beside its word, never instead of it. Filled is Verified, hollow is Reported, struck with a diagonal is Stale, and a dashed ring is Unknown. Marks for the Production station are stroked vermilion.

### Detail letter and step number
Sections that are details open with a 52 px ringed capital letter beside the heading, as on a print. Assembly steps use a 36 px square `ink` block with a reversed numeral.

## Do's and Don'ts

### Do:
- **Do** put every new section on the one sheet and name it after a real print part (detail, section view, notes, assembly, revisions).
- **Do** set annotation at 1rem condensed caps and rank it by weight, tracking, ink strength (`ink`, `ink-2`, `ink-3`), or reversal.
- **Do** draw status as a mark next to its word: filled, hollow, struck, or dashed.
- **Do** use 1.5–2 px `line` for frames and 1 px `hair` for dividers. Dash a line only when it means construction or uncertainty.
- **Do** let the leaders draw in once with `--ease` (cubic-bezier(0.16, 1, 0.3, 1)), and show them already drawn under reduced motion.
- **Do** keep text at `ink-3` or stronger on the sheet. Lighter alphas are for linework only.

### Don't:
- **Don't** use green anywhere except the download stamp, or vermilion anywhere except Production.
- **Don't** add drop shadows, glows, gradients, or blur. The sheet's grid is the only background pattern.
- **Don't** round containers. Circles are reserved for balloons, detail letters, evidence marks, and the seal.
- **Don't** add a light theme or a second sheet color. The cyanotype is one scheme by decision.
- **Don't** apply this file to the macOS app. It follows `design/KIT.md`.
