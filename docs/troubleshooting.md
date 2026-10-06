# Troubleshooting

Symptoms and fixes, Swarm's logs, and how to uninstall. Back to the [README](../README.md). Swarm's
data folder and state files are listed in [How it works](how-it-works.md#where-swarm-keeps-its-state).

## Symptoms and fixes

| Symptom | Cause | Fix |
|---|---|---|
| A log line, block reason or error says `omp was not found in …` (or `git` or `gh`); roles never load | Background commands search only a short list of folders | Add the program's folder to `bin_dirs` (Settings › Machine › Programs) |
| Open board says `Swarm needs a pane inside a non-bare git repository` in a real repository | `git` isn't on Swarm's search path | Add git's folder to `bin_dirs` |
| A toast says `Swarm can't use this pane` | The focused pane is on a remote host | Focus a pane on this machine |
| Nothing starts and the panel lists what the repository runs | The repository waits for your approval, or its settings changed since you approved them | Read the list and click **Approve** (see [Repository approval](configuration.md#repository-approval)) |
| Approve, or dragging to Done, says `Swarm: can't ship …` | The repository waits for your approval, or `.tern/swarm.json` is broken with no earlier valid settings | Approve the repository in the panel, or fix the file |
| A task returns to Review with a shipping error at the `push` or `pr` step | gh isn't signed in or can't push | Run `gh auth status` and `gh auth login`. Click **Log** for the full output, then Approve again |
| Tasks start from the wrong branch | With `base` unset, the remote has no default-branch ref, so Swarm used the branch checked out in the repository | Run `git remote set-head <remote> --auto` with your `remote` setting (`origin` by default), or set `base` |
| A task is blocked with `Could not resolve a base branch` | No `<remote>/HEAD` and a detached `HEAD` | Same as above |
| A task is blocked with `Unknown omp role` | The card's `#role-` tag or `default_role` names a role omp doesn't have | Fix the tag or `default_role`, or add the role to omp, then Retry |
| A task is blocked with `The card's #role-… tag isn't a valid omp role name` | The tag's name has characters other than letters, digits, `_` and `-` | Fix the tag, then Retry |
| Checks never pass | The command fails in the worktree, or runs out of time | Click **Log**. Run the command yourself in the task's shell. Raise `timeouts.checks`. Set `agent_runs: false` on slow suites. Jobs use your shell's `PATH` and Node version |
| A task stays `queued` | Pickups are paused, the project or machine limit is reached, the repository waits for your approval, or `.tern/swarm.json` is broken | Check the panel header for `paused`, the approval card and settings problems. Raise `max_concurrent` or `max_concurrent_total` |
| A task is `waiting` with `The agent opened … in its tab` | The agent (or you) opened another pane in the task's tab while the agent worked | Click **Focus** to see it. Close the pane when you're done; the task returns to `running` |
| A task stays in `preparing`, `running` or `checking` | Setup or checks are still running, or the agent is still working (up to `max_time`) | Focus its tab. Park or Retry it. Read `task.json` and the latest job log |
| A task is blocked with `The task's shell is busy…` | Something else is running in the task's shell | Finish it or press Ctrl-C in that shell, then Retry |
| The panel stops updating, or a toast says `Swarm is stalled` | Tern disabled one of Swarm's hooks after it ran over its time budget | Run **Reload plugins** from the palette. With `watchdog: "reload"`, Swarm does it once you've been idle for 30 s. See `watchdog` and [Known limitations](how-it-works.md#known-limitations) |
| A toast says `Swarm didn't finish starting` | Tern disabled Swarm's loader while it was loading a module (the log names it) | Run **Reload plugins** from the palette. If it keeps happening, look for `swarm: loading … took` lines (below) |
| A task is blocked with `task.json is damaged (…)` | Its `task.json` isn't valid JSON, names another slug or project, has an unknown status, or was written by a newer Swarm | Swarm leaves the file alone and copies it once to `task.json.corrupt` beside it. Fix `task.json` and the task comes back within a few seconds. Or delete it: within a few seconds its card becomes a fresh task in Backlog. The old worktree and branch stay on disk, no longer linked |
| The panel says `Swarm's projects.json is damaged` | `projects.json` and its backup `projects.json.bak` are both unreadable, or `projects.json` was written by a newer Swarm | Fix or delete `projects.json`. Until then Swarm never writes it, keeps the projects it read earlier in this session, and Open board fails with `Swarm can't register this repository` |
| Nothing happens for a minute or more while Tern sits in the background, then everything catches up | Tern can run a window's timers late while the app is idle in the background (40–90 s has been seen on macOS) | Focus Tern or run any `tern` CLI command to wake it. Swarm catches up on the next tick. See [Known limitations](how-it-works.md#known-limitations) |

## Logs

Tern's logs are in `~/Library/Logs/Tern` on macOS and `~/.local/state/tern/logs` on Linux.
Swarm's orchestrator runs in the window and logs to `tern.log`. The New task and Settings blocks run
in the session daemon and log to `tern-daemon.log`. Swarm's lines start with `swarm:`; budget trips
contain `exceeded`. Lines worth knowing:

| Line | Meaning |
|---|---|
| `swarm: startup stalled while loading ./lib/<module>` | Loading stopped at that module, usually because Tern disabled the loader after a step ran over 50 ms. Logged on the first window focus at least 20 s after Swarm started loading |
| `swarm: loading ./lib/<module> took <n> ms` | Loading one module took 15 ms or more. Repeated lines on an idle machine mean the module is close to the budget |
| `swarm: <what> of <project id> took <n> ms` | A step took more than 25 ms (wall-clock, the clock Tern's budgets use). `<what>` is `tick`, `load`, `publish`, `panel redraw`, `reconcile`, `reconcile slice`, `reconcile tail slice` or `reconcile tail`; tick and publish say `of all`. `load` is one project's tasks loading at startup |
| `swarm: projects.json was damaged; restored it from projects.json.bak` | `projects.json` couldn't be read and Swarm restored the backup |
| `swarm: projects.json is damaged; Swarm won't change it until you fix or delete it` | Neither file could be used (see the table above) |
| `swarm: task.json is damaged` | Followed by the project id, slug and reason. Logged once per file per session |

By default only warnings and errors are logged. To also see each task's status changes, quit Tern and
start it from a terminal with this variable set:

```sh
export STENCIL_LOG=warn,stencil=info,tern::plugin=debug
```

The session daemon keeps the environment it started with, so host-half logging changes only after the
daemon restarts.

## Uninstall

1. Stop Swarm's work first. Pause pickups (**Swarm: Pause or resume pickups**), Park every
   preparing, running, checking, waiting and review task, and let shipping and discarding tasks
   finish. Agents and jobs run in their own panes and keep running after the plugin is gone. Then
   remove the plugin:

   ```sh
   tern plugin remove swarm      # an installed copy
   tern plugin unlink swarm      # a linked clone
   ```

2. Delete Swarm's data folder. Tern keeps it after removal.

   ```sh
   rm -rf ~/Library/Application\ Support/Tern/plugin-data/swarm   # macOS
   rm -rf ~/.local/state/tern/plugin-data/swarm                   # Linux
   ```

3. In each repository you used, remove the worktrees and branches Swarm left:

   ```sh
   git worktree list                    # worktrees are in ../<repo>-swarm/ by default
   git worktree remove --force <path>
   git branch --list 'swarm/*'          # or your branch_prefix
   git branch -D <branch>
   ```

4. Delete `.tern/swarm.json` from each repository if you don't want to keep it. Pushed branches and
   open pull requests stay on the remote.

