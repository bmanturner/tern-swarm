--!strict
-- One project's reconcile after a board read: card removals, adoption, human lane moves, pickup,
-- then status steps, after-merge cleanup and lane sync in two time-sliced phases. Window half.

local actions = require("./actions")
local cardsync = require("./cardsync")
local config = require("./config")
local const = require("./const")
local git = require("./git")
local names = require("./names")
local paths = require("./paths")
local projects = require("./projects")
local publish = require("./publish")
local state = require("./state")
local steps = require("./steps")
local store = require("./store")
local taskctx = require("./taskctx")

local reconcile = {}

local seen: { [string]: { [string]: any } } = {}
local missing: { [string]: number } = {}
-- pid -> when "board too large" was last logged.
local unread_warned: { [string]: number } = {}

-- Forgets adoption and missing-card counts (a new leadership period starts over).
function reconcile.reset()
	seen = {}
	missing = {}
end

local function sorted_keys(t: { [string]: any }): { string }
	local keys: { string } = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

-- Phase 2 for one task of `job`: step 6b, step 7, then its save. Runs once every status step of
-- `job` has run (phase 1), in the same queue order.
local function tail_task(cx: WindowCx, job: any, ctx: any, slug: string, task: any)
	local pid, by_slug, epoch = job.pid, job.by_slug, job.epoch
	local proj = state.projects[pid]
	local cfg = ctx.cfg

	-- 6b. After a PR is merged or closed, remove the shipped task's worktree (clean.auto = after_merge),
	-- unless it holds work made after shipping. The branch goes too; a later Clean up still archives the task.
	if proj and cfg.clean.auto == "after_merge" then
		local root = proj.root
		if
			task.status == "shipped"
			and type(task.pr_url) == "string"
			and task.worktree
			and task.kept == nil
			and state.inflight[pid .. "/" .. slug] == nil
			and os.time() - (task.pr_checked_at or 0) >= 300
		then
			task.pr_checked_at = os.time()
			local url, wt, branch = task.pr_url, task.worktree, task.branch
			actions.start_op(task, "clean", function(done, alive)
				git.pr_state(root, url, function(pr)
					if pr == "MERGED" or pr == "CLOSED" then
						git.shipped_safe(root, wt, branch, task.commit, function(safe, why)
							if not safe then
								done(function()
									task.kept = why
									state.notify(
										"info",
										"Swarm: kept the worktree of " .. task.title,
										tostring(why) .. ". Discard it from the Done list when you're done with it."
									)
								end)
								return
							end
							git.remove(root, wt, branch, true, alive, function(ok, rwhy)
								done(function()
									if ok then
										task.worktree = nil
										task.kept = nil
									else
										tern.log.warn("swarm: could not remove the worktree of " .. pid .. "/" .. slug, rwhy)
									end
								end)
							end)
						end)
					else
						done(function() end)
					end
				end)
			end)
		end
	end

	-- 7. Lane sync: cards follow their task's status (not while an operation is in flight, so a
	-- human's move made meanwhile is still seen by step 4 once it finishes). A shipped task whose kept
	-- worktree is being discarded keeps its Done card.
	local card = by_slug[slug]
	local want = const.LANE[task.status]
	if
		card
		and want
		and card.lane ~= want
		and task.discard_from ~= "shipped"
		and state.inflight[pid .. "/" .. slug] == nil
		and (not const.TERMINAL[task.status] or task.lane ~= want)
	then
		local before = task.lane
		task.lane = want
		local id = card.id
		local ok = pcall(function()
			cx.board:move(id, want):next(function(_, err)
				if not state.current(epoch) then
					return
				end
				if err then
					task.lane = before
					tern.log.warn("swarm: could not move card " .. slug .. " to " .. want, err)
				end
			end)
		end)
		if not ok then
			task.lane = before
		end
	end

	store.save_task(task)
end

-- Runs `job` until const.SLICE_MS have passed: phase 1 (status steps, `job.i`) over the sorted
-- queue, then phase 2 (steps 6b-7 and the save, `job.j`) over the same queue; phase 1 flows into
-- phase 2 when time remains. Returns true when work remains; after phase 2 flushes toasts and
-- requests a publish.
local function slice(cx: WindowCx, job: any): boolean
	local t0 = tern.now()
	local ctx = taskctx.make_ctx(cx, job.pid)
	ctx.cards = job.by_slug
	while job.i <= #job.queue and (tern.now() - t0) < const.SLICE_MS do
		local slug = job.queue[job.i]
		job.i += 1
		local task = state.tasks[job.pid] and state.tasks[job.pid][slug]
		if task and not const.TERMINAL[task.status] and state.inflight[job.pid .. "/" .. slug] == nil then
			local ok, err = pcall(steps.run, ctx, task, job.by_slug[slug])
			if not ok then
				tern.log.warn("swarm: step failed for " .. job.pid .. "/" .. slug, err)
				actions.block(task, "Internal error: " .. tostring(err))
			end
			store.save_task(task)
		end
	end
	if job.i <= #job.queue then
		publish.log_slow("reconcile slice", job.pid, t0)
		return true
	end
	job.phase = 2
	while job.j <= #job.queue and (tern.now() - t0) < const.SLICE_MS do
		local slug = job.queue[job.j]
		job.j += 1
		local task = state.tasks[job.pid] and state.tasks[job.pid][slug]
		if task then
			tail_task(cx, job, ctx, slug, task)
		end
	end
	if job.j <= #job.queue then
		publish.log_slow("reconcile tail slice", job.pid, t0)
		return true
	end
	publish.flush_toasts(cx)
	publish.request()
	publish.log_slow("reconcile tail", job.pid, t0)
	return false
end

-- One timer call of a sliced reconcile; reschedules itself until done, then calls `finished`.
local function continue_job(cx2: WindowCx?, job: any, finished: () -> ())
	if cx2 == nil or not state.current(job.epoch) or state.projects[job.pid] == nil then
		finished()
		return
	end
	local ok, more = pcall(slice, cx2, job)
	if ok and more then
		tern.timer(const.YIELD_MS, function(cx3: WindowCx?)
			continue_job(cx3, job, finished)
		end)
		return
	end
	if not ok then
		tern.log.warn("swarm: reconcile failed for " .. job.pid, more)
	end
	finished()
end

-- Steps 0-5 run now. On later timer calls, each starting work for up to const.SLICE_MS, phase 1
-- runs step 6 per task and phase 2 runs steps 6b-7 and the save per task (see slice). Calls
-- `finished` exactly once, when the whole reconcile is over (or abandoned).
function reconcile.run(cx: WindowCx, pid: string, snap: any, finished: () -> ())
	local t0 = tern.now()
	local proj = state.projects[pid]
	if proj == nil or type(snap) ~= "table" or #(snap.lanes or {}) == 0 then
		finished()
		return
	end
	local unread = if (snap.more or 0) > 0 then snap.more else nil
	state.board_unread[pid] = unread
	if unread and os.time() - (unread_warned[pid] or 0) >= 600 then
		unread_warned[pid] = os.time()
		tern.log.warn("swarm: board of " .. pid .. " is too large to read in full", unread)
	end
	local epoch = state.epoch
	local tasks = state.tasks[pid] or {}
	state.tasks[pid] = tasks
	local ctx = taskctx.make_ctx(cx, pid)
	local cfg = ctx.cfg
	local roles = state.roles[pid]
	if roles == nil or (not roles.fetching and os.time() - (roles.at or 0) > const.ROLE_CACHE_S) then
		projects.fetch_roles(pid, proj.root)
	end

	local by_slug, untagged = cardsync.build(snap)
	ctx.cards = by_slug
	local complete = (snap.more or 0) == 0 and (snap.phase == nil or snap.phase == "ready")

	-- 0. Remove the Done cards Clean up archived (clean.remove_done_cards). A slug stays queued until
	-- a complete board read no longer shows its card, so a failed removal is retried next tick.
	local removals = state.card_removals[pid]
	if removals then
		for slug in removals do
			local card = by_slug[slug]
			if card == nil then
				if complete then
					removals[slug] = nil
				end
			elseif type(card.id) == "string" then
				local id = card.id
				pcall(function()
					cx.board:remove(id):next(function(_, err)
						if err then
							tern.log.warn("swarm: could not remove the card of " .. slug, err)
						end
					end)
				end)
			end
		end
		if next(removals) == nil then
			state.card_removals[pid] = nil
		end
	end

	-- 1. Adopt untagged cards (per `adopt_cards`) once their text is stable, and tagged cards without a task.
	local prev_seen = seen[pid] or {}
	local now_seen: { [string]: any } = {}
	local adopt = cfg.adopt_cards
	for _, card in (if adopt == "off" then {} else untagged) do
		if
			(card.lane == "Backlog" or (card.lane == "Ready" and adopt == "backlog_and_ready"))
			and card.title ~= ""
			and type(card.id) == "string"
		then
			local s = prev_seen[card.id]
			local count = if s and s.text == card.text and s.lane == card.lane then s.count + 1 else 1
			if count >= const.ADOPT_STABLE_TICKS then
				local slug = paths.unique_slug(pid, card.title)
				local task = taskctx.new_task(pid, slug, card.title, card.lane)
				tasks[slug] = task
				store.save_task(task)
				local tags = table.clone(card.tags)
				table.insert(tags, const.TAG_TASK .. slug)
				local id = card.id
				pcall(function()
					cx.board:edit(id, { tags = tags }):next(function(_, err)
						if not state.current(epoch) then
							return
						end
						if err then
							tern.log.warn("swarm: could not tag an adopted card", err)
						end
					end)
				end)
				card.slug = slug
				by_slug[slug] = card
			else
				now_seen[card.id] = { text = card.text, lane = card.lane, count = count }
			end
		end
	end
	seen[pid] = now_seen
	local damaged = state.damaged[pid] or {}
	for slug, card in by_slug do
		if
			tasks[slug] == nil
			and not damaged[slug]
			and (card.lane == "Backlog" or card.lane == "Ready")
			and string.find(slug, "^[a-z0-9][a-z0-9%-]*$")
		then
			local task = taskctx.new_task(pid, slug, card.title, card.lane)
			tasks[slug] = task
			store.save_task(task)
		end
	end

	-- 2-4. Card gone, title sync, short names, human lane moves. Tasks with an operation in flight or
	-- being discarded keep their card where the human put it; the move is honoured once they settle.
	-- Damaged tasks (placeholders for an unreadable task.json) are left alone.
	for slug, task in tasks do
		local key = pid .. "/" .. slug
		local card = by_slug[slug]
		state.orders[key] = if card then card.index else nil
		state.next_roles[key] = if card then card.role or cfg.default_role else nil
		if state.inflight[key] == nil and task.status ~= "discarding" and not task.damaged then
			if task.status == "cancelled" then
				if card and (card.lane == "Backlog" or card.lane == "Ready") then
					task.status = if card.lane == "Ready" then "queued" else "backlog"
					task.lane = card.lane
				end
			elseif not const.TERMINAL[task.status] then
				if card == nil then
					if complete then
						missing[key] = (missing[key] or 0) + 1
						if missing[key] >= const.MISSING_CARD_TICKS then
							missing[key] = nil
							actions.cancel(ctx, task)
							state.notify(
								"info",
								"Swarm: " .. task.title .. " was removed from the board",
								if task.worktree then "Its worktree is kept until Swarm: Clean up." else nil
							)
						end
					end
				else
					missing[key] = nil
					if card.title ~= "" and card.title ~= task.title then
						task.title = card.title
					end
					names.ensure(pid, task, cfg.tabs.names)
					if card.lane ~= task.lane then
						cardsync.human_move(ctx, task, card)
					end
				end
			end
		end
	end

	-- 5. Pickup, in Ready-lane order.
	if not state.paused and not state.paused_projects[pid] and not ctx.hold then
		local limit = cfg.max_concurrent
		local total = config.user().max_concurrent_total
		if total then
			local elsewhere = 0
			for other, list in state.tasks do
				if other ~= pid then
					for _, t in list do
						if const.ACTIVE[t.status] then
							elsewhere += 1
						end
					end
				end
			end
			limit = math.min(limit, math.max(0, total - elsewhere))
		end
		local active = 0
		local queued: { any } = {}
		for slug, task in tasks do
			if const.ACTIVE[task.status] then
				active += 1
			elseif task.status == "queued" and by_slug[slug] and state.inflight[pid .. "/" .. slug] == nil then
				table.insert(queued, task)
			end
		end
		table.sort(queued, function(a, b)
			local ca, cb = by_slug[a.slug], by_slug[b.slug]
			local la, lb = cardsync.lane_order(ca.lane), cardsync.lane_order(cb.lane)
			if la ~= lb then
				return la < lb
			end
			return ca.index < cb.index
		end)
		for _, task in queued do
			if active >= limit then
				break
			end
			local bad = by_slug[task.slug].bad_role
			if bad then
				actions.block(task, "The card's #role-" .. bad .. " tag isn't a valid omp role name")
			else
				local role = by_slug[task.slug].role or cfg.default_role
				task.role = role
				local known = state.roles[pid]
				if known and known.names and not known.names[role] then
					local known_names: { string } = {}
					for _, r in known.list or {} do
						table.insert(known_names, r.name)
					end
					actions.block(task, string.format("Unknown omp role '%s' (known: %s)", role, table.concat(known_names, ", ")))
				else
					task.status = "preparing"
					active += 1
				end
			end
		end
	end

	-- 6, 6b, 7. Status steps, then cleanup, lane sync and saves, on later timer calls (see slice).
	local queue = sorted_keys(tasks)
	local job = { pid = pid, epoch = epoch, by_slug = by_slug, queue = queue, i = 1, phase = 1, j = 1 }
	publish.log_slow("reconcile", pid, t0)
	tern.timer(const.YIELD_MS, function(cx2: WindowCx?)
		continue_job(cx2, job, finished)
	end)
end

return reconcile
