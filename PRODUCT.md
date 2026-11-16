# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

The product itself is a native macOS app (SwiftUI, macOS 26+). This record covers its public website, a web surface.

## Stack

Website: plain static HTML/CSS in `site/`, no build step, deployed to GitHub Pages by a GitHub Actions workflow.

## Users

Indie developers and small teams who run several products at once (SaaS apps, mobile apps, WordPress plugins, client sites, side projects) from one Mac, and who want one place that shows where each product's code is, what is deployed, and what is healthy. They arrive at the website deciding whether to download the app.

## Product Purpose

ForgeDeck is a native macOS control room for a portfolio of software products. It tracks local checkouts, GitHub, staging, and production with evidence; opens a product in a terminal, editor, AI coding agent, or simulator in one click; keeps scoped secrets in the Keychain; and gives agents compact context across related repositories. Success: a visitor understands what it does in one screen and downloads the latest release.

## Positioning

Evidence over guesses: every deployment fact is marked Verified, Reported, Stale, or Unknown, and production is never inferred from a green build or a `main` branch. Fully local: no account, no server, no telemetry, secrets only in the Keychain. Native Mac app that doubles as the `forgedeck` command line tool.

## Operating Context

Used on a developer's Mac alongside a terminal, an editor (Cursor, VS Code, Zed, Xcode), AI coding agents (Claude Code, Codex, Gemini, OpenCode), GitHub, local WordPress sites, and iOS simulators / Android emulators.

## Capabilities and Constraints

- Products in groups (rename, drag between groups); evidence chain Local → GitHub → Staging → Production.
- Built-in terminal with session indicators; open in editor; AI agent launch with linked repo context (repo maps).
- Play: run on simulator, start desktop app, start dev server and open it, or open a local WordPress site's admin.
- CI failure logs from GitHub Actions with fix prompts; AI usage side panel from local logs.
- Keychain-scoped variables; production secrets need Touch ID; remote writes need press-and-hold confirmation.
- Recipes start as unapproved suggestions; toolbox of token-saving tools.
- In-app updater from GitHub releases, signature and team checked.
- Distribution: zip from GitHub releases, signed but not notarized: first launch needs System Settings › Privacy & Security › Open Anyway. macOS 26+, Apple silicon and Intel.
- Undecided: license, pricing (none stated; it is a free download).

## Brand Commitments

Name: ForgeDeck. App icon: `docs/screenshots/icon.png` (hammer on a green gradient tile). The app's own design kit uses a green accent and a red reserved for Production. Voice: plain, factual, short sentences; status as words first.

## Evidence on Hand

Real app screenshots with demo data, light and dark: `docs/screenshots/*.png` (overview, product pages, deployments, terminal dock, palette, toolbox, settings). No testimonials, users, download counts, press, or benchmarks exist; do not invent them.

## Product Principles

1. Evidence before claims: show how a fact is known.
2. Local and private by default.
3. One click from seeing a product to working on it.
4. Nothing runs or writes remotely without the user's approval.

## Accessibility & Inclusion

Respect reduced motion; WCAG AA contrast.
