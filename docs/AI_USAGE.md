# AI usage panel

A right-hand panel (⌘⇧U, or the gauge in the toolbar) shows what the AI coding tools on this
Mac have used, and what is left where the tool reports it. `forgedeck usage` prints the same.

## What each tool can tell

| Tool | Read from | "What's left" | Also shown |
| --- | --- | --- | --- |
| Codex | `~/.codex/sessions/**/*.jsonl`, the newest `token_count` event | Yes: the 5-hour and weekly windows as Codex reported them, with reset times and plan | Tokens today, 7 days, top models |
| Claude Code | `~/.claude/projects/*/*.jsonl`, `usage` of each response | No: Claude Code does not record plan limits on this Mac | The current 5-hour block, compared with your busiest block this week; tokens today, 7 days, top models |
| OpenCode | `~/.local/share/opencode/opencode.db`, read-only | No | Tokens and OpenCode's own cost estimate, today and this week |

A Codex window whose reset time has passed shows as reset, with the last reported number for
reference ("was 88% used when last seen 5 days ago"), not as current. The Claude Code block bar is
a comparison with your own history, labeled as such: it is not your plan's limit.

## Not real time

The numbers come from the tools' own logs. They change when the tools write, and the panel
re-reads every 5 minutes while open (or on Refresh). Codex reports its limits after each
request, so they are as fresh as your last Codex request.

## Privacy and cost

- Only numbers are read: token counts, limit percentages, costs, model names, and times. Claude
  Code logs are scanned as bytes for the small `usage` object; message text is never decoded.
  OpenCode's database is opened read-only and only the message table's numeric fields are queried.
- Nothing is sent anywhere.
- A week of Claude Code logs on this Mac was 662 MB. The first read takes about 2 seconds; later
  reads reuse results for files that have not changed.

## Measured on this Mac (2026-11-15)

Claude Code: 2.4M tokens today plus 152M cache reads, the current block at 56% of the busiest
block this week. Codex (Plus): both windows have reset since its last use five days ago. OpenCode:
no use this week. Screenshots in docs/screenshots use fixed sample numbers, not these.
