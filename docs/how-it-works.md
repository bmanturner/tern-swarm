# How it works

How a task moves through Swarm, its internals and state files, platform support and known limitations. Back to the [README](../README.md).

## How a task flows

1. **Queued.** A card in **Ready** is a queued task. Swarm stamps it with a `#swarm-<slug>` tag.
2. **Pickup.** About every 3 s, Swarm starts queued tasks in board order while a slot is free. Limits:
   `max_concurrent` per project and `max_concurrent_total` across projects. Nothing starts while
   pickups are paused, globally or for this project, or while the repository waits for your
   approval (see [Repository approval](configuration.md#repository-approval)). When `.tern/swarm.json` is broken,
   Swarm keeps using the last valid settings it saw; without any, nothing starts until the file is
   fixed.
3. **Preparing.**
   1. The role comes from the card's `#role-<name>` tag, else `default_role`. An unknown role, or a
      tag whose name isn't letters, digits, `_` and `-`, blocks the task.
   2. Swarm creates the worktree `<worktree_dir>/<slug>` on branch `<branch_prefix><slug>` from
      `base`. When the branch name is taken, Swarm appends `-` and 4 hex digits. In a newly created
      worktree, Swarm records the untracked and ignored files already there (for example `.env` or
      `node_modules` copied by `omp worktree add`), so Approve never commits them.
   3. It opens a shell tab in the worktree and runs the `setup` commands there.
4. **Running.** Swarm starts `omp --model @<role> --max-time <max_time> <agent_args>` in the same tab,
   above the shell, with a prompt built from the card's title, details and your `instructions`. See
   `agent_args` in [Settings](configuration.md#settings) for where the arguments come from. The prompt tells the agent
   not to commit, push, open pull requests or start servers, and that nobody watches its pane: it
   should ask with its ask tool or stop, and never open interactive UI.
5. **Checking.** When the agent goes idle, Swarm checks that it changed something (see `no_change`),
   then runs `checks` as a job in the task's shell.
   - All checks pass: the task goes to **Review**, or ships right away when `on_checks_pass` is
     `"ship"` or the card has `#auto-ship`. Shipping right away needs at least one check and a task
     that changed something.
   - There are no checks: the task goes to **Review**. It never ships right away.
   - Some fail and attempts remain: Swarm sends the failure output to the same agent and the task
     runs again. `max_attempts` counts these rounds.
   - Some fail and no attempts remain: the task is blocked.
6. **Review.** You approve, retry or discard it. See [Review and approve](configuration.md#review-and-approve).
7. **Shipping.** Approve commits every file in the worktree, then (with `ship: "pr"`) pushes and opens
   a pull request. The task becomes **shipped**.
8. **Clean up.** Finished tasks keep their worktree until **Swarm: Clean up finished worktrees**, the
   panel's **Clean up** button, or `clean.auto`. Clean up moves the task's record to the project's
   `archive/` folder. A shipped task's worktree that holds work made after shipping is kept (see
   [Known limitations](#known-limitations)).

Add tasks in any of these ways:

- **Swarm: New task…** (or the panel's **New task** button). The form has a title, details and an omp
  role picker. `⌃↵` adds the task to the lane chosen by `new_task.lane` (Ready by default) and `⌃⇧↵`
  to the other lane.
- **Type a card on the board** in **Backlog** or **Ready**. About 6 s after you stop editing it, Swarm
  adopts it (see `adopt_cards`). A card typed into Ready starts right away; type it into Backlog to
  hold it. Add `#role-<name>` to the card to pick the role.
- **Ask Carly.** Carly's tasks go to Backlog unless it passes `start = true`. See [Carly](configuration.md#carly).

## Internals

- `window.luau` loads the modules in `lib/` one per timer callback, because loading them all at once
  overruns Tern's 50 ms budget. Then it registers commands, the panel's click handling, Carly exports
  and the orchestrator. On iOS it stops before loading anything.
- The orchestrator runs in one window. That window holds a lease in `tern.kv` and leads once it has
  held it for two ticks in a row. At the start of each leadership period it loads one project's tasks
  per tick; intents and board reads wait until every project is loaded. Then, every 3 s, it handles
  queued intents (for up to 15 ms; the rest wait for the next tick), reads each board and reconciles:
  1. adopts cards;
  2. applies your lane moves;
  3. starts queued tasks;
  4. follows the agents;
  5. runs jobs;
  6. moves cards.

  Steps 1–3 run in one call. Steps 4–6 run task by task in slices: each slice starts new per-task
  work for up to 10 ms and runs on its own timer callback 60 ms after the previous one, so a project
  with many tasks doesn't overrun the budget. A project's next board read waits until its reconcile
  finishes (or 30 s). All timings use `tern.now()`, the wall clock Tern's budgets use. Other windows
  read `snapshot.json`.
- Publishing writes `snapshot.json` on a timer 60 ms after a reconcile asks for it, then queues one
  panel redraw per changed project, 60 ms apart. A redraw builds the view in one timer call (Needs
  you and Review cards are reused per task until the task changes; on a cold start cards are built
  for at most 25 ms per call and the build repeats until complete) and hands it to the canvas in a
  later call. A newly opened panel shows an empty view first and fills in on later calls.
- Jobs (setup, checks, ship) are generated `sh` scripts typed into the task's shell pane, so they use
  your shell's `PATH` and Node version. Each job writes per-step status and logs to `jobs/<n>-<kind>/`.
- `host.luau` defines the New task form and the Settings page. They write an intent file and wake the
  leader through the `swarm://wake` link.
- Each task title gets one `omp -p --model @tiny` call in the background to name its tab (with
  `tabs.names: "model"`). The title's key words are used until it answers, or if it fails.
- Discarding a task stops its agent and shell, then sets it to `discarding` until the worktree is
  removed (and the branch, unless `discard.delete_branch` is `false`). The state is saved, so a reload
  finishes the job.
- A watchdog notices when board reads or the orchestrator timer have stopped for a minute, because
  Tern disabled a hook that overran its time budget. It then acts on the `watchdog` setting. A reload
  waits until you've been idle in Tern for 30 s, so it doesn't interrupt your typing.
- `projects.json`, `task.json` and `snapshot.json` carry `"format": 1`. Swarm leaves a file with a
  higher format alone.
- Nothing is written into your repository except the worktrees, the branches, and `.tern/swarm.json`
  when you create it.

## Where Swarm keeps its state

Swarm's data folder is
`~/Library/Application Support/Tern/plugin-data/swarm` on macOS (Linux: see
[Platform support](#platform-support)). In it:

| Path | Holds |
|---|---|
| `settings.json` | Your personal settings |
| `projects.json` | Registered projects: root, name and worktree folder, under `projects`, with `"format": 1` |
| `projects.json.bak` | The copy Swarm writes before each `projects.json` write. When `projects.json` is damaged, Swarm restores it from here |
| `snapshot.json` | What the panels show. Each project's `config_error` holds its settings problems, `hold` why nothing may start or ship, and `trust` the list waiting for your approval |
| `kv.json` | The leader lease, `paused`, `paused_projects`, the watchdog's last reload, and `trust`: the approved list per repository path |
| `intents/` | Queued commands from the panel, forms and Carly |
| `projects/<id>/board.md` | The project's board |
| `projects/<id>/tasks/<slug>/` | `task.json` (status, `reason`, attempt, `"format": 1`), `details.md`, `prompt.md` (the last prompt sent to the agent) and `jobs/`. `task.json.corrupt` is a copy of a damaged `task.json` |
| `projects/<id>/tasks/<slug>/jobs/<n>-<kind>/` | One setup, checks or ship job: `run.sh`, and per step `<name>.log`, `<name>.status` (exit code) and `<name>.secs` |
| `projects/<id>/archive/<slug>/` | Tasks moved here by Clean up |

## Platform support

| Platform | Status |
|---|---|
| macOS | Tested |
| Linux | Untested. Data is in `~/.local/state/tern/plugin-data/swarm` (`$XDG_STATE_HOME/tern/plugin-data/swarm`), logs in `~/.local/state/tern/logs`, plugins in `~/.config/tern/plugins` |
| Windows | Unsupported. Jobs are `sh` scripts |
| iOS | Swarm's window half does nothing: no orchestrator, commands, panel or Carly exports. iOS has no process API and no boards |
| Remote and SSH panes | Unsupported. Commands and Carly refuse a focused pane on a remote host with `Swarm works only with repositories on this machine` |

When `TERN_CONFIG_DIR` is set, Tern's data folder is `$TERN_CONFIG_DIR/plugin-data/swarm` on every
platform.

## Known limitations

- **Shipped worktrees with later work are kept.** Before Clean up or `clean.auto` removes a shipped
  task's worktree, Swarm checks that the worktree has no uncommitted changes and that the branch has
  no commits after the shipped commit. When either check fails, or Swarm has no record of the shipped
  commit, the worktree stays and the Done section shows why. Discard there removes the worktree by
  force and keeps the branch. Otherwise:
  - with `ship: "commit"`, Clean up removes a shipped task's worktree right away and keeps the branch;
  - with `ship: "pr"`, it removes the worktree once the PR is merged or closed, deletes the local
    branch too, and archives the task;
  - `clean.auto: "after_merge"` removes the worktree and branch the same way, but doesn't archive the
    task. `clean.auto: "after_ship"` removes the worktree right after shipping, even while the PR is
    open, and keeps the branch.
- **Untracked files the worktree started with count as uncommitted changes.** Files kept out of the
  commit because they were there before the agent ran (for example a copied `.env` that `.gitignore`
  doesn't exclude) make that check fail, so the worktree is kept. Use Discard in the Done section.
- **Clean up skips some tasks.**
  - It skips shipped tasks whose PR is still open, and shipped tasks whose worktree it keeps.
  - It skips closed and cancelled tasks with uncommitted changes. Agent work is never committed, so a
    task you dragged to Done or deleted mid-run usually keeps its worktree. Discard doesn't accept
    closed or cancelled tasks.
  - To clear such a task, run `git worktree remove --force <path>`, then Clean up again.
- **Some pre-existing files aren't recorded.** Swarm records at most 2000 untracked and ignored
  entries per new worktree, and skips names git has to quote (for example names with non-ASCII
  characters or control characters). Those files can be committed. Worktrees Swarm resumes or
  reattaches record nothing, because their files may be the agent's.
- **Tern can disable Swarm.** Tern disables any plugin hook whose call runs over its time budget,
  until the next reload. Most window calls, including the orchestrator, get 50 ms; status-bar
  formatters get 4 ms; the New task form and the Settings page get 2 s. Overruns are likelier on a
  heavily loaded machine and in projects with many tasks.
  - The `watchdog` setting decides what Swarm does once it notices.
  - If the overrun happens while Swarm is loading, Swarm stays off. On the next window focus at
    least 20 s after loading started, it shows `Swarm didn't finish starting`. Run
    **Reload plugins** from the palette.
  - `watchdog: "reload"` reloads every plugin, not just Swarm. On a busy machine `"notify"` is the
    safer choice.
  - Run Clean up now and then: finished tasks still cost time on every tick until they are archived.
- **Only npm is detected.** Without `checks`, Swarm only looks for `package.json` scripts and runs
  them with `npm run`. Without `setup`, it only runs `npm ci` (when `package-lock.json` exists). pnpm,
  yarn, bun and non-JavaScript projects must set `setup` and `checks`.
- **A damaged state file stops Swarm from changing it.** `tern.fs` writes aren't atomic, so a crash
  mid-write can leave a broken file. Swarm never overwrites a damaged `projects.json` or `task.json`;
  see [Troubleshooting](troubleshooting.md#symptoms-and-fixes).
- **New task, Carly's `add_task` and Settings look up the project by folder.** They take the
  registered project whose folder holds the pane's directory, so a pane inside a submodule of a
  registered repository uses the parent's project (or, when both are registered, either one). Open
  board asks git instead, so it opens the submodule's own board.
- **The Settings page has narrower ranges than the files.** It offers `max_time` 5–480 minutes and
  `timeouts.setup` and `timeouts.checks` 5–240 minutes, in steps of 5; `timeouts.ship` 1–60 minutes;
  `max_concurrent` 1–16 (the files allow 32); and `max_concurrent_total` 0–16, where 0 means no limit
  (the files allow 64). Durations are whole minutes. Set other values in the JSON files.
- **Bare `max_time` numbers are seconds to omp.** The Settings page shows them as seconds rounded up
  to whole minutes. Prefer an explicit unit.
- **Large boards.** A board read returns at most 500 cards per lane. When a lane is larger, Swarm
  stops noticing deleted cards and the panel shows a warning. Turn on `clean.remove_done_cards` and run
  Clean up.
- **Agent UI detection can't tell who opened a pane.** Any extra pane in a task's tab while its agent
  works marks the task `waiting`, including a split you opened there yourself.
- **Tern can run Swarm's timers late while it's idle in the background.** On macOS, delays of
  40–90 s have been seen until any event (a focus, a `tern` CLI call) wakes the window. Swarm then
  catches up on the next tick. A gap of a minute or more looks like a stall to the watchdog, which
  acts on the `watchdog` setting (a reload still waits until you've been idle for 30 s).

