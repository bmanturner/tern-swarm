# Changelog

All notable changes to Swarm are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## 0.1.0 - Unreleased

First public release.

### Added

- **Board.** A Kanban board per repository with the lanes `Backlog`, `Ready`, `Doing`, `Blocked`,
  `Review` and `Done`. Swarm adopts hand-written cards (see `adopt_cards`) and tags them
  `#swarm-<slug>`. Moving a card yourself parks, starts, approves or closes its task. Deleting a
  card cancels the task.
- **Tasks.** Create tasks from the New task form, from cards on the board, or through Carly. A
  `#role-<name>` tag picks the omp model role; a tag whose name isn't letters, digits, `_` and `-`
  blocks the task at pickup.
- **Repository approval.** Swarm runs nothing in a repository until you approve what it will run:
  the project file's `setup`, `checks`, `env`, `agent_args`, `roles`, `instructions`, `base`,
  `remote`, `worktree_dir` and `on_checks_pass: "ship"`, plus checks detected from `package.json`
  and the automatic `npm ci`. The panel lists these items with an **Approve** button. Approval is
  saved per repository path on this machine (`trust` in `kv.json`), and Swarm asks again when any
  item changes. Your own edits on the Settings page keep an approved repository approved.
- **Worktrees.** Each task gets its own git worktree and branch (`swarm/<slug>` by default), created
  with omp or with plain `git worktree add` (see `worktree_tool`).
- **omp agents.** Each task runs an omp agent in its own tab, above a shell pane. Tabs get short
  names and a status glyph. Agents get a generated prompt with the task, the workspace rules, the
  checks and any project or personal instructions. The prompt says nobody watches the pane and
  forbids interactive UI. An agent that opens another pane in its tab while working shows as
  `waiting`, and **Focus** goes to that pane.
- **Agent arguments.** Your own `agent_args` win over a project's. A project's `agent_args` (and a
  role's) can't contain approval or omp config flags (`--approval-mode`, `--yolo`, `--auto-approve`,
  `--plan-yolo`, `--plan-yolo-into`, `--config`). The approval arguments always come from your list,
  else the default `--approval-mode yolo`, and go before a project's or role's arguments.
- **Checks.** Setup and check commands run as shell jobs in the task's shell pane, with per-step
  status and logs. Checks are detected from `package.json` when none are configured. Failures go
  back to the same agent until `max_attempts` is reached, then the task is blocked.
- **Review and approve.** The Swarm panel shows tasks that need you, tasks in review (changed
  files, check results, the agent's summary), running tasks, the queue and recent Done tasks. From
  there you can approve, retry, park or discard a task, open its diff, log or details, and pause
  pickups for one project.
- **Shipping.** Approve either commits, pushes and opens a pull request with `gh` (`ship: "pr"`),
  or only commits on the task branch (`ship: "commit"`). The commit message, PR title, draft state,
  reviewers, labels and assignees are configurable. Tasks can ship automatically when checks pass
  (`on_checks_pass` or the `#auto-ship` tag). Untracked and ignored files a new worktree starts with
  (such as a copied `.env` or `node_modules`) are recorded and never committed.
- **Settings.** A Settings page (**Swarm: Settings**, or the panel's **Settings** button) edits two
  layers: the project file `<repo>/.tern/swarm.json` and your own `settings.json` in Swarm's data
  folder. Every key is validated, and problems show in the panel. Changes apply on the next
  orchestrator tick.
- **Carly exports.** `open_board`, `add_task`, `list_tasks` and `task_action`, plus a short request
  context about active tasks. `carly.actions` (default `retry` and `park`) and `carly.context` limit
  what Carly can do and see; a repository's `carly.actions` can only narrow the actions, never widen
  them past your own list or the default. `add_task` puts tasks in Backlog unless `start = true` and
  returns the task's slug. `task_action` fails at once when the task's status doesn't allow the
  action or the project is held. `list_tasks` returns `{tasks, truncated}`.
- **Watchdog.** Notices when the orchestrator stops answering, for example after Tern disabled a
  hook that ran over its time budget. By default it reloads plugins once you've been idle for 30 s
  (or 15 minutes after a window focus first saw the stall), at most once every 10 minutes (see
  `watchdog`). A stalled startup is reported with a toast on the next window focus.
- **Clean up.** **Swarm: Clean up finished worktrees** (or the panel's **Clean up** for one project)
  removes the worktrees of finished tasks and archives them. `clean.auto` can remove worktrees right
  after shipping or once the pull request is merged or closed. A shipped task's worktree with
  uncommitted changes or commits made after shipping is kept and listed in the panel's Done section;
  its **Discard** removes the worktree and keeps the branch.
- **Damaged state.** `projects.json` is backed up to `projects.json.bak` and restored from it. A
  damaged `projects.json` or `task.json` is never overwritten: the panel warns about the first, and
  the second shows as a blocked task (with a copy in `task.json.corrupt`) until you fix or delete it.
  Deleting it turns its card into a fresh Backlog task. `projects.json`, `task.json` and
  `snapshot.json` carry `"format": 1`.
- **Repositories.** Submodules and repositories with a separate git directory are their own
  projects, and Open board inside a submodule of a registered repository opens the submodule's
  board; linked worktrees resolve to their main repository. Panes on a remote host are refused.
  On iOS the window half does nothing.
- **Commands and status line.** Palette commands to open the board, add a task, go to the tasks
  needing attention, pause pickups, clean up, open Settings and edit the project config file. The
  status line summarizes running, blocked and review counts. **Swarm: Edit project config file**
  writes a starter file holding only the detected `checks`.
- **Time budgets.** Modules load one per timer callback; at startup the leader loads one project's
  tasks per tick; reconcile runs in slices that start work for up to 10 ms, 60 ms apart; the intent
  queue drains for at most 15 ms per tick; panels redraw over several timer calls. Slow loads and
  slow ticks, task loads, reconciles, publishes and panel redraws are logged as warnings.

## Versioning

- Bump `version` in `plugin.toml` with every release.
- Tag each release `vX.Y.Z`, matching `plugin.toml`.
- Users update with `tern plugin install github.com/bmanturner/tern-swarm --force`. `--force`
  replaces an installed copy; it never touches a linked one.
