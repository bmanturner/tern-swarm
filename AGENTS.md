# AGENTS.md

Rules for coding agents that change this plugin. For user docs, see README.md and `docs/`.

Swarm is a Tern plugin written in Luau. Read the Tern plugin SDK skill (`tern-plugin`, `SKILL.md`)
before you change anything. API types are in `tern.d.luau`.

## Layout

| Path | Half | Role |
|---|---|---|
| `plugin.toml` | both | Manifest: id `swarm`, `version`, the `new-task` and `settings` blocks |
| `window.luau` | window | Returns at once on iOS. Otherwise installs the `focus` handler (startup-stall warning), then a staged loader for `MODULES`, then registers events, the `swarm://wake` route, commands and Carly exports |
| `host.luau` | host | Defines the `new-task` and `settings` blocks |
| `blocks/new-task.luau` | host | New task form |
| `blocks/settings.luau` | host | Settings page (`prefs` node) |
| `lib/*.luau` | see below | Shared modules; each header comment names its half |
| `tern.d.luau` | n/a | Generated API types for luau-lsp. Regenerate with `tern plugin types .` after a Tern upgrade |
| `.vscode/settings.json` | n/a | luau-lsp settings. Committed on purpose |

Module halves:

| Half | Modules |
|---|---|
| Both | `const`, `text`, `paths`, `schema`, `config`, `bin`, `sh`, `run`, `store`, `roles` |
| Window only | `state`, `panel_cards`, `panel_view`, `panel`, `projects`, `git`, `jobs`, `prompts`, `names`, `actions`, `ship`, `cleanup`, `prepare`, `checking`, `steps`, `taskctx`, `cardsync`, `publish`, `reconcile`, `boardread`, `intents`, `orchestrator`, `commands`, `carly` |
| Host only | `textfield`, `settings_ui` (and `store.pane_alive`, which uses `tern.pane`) |

Modules:

| Module | Role |
|---|---|
| `const` | Tick and timeout constants, status/lane vocabulary, `CAN` (statuses each user action accepts), card tags |
| `text` | UTF-8-safe clipping and trimming |
| `paths` | Data-folder layout, project ids, task slugs |
| `schema` | Every settings key: scope, default, parser, merge rule; `approval_flag` |
| `config` | Reads, validates and merges both settings layers; `approval_args`, `trust` items, `trusted`/`approve`, starter file |
| `bin` | Finds `omp`, `git` and `gh` on known folders plus `bin_dirs` |
| `sh` | POSIX shell quoting |
| `run` | `tern.process.run` with absolute paths and the plugin PATH |
| `store` | JSON files: `projects.json` (+ `.bak`, damage tracking), `task.json` (validation, `.corrupt` copies), intents |
| `roles` | omp model roles from `omp config get modelRoles` |
| `state` | Per-VM shared state (tasks, config cache, snapshot, damaged marks, orders) |
| `panel_cards` | Panel node builders (buttons, task cards, lists, sections) |
| `panel_view` | The panel canvas tree of one snapshot project (header, approval card, sections, kept rows) |
| `panel` | Panel canvases: finding, updating, click handling |
| `projects` | Repository root resolution, registration, board and panel opening, roles fetch |
| `git` | Background git: worktrees, review stats, `shipped_safe`, `baseline`, removal, PR state |
| `jobs` | Generated `sh` job scripts typed into a task's shell, with per-step status files |
| `prompts` | Initial and resume prompts for task agents |
| `names` | Short tab names (omp `@tiny` or title key words) |
| `actions` | User actions (approve, retry, park, discard, close, cancel) and shared step helpers |
| `ship` | The ship job (commit, push, PR) and its outcome, including after-ship cleanup |
| `cleanup` | Clean up: worktree removal and archiving, keeping shipped worktrees with later work |
| `prepare` | The `preparing` step: worktree, preexisting-file baseline, shell, setup, agent start |
| `checking` | The `checking` step: change gate, checks job, review / feedback / block |
| `steps` | Per-task status machine: agent tracking (including opened-UI detection), placement, discarding |
| `taskctx` | Cached merged config and `hold` per project (`cfg_for`), the step `ctx`, new task records |
| `cardsync` | Board read → cards by slug (`#role-` validation), lane order, human lane moves |
| `publish` | Builds and writes `snapshot.json`, redraws panels, flushes toasts, logs slow calls |
| `reconcile` | One project's reconcile after a board read; status steps and lane sync run in time slices |
| `boardread` | Pages through a whole board past Tern's per-read cap |
| `intents` | Handles intents: open, create, action, clean, config, trust |
| `orchestrator` | Leader lease, tick, task loading (damaged placeholders), intent drain, watchdog |
| `commands` | Palette commands, status segment, focused-pane cwd (refuses remote hosts) |
| `carly` | Carly exports and request context |
| `textfield` | Program-owned text field for host blocks |
| `settings_ui` | Settings page rows built from both layers |

- Host code (`host.luau`, `blocks/*`) may require only "both" and "host only" modules.
- A "both" module must never require a window-only or host-only module.
- Keep the require graph acyclic. `run` requires `bin`, and `bin` requires `config`. So `config`,
  `schema`, `paths` and `const` must never require `bin` or `run`.
- Write `--!strict` at the top of every file. Use relative `require` paths (`./x` in `lib`,
  `../lib/x` in `blocks`).

## Window loader

- A full window-half load runs over the 50 ms budget. `window.luau` loads one module per timer
  callback instead.
- List every window module in `MODULES` in `window.luau`, in dependency order: a module comes after
  everything it requires. A missing module compiles inside its requirer's step and can blow the
  budget. The loader warns `swarm: loading <module> took <n> ms` at 15 ms or more; split a module
  that keeps logging it, at a function boundary.
- Host-only modules don't go in `MODULES`.
- An over-budget loader step disables every timer, so `register()` never runs. The `focus` handler
  is installed before loading for that reason; `register()` only sets its `on_focus` callback. Don't
  register a second `focus` handler.
- Reconcile runs its per-task work in slices that start new work for up to `const.SLICE_MS` (10 ms),
  each on a timer `const.YIELD_MS` (60 ms) later; publish and each panel redraw step also run on
  `YIELD_MS` timers. The intent drain stops after 15 ms, and at startup the leader loads one project's
  tasks per tick. Time with `tern.now()` (wall-clock ms). Keep new per-task work inside those loops,
  not in a single pass.

## Time budgets

| Hook | Budget |
|---|---|
| Window call (events, timers, commands, canvas actions, Carly exports) | 50 ms |
| Chrome formatters and `available` | 4 ms |
| Host call (block `init`, `view`, `key`, `event`) | 2 s |

- A call over budget raises `tern: <hook> exceeded <n> ms`. `pcall` can't catch it. Tern disables
  the hook until a reload.
- Do slow work in `tern.process.run` or `run.exec` callbacks. Never loop over unbounded boards,
  files or task lists in one call.
- Cap file reads. Never block on a process.

## Luau and Tern rules

- Never annotate a table-field assignment. `m.X: T = …` is a syntax error. Declare a local with the
  type, then assign it: `local X: T = …; m.X = X`.
- A host block `key` handler returns exactly `false` only when nothing changed. `false` skips
  render and save.
- Wrap an empty list in `tern.json.array()`, or it encodes as `{}`. `tern.json.decode` drops null
  members. `tern.json.encode(v, true)` pretty-prints.
- `tern.fs` has `read`, `write`, `list`, `exists`, `mkdir` and `remove`. It has no rename and no
  stat. Relative paths resolve against the package folder, and `~` isn't expanded.
- Window timer, process and fetch callbacks receive a fresh `cx`. Use it. Never keep a `cx` and use
  it later, for example inside an async op's apply. Host-half callbacks receive no `cx`.
- Window `cx:toast` takes only `"success"`, `"info"` or `"error"`.
- `tern.process.run` runs no shell, and its PATH is short. Spawn through `lib/run` (absolute paths
  from `bin.resolve`, PATH from `bin.env()`).
- Only the leader window writes task files. Other contexts write intents with `store.write_intent`;
  host blocks then open `swarm://wake`, while window contexts call `state.poke()`. The leader
  consumes queued intents on its next tick.

## Data

- Never write into the package folder. Any change there reloads every plugin, which causes a reload
  loop.
- Runtime data goes under `tern.plugin.data` (see `lib/paths`). The only files Swarm writes in a
  user's repository are worktrees and `.tern/swarm.json`.
- `projects.json`, `task.json` and `snapshot.json` carry `format = 1`. Bump it only with a reader for
  the old shape. A damaged `projects.json` or `task.json` must never be overwritten: `store` raises
  or skips, and the orchestrator stands in an inert placeholder for a damaged task.
- Never remove a shipped task's worktree without `git.shipped_safe`; only a user's Discard forces it.

## Settings

`lib/schema.luau` is the single source of truth for every key: scope, default, validation and merge
rule. `lib/config.luau` reads, validates and merges both layers from it.

To add a key:

1. Add a `Spec` to `FIELDS` in `lib/schema.luau`. Add the field to `Config` or `UserConfig` in
   `lib/config.luau`.
2. Wire it into behavior. Read it from the merged config (`ctx.cfg`, or `config.user()` for
   user-only keys). Don't add a second validation path.
3. Add a row in `lib/settings_ui.luau` on the right page. Use an existing op, or add the op in
   `blocks/settings.luau`.
4. If the key makes Swarm run something or tells agents something, add it to the `trust` items in
   `config.load`, so changing it asks for approval again.
5. Add a row to the settings table in `docs/configuration.md` and an entry in CHANGELOG.md.

After writing a settings file, call `config.forget()`, write the intent `{ kind = "config" }` and
open `swarm://wake`. A write the user makes on the Settings page re-approves a repository that was
approved before it (`blocks/settings.luau` `persist`); no other code may call `config.approve`
except the `trust` intent.

Approval and config-overlay flags (`schema.approval_flag`) come only from the user's `agent_args`.
A project value containing one is invalid.

## Logging

- The default log filter drops `print`, `tern.log.info` and `tern.log.debug`.
- Use `tern.log.warn` for any message that must show. Prefix it with `swarm:`.

## Verify

Run these from the repository root after every change:

1. `python3 <tern-plugin skill>/scripts/check_plugin.py --no-types .` must report 0 errors.
2. `tern plugin reload` must exit 0 with both halves loaded.
3. Scan `~/Library/Logs/Tern/tern.log` (windows) and `~/Library/Logs/Tern/tern-daemon.log` (host)
   for new lines matching `swarm|exceeded`. There must be no new `failed to load`, `handler failed`
   or `exceeded` lines.

Window-half load errors show only as a toast and in `tern.log`, never in `tern plugin list`.

## Testing

- Test only in a scratch git repository. Never run Swarm against a real project: agents run
  unattended, and approving pushes branches and opens pull requests.
- A linked package reloads the user's live Tern on every save. Say so before you link it.

## Docs to keep in sync

Update these in the same change as the code:

- `README.md`: overview, install, quick start, the condensed task flow, security and trust.
- `docs/configuration.md`: prerequisites, repository approval, lanes, review, panel, commands,
  settings, card tags, task statuses, Carly, agent skills.
- `docs/troubleshooting.md`: symptoms and fixes, logs, uninstall.
- `docs/how-it-works.md`: the full task flow, internals, state files, platform support, known
  limitations.
- `CHANGELOG.md`: every user-visible change, under the unreleased version.
- `skills/swarm/SKILL.md`: the agent skill for Swarm users.
- The Carly export `doc` strings in `lib/carly.luau`, when exports change.
