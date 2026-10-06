# Tern Swarm

Swarm is a Tern plugin that turns a Kanban board into a queue of coding agents.

- Each card you put in **Ready** becomes a task.
- Each task gets its own git worktree (a second checkout of your repository on its own branch), so
  agents never touch your working copy.
- An [omp](https://omp.sh) coding agent works on the task, unattended, on the model role you chose.
  omp is a command-line coding agent; a role such as `@smol` or `@slow` names a model in your omp
  config.
- When the agent stops, Swarm runs your checks (type check, lint, tests). Failures go back to the
  same agent. Passing work waits in **Review**.
- In Review you approve the work (commit, push and open a pull request), retry it, or discard it.

Version 0.1.0. MIT licensed.

## Before you start

You need all of the following:

1. **Tern desktop**, running with at least one window open. The orchestrator runs inside a Tern
   window; when every window is closed, nothing moves. Swarm is tested with Tern 0.5.2 on macOS.
2. **omp**, installed and signed in to a model provider. Check it with `omp -p hi`.
3. **omp model roles.** List them with `omp config get modelRoles --json`. Swarm offers every role
   except `commit`, `memory`, `tiny`, `vision`, `advisor`, `dictation` and `speech`. Tasks without a
   role tag run on `default_role` (default `default`), so that role must exist or you must change the
   setting. Tab names use omp's `@tiny` role (see `tabs.names`).
4. **A non-bare git repository with at least one commit.** Swarm branches from `base` when it's
   set, else from the remote's default branch, else from the branch checked out in the repository.
   The default `ship: "pr"` needs a remote (`origin` unless you set `remote`). Check that
   `git symbolic-ref refs/remotes/origin/HEAD` prints a branch. If it fails, run
   `git remote set-head origin --auto`, or set `base`. With `ship: "commit"`, no remote is needed.
5. **gh**, signed in with push rights (`gh auth login`, check with `gh auth status`). Only needed when
   `ship` is `"pr"` (the default) or `clean.auto` is `"after_merge"`. Clean up also asks gh for the
   state of a shipped task's PR.
6. **Programs on a path Swarm searches.** Swarm's background commands (worktrees, roles, tab names,
   PR state) look for `omp`, `git` and `gh` in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
   `/usr/bin` and `/bin`. If yours live elsewhere (for example `~/.bun/bin` or mise shims), add the
   folder to `bin_dirs`. Agents and jobs run in your interactive shell and use its `PATH`.

Read [Security and trust](#security-and-trust) before you open a board for a repository. Swarm runs
nothing in a repository until you approve what that repository makes it run (see
[Repository approval](#repository-approval)).

## Install

```sh
tern plugin install github.com/bmanturner/tern-swarm
```

Tern copies the package into its plugins folder and reloads. Check it with `tern plugin list`.

To update, install again with `--force`:

```sh
tern plugin install --force github.com/bmanturner/tern-swarm
```

To work on Swarm itself, clone the repository and link it instead. Tern then loads the plugin from
your clone and reloads it every time you save a file. Update a linked copy with `git pull`.

```sh
git clone https://github.com/bmanturner/tern-swarm
tern plugin link ./tern-swarm
```

## Quick start

1. Install Swarm (see [Install](#install)).
2. Focus a terminal pane inside a git repository that has a remote.
3. Run **Swarm: Open board** (`ctrl+alt+shift+k`). The board opens in a tab, and the **Swarm panel**
   opens below it.
4. If the panel shows **Swarm runs nothing in this repository until you approve what it will run**,
   read the list and click **Approve**. A repository with nothing to run (no `.tern/swarm.json`, no
   detected checks, no `package-lock.json`) doesn't ask.
5. Run **Swarm: New task…** (`ctrl+alt+shift+n`). Type a title, for example
   `Add a CONTRIBUTING.md with setup steps`, and press `⌃↵`. The task goes to **Ready**.
6. Within a few seconds a new tab opens with the agent above a shell. The card moves to **Doing**.
7. When the agent finishes, the checks run in the shell. Passing work moves the card to **Review**.
8. In the panel's **Review** section, click **Diff** to read the change, then **Approve**. Swarm
   commits, pushes and opens a pull request.

To commit without pushing or opening a pull request, set `"ship": "commit"` (see [Settings](#settings)).

## How a task flows

1. **Queued.** A card in **Ready** is a queued task. Swarm stamps it with a `#swarm-<slug>` tag.
2. **Pickup.** About every 3 s, Swarm starts queued tasks in board order while a slot is free. Limits:
   `max_concurrent` per project and `max_concurrent_total` across projects. Nothing starts while
   pickups are paused, globally or for this project, or while the repository waits for your
   approval (see [Repository approval](#repository-approval)). When `.tern/swarm.json` is broken,
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
   `agent_args` in [Settings](#settings) for where the arguments come from. The prompt tells the agent
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
6. **Review.** You approve, retry or discard it. See [Review and approve](#review-and-approve).
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
- **Ask Carly.** Carly's tasks go to Backlog unless it passes `start = true`. See [Carly](#carly).

## Repository approval

A repository's settings can make Swarm run commands and tell agents what to do. Swarm runs nothing in
a repository until you approve what it will run there.

**What needs approval.** Only values from the repository itself count:

- `.tern/swarm.json` values of `setup`, `checks`, `env`, `agent_args`, `roles`, `instructions`,
  `base`, `remote` and `worktree_dir`, and `on_checks_pass: "ship"`;
- checks detected from `package.json`;
- the automatic `npm ci` when the repository has `package-lock.json` and no `setup`.

A repository with none of these needs no approval. Your own `settings.json` never needs approval.

**The approval card.** Until you approve, the panel header shows a card that lists each item, for
example `Setup: npm ci (automatic: the repository has package-lock.json)` or
`Check test: npm run test (from package.json)`. **Approve** records your approval; **Open
swarm.json** opens `.tern/swarm.json` beside the panel when it exists.

**While a repository waits for approval:**

- queued tasks don't start;
- a task in `preparing` stops before its next step, and a task in `checking` doesn't start its checks
  job;
- nothing ships: Approve, dragging to Done and automatic shipping are refused with an error toast;
- agents that already run keep working.

**When Swarm asks again.** Swarm stores the approved list per repository path on this machine, in
`kv.json` under `trust`. When any item changes (a teammate's commit, your hand edit, a new check
script in `package.json`), the card comes back and work stops as above. Swarm notices a hand edit
once its cached settings expire, a little over 30 s later. A change you make on the Settings page
keeps an approved repository approved.

Approval covers the commands as written, such as `npm run test`, not what the scripts they call do.

## Lanes

The board has six lanes. Swarm moves cards to match each task's status. You can also drag cards
yourself.

| Lane | What's in it | What happens when you drag a card here |
|---|---|---|
| Backlog | Not started, parked, or being discarded | A queued task goes back to backlog. A preparing, running, checking, waiting, blocked or review task is parked: its agent stops and its worktree stays |
| Ready | Queued for an agent | A backlog task is queued. A parked, preparing, running, checking, waiting, blocked or review task is restarted with a fresh agent in its existing worktree. A shipping or discarding task is left alone and the card moves back |
| Doing | Preparing, agent running, checks running | Nothing; Swarm moves the card back |
| Blocked | Waiting for your input, or blocked | Nothing; Swarm moves the card back |
| Review | Waiting for you, or shipping | Nothing; Swarm moves the card back |
| Done | Shipped or closed | Depends on `on_move_to_done`. By default, a task in Review ships, and any other task is closed |

Deleting a card cancels its task after two complete board reads (about 6 s) that don't find it.
Cancelling waits while an operation is running or the task is being discarded, and it is off while the
board can't be read in full. Shipped and closed tasks are never cancelled this way. A cancelled task
keeps its worktree until Clean up. Putting its card back (with its `#swarm-` tag) in Backlog or Ready
before Clean up archives it revives the task.

While a shipped task's kept worktree is being discarded, its card stays in Done.

## Review and approve

A task in **Review** has a card in the panel's Review section. It shows:

- a folded **Context** card: branch, base, how it ships (pull request or commit only), the names of
  the checks recorded for this task, and the task's details. With no recorded results (for example a
  task that changed nothing), the checks row says `none configured`;
- the first 10 changed files with added and removed line counts. Use **Diff** to see the whole change;
- the check results;
- the agent's summary (its final message);
- a shipping error, when the last Approve failed.

Its buttons:

| Button | What it does |
|---|---|
| **Approve** | Ships the task (below) |
| **Diff** | Opens a git block on the worktree |
| **Log** | Opens a log of the latest job beside the panel: the failing step's log, or the first log when no step failed. Steps are taken in alphabetical order, not run order |
| **Details** | Opens the task's `details.md`. Edit it before Retry to give the next agent more instructions |
| **Focus** | Focuses the agent's tab, or the pane the agent opened there (see [Agent skills](#agent-skills)) |
| **Retry** | Stops the agent and starts a fresh one in the same worktree. The new agent gets a resume prompt telling it to review `git status` and `git diff` first. The attempt count restarts |
| **Discard** | Two clicks. Stops the agent, deletes the worktree and, unless `discard.delete_branch` is `false`, the branch. The task returns to Backlog |

You can also type into the agent's tab. When the agent starts working again, the task goes back to
**running**, and the checks run again when it stops.

**What Approve runs.** Swarm writes a job script to the task's `jobs/<n>-ship/` folder and runs it in
the task's shell, with the `env` variables exported. The steps are:

```sh
git add -A [--pathspec-from-file=<job>/add-pathspec.txt] \
  && (git diff --cached --quiet || git commit -q -F <job>/commit-msg.txt) \
  && git rev-parse --short HEAD > <job>/commit
# with ship: "pr" only:
git push -u <remote> <branch>
gh pr view <branch> --json url -q .url \
  || gh pr create --base <base> --head <branch> --title <pr.title> --body-file <job>/pr-body.md \
       [--draft] [--reviewer …] [--label …] [--assignee …]
```

- `git add -A` stages every file in the worktree that `.gitignore` doesn't exclude, except the files
  Swarm recorded when it created the worktree. When there are any, `add-pathspec.txt` excludes each
  of them (`:(exclude,literal)<path>`); a recorded folder is excluded with everything in it, including
  files the agent added there. Scratch files the agent left behind are committed. Read the file list
  before you approve.
- The commit message is `commit.message` with its placeholders filled in.
- `<base>` is the task's base branch without the `<remote>/` prefix (`main` when unknown).
- When a pull request for the branch already exists, Swarm reuses it.
- The PR body is the task's details, then `## Summary` (the agent's summary), then `## Checks` (one line
  per check with its result and duration), then a footer with the role, attempts and branch.

When the job succeeds, the task becomes **shipped**. Swarm closes its agent and shell tabs, adds
`· PR <n>` to the card text, and lists the task in the panel's Done section with its PR link. When a
step fails, the task returns to **Review** with the error. Fix the cause and click Approve again.

With `ship: "commit"`, Approve only commits. The branch stays local.

While `.tern/swarm.json` is broken and Swarm has no earlier valid settings, or while the repository
waits for your approval, Approve is refused with an error toast.

## Panel

**Swarm: Open board** opens the panel next to the board (see `layout.panel`). It shows one project.

The header has:

- counts: running, need you, to review, queued, and `paused` or `all paused`;
- buttons:
  - **New task**;
  - **Settings**;
  - **Pause**, which stops pickups in this project only. It shows **Resume** while this project is
    paused, and **Resume all** while the palette command has paused every project. **Resume all**
    clears only that global pause; a project you paused on its own stays paused;
  - **Clean up**, shown when the project has finished tasks. It cleans this project only;
- the settings problems of this project, with an **Open Settings** button;
- the approval card, while the repository waits for your approval (see
  [Repository approval](#repository-approval));
- a warning when Swarm can't read the whole board. A lane with more than 500 cards, the read's
  64,000-character limit, or a read that stops paging early can leave cards unread. Swarm doesn't
  notice deleted cards until it can read the whole board again;
- at the very top, a warning when Swarm's `projects.json` is damaged (see
  [Troubleshooting](#troubleshooting)).

Pausing stops pickups only. Running agents keep working.

The sections:

| Section | Tasks | Buttons on each task |
|---|---|---|
| Needs you | waiting and blocked, with the reason | Focus, Log, Details, Retry, Discard |
| Review | review and shipping | See [Review and approve](#review-and-approve). While a task ships, only Diff and Focus |
| Running | preparing, running, checking, with role, attempt and elapsed time | Focus, Park |
| Up next | queued, with the role each will run on | none |
| Backlog | backlog, parked and discarding | none |
| Done | the 8 most recently shipped or closed tasks, with PR links. Below them, every shipped task whose worktree Swarm kept, with the reason | **Discard** (two clicks) on a kept worktree: removes the worktree, keeps the branch, and the task stays shipped |

The status line shows `Swarm 2 running · 1 need you · 3 to review` while there's work, plus `paused`
or `1 project paused`. Click it to run **Swarm: Go to tasks needing attention**.

## Commands

| Command | Keys | What it does |
|---|---|---|
| **Swarm: Open board** | `ctrl+alt+shift+k` | Registers the focused pane's repository and opens its board and panel. A linked worktree resolves to its main repository; a submodule or a repository with a separate git directory is its own repository |
| **Swarm: New task…** | `ctrl+alt+shift+n` | Opens the New task form for the focused repository's project. Run Open board there first |
| **Swarm: Go to tasks needing attention** | | Opens the project with the most tasks needing you. Ties go to the most tasks in review, then running, then queued. With nothing pending, opens the focused repository's board |
| **Swarm: Pause or resume pickups** | | Pauses pickups in every project, or lifts that pause. Projects paused with their panel's **Pause** stay paused. Running agents continue |
| **Swarm: Clean up finished worktrees** | | Runs Clean up in every project. See [Known limitations](#known-limitations) for what it skips and deletes |
| **Swarm: Settings** | | Opens the Settings page. Project pages appear when the focused pane is inside a registered project (or only one project is registered) |
| **Swarm: Edit project config file** | | Opens `<repo>/.tern/swarm.json`. When the file doesn't exist yet, it first writes a starter file (see below) |

The starter file holds only `checks`: the checks detected from `package.json` (`[]` when none). It
never adds defaults or your personal settings. Writing the checks into the file makes them the
project's `checks`, so later `package.json` changes no longer change them.

Commands that use the focused pane refuse a pane on a remote host with the toast
`Swarm can't use this pane`.

## Settings

**Swarm: Settings**, or the panel's **Settings** button, opens a settings page that edits two files:

| Scope | File | Applies to |
|---|---|---|
| project | `<repo>/.tern/swarm.json`. Commit it to share settings with your team | That repository |
| you | `settings.json` in Swarm's data folder (see [Troubleshooting](#troubleshooting)) | Every project |

A key marked **both** can be set in either file. A key marked **project** or **you** can only be set
in that file; elsewhere it is reported and ignored.

**Which value wins.** For a `both` key, the project file wins over your settings, which win over the
built-in default. A card tag wins over both for the keys it affects (see [Card tags](#card-tags)).
Exceptions:

- `worktree_dir` and `agent_args`: your setting wins over the project's.
- `instructions`: both are added to the prompt, yours first.
- `carly.actions`: when both files set it, Carly may only do what both allow. When only your settings
  set it, your list applies. When only the project file sets it, Carly may only do what both that
  list and the default (`retry` and `park`) allow, so a repository can narrow Carly but never widen
  it. When neither does, the default applies.
- `tabs.names`: the more private choice wins (`off` > `slug` > `keywords` > `model`).

**When changes apply.** A change made on the Settings page applies on the next orchestrator tick,
about 3 s later. A hand edit applies once Swarm's cached copy expires: a little over 30 s for the
project file, and up to about a minute for your personal values. A change affects later decisions;
it doesn't restart a running agent or job.

**Problems.**

- An invalid value counts as not set in its file, so the merge rules above pick the value: usually
  the other file's, else the default. An invalid `checks` falls back to the detected checks. The panel
  reports each problem as `<file>: <key> <problem>; using <fallback>`, where `<file>` is
  `swarm.json` or `settings.json`.
- An invalid `ship` falls back to `"commit"`, so a typo never opens pull requests.
- Unknown keys are reported. At the top level and inside groups such as `pr`, `clean` and `timeouts`,
  keys starting with `_`, and `$schema`, are ignored, so you can use `_` keys as comments there. Inside
  `roles` and `env` they are not: a role accepts only `max_time` and `agent_args`, and an `env` key
  such as `_comment` is exported as a variable.
- When `.tern/swarm.json` stops parsing, Swarm keeps using the last valid settings it saw since Tern
  loaded it. Without any (for example after a restart), nothing new starts or ships until the file is
  fixed.
- A project `agent_args` containing `--approval-mode`, `--yolo`, `--auto-approve`, `--plan-yolo`,
  `--plan-yolo-into` or `--config` (or `--approval-mode=…`, `--plan-yolo-into=…`, `--config=…`) is
  invalid: only your own settings choose the approval mode and load omp config overlays. In a role's
  `agent_args`, one of these makes the whole `roles` value invalid.
- When `settings.json` stops parsing, Swarm ignores all your personal values and reports it.

**Value format.** Both files are JSON objects. Write values as JSON literals. A dotted key is a nested
object: `pr.draft` is `{"pr": {"draft": true}}`. A list of strings means a JSON array of strings.

**Durations.**

- `timeouts.*` need a unit: a whole number greater than 0 followed by `s`, `m` or `h`, such as
  `"90s"`, `"30m"` or `"2h"`.
- `max_time` and `roles.<r>.max_time` also accept a bare whole number such as `"45"`. Swarm passes it
  to `omp --max-time` unchanged, and omp reads a bare number as seconds. The Settings page shows it as
  seconds rounded up to whole minutes. Prefer an explicit unit.
- Durations are JSON strings, never JSON numbers.

### Agent

| Key | Scope | Default | Allowed values | Meaning |
|---|---|---|---|---|
| `default_role` | both | `"default"` | Letters, digits, `_` and `-` (`^[%w_%-]+$`) | omp role for cards without a `#role-` tag. The panel reports a name that isn't an omp role |
| `max_time` | both | `"45m"` | Duration; a bare number is allowed (see above) | `omp --max-time` for each agent |
| `max_attempts` | project | `3` | Whole number 1–20 | Agent turns, counting check-failure feedback rounds, before the task is blocked |
| `agent_args` | both (yours wins) | `["--approval-mode", "yolo"]` | List of strings. Each entry is one argument of letters, digits and `-_=.:/@` (`^[%w%-_=.:/@]+$`); no spaces, `~`, `,` or `*`. A project's list can't contain approval or config flags (see above) | omp arguments for every agent. Yours **replaces** the default and every project's list: if you leave out `--approval-mode yolo`, agents stop to ask for approval. A project's list is added after the approval arguments, which come from your list (its `--approval-mode`, `--yolo`, `--auto-approve`, `--plan-yolo`, `--plan-yolo-into` and `--config` flags with their values), else the default `--approval-mode yolo` |
| `instructions` | both | not set | A string of at most 8000 bytes (non-ASCII characters take more than one), or a list of strings (each becomes a `- ` bullet line) | Added to every agent prompt after Swarm's workspace rules: yours under `## Personal instructions`, the project's under `## Project instructions`. Each is cut to 8000 characters in the prompt, so a long list is truncated |
| `roles` | project | `{}` | Object: role name (`^[%w_%-]+$`) → `{ "max_time"?, "agent_args"? }`, each checked like the top-level key | Per-role overrides, e.g. `{"slow": {"max_time": "2h"}}`. A role's `agent_args` replace the merged `agent_args` (yours too), but the approval arguments still come first |
| `max_concurrent` | both | `3` | Whole number 1–32 | Tasks preparing, running or checking at once in this project |

### Checks and jobs

| Key | Scope | Default | Allowed values | Meaning |
|---|---|---|---|---|
| `checks` | project | Detected: the `type-check`, `typecheck`, `lint` and `test` scripts in the root `package.json`, each run as `npm run <name>` (a `test` script containing `no test specified` is skipped) | List of `{ "name", "run", "agent_runs"? }`. `name` and `run` are non-empty strings. `agent_runs` is a boolean, default `true` | Commands run in the task's shell after each agent turn. `agent_runs: false` tells the agent the orchestrator runs that check, so it doesn't need to. In `name`, every character other than letters, digits, `_` and `-` becomes `-`; two names that end up the same make `checks` invalid |
| `checks_mode` | project | `"all"` | `"all"`, `"fail_fast"` | `"fail_fast"` stops at the first failing check |
| `setup` | project | not set: `npm ci` when `package-lock.json` exists and `node_modules` doesn't | List of non-empty strings | Commands run once in a new worktree, before the agent starts. Setting it (even to `[]`) replaces the automatic `npm ci` |
| `env` | project | `{}` | Object: name (`^[%a_][%w_]*$`) → one-line string (no newline or NUL) | Variables exported in setup, check and ship jobs. Agents don't get them |
| `timeouts.setup` | project | `"20m"` | Duration with a unit | Time limit of a setup job |
| `timeouts.checks` | project | `"30m"` | Duration with a unit | Time limit of a checks job. When it runs out, Swarm interrupts the job and blocks the task |
| `timeouts.ship` | project | `"5m"` | Duration with a unit | Time limit of a ship job |

### Workflow

| Key | Scope | Default | Allowed values | Meaning |
|---|---|---|---|---|
| `adopt_cards` | both | `"backlog_and_ready"` | `"backlog_and_ready"`, `"backlog"`, `"off"` | Which hand-written cards become tasks: those in Backlog and Ready (Ready ones start right away), those in Backlog only, or none (tasks come only from New task and Carly) |
| `new_task.lane` | both | `"Ready"` | `"Ready"`, `"Backlog"` | Where the New task form's main button (`⌃↵`) puts tasks. Carly's `add_task` ignores it |
| `on_move_to_done` | both | `"approve"` | `"approve"`, `"approve_only"`, `"close"`, `"revert"` | Dragging a card to Done. `"approve"`: ships from Review, closes otherwise. `"approve_only"`: ships from Review, moves the card back otherwise. `"close"`: always closes, never ships. `"revert"`: always moves the card back; use Approve |
| `no_change` | project | `"block"` | `"block"`, `"review"`, `"done"` | When the agent changed nothing. `"block"`: blocks the task. `"review"`: sends it to Review without running checks; approving it closes it without a commit. `"done"`: closes it |
| `on_checks_pass` | project | `"review"` | `"review"`, `"ship"` | `"ship"` approves automatically when checks pass. It only applies when at least one check is configured (detected checks count) and the task changed something |
| `tabs.names` | both (the more private wins) | `"model"` | `"model"`, `"keywords"`, `"slug"`, `"off"` | Task tab names. `"model"` sends the task title to omp's `@tiny` role for a short name and uses the title's key words until it answers. `"keywords"` uses the title's key words, `"slug"` the task slug, and `"off"` leaves tab names alone (tabs are still colored) |
| `carly.actions` | both (see [Which value wins](#settings)) | `["retry", "park"]` | List with any of `"approve"`, `"retry"`, `"park"`, `"discard"` | Which `task_action` calls Carly may make |

### Git and pull requests

| Key | Scope | Default | Allowed values | Meaning |
|---|---|---|---|---|
| `base` | project | not set: `<remote>/HEAD`, else the branch checked out in the repository | A branch name like `"main"` or `"origin/main"`: letters, digits, `.`, `_`, `/` and `-`. No leading `-` or `/`, no `..` or `//`, no trailing `/`, `.` or `.lock` | Branch new worktrees start from. A base starting with `<remote>/` is fetched first |
| `remote` | project | `"origin"` | Letters, digits, `.`, `_` and `-` (`^[%w._-]+$`) | Remote to read the default branch from, fetch the base from, and push to |
| `branch_prefix` | both | `"swarm/"` | Letters, digits, `.`, `_`, `/` and `-`, or empty. No `..` or `//`, no leading `/` or `-`, no trailing `.lock` | Prefix of task branches |
| `worktree_tool` | both | `"omp"` | `"omp"`, `"git"` | `"omp"` creates worktrees with `omp worktree add`, which is clone-first when omp's `worktree.clone` setting is on (copies `node_modules` and `.env*` files), and falls back to `git worktree add` when omp fails. `"git"` always uses plain `git worktree add` |
| `worktree_dir` | both (yours wins) | `"../{repo}-swarm"` | Non-empty string. Yours must contain `{repo}` | Folder for worktrees, relative to the repository. `{repo}` is the repository's folder name, and a leading `~/` is your home folder |
| `ship` | project | `"pr"` | `"pr"`, `"commit"`. Anything else means `"commit"` | What Approve does: `"pr"` commits, pushes and opens a pull request; `"commit"` only commits |
| `commit.message` | project | see below | At most 2000 bytes, with a non-empty first line. The only placeholders are `{title}`, `{slug}`, `{role}` and `{branch}` | Commit message template |
| `pr.draft` | both | `false` | `true`, `false` | Open pull requests as drafts |
| `pr.title` | project | `"{title}"` | One non-empty line of at most 200 bytes, same placeholders | Pull request title template |
| `pr.reviewers` | project | `[]` | List of users or teams (`^@?[%w._/-]+$`, e.g. `"octocat"`, `"org/team"`) | `gh pr create --reviewer` |
| `pr.labels` | project | `[]` | List of non-empty labels without `,` or newlines | `gh pr create --label` |
| `pr.assignees` | project | `[]` | List of users (`^@?[%w._/-]+$`, e.g. `"@me"`) | `gh pr create --assignee` |

The default `commit.message` is:

```text
{title}

Swarm-Task: {slug}
Swarm-Role: {role}
```

`{role}` is `default` when the task has no role.

### Cleanup

| Key | Scope | Default | Allowed values | Meaning |
|---|---|---|---|---|
| `discard.delete_branch` | both | `true` | `true`, `false` | Discard also deletes the task's branch |
| `clean.auto` | both | `"manual"` | `"manual"`, `"after_ship"`, `"after_merge"` | When worktrees are removed without Clean up. `"after_ship"`: right after shipping (the branch stays). `"after_merge"`: once the PR is merged or closed, checked at most every 5 minutes (the branch is deleted). Neither removes a worktree that holds work made after shipping (see [Known limitations](#known-limitations)). A later Clean up still archives the task |
| `clean.remove_done_cards` | both | `false` | `true`, `false` | Clean up also deletes the Done cards of the tasks it archives |

### Your machine and interface

These keys can only be set in your `settings.json`.

| Key | Scope | Default | Allowed values | Meaning |
|---|---|---|---|---|
| `max_concurrent_total` | you | not set (no limit) | Whole number 1–64 | Tasks preparing, running or checking at once across all projects. Projects compete first come, first served |
| `layout.panel` | you | `"below"` | `"beside"`, `"below"`, `"tab"`, `"none"` | Where **Open board** puts the panel. `"none"` doesn't open it |
| `carly.context` | you | `"all"` | `"all"`, `"attention"`, `"off"` | What Carly's request context says about tasks: everything, only tasks needing you and in review, or nothing |
| `bin_dirs` | you | `[]` | List of absolute folders; a leading `~/` is expanded | Extra folders searched first for `omp`, `git` and `gh` in background work. Agents and jobs use your shell's `PATH` |
| `watchdog` | you | `"reload"` | `"reload"`, `"notify"`, `"off"` | What Swarm does when Tern has disabled one of its hooks. `"reload"` reloads all plugins once you've been idle in Tern for 30 s (or 15 minutes after a window focus first saw the stall), at most once every 10 minutes, and tells you in the meantime. `"notify"` only tells you. `"off"` only writes a log line |

### Example project file

A complete `.tern/swarm.json` for a pnpm monorepo. Every key is optional; leave out what you don't
need.

```json
{
  "_comment": "Keys starting with _ are ignored.",
  "base": "origin/main",
  "remote": "origin",
  "setup": ["pnpm install --frozen-lockfile", "pnpm run build:packages"],
  "checks": [
    { "name": "typecheck", "run": "pnpm run typecheck" },
    { "name": "lint", "run": "pnpm run lint" },
    { "name": "e2e", "run": "pnpm run test:e2e", "agent_runs": false }
  ],
  "checks_mode": "all",
  "env": { "CI": "true" },
  "timeouts": { "setup": "20m", "checks": "45m", "ship": "5m" },
  "max_attempts": 3,
  "roles": { "slow": { "max_time": "2h" } },
  "instructions": ["Use pnpm, never npm.", "Keep each change small and focused."],
  "adopt_cards": "backlog",
  "on_move_to_done": "approve_only",
  "no_change": "review",
  "on_checks_pass": "review",
  "branch_prefix": "agent/",
  "worktree_tool": "git",
  "ship": "pr",
  "commit": { "message": "{title}\n\nSwarm-Task: {slug}" },
  "pr": {
    "draft": true,
    "title": "[agent] {title}",
    "reviewers": ["octocat"],
    "labels": ["agent"],
    "assignees": ["@me"]
  },
  "discard": { "delete_branch": true },
  "clean": { "auto": "after_merge", "remove_done_cards": false },
  "tabs": { "names": "keywords" },
  "carly": { "actions": ["retry", "park"] }
}
```

What it does:

1. Every task branches from `origin/main` and pushes to `origin`.
2. A new worktree runs `pnpm install` and builds the packages before the agent starts.
3. Three checks run after each agent turn. The agent is told it doesn't need to run `e2e`.
4. `CI=true` is exported in every setup, check and ship job.
5. Agents on the `slow` role get two hours; other roles use your `max_time` or the default.
6. Two bullet lines are added to every prompt.
7. Only cards typed into Backlog are adopted. Dragging to Done ships from Review only.
8. A task that changes nothing goes to Review instead of being blocked.
9. Branches are named `agent/<slug>` and worktrees are made with plain git.
10. Pull requests open as drafts with a reviewer, a label and you as assignee.
11. Worktrees go away once their PR is merged or closed.
12. Tab names never go to a model, and Carly may only retry or park tasks here.

The first time you open its board, Swarm lists the setup commands, checks, `env`, roles,
instructions, base and remote this file sets and waits for your approval (see
[Repository approval](#repository-approval)).

`default_role`, `max_concurrent`, `max_time` and `new_task.lane` are left out on purpose, so each
teammate's personal values or the defaults apply. Setting them here would override those personal
values. `worktree_dir` and `agent_args` are left out too: a teammate's own value would win anyway. The
other `both` keys it sets are shared choices for this repository.

### Example personal settings

A complete `settings.json`:

```json
{
  "default_role": "default",
  "max_time": "30m",
  "max_concurrent": 2,
  "max_concurrent_total": 4,
  "agent_args": ["--approval-mode", "yolo", "--config", "/Users/me/.omp/agent/swarm-agent.yml"],
  "instructions": "Explain any trade-off you made in your final summary.",
  "worktree_dir": "~/swarm-worktrees/{repo}",
  "branch_prefix": "me/",
  "pr": { "draft": true },
  "clean": { "auto": "after_ship" },
  "tabs": { "names": "slug" },
  "layout": { "panel": "beside" },
  "carly": { "context": "attention", "actions": ["retry", "park"] },
  "bin_dirs": ["~/.bun/bin", "~/.local/share/mise/shims"],
  "watchdog": "notify"
}
```

The `--config` file is explained in [Agent skills](#agent-skills).

## Card tags

Tags are words starting with `#` in a card's text. They change one task. Tag names are
case-sensitive. Use at most one `#role-` tag per card: when a card has several, the first one counts.

| Tag | Effect |
|---|---|
| `#role-<name>` | Runs the task on that omp role instead of `default_role`. Swarm reads it each time the task is picked up, so editing it doesn't change a running agent; Retry to apply it. An empty name uses `default_role`. A name with characters other than letters, digits, `_` and `-` blocks the task at pickup |
| `#no-change-ok` | A task that changes nothing goes to Review instead of following `no_change` |
| `#auto-ship` | Ships as soon as checks pass, as `on_checks_pass: "ship"` does. Needs at least one check |
| `#draft` | Opens the task's pull request as a draft |
| `#swarm-<slug>` | Added by Swarm. It links the card to its task. Don't edit or remove it |

## Task statuses

Each task has a status, stored in its `task.json`. Carly's `list_tasks()` returns it too.

| Status | Lane | Meaning | What moves it out |
|---|---|---|---|
| `backlog` | Backlog | Not started | Dragging the card to Ready (→ `queued`) |
| `queued` | Ready | Waiting for a free slot | Pickup (→ `preparing`, or `blocked` for an unknown role or an invalid `#role-` tag); dragging to Backlog (→ `backlog`) |
| `preparing` | Doing | Creating the worktree, running setup, starting the agent | The agent starts (→ `running`); a failure (→ `blocked`) |
| `running` | Doing | The agent is working | The agent goes idle (→ `checking`), asks for input or opens a pane in its tab (→ `waiting`); the agent exits, its tab closes or it never starts (→ `blocked`) |
| `checking` | Doing | Swarm checks for changes, then runs the checks | Pass (→ `review` or `shipping`); a feedback round (→ `running`); out of attempts, a timeout or an interrupted job (→ `blocked`); no change with `no_change: "done"` (→ `closed`) |
| `waiting` | Blocked | The agent is asking you something in its tab, or it opened another pane there while working (a terminal, a plugin block, a browser…) and may be waiting for you | Answer in the tab, or close the opened pane while the agent works (→ `running`); the agent goes idle (→ `checking`); Retry, Park or Discard |
| `blocked` | Blocked | Something needs you; the panel shows the reason | Retry or drag to Ready (→ `queued`); Park; Discard |
| `review` | Review | Waiting for you. Checks passed, or none ran (no checks, or no change with `no_change: "review"`) | Approve (→ `shipping`); drag to Done (follows `on_move_to_done`; ships by default); Retry; Park; Discard; the agent working again (→ `running`) |
| `shipping` | Review | The ship job is running | Success (→ `shipped`); failure (→ `review` with the error) |
| `shipped` | Done | Committed, and pushed with a PR when `ship` is `"pr"`. Finished | Clean up archives it. When Swarm kept its worktree, Discard in the Done section removes the worktree (→ `discarding`, then back to `shipped`) |
| `closed` | Done | Finished without shipping (dragged to Done, or no change) | Clean up archives it |
| `parked` | Backlog | Stopped by you; the worktree stays | Retry or drag to Ready (→ `queued`, resumes in the worktree); Discard |
| `discarding` | Backlog | Removing the worktree, and the branch unless `discard.delete_branch` is `false`. For a shipped task's kept worktree, only the worktree, and the card stays in Done | Done (→ `backlog`, reset; a shipped task goes back to `shipped`); a failure (→ `blocked`; a shipped task goes back to `shipped` with the error as its kept reason) |
| `cancelled` | none | The card was deleted. Finished | Putting the tagged card back in Backlog or Ready (→ `backlog` or `queued`); Clean up archives it |

Common reasons for `blocked`:

- checks failed `max_attempts` times;
- setup failed;
- the worktree couldn't be created;
- the role is unknown, or the card's `#role-` tag isn't a valid role name;
- the agent exited (time limit or crash), its tab was closed, or it didn't start within 3 minutes;
- the task's shell stayed busy for 2 minutes, so a job couldn't start;
- the agent changed nothing (`no_change: "block"`);
- a discard couldn't remove the worktree;
- the task's `task.json` is damaged (see [Troubleshooting](#troubleshooting)).

## Carly

Carly is Tern's built-in assistant. Swarm gives it four functions. Call them from Carly with `await`,
for example `await(plugins.swarm.add_task("Fix the login redirect", "details…", "slow"))`.

| Export | Returns | What it does |
|---|---|---|
| `open_board(path?)` | `{project}` | Opens the board and panel for the repository at `path` (default: the focused pane's directory) and returns its project id. Without `path`, fails when the focused pane is on a remote host |
| `add_task(title, details?, role?, start?)` | `{project, slug, lane}` | Adds a task to the project containing the focused pane's directory or, when none does and only one project is registered, to that project. `role` is an omp role name without `@`. `start = true` puts it in Ready; anything else puts it in Backlog (`new_task.lane` doesn't apply). `slug` is the task's slug unless another task claims it before the task is created a few seconds later; confirm with `list_tasks()`. Fails when no project matches (run `open_board()` first for a new repository) or the focused pane is on a remote host |
| `list_tasks()` | `{tasks, truncated}`; each task is `{project, slug, title, status, role?, reason?, pr_url?}` | Reads the latest snapshot: unfinished tasks, up to 8 recently shipped or closed tasks per project, and every shipped task whose worktree Swarm kept. Cancelled tasks are left out. At most 40 tasks in total; `truncated` is `true` when more exist. `role` is the role chosen at the task's last pickup |
| `task_action(project, slug, action)` | `true` | Queues `approve`, `retry`, `park` or `discard`. `project` is the id from `list_tasks()`. Fails at once when the task's status doesn't allow the action, when `approve` targets a project that is held (waiting for approval or with a broken `.tern/swarm.json`), or when `carly.actions` doesn't allow the action |

Details:

- `task_action` returns `true` once the action is queued. It checks the status in the last
  snapshot, so it fails with, for example, `fix-login is backlog; approve needs review`. If the status
  changed in the few seconds since, Swarm shows a toast and Carly is not told.
- `approve` works from `review`. It closes a task that changed nothing; otherwise it ships the task
  as `ship` says.
- `retry` works from `waiting`, `blocked`, `review` and `parked`; `park` from `preparing`, `running`,
  `checking`, `waiting`, `blocked` and `review`.
- `discard` works from every unfinished status except `shipping` and `discarding`, and on a shipped
  task whose worktree Swarm kept. It deletes the branch only when `discard.delete_branch` is `true`,
  and never for a shipped task.
- By default Carly may only `retry` and `park`. Allow more with `carly.actions`.
- `task_action`'s description, which Carly reads, lists only the actions your own `carly.actions`
  allows when Swarm loads.
- `carly.actions` doesn't limit `add_task`. A task added with `start = true` is picked up on a later
  tick, unless pickups are paused, the project is held, or the limits are reached.
- While tasks are active, Carly's request context mentions them (see `carly.context`).

## Security and trust

Swarm runs code on your machine without asking. Know what it does before you use it.

- **Agents run unattended as you.** The default `agent_args` include `--approval-mode yolo`: agents
  run shell commands and edit files without asking. They have your user account, credentials (git,
  gh, ssh, cloud tokens), network access and file system. Several run at once, and each one costs
  model usage.
- **A worktree is not a sandbox.** It keeps changes off your checkout; it doesn't contain the agent.
  The rule against committing and pushing is prompt text only.
- **Secrets can reach worktrees.** With `worktree_tool: "omp"` (the default), `.env*` files and
  `node_modules` can be copied into each worktree, where the agent can read them. Swarm records the
  untracked and ignored files a new worktree starts with and never commits them, but Approve commits
  every other file that `.gitignore` doesn't exclude, including any the agent creates. Read the file
  list before you approve, and consider `worktree_tool: "git"`.
- **A repository's settings run commands, after you approve them.** A repository's
  `.tern/swarm.json` can run `setup` commands and `checks`, export `env` variables, add agent
  arguments, roles and instructions, and choose `base`, `remote` (where Approve pushes) and
  `worktree_dir`. Without the file, the detected `npm` scripts and `npm ci` run. Swarm shows you this
  list and runs nothing until you approve it, and asks again when it changes (see
  [Repository approval](#repository-approval)). A repository can't set the approval mode or load an
  omp config: those flags come only from your own `agent_args`. Approval covers the command lines,
  not the scripts they call, so a later change to a script's body isn't noticed.
- **Review is a workflow step, not a security boundary.** An agent can do anything you can before you
  see its work. `on_checks_pass: "ship"` and `#auto-ship` skip your review entirely.
- **Carly may retry and park by default.** The default `carly.actions` is `["retry", "park"]`. Add
  `approve` or `discard` to both files' lists to let Carly ship or discard. A repository's list can
  only narrow what Carly may do: without your own `carly.actions` it is limited to the default.
  `add_task` is not limited by this setting, and its tasks go to Backlog unless Carly passes
  `start = true`.
- **The intent queue is not a security boundary.** Swarm takes commands from JSON files in its
  `intents/` folder. Any program running as you, including an agent, can write one and, for example,
  approve its own task or approve a repository.
- **Task titles go to a model.** With `tabs.names: "model"`, Swarm sends each task title to omp's
  `@tiny` role. Set `tabs.names` to another value to stop it.

## Agent skills

omp loads skills (instructions for specific tools) into each task agent like any other omp session.
Some skills are interactive and don't suit an agent nobody is watching. Swarm's prompt tells every
agent that nobody watches its pane, to ask with its ask tool or stop when it needs a decision, and
never to open interactive UI (Tern blocks, canvases, pickers, forms, browser windows or full-screen
terminal programs). An agent waiting on omp's `ask` tool shows up as `waiting` in the panel's Needs
you section.

If an agent opens a pane in its tab anyway while it works, Swarm marks the task `waiting` with the
reason `The agent opened <a terminal, a plugin block, …> in its tab and may be waiting for you`, and
**Focus** goes to that pane. Close the pane and the task returns to `running` while the agent still
works. Any extra pane in a task's tab counts, including one you split there yourself.

omp's `--skills` flag is an allowlist and has no exclusion syntax. Swarm's `agent_args` charset rejects
`,` and `*`, so `--skills=a,b` can't be passed anyway. `--no-skills` works, but it turns off every
skill, including your repository's own.

To exclude interactive skills, use an omp config overlay:

1. Create a YAML file at an absolute path without spaces or `~`, for example
   `/Users/me/.omp/agent/swarm-agent.yml`:

   ```yaml
   skills:
     ignoredSkills:
       - tern-genui
   ask:
     enabled: false
   ```

2. Add `--config` and the path to your own `agent_args` in `settings.json`, keeping the default
   arguments. A project's `agent_args` can't contain `--config`.

   ```json
   { "agent_args": ["--approval-mode", "yolo", "--config", "/Users/me/.omp/agent/swarm-agent.yml"] }
   ```

The path can't contain spaces or `~`, because `agent_args` rejects both, so a file under
`~/Library/Application Support` won't work. If the file is missing or invalid, omp doesn't start.

This repository also ships an optional skill, `skills/swarm/SKILL.md`, for your own interactive omp or
Claude sessions. It helps them set up `.tern/swarm.json` and debug tasks. Task agents don't need it.
To use it with omp, add the folder holding it to omp's `skills.customDirectories` setting:

- an installed copy: `<plugins>/swarm/skills`, where `<plugins>` is the folder `tern plugin dir`
  prints;
- a linked clone: `<clone>/skills`. `<plugins>/swarm.path` records where the clone is.

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

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| A log line, block reason or error says `omp was not found in …` (or `git` or `gh`); roles never load | Background commands search only a short list of folders | Add the program's folder to `bin_dirs` (Settings › Machine › Programs) |
| Open board says `Swarm needs a pane inside a non-bare git repository` in a real repository | `git` isn't on Swarm's search path | Add git's folder to `bin_dirs` |
| A toast says `Swarm can't use this pane` | The focused pane is on a remote host | Focus a pane on this machine |
| Nothing starts and the panel lists what the repository runs | The repository waits for your approval, or its settings changed since you approved them | Read the list and click **Approve** (see [Repository approval](#repository-approval)) |
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
| The panel stops updating, or a toast says `Swarm is stalled` | Tern disabled one of Swarm's hooks after it ran over its time budget | Run **Reload plugins** from the palette. With `watchdog: "reload"`, Swarm does it once you've been idle for 30 s. See `watchdog` and [Known limitations](#known-limitations) |
| A toast says `Swarm didn't finish starting` | Tern disabled Swarm's loader while it was loading a module (the log names it) | Run **Reload plugins** from the palette. If it keeps happening, look for `swarm: loading … took` lines (below) |
| A task is blocked with `task.json is damaged (…)` | Its `task.json` isn't valid JSON, names another slug or project, has an unknown status, or was written by a newer Swarm | Swarm leaves the file alone and copies it once to `task.json.corrupt` beside it. Fix `task.json` and the task comes back within a few seconds. Or delete it: within a few seconds its card becomes a fresh task in Backlog. The old worktree and branch stay on disk, no longer linked |
| The panel says `Swarm's projects.json is damaged` | `projects.json` and its backup `projects.json.bak` are both unreadable, or `projects.json` was written by a newer Swarm | Fix or delete `projects.json`. Until then Swarm never writes it, keeps the projects it read earlier in this session, and Open board fails with `Swarm can't register this repository` |
| Nothing happens for a minute or more while Tern sits in the background, then everything catches up | Tern can run a window's timers late while the app is idle in the background (40–90 s has been seen on macOS) | Focus Tern or run any `tern` CLI command to wake it. Swarm catches up on the next tick. See [Known limitations](#known-limitations) |

**Where Swarm keeps its state.** Swarm's data folder is
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

**Logs.** Tern's logs are in `~/Library/Logs/Tern` on macOS and `~/.local/state/tern/logs` on Linux.
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

## How it works

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
  see [Troubleshooting](#troubleshooting).
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

## License

MIT. See [LICENSE](LICENSE).
