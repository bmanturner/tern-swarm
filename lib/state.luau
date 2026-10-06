--!strict
-- Window-VM state shared by the orchestrator, panel, commands and Carly exports. One table per VM
-- (require caches it). Nothing here survives a reload; durable state lives in the data folder.

local state = {}

-- projects.json as last read: pid -> {root, name, session, worktree_dir}.
state.projects = {} :: { [string]: any }

-- Leader only: pid -> slug -> task (task.json contents).
state.tasks = {} :: { [string]: { [string]: any } }

-- Leader only: pid -> {cfg, load_err, err, hold, untrusted, at} (taskctx cfg_for cache).
state.cfg = {} :: { [string]: any }

-- pid -> {list = {{name, model}}, names = {[name]: true}, at} (omp roles cache).
state.roles = {} :: { [string]: any }

-- Leader only: "pid/slug" -> {op, status} for tasks with an async operation in flight.
state.inflight = {} :: { [string]: any }

-- Leader only: "pid/slug" -> the title already sent to @tiny for a short name.
state.naming = {} :: { [string]: string }

-- Leader only: toasts raised from callbacks without a window cx, shown at the next reconcile.
state.toasts = {} :: { any }

-- Leader only: "pid/slug" -> the card's index in its lane (reconcile writes, publish reads).
state.orders = {} :: { [string]: number }

-- Leader only: "pid/slug" -> the role the task's next agent runs as (reconcile writes, publish reads).
state.next_roles = {} :: { [string]: string }

-- Watchdog: when a board read last answered (boardread writes) and when the last tick ran.
state.last_await_at = os.time()
state.last_tick_at = os.time()

-- When a window last had focus (the watchdog reloads plugins only while the user is idle).
state.last_focus_at = 0

-- Leader only: pid -> set of slugs whose task.json is damaged (a blocked placeholder stands in).
state.damaged = {} :: { [string]: { [string]: boolean } }

-- The latest snapshot (built by the leader, read from snapshot.json elsewhere).
state.snapshot = { paused = false, counts = { running = 0, needs = 0, review = 0, queued = 0 }, projects = {} } :: any

-- Whether this VM orchestrates.
state.leader = false

-- Leadership period; bumped whenever this VM starts or stops leading. Async callbacks capture it.
state.epoch = 0

-- This VM's lease token (kv `leader.id` while it leads); set by the orchestrator at load.
state.token = ""

-- True while this VM still leads in leadership period `epoch` (and the kv lease is still ours).
function state.current(epoch: number): boolean
	if not state.leader or state.epoch ~= epoch then
		return false
	end
	local ok, cur = pcall(tern.kv.get, "leader")
	return ok and type(cur) == "table" and cur.id == state.token
end

-- Leader only: pickups are paused (kv `paused`).
state.paused = false

-- Leader only: pid -> true for projects whose pickups are paused (kv `paused_projects`).
state.paused_projects = {} :: { [string]: boolean }

-- Leader only: pid -> cards the last board read skipped (the board is too large to read in full).
state.board_unread = {} :: { [string]: number }

-- Leader only: pid -> set of slugs whose Done card must be removed from the board (Clean up with
-- `clean.remove_done_cards`); a slug stays until a complete board read no longer shows its card.
state.card_removals = {} :: { [string]: { [string]: boolean } }

-- Wakes the orchestrator now; set by the orchestrator at load.
state.poke = function() end

-- Queues a toast for the next reconcile (callbacks of process and fetch have no cx in some paths).
function state.notify(level: string, text: string, sub: string?)
	table.insert(state.toasts, { level = level, text = text, sub = sub })
end

-- The snapshot project with id `pid`, or nil.
function state.snapshot_project(pid: string): any
	for _, p in state.snapshot.projects or {} do
		if p.id == pid then
			return p
		end
	end
	return nil
end

-- The snapshot task `slug` of project `pid`, or nil.
function state.snapshot_task(pid: string, slug: string): any
	local p = state.snapshot_project(pid)
	if p == nil then
		return nil
	end
	for _, t in p.tasks or {} do
		if t.slug == slug then
			return t
		end
	end
	return nil
end

return state
