# CI failure logs and fix prompts

ForgeDeck fetches the failing part of a GitHub Actions run, shrinks it to what an AI agent
needs, and starts the agent with a short brief. It reads from GitHub and changes nothing there.

## Where

- Product > Development > **CI runs**: **Last Failure Logs**, and **Logs** on each failed run.
- **Git & CI** page: click a "Failing · Logs" pill.
- Command palette: **Show Last CI Failure · <product>**.
- Terminal: `forgedeck ci <product>` prints the excerpt; `--brief` prints the whole brief;
  `--fix` starts the agent with it; `--fix --print` shows the command instead.

## Which run

The newest failed run of a deploy-type workflow (its name contains deploy, release, publish,
ship, or production). Without one, the newest failed run. A specific run can be chosen.

## Where the log comes from

- With a GitHub token connected in ForgeDeck: the REST API (`/actions/runs/{id}/jobs`, then
  `/actions/jobs/{id}/logs`). GitHub answers the log request with a redirect to a short-lived
  signed URL. ForgeDeck follows it only to GitHub's log hosts, and without the token.
- Otherwise: the `gh` CLI with its own sign-in (`gh run view --log-failed`). When gh labels a
  step "UNKNOWN STEP", ForgeDeck names it from the run's job list.

## What the agent gets

- The failing steps only. Timestamps, color codes, and GitHub's group markers are removed;
  `##[error]` lines become `ERROR:`. The excerpt centers on the last error (what led up to it,
  and a few lines after) and is capped at 12,000 characters, about 3,000 tokens.
- Secrets that GitHub masks stay `***`; ForgeDeck's redactor also removes token-shaped text.
- A brief file, `context/<product>/ci-failure-<run>.md` in ForgeDeck's data folder: the run
  URL, workflow, branch, commit, failed job and step, whether the local checkout is on the
  same commit, the excerpt, and the task.
- The task tells the agent to name the root cause before changing anything, to make the
  smallest fix, to say exactly what must be set when the cause is a secret or a CI setting
  rather than code, and not to push, tag, deploy, or re-run the workflow.

**Fix with claude** opens the agent in the in-app terminal, in the checkout, with the product's
CONTEXT.md and one opening message pointing at the brief. **Copy Prompt** copies the brief to
paste into any assistant.

## Tried on real runs (2026-11-15)

| Repository | Run picked | Cause in the excerpt | Size |
| --- | --- | --- | --- |
| a private mobile game | CI (newest failure) | a store config file had no licence key | a few hundred tokens |
| a private WordPress plugin | Release (deploy type, over newer CI failures) | `ssh-private-key` secret is empty | 154 lines → about 1,330 tokens |

Both causes are outside the code (a store key and a CI secret), which is the case the brief
asks the agent to report rather than guess. The agent was not started during development.
