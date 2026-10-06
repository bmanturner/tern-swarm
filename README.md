# Tern Swarm

Turn a Kanban board into a queue of coding agents, each in its own git worktree.

Swarm is a plugin for the Tern terminal. It runs [omp](https://omp.sh) coding agents on the cards
of a board, runs your checks on their work, and waits for your approval before anything ships.

> [!NOTE]
> Early release (0.1.0) with a single maintainer. Tested on macOS with Tern 0.5.2. Linux is
> untested; Windows, iOS and remote hosts are unsupported. Expect rough edges;
> [issues](https://github.com/bmanturner/tern-swarm/issues) are welcome. MIT licensed, see
> [LICENSE](LICENSE).

> [!WARNING]
> Agents run unattended as you, with `--approval-mode yolo` by default: they have your credentials,
> network access and files. Swarm runs nothing in a repository until you approve what it will run
> there. Read [Security and trust](#security-and-trust) before you open a board.

## Why Swarm

- **The board is the interface.** Each card you put in **Ready** becomes a task. Swarm moves cards
  between lanes as tasks progress, and you can drag them yourself.
- **One worktree and branch per task.** Each task gets its own git worktree (a second checkout of
  your repository on its own branch), so agents never touch your working copy.
- **Your checks gate the work.** When the agent stops, Swarm runs your checks (type check, lint,
  tests). Failures go back to the same agent.
- **Nothing ships until you approve.** Passing work waits in **Review**, where you approve it
  (commit, push and open a pull request), retry it, or discard it. Auto-ship is opt-in
  (`on_checks_pass: "ship"` or the `#auto-ship` card tag).
- **Everything happens in visible Tern tabs.** Each agent runs in its own tab above a shell.
  **Focus** takes you there, and you can type into the agent's tab.

**When not to use it:** you're not on Tern desktop on macOS, your repositories are on a remote host,
or you don't want agents running unattended with your credentials.

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

You also need:

- **Tern desktop**, running with at least one window open;
- **omp**, installed and signed in to a model provider (check with `omp -p hi`);
- **a non-bare git repository with at least one commit** (and a remote for pull requests);
- **gh**, signed in with push rights, when Swarm opens pull requests (the default).

See [Before you start](docs/configuration.md#before-you-start) for the full prerequisites, including
omp model roles and the folders Swarm searches for `omp`, `git` and `gh`.

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

To commit without pushing or opening a pull request, set `"ship": "commit"` (see [Settings](docs/configuration.md#settings)).

## How a task flows

1. A card in **Ready** is a queued task. Swarm stamps it with a `#swarm-<slug>` tag.
2. About every 3 s, Swarm picks up queued tasks while a slot is free (`max_concurrent`).
3. It creates a worktree on branch `<branch_prefix><slug>` from `base` and runs your `setup` commands.
4. An omp agent starts in a new tab on the card's `#role-<name>` role, else `default_role`. A role
   such as `@smol` or `@slow` names a model in your omp config.
5. When the agent goes idle, Swarm runs your `checks` in the task's shell.
6. Failures go back to the same agent, up to `max_attempts` rounds; then the task is blocked.
7. Passing work waits in **Review**, where you approve, retry or discard it.
8. Approve commits, then (with `ship: "pr"`) pushes and opens a pull request. Clean up removes the
   worktree later.

Each step in detail, and the other ways to add tasks: [How a task flows](docs/how-it-works.md#how-a-task-flows).

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
  [Repository approval](docs/configuration.md#repository-approval)). A repository can't set the approval mode or load an
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

## Documentation

- [Configuration](docs/configuration.md): full prerequisites, repository approval details, lanes,
  review and approve, the panel, commands, settings (with example files), card tags, task statuses,
  Carly and agent skills.
- [Troubleshooting](docs/troubleshooting.md): symptoms and fixes, logs, and uninstalling.
- [How it works](docs/how-it-works.md): the full task flow, internals, state files, platform
  support and known limitations.

## License

MIT. See [LICENSE](LICENSE).
