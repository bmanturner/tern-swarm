---
name: swarm
description: Configure and debug the Swarm Tern plugin, which turns Kanban cards into git worktrees, each worked by an unattended omp agent, then runs checks and waits for review. Use when the user asks to set up Swarm for a repo, write or fix `.tern/swarm.json` or the user `settings.json`, find out why a Swarm task is blocked, queued or failed, or script Swarm through its Carly exports. Not for agents launched by Swarm to work on a task.
---

# Swarm

## What Swarm does

- Swarm tasks are tracked by `#swarm-<slug>` cards. Hand-written cards become tasks only when adopted from Backlog or Ready according to `adopt_cards`; other cards can remain untracked. Lanes, in order: `Backlog`, `Ready`, `Doing`, `Blocked`, `Review`, `Done`.
- A task in `Ready` (status `queued`) gets a git worktree, setup commands, and an omp agent in its own tab (`preparing`, then `running`).
- When the agent finishes, Swarm runs the checks (`checking`). A pass moves the task to `Review`. A failure goes back to the agent until `max_attempts`, then the task is `blocked`.
- In `Review` the user approves (`shipping`, then `shipped`: commit plus pull request, or commit only), retries, parks or discards.
- Other statuses: `waiting` (the agent asked something, or opened another pane in its tab while working), `closed`, `parked`, `discarding`, `cancelled` (its card was removed). The README section "Task statuses" has the full table.
- Swarm runs nothing in a repository until the user approves, in the Swarm panel, what that repository makes it run: the project file's `setup`, `checks`, `env`, `agent_args`, `roles`, `instructions`, `base`, `remote`, `worktree_dir` and `on_checks_pass: "ship"`, plus detected `package.json` checks and the automatic `npm ci`. Approval is stored per repository path in `kv.json` under `trust`; any change to those items asks again (edits made on the Settings page keep an approved repository approved). Never approve on the user's behalf.

## Config files

| Layer | Path | Shared |
|---|---|---|
| Project | `<repo>/.tern/swarm.json` | Yes, commit it |
| User | `<plugin data>/settings.json` | No, applies to every project |

`<plugin data>` is `<state>/plugin-data/swarm`. On macOS that is `~/Library/Application Support/Tern/plugin-data/swarm`.

How a key set in both files combines:
- `override` (most keys): the project value wins, else the user value, else the default.
- `user_wins` (`worktree_dir`, `agent_args`): the user value wins.
- `append` (`instructions`): both are added to the prompt, personal first.
- `intersect` (`carly.actions`, default `["retry", "park"]`): when both files set it, Carly may only do what both allow; when only the personal file does, that list applies; when only the project file does, it is intersected with the default, so a repository can never widen Carly's actions.
- `strictest` (`tabs.names`): the more private choice wins (`model` < `keywords` < `slug` < `off`).

Each key has a scope. Some keys are project-only (for example `checks`, `ship`, `env`, `max_attempts`), some are user-only (`layout.panel`, `bin_dirs`, `watchdog`, `max_concurrent_total`, `carly.context`), and the rest can be set in both. A key in the wrong file is ignored and reported.

For every key, its default and valid values, read the Settings section of the installed README: `<plugins dir>/swarm/README.md`. `tern plugin dir` prints the plugins folder. The source of truth is `lib/schema.luau`. Don't guess keys; unknown keys are reported and ignored.

## Writing a project config

A minimal valid `.tern/swarm.json`:

```json
{
  "checks": [
    { "name": "typecheck", "run": "npm run typecheck" },
    { "name": "test", "run": "npm test", "agent_runs": false }
  ],
  "setup": ["pnpm install --frozen-lockfile"],
  "env": { "CI": "true" },
  "timeouts": { "checks": "20m" },
  "ship": "pr",
  "max_concurrent": 2
}
```

Pitfalls:
- `agent_args` can't contain approval or config flags in a project file (`--approval-mode`, `--yolo`, `--auto-approve`, `--plan-yolo`, `--plan-yolo-into`, `--config`, or the `=` forms); that makes the value invalid. Agents get the approval arguments from the user's `agent_args`, else `--approval-mode yolo`, followed by the project's or role's list. In the user's `settings.json`, `agent_args` replaces the default and every project's list, so keep `--approval-mode yolo` there or agents stop to ask with nobody watching. Each entry must match `^[%w%-_=.:/@]+$`, so no spaces, `~`, `*` or `,`.
- `timeouts.checks`, `timeouts.setup` and `timeouts.ship` need a unit: `"90s"`, `"30m"`, `"2h"`. `max_time` also accepts a unitless string such as `"45"`, which omp reads as seconds; prefer an explicit unit (`"45m"`). All durations are JSON strings, never JSON numbers.
- `base` must be a branch name like `"main"` or `"origin/main"`: no leading `-` or `/`, no `..` or `//`, no trailing `/`, `.` or `.lock`.
- Check names are sanitized: every character outside `[A-Za-z0-9_-]` becomes `-`. Two checks with the same sanitized name make the whole `checks` value invalid.
- Without `checks`, Swarm detects them from `package.json` scripts (`type-check`, `typecheck`, `lint`, `test`). With no checks at all, tasks go straight to `Review`.
- Setting `setup` replaces the automatic `npm ci` (run when `package-lock.json` exists without `node_modules`).
- An invalid value falls back to the user value or the default and is reported. An invalid `ship` becomes `"commit"`, not the default.
- If `swarm.json` is not valid JSON, Swarm keeps the last valid settings it loaded. With none, nothing new starts or ships until the file is fixed.
- Every change to the approval items above makes the user approve the repository again in the panel.

Problems appear in the Swarm panel and as `config_error` on the project in `<plugin data>/snapshot.json`. A project waiting for approval has `trust` (`subject`, `items`) and `hold` there.

## Debugging a task

Files under `<plugin data>`:

| Path | Holds |
|---|---|
| `snapshot.json` | Every project's tasks, status, `reason`, `config_error`, `hold`, `trust`, `paused`; top-level `projects_error` when `projects.json` is damaged |
| `projects.json` | Known projects under `projects`; the project id is `<repo folder>-<8 hex>`. `projects.json.bak` is its backup |
| `projects/<id>/board.md` | The board |
| `projects/<id>/tasks/<slug>/task.json` | Task state: `status`, `reason`, `attempt`, `branch`, `worktree`, `pr_url`, `commit`, `kept`, `preexisting` |
| `projects/<id>/tasks/<slug>/task.json.corrupt` | A copy of a damaged `task.json` |
| `projects/<id>/tasks/<slug>/prompt.md` | The last prompt sent to the agent |
| `projects/<id>/tasks/<slug>/details.md` | The card's details |
| `projects/<id>/tasks/<slug>/jobs/<n>-<kind>/` | One folder per setup, checks or ship job: `run.sh`, and per step `<name>.log`, `<name>.status` (exit code), `<name>.secs`. A ship job may hold `add-pathspec.txt`, which keeps the `preexisting` files out of the commit |
| `projects/<id>/archive/<slug>/` | Tasks removed by Clean up |
| `kv.json` | `paused` (all projects), `paused_projects`, `trust` (approved items per repository path) |

Logs are in `~/Library/Logs/Tern/` on macOS. `tern.log` has the window half (the orchestrator); `tern-daemon.log` has the host half (the New task form and Settings). Search for `swarm`.

Common causes:
- `queued` and never starts: the repository waits for approval (`trust` in the snapshot), Swarm is paused, `max_concurrent` or the user's `max_concurrent_total` is reached, or `swarm.json` is broken with no last valid settings.
- `blocked`: read `reason` in `task.json`. For check failures, open the newest `jobs/<n>-checks/` folder and read the `.status` and `.log` files.
- `waiting` with `The agent opened … in its tab`: some pane other than the agent and shell is open in the task's tab. Closing it returns the task to `running` while the agent works.
- `blocked` with `task.json is damaged (…)`: Swarm never rewrites that file. Fix it (it must be valid JSON with the folder's `slug`, the project id as `project`, and a known `status`) or delete it; within a few seconds its card becomes a fresh Backlog task.
- A shipped task with `kept`: Clean up left its worktree because it has uncommitted changes or commits after the shipped `commit`. The user's Discard in the panel's Done section removes the worktree and keeps the branch.
- `default_role "<x>" is not an omp role`: set `default_role` to a name from `omp`'s model roles.
- `The card's #role-<x> tag isn't a valid omp role name`: the tag may only use letters, digits, `_` and `-`.
- Log lines: `swarm: startup stalled while loading …`, `swarm: loading … took N ms` (slow module load), `swarm: <what> of <id> took N ms` (over 25 ms; `<what>` is `tick`, `load`, `publish`, `panel redraw`, `reconcile`, `reconcile slice`, `reconcile tail slice` or `reconcile tail`), and `swarm: projects.json …` / `swarm: task.json is damaged` warnings.

Swarm caches each file's settings for up to 30 s. To apply a hand edit at once, queue a config intent:

```sh
D="$HOME/Library/Application Support/Tern/plugin-data/swarm"
mkdir -p "$D/intents" && printf '{"kind":"config"}' > "$D/intents/$(date +%s)-x.json"
```

The orchestrator reads `intents/*.json` in name order on its next tick (every 3 s), reloads settings and deletes the file.

## Driving Swarm through Carly

Carly exports: `open_board`, `add_task`, `list_tasks`, `task_action` (`approve`, `retry`, `park`, `discard`). `add_task` puts the task in Backlog unless `start = true` and returns `{project, slug, lane}`. `list_tasks` returns `{tasks, truncated}`. `task_action` fails at once when the task's status (in the last snapshot) doesn't allow the action, when approving in a held project, or when the merged `carly.actions` doesn't allow it (default: only `retry` and `park`). See the README Carly section for signatures.

Card tags change a single task: `#role-<name>`, `#no-change-ok`, `#auto-ship`, `#draft`. See the README Card tags section.

## Safety

- Agents run unattended with `--approval-mode yolo` by default. They can run any command in their worktree. Swarm's prompt tells them nobody watches and forbids interactive UI.
- Approving pushes a branch and opens a pull request (or commits). Never approve tasks or repositories, discard, or edit `ship`, `on_checks_pass` or `agent_args` on the user's behalf unless they ask.
- `.tern/swarm.json` is shared with the team. Keep personal paths and preferences in the user `settings.json`.
