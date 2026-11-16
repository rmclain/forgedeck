# In-app terminal

Terminals open inside ForgeDeck by default, in a dock at the bottom of the window. Each one is
a real pseudo-terminal (PTY) running your login shell or a command, drawn by SwiftTerm
(github.com/migueldeicaza/SwiftTerm, MIT, pinned to 1.99.3). Colors, resizing, Ctrl-C, and
full-screen programs like vim, htop, and Claude Code work as they do in Terminal.app.

## What opens there

- **Terminal** buttons and ⌘O: your login shell (`$SHELL -l`) in the checkout.
- **Open claude** (or Codex, OpenCode): the agent, with its CONTEXT.md flags.
- **SSH Connect**: `ssh -- <alias>`.
- **Recipes** that run in a terminal: the same quoted script an external terminal would get.

Each session is a tab. Tabs keep running while you move between pages. ⌘` shows or hides
the dock; drag its top edge to resize it. When a command ends, the tab stays with its output
and exit code, and offers Run Again.

## Which product has something running

- **Sidebar**: a terminal glyph next to each product with an open session.
- **Product cards and the product header**: a pill naming what is running, like `claude` or
  `node`, or "Shell open" when the shell is idle. Click it to jump to that tab.
- **Top bar**: a terminal button with the number of running sessions.
- **Tabs**: a dot per session: green for an idle shell, accent for a busy one, red for a
  non-zero exit.

"What is running" is the terminal's foreground process group, read from the PTY once a second.
It names the program you started (`sleep`, `npm`, `claude`), not its arguments.

## Settings

Settings > Launching > Open terminals: **Inside ForgeDeck** or **In the terminal app**. The
product menu always has **Open in External Terminal**, and the dock has a button to open the
current folder in your terminal app.

## Notes

- Quitting ForgeDeck ends running sessions. With any running, it asks first.
- Nothing is recorded: ForgeDeck keeps no transcript. Copy Text copies what is on screen.
- The terminal inherits ForgeDeck's environment with a full PATH and `TERM=xterm-256color`. It
  receives no secrets. Use `forgedeck exec` with a profile for that.
- Tested by the self-test: output on screen, exit code, a folder with an apostrophe, the
  foreground indicator, and that closing a session ends its processes.
