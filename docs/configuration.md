# Configuration

Prerequisites, settings, card tags, statuses, the panel, commands and Carly. Back to the [README](../README.md).

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

Read [Security and trust](../README.md#security-and-trust) before you open a board for a repository. Swarm runs
nothing in a repository until you approve what that repository makes it run (see
[Repository approval](#repository-approval)).

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
  [Troubleshooting](troubleshooting.md#symptoms-and-fixes)).

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
| **Swarm: Clean up finished worktrees** | | Runs Clean up in every project. See [Known limitations](how-it-works.md#known-limitations) for what it skips and deletes |
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
| you | `settings.json` in Swarm's data folder (see [Where Swarm keeps its state](how-it-works.md#where-swarm-keeps-its-state)) | Every project |

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
| `clean.auto` | both | `"manual"` | `"manual"`, `"after_ship"`, `"after_merge"` | When worktrees are removed without Clean up. `"after_ship"`: right after shipping (the branch stays). `"after_merge"`: once the PR is merged or closed, checked at most every 5 minutes (the branch is deleted). Neither removes a worktree that holds work made after shipping (see [Known limitations](how-it-works.md#known-limitations)). A later Clean up still archives the task |
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
- the task's `task.json` is damaged (see [Troubleshooting](troubleshooting.md#symptoms-and-fixes)).

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

