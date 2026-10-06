--!strict
-- The snapshot: builds each project's part from leader state, writes snapshot.json and redraws the
-- changed panels; non-leaders follow snapshot.json. Also queued toasts and slow-call logging. Window half.

local const = require("./const")
local names = require("./names")
local panel = require("./panel")
local paths = require("./paths")
local state = require("./state")
local store = require("./store")
local text = require("./text")

local publish = {}

-- Slow reconcile/publish calls are logged above this many milliseconds.
local SLOW_MS = 25

-- Published JSON per project part, and of {paused, counts}.
local published: { [string]: string } = {}
local published_head = ""
local published_paused: boolean? = nil
local publish_pending = false
local snapshot_json = ""
local snapshot_warned_at = 0

-- Forgets what was published (a new leadership period republishes everything).
function publish.reset()
	published = {}
	published_head = ""
	published_paused = nil
	snapshot_json = ""
end

-- Statuses whose snapshot carries a clip of details.md (the panel shows it on their cards).
local WITH_DETAILS: { [string]: boolean } = { review = true, shipping = true, waiting = true, blocked = true }

local function clip(s: any, max: number): any
	return if type(s) == "string" then text.clip(s, max) else s
end

local function snapshot_task(task: any, cfg: any): any
	local key = task.project .. "/" .. task.slug
	local review = task.review
	if type(review) == "table" and type(review.files) == "table" and #review.files > 10 then
		review = table.clone(review)
		local files = tern.json.array()
		for i = 1, 10 do
			table.insert(files, task.review.files[i])
		end
		review.files = files
	end
	local details: string? = nil
	if WITH_DETAILS[task.status] then
		local d = text.trim(store.details(task.project, task.slug))
		if d ~= "" then
			details = text.clip(d, 1500)
		end
	end
	return {
		slug = task.slug,
		title = task.title,
		short = names.label_plain(task, cfg and cfg.tabs.names),
		status = task.status,
		lane = task.lane,
		role = task.role,
		next_role = state.next_roles[key] or (cfg and cfg.default_role),
		agent_model = task.agent_model,
		reason = task.reason,
		attempt = task.attempt,
		max_attempts = cfg and cfg.max_attempts,
		started_at = task.started_at,
		finished_at = task.finished_at,
		checks = task.checks,
		review = review,
		summary = clip(task.summary, 2000),
		last_message = clip(task.last_message, 600),
		details = details,
		pr_url = task.pr_url,
		commit = task.commit,
		ship_error = task.ship_error,
		worktree = task.worktree,
		branch = task.branch,
		agent_pane = task.agent_pane,
		shell_pane = task.shell_pane,
		ui_pane = task.ui_pane,
		kept = task.kept,
		order = state.orders[key],
	}
end

local function sorted_keys(t: { [string]: any }): { string }
	local keys: { string } = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

-- Logs a reconcile or publish that ran longer than SLOW_MS (`t0` from tern.now(), wall-clock ms,
-- the clock Tern's budgets use).
function publish.log_slow(what: string, pid: string?, t0: number)
	local ms = tern.now() - t0
	if ms > SLOW_MS then
		tern.log.warn(string.format("swarm: %s of %s took %.0f ms", what, pid or "all", ms))
	end
end

-- How many shipped/closed tasks a project part carries (newest first). Shipped tasks whose
-- worktree Swarm kept are carried too, beyond this count.
local DONE_IN_SNAPSHOT = 8

-- The snapshot part of project `pid`, and adds its tasks to `counts`.
local function build_part(pid: string, counts: any): any
	local proj = state.projects[pid]
	local entry = state.cfg[pid]
	local cfg = entry and entry.cfg
	local sp: any = {
		id = pid,
		name = proj.name,
		root = proj.root,
		config_error = entry and entry.err,
		hold = entry and entry.hold,
		trust = if entry and entry.untrusted
			then { subject = entry.cfg.trust.subject, items = entry.cfg.trust.items }
			else nil,
		ship = cfg and cfg.ship,
		paused = state.paused_projects[pid] == true,
		board_unread = state.board_unread[pid],
		finished_count = 0,
		tasks = tern.json.array(),
	}
	local done: { any } = {}
	local tasks = state.tasks[pid] or {}
	for _, slug in sorted_keys(tasks) do
		local task = tasks[slug]
		local st = task.status
		if const.ACTIVE[st] then
			counts.running += 1
		elseif st == "waiting" or st == "blocked" then
			counts.needs += 1
		elseif st == "review" or st == "shipping" then
			counts.review += 1
		elseif st == "queued" then
			counts.queued += 1
		end
		if const.TERMINAL[st] then
			sp.finished_count += 1
			if st ~= "cancelled" then
				table.insert(done, task)
			end
		else
			table.insert(sp.tasks, snapshot_task(task, cfg))
		end
	end
	table.sort(done, function(a, b)
		local fa, fb = a.finished_at or 0, b.finished_at or 0
		if fa ~= fb then
			return fa > fb
		end
		return a.slug < b.slug
	end)
	for i, task in done do
		if i <= DONE_IN_SNAPSHOT or task.kept ~= nil then
			table.insert(sp.tasks, snapshot_task(task, cfg))
		end
	end
	return sp
end

-- Rebuilds the snapshot; when any part changed, writes snapshot.json, refreshes chrome and queues
-- redraws of the changed panels (all of them when `paused` flipped).
local function publish_now()
	local paused = state.paused == true
	local counts = { running = 0, needs = 0, review = 0, queued = 0 }
	local order = sorted_keys(state.projects)
	local parts: { [string]: any } = {}
	local jsons: { [string]: string } = {}
	local changed = false
	for _, pid in order do
		local sp = build_part(pid, counts)
		local json = tern.json.encode(sp)
		parts[pid] = sp
		jsons[pid] = json
		if published[pid] ~= json then
			changed = true
		end
	end
	for pid in published do
		if jsons[pid] == nil then
			changed = true
		end
	end
	local projects_error = store.projects_problem()
	local head = tern.json.encode({ paused = paused, counts = counts, projects_error = projects_error })
	if not changed and head == published_head then
		return
	end
	local snap: any = {
		format = 1,
		paused = paused,
		counts = counts,
		projects_error = projects_error,
		projects = tern.json.array(),
	}
	for _, pid in order do
		table.insert(snap.projects, parts[pid])
	end
	pcall(store.write_json, paths.snapshot_file(), snap)
	state.snapshot = snap
	if tern.chrome then
		pcall(tern.chrome.refresh)
	end
	-- Each changed panel is redrawn on its own timer calls (see panel.update), staggered by
	-- YIELD_MS so no two are due at once.
	local all = published_paused ~= paused
	local n = 0
	for _, pid in order do
		if all or published[pid] ~= jsons[pid] then
			local part = parts[pid]
			n += 1
			tern.timer(n * const.YIELD_MS, function(cx2: WindowCx?)
				if cx2 then
					local t0 = tern.now()
					pcall(panel.update, cx2, part)
					publish.log_slow("panel redraw", part.id, t0)
				end
			end)
		end
	end
	published = jsons
	published_head = head
	published_paused = paused
end

function publish.publish(_cx: WindowCx)
	local t0 = tern.now()
	publish_now()
	publish.log_slow("publish", nil, t0)
end

-- Publishes on a fresh timer callback (its own 50 ms budget), once per burst of reconciles.
function publish.request()
	if not publish_pending then
		publish_pending = true
		tern.timer(const.YIELD_MS, function(cx2: WindowCx?)
			publish_pending = false
			if cx2 and state.leader then
				pcall(publish.publish, cx2)
			end
		end)
	end
end

function publish.flush_toasts(cx: WindowCx)
	local list = state.toasts
	state.toasts = {}
	for _, t in list do
		local level = if t.level == "success" or t.level == "error" then t.level else "info"
		pcall(function()
			cx:toast(level :: any, t.text, t.sub)
		end)
	end
end

-- Non-leaders follow the leader's snapshot.json.
function publish.refresh_reader()
	local snap = store.read_json(paths.snapshot_file(), 1048576)
	if type(snap) ~= "table" then
		if snap == nil and tern.fs.exists(paths.snapshot_file()) and os.time() - snapshot_warned_at >= 60 then
			snapshot_warned_at = os.time()
			tern.log.warn("swarm: could not read snapshot.json")
		end
		return
	end
	local json = tern.json.encode(snap)
	if json ~= snapshot_json then
		snapshot_json = json
		state.snapshot = snap
		if tern.chrome then
			pcall(tern.chrome.refresh)
		end
	end
end

return publish
