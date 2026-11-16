ForgeDeck
=========

A Mac app for keeping track of the software projects you build and run: their folders,
GitHub repositories, deployments, health checks, terminals, and AI coding agents, in one
window. Everything stays on your Mac. No account is needed.

Requirements
- macOS 26 or later. Works on Apple silicon and Intel Macs.

Install
1. Drag ForgeDeck.app into your Applications folder.
2. Open it. macOS will say it cannot verify the app, because this copy is not notarized
   by Apple. Click Done (not Move to Trash).
3. Open System Settings > Privacy & Security, scroll down to the message about ForgeDeck,
   and click Open Anyway. Confirm with your password or Touch ID.
   You only need to do this once.

   Or, in Terminal:  xattr -dr com.apple.quarantine /Applications/ForgeDeck.app

First steps
- Click "Add 3 Demo Products" on the welcome screen to look around with sample data
  (marked Demo). Remove it later in Settings > Privacy & Data.
- Or press Cmd-N to add your own project from a folder, a GitHub URL, or an SSH host.
- Cmd-K opens the command palette. Cmd-` shows the terminal. Cmd-Shift-U shows AI usage.

Optional
- GitHub: Infrastructure > Connections > Connect, with a read-only token, or sign in to
  the gh command-line tool. Public repositories work without either.
- Command line: Settings > Command Line > Install adds `forgedeck` to ~/.local/bin.
- AI agents: Claude Code, Codex, OpenCode, Gemini CLI, or Antigravity, if installed,
  can be chosen in Settings > Launching.

Privacy
- Secrets you add go to your macOS Keychain. ForgeDeck has no server and sends no
  telemetry. Its data lives in ~/Library/Application Support/ForgeDeck.

To remove it: quit ForgeDeck, delete the app, and delete that folder.
