# AI usage panel

A right-hand panel (⌘⇧U, or the gauge in the toolbar) shows what the AI coding tools on this
Mac have used, and what is left where the tool reports it. `forgedeck usage` prints the same.

## What each tool can tell

| Tool | Read from | "What's left" | Also shown |
| --- | --- | --- | --- |
| Codex | `~/.codex/sessions/**/*.jsonl`, the newest `token_count` event | Yes: the 5-hour and weekly windows as Codex reported them, with reset times and plan | Tokens today, 7 days, top models |
| Claude Code | `~/.claude/projects/*/*.jsonl`, `usage` of each response; limits from Claude Code's account check | Yes: the 5-hour window, the weekly window, and weekly limits for one model (like "Weekly · Fable"), with reset times and plan (from `~/.claude.json`) | Tokens today, 7 days, top models; the 5-hour block comparison when no limits are known |
| OpenCode | `~/.local/share/opencode/opencode.db`, read-only | No | Tokens and OpenCode's own cost estimate, today and this week |
| Antigravity (agy) | `agy --print /usage`, at most every 5 minutes while the panel is open | Yes: each model group's 5-hour and weekly windows, with reset times | Nothing else: agy keeps no token counts on this Mac |

## Use it before it resets

A weekly (or longer) window that resets within a day with at least 20% left is flagged: a green note at the
top of the panel ("75% of Codex left, resets in 18h"), a "Use it" tag on the window, a green dot on the
toolbar gauge, and "use it" in `forgedeck usage`. 5-hour windows are never flagged; they reset all the time.

A Codex window whose reset time has passed shows as reset, with the last reported number for
reference ("was 88% used when last seen 5 days ago"), not as current. The Claude Code block bar is
a comparison with your own history, labeled as such: it is not your plan's limit.

## Not real time

The numbers come from the tools' own logs. They change when the tools write, and the panel
re-reads every 5 minutes while open (or on Refresh). Codex reports its limits after each
request, so they are as fresh as your last Codex request. Claude's limits are as fresh as the last check, shown as
"as of" under each window.

## Privacy and cost

- Only numbers are read: token counts, limit percentages, costs, model names, and times. Claude
  Code logs are scanned as bytes for the small `usage` object; message text is never decoded.
  OpenCode's database is opened read-only and only the message table's numeric fields are queried.
- ForgeDeck itself sends nothing. For Claude's limits, while the panel is open, ForgeDeck asks Claude Code at most every
  5 minutes (or on Refresh) for the same numbers `/usage` shows: one short `claude --print` that answers a
  `get_usage` control request and exits. Claude Code signs in and asks Anthropic itself; no prompt reaches a model,
  and no tool, MCP server, hook, setting file, or saved session is used. Between checks, and for `forgedeck usage`,
  the copy Claude Code saves in `~/.claude.json` (`cachedUsageUtilization`) is read, ignored when it was saved for
  another account. From that file only percentages, reset times, and the plan tier are read; name, email, and IDs
  are not kept. The idea came from vorssaint-utils (GPL-3.0); ForgeDeck's code is its own.
- A week of Claude Code logs on this Mac was 662 MB. The first read takes about 2 seconds; later
  reads reuse results for files that have not changed.

## Measured on this Mac (2026-11-15)

Claude Code: 2.4M tokens today plus 152M cache reads, the current block at 56% of the busiest
block this week. Codex (Plus): both windows have reset since its last use five days ago. OpenCode:
no use this week. Screenshots in docs/screenshots use fixed sample numbers, not these.
