--!strict
-- The orchestrator: one window holds a lease in tern.kv and drives every project every TICK_MS:
-- intents, board reads, reconcile and publishing (see those modules). Other windows only read
-- snapshot.json. Window half.

local boardread = require("./boardread")
local config = require("./config")
local const = require("./const")
local intents = require("./intents")
local paths = require("./paths")
local projects = require("./projects")
local publish = require("./publish")
local reconcile = require("./reconcile")
local state = require("./state")
local store = require("./store")
local taskctx = require("./taskctx")

local orchestrator = {}

-- Set once start() ran (the watchdog only judges a started orchestrator).
orchestrator.started = false

local TOKEN = string.format("%x-%x", math.random(0, 0x7fffffff), math.floor(tern.now() * 1000) % 0x7fffffff)
state.token = TOKEN

local pending: TimerHandle? = nil
local held = false
local leading = false
local stopped = false
local gated = false
local reading: { [string]: number } = {}
-- pid -> when its sliced reconcile started; no new board read starts while one runs (up to 30 s).
local reconciling: { [string]: number } = {}
local read_warned: { [string]: number } = {}
local stall_toasted = false
-- When a focus event first found Swarm stalled (watchdog "reload" waits for the user to go idle).
local stalled_since: number? = nil

-- Takes or renews the leader lease; leads only after holding it on two consecutive ticks.
local function lease(): boolean
	local ok, cur = pcall(tern.kv.get, "leader")
	if not ok then
		held = false
		return false
	end
	local now = os.time()
	local mine = type(cur) == "table" and cur.id == TOKEN
	if mine or type(cur) ~= "table" or type(cur.at) ~= "number" or now - cur.at > const.LEASE_TTL_S then
		pcall(tern.kv.set, "leader", { id = TOKEN, at = now })
		local ok2, again = pcall(tern.kv.get, "leader")
		mine = ok2 and type(again) == "table" and again.id == TOKEN
	end
	local was = held
	held = mine
	return mine and was
end

-- Starts a new leadership period (on gaining or losing the lease): drops every leader-only cache so
-- a returning leader reloads from disk, and fences callbacks issued in the previous period.
local function new_epoch()
	state.epoch += 1
	state.tasks = {}
	state.inflight = {}
	state.cfg = {}
	state.naming = {}
	state.toasts = {}
	state.board_unread = {}
	state.card_removals = {}
	state.damaged = {}
	reconcile.reset()
	reading = {}
	reconciling = {}
	state.orders = {}
	state.next_roles = {}
	publish.reset()
	state.last_await_at = os.time()
end

local function begin_epoch()
	new_epoch()
	tern.log.info("swarm: leading (epoch " .. state.epoch .. ")")
end

local function end_epoch()
	new_epoch()
	tern.log.info("swarm: no longer leading (epoch " .. state.epoch .. ")")
end

-- Something stopped answering (a hook Tern disabled after it overran its budget). Per the user's
-- `watchdog` setting: "reload" reloads plugins once the user has been idle for 30 s (or 15 min
-- after a focus event first saw the stall), at most once per WATCHDOG_RELOAD_GAP_S across windows,
-- else tells the user once per VM; "notify" only tells the user; "off" only logs.
local function recover(cx: WindowCx, why: string, kind: "focus" | "command" | "tick")
	local mode = config.user().watchdog
	if mode == "off" then
		if not stall_toasted then
			stall_toasted = true
			tern.log.warn("swarm: watchdog: " .. why .. " (recovery is off)")
		end
		return
	end
	local sub = "Run Reload plugins from the palette."
	if mode ~= "notify" then
		sub = "Swarm reloads plugins after you've been idle for 30 s, or run Reload plugins now."
		if kind == "focus" then
			stalled_since = stalled_since or os.time()
		else
			local now = os.time()
			local idle = now - state.last_focus_at >= 30 or (stalled_since ~= nil and now - stalled_since >= 900)
			if not idle then
				return
			end
			local ok, at = pcall(tern.kv.get, "watchdog_at")
			if ok and (type(at) ~= "number" or now - at >= const.WATCHDOG_RELOAD_GAP_S) then
				pcall(tern.kv.set, "watchdog_at", now)
				tern.log.warn("swarm: watchdog reloading plugins: " .. why)
				pcall(function()
					cx:toast("info", "Swarm reloaded plugins to recover", why)
				end)
				local reloaded = pcall(function()
					cx:command("reload_plugins")
				end)
				if not reloaded then
					reloaded = pcall(function()
						cx:action("reload_plugins")
					end)
				end
				if reloaded then
					stalled_since = nil
					return
				end
				tern.log.warn("swarm: watchdog could not reload plugins")
				sub = "Run Reload plugins from the palette."
			end
		end
	end
	if not stall_toasted then
		stall_toasted = true
		pcall(function()
			cx:toast("error", "Swarm is stalled: " .. why, sub)
		end)
	end
end

-- The inert stand-in for a task whose task.json is damaged: blocked, never run or changed.
local function placeholder(pid: string, slug: string, why: string): any
	return {
		slug = slug,
		project = pid,
		title = slug,
		status = "blocked",
		lane = "Blocked",
		damaged = true,
		reason = "task.json is damaged ("
			.. why
			.. "). A copy is in task.json.corrupt. Fix or delete task.json; Swarm picks it up within a few seconds.",
	}
end

-- Loads the tasks of project `pid`, with a placeholder for each damaged task.json.
local function load_project(pid: string)
	local tasks, damaged = store.load_tasks(pid)
	local marks: { [string]: boolean } = {}
	for slug, why in damaged do
		tasks[slug] = placeholder(pid, slug, why)
		marks[slug] = true
	end
	state.tasks[pid] = tasks
	state.damaged[pid] = marks
end

-- Re-reads every damaged task.json: a fixed one replaces its placeholder; a deleted one becomes a
-- fresh Backlog task (lane sync already moved the card to Blocked, where tagged-card recovery
-- wouldn't adopt it; lane sync now moves it to Backlog and title sync restores the card's title).
local function recheck_damaged()
	for pid, marks in state.damaged do
		local tasks = state.tasks[pid]
		for slug in marks do
			local task, why = store.load_task(pid, slug)
			if task ~= nil then
				if tasks then
					tasks[slug] = task
				end
				marks[slug] = nil
			elseif why == nil then
				if tasks then
					local old = tasks[slug]
					local fresh = taskctx.new_task(pid, slug, if old and type(old.title) == "string" then old.title else slug, "Backlog")
					tasks[slug] = fresh
					store.save_task(fresh)
				end
				marks[slug] = nil
			end
		end
	end
end

local function tick(cx: WindowCx)
	state.last_tick_at = os.time()
	if not gated then
		gated = true
		if cx.board == nil or cx.agents == nil or cx.canvas == nil or cx.layout == nil then
			tern.log.warn("swarm: this Tern lacks the board, agent, canvas or layout API; orchestration is off")
			stopped = true
			return
		end
	end
	local leader = lease()
	if leader ~= leading then
		if leader then
			begin_epoch()
		else
			end_epoch()
		end
	end
	leading = leader
	state.leader = leader
	if not leader then
		publish.refresh_reader()
		return
	end
	state.projects = store.projects()
	-- Parsing every task.json of every project in one call can overrun the 50 ms budget, so each
	-- tick loads one project; intents and board reads wait until every project is loaded.
	for pid in state.projects do
		if state.tasks[pid] == nil then
			local t0 = tern.now()
			load_project(pid)
			publish.log_slow("load", pid, t0)
			return
		end
	end
	recheck_damaged()
	local ok, paused = pcall(tern.kv.get, "paused")
	state.paused = ok and paused == true
	local okp, pp = pcall(tern.kv.get, "paused_projects")
	state.paused_projects = if okp and type(pp) == "table" then pp else {}

	local t0 = tern.now()
	for _, entry in store.pending_intents() do
		if tern.now() - t0 >= 15 then
			break
		end
		local handled, defer = pcall(intents.handle, cx, entry.intent)
		if not handled then
			tern.log.warn("swarm: intent failed", tern.json.encode(entry.intent), defer)
			store.remove_intent(entry.path)
		elseif defer ~= true then
			store.remove_intent(entry.path)
		end
	end

	for pid, proj in state.projects do
		local busy = reconciling[pid] ~= nil and os.time() - reconciling[pid] <= 30
		if not busy and (reading[pid] == nil or os.time() - reading[pid] > 20) then
			reading[pid] = os.time()
			local board = paths.board(pid)
			if not tern.fs.exists(board) then
				projects.ensure_board(pid, proj.name or pid)
			end
			local epoch = state.epoch
			local started, err0 = pcall(boardread.read, cx, board, epoch, function(snap: any?, err: any, cx2: WindowCx?)
				if not state.current(epoch) then
					return
				end
				reading[pid] = nil
				if cx2 == nil then
					return
				end
				if err then
					if os.time() - (read_warned[pid] or 0) > 60 then
						read_warned[pid] = os.time()
						tern.log.warn("swarm: could not read the board of " .. pid, err)
					end
					return
				end
				-- Reconcile on its own timer call: the board read's callback has already spent part
				-- of its budget on the last page.
				reconciling[pid] = os.time()
				local function finished()
					if state.epoch == epoch then
						reconciling[pid] = nil
					end
				end
				tern.timer(const.YIELD_MS, function(cx3: WindowCx?)
					if cx3 == nil or not state.current(epoch) then
						finished()
						return
					end
					local done, rerr = pcall(reconcile.run, cx3, pid, snap, finished)
					if not done then
						finished()
						tern.log.warn("swarm: reconcile failed for " .. pid, rerr)
					end
				end)
			end)
			if not started then
				reading[pid] = nil
				tern.log.warn("swarm: board read failed to start", err0)
			end
		end
	end
	if next(state.projects) == nil then
		publish.publish(cx)
	elseif os.time() - state.last_await_at > const.WATCHDOG_S then
		recover(cx, "board reads stopped answering", "tick")
	end
end

local function schedule(ms: number)
	if stopped then
		return
	end
	if pending then
		pending:cancel()
	end
	pending = tern.timer(ms, function(cx: WindowCx?)
		pending = nil
		if cx then
			local t0 = tern.now()
			local ok, err = pcall(tick, cx)
			publish.log_slow("tick", nil, t0)
			if not ok then
				tern.log.warn("swarm: tick failed", err)
			end
		end
		if pending == nil then
			schedule(const.TICK_MS)
		end
	end)
end

-- Runs a tick now.
function orchestrator.poke()
	schedule(0)
end

-- A command finished in some pane: wake up when it was a task's shell (a job ended).
function orchestrator.on_command_finished(ev: any)
	if not state.leader then
		return
	end
	for _, tasks in state.tasks do
		for _, task in tasks do
			if task.shell_pane == ev.pane then
				orchestrator.poke()
				return
			end
		end
	end
end

-- Any window event: when the orchestrator timer has stopped firing (Tern disabled it), recover.
function orchestrator.on_event(cx: WindowCx, kind: "focus" | "command")
	if kind == "focus" then
		state.last_focus_at = os.time()
	end
	if orchestrator.started and not stopped and os.time() - state.last_tick_at > const.WATCHDOG_S then
		recover(cx, "the orchestrator timer stopped", kind)
	end
end

function orchestrator.start()
	orchestrator.started = true
	state.last_tick_at = os.time()
	state.poke = orchestrator.poke
	schedule(1500)
end

return orchestrator
