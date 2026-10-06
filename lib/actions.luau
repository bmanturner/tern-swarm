--!strict
-- Task actions (approve, discard, retry, park, close, cancel) and the helpers the status steps share.
-- Leader window only. `ctx` is {cx, pid, proj, cfg, agents, tabs, cards}.

local const = require("./const")
local state = require("./state")
local store = require("./store")

local actions = {}

-- Whether the board card carries `tag` (card tags are stored without `#`).
function actions.has_tag(card: any, tag: string): boolean
	return card ~= nil and table.find(card.tags or {}, tag) ~= nil
end

function actions.block(task: any, reason: string)
	task.status = "blocked"
	task.reason = reason
end

function actions.block_loud(task: any, reason: string)
	actions.block(task, reason)
	state.notify("error", "Swarm: " .. task.title .. " is blocked", reason)
end

-- Runs async operation `op` for `task` unless one is already in flight. `fn` receives `done(apply)` and
-- `alive()` (true while this VM still leads in the leadership period the op started in); `apply` runs
-- only if the task's status is unchanged since the start, then the task is saved and the orchestrator
-- woken. A `done` from a past leadership period does nothing. While in flight the orchestrator leaves
-- the task alone.
function actions.start_op(task: any, op: string, fn: (done: (apply: () -> ()) -> (), alive: () -> boolean) -> ()): boolean
	local key = task.project .. "/" .. task.slug
	if state.inflight[key] then
		return false
	end
	local status = task.status
	local epoch = state.epoch
	local function alive(): boolean
		return state.current(epoch)
	end
	state.inflight[key] = { op = op, status = status }
	local ok, err = pcall(fn, function(apply: () -> ())
		if not alive() then
			return
		end
		state.inflight[key] = nil
		if task.status == status then
			local applied, apply_err = pcall(apply)
			if not applied then
				tern.log.warn("swarm: " .. op .. " failed for " .. key, apply_err)
				actions.block(task, "Internal error: " .. tostring(apply_err))
			end
		end
		store.save_task(task)
		state.poke()
	end, alive)
	if not ok then
		state.inflight[key] = nil
		tern.log.warn("swarm: could not start " .. op .. " for " .. key, err)
		actions.block(task, "Internal error: " .. tostring(err))
	end
	return true
end

function actions.stop_agent(cx: WindowCx, task: any)
	local pane = task.agent_pane
	if type(pane) == "number" then
		pcall(function()
			cx.agents:stop(pane)
		end)
	end
	task.agent_pane = nil
end

function actions.close_shell(cx: WindowCx, task: any)
	local pane = task.shell_pane
	if type(pane) == "number" and cx.session:pane(pane) ~= nil then
		pcall(function()
			cx.layout:close(pane)
		end)
	end
	task.shell_pane = nil
	task.job = nil
	task.job_wait_since = nil
end

-- The task's live shell pane. Opens one in the worktree when it is gone and returns nil (jobs wait for
-- its prompt); the second result is true when the worktree itself is missing.
function actions.ensure_shell(ctx: any, task: any): (number?, boolean?)
	local cx: WindowCx = ctx.cx
	if type(task.shell_pane) == "number" and cx.session:pane(task.shell_pane) ~= nil then
		return task.shell_pane, nil
	end
	if task.worktree == nil or not tern.fs.exists(task.worktree) then
		return nil, true
	end
	local ok, pane = pcall(function()
		return cx.layout:new_tab({ cwd = task.worktree }, { focus = false })
	end)
	if not ok or type(pane) ~= "number" then
		tern.log.warn("swarm: could not open a shell for " .. task.slug, pane)
		return nil, nil
	end
	task.shell_pane = pane
	task.job = nil
	task.job_wait_since = nil
	task.resized = nil
	local sid = ctx.proj and ctx.proj.session
	if type(sid) == "number" then
		pcall(function()
			if cx.sessions:current().id ~= sid then
				for _, s in cx.sessions:list() do
					if s.id == sid then
						cx.layout:move_to_new_tab(pane, sid, { focus = false })
						break
					end
				end
			end
		end)
	end
	return nil, nil
end

-- review → shipping; the ship job starts in ship.step. False when the task is not in review.
function actions.approve(_ctx: any, task: any): boolean
	if not const.CAN.approve[task.status] then
		return false
	end
	task.status = "shipping"
	task.ship_error = nil
	task.job = nil
	task.job_wait_since = nil
	return true
end

-- Resets everything about the task's attempt and returns it to Backlog (keeps title, role tag, details
-- and its short name).
function actions.clear(task: any)
	for _, field in {
		"worktree", "worktree_ready", "setup_done", "resume", "branch", "base_ref", "base_sha", "agent_pane",
		"agent_model", "shell_pane", "job", "checks", "review", "summary", "last_message", "reason", "ship_error",
		"tab_color", "resized", "split_tabs", "move_fails", "changes_checked", "busy_seen", "baseline",
		"prompted_at", "started_at", "job_wait_since", "finished_at", "no_change", "ui_pane", "preexisting", "kept",
		"discard_from",
	} do
		task[field] = nil
	end
	task.attempt = 0
	task.status = "backlog"
end

-- Stops the agent and shell and marks the task `discarding`; steps.discarding then deletes the worktree
-- and branch and clears it back to Backlog. A shipped task whose worktree Swarm kept is accepted too:
-- only its worktree goes and it stays shipped. False when the status does not allow a discard.
function actions.discard(ctx: any, task: any): boolean
	local shipped = task.status == "shipped" and task.kept ~= nil and task.worktree ~= nil
	if not const.CAN.discard[task.status] and not shipped then
		return false
	end
	local cx: WindowCx = ctx.cx
	actions.stop_agent(cx, task)
	actions.close_shell(cx, task)
	if shipped then
		task.discard_from = "shipped"
	end
	task.status = "discarding"
	task.reason = nil
	return true
end

local RETRY_FROM = {
	waiting = true,
	blocked = true,
	review = true,
	parked = true,
	backlog = true,
	queued = true,
	preparing = true,
	running = true,
	checking = true,
}

-- A fresh agent in the same worktree (resume prompt when the worktree exists). False when the status
-- does not allow a retry.
function actions.retry(ctx: any, task: any, from_move: boolean): boolean
	local allowed = if from_move then RETRY_FROM[task.status] else const.CAN.retry[task.status]
	if not allowed then
		return false
	end
	local cx: WindowCx = ctx.cx
	if task.job and type(task.shell_pane) == "number" and cx.session:pane(task.shell_pane) ~= nil then
		pcall(function()
			cx:run(task.shell_pane, "\3")
		end)
	end
	actions.stop_agent(cx, task)
	task.resume = task.worktree_ready == true or nil
	task.attempt = 0
	task.job = nil
	task.job_wait_since = nil
	task.checks = nil
	task.review = nil
	task.ship_error = nil
	task.changes_checked = nil
	task.no_change = nil
	task.status = "queued"
	return true
end

-- Stops the agent and shell and moves the task to Backlog (the worktree stays). False when the status
-- does not allow parking.
function actions.park(ctx: any, task: any): boolean
	if not const.CAN.park[task.status] then
		return false
	end
	local cx: WindowCx = ctx.cx
	actions.stop_agent(cx, task)
	actions.close_shell(cx, task)
	task.status = "parked"
	task.reason = "Parked by you"
	task.resume = task.worktree_ready == true or nil
	return true
end

-- Card moved to Done outside review: stop and close (the worktree stays until clean).
function actions.close(ctx: any, task: any)
	local cx: WindowCx = ctx.cx
	actions.stop_agent(cx, task)
	actions.close_shell(cx, task)
	task.status = "closed"
	task.finished_at = os.time()
end

-- Card removed from the board.
function actions.cancel(ctx: any, task: any)
	local cx: WindowCx = ctx.cx
	actions.stop_agent(cx, task)
	actions.close_shell(cx, task)
	task.status = "cancelled"
	task.finished_at = os.time()
end

return actions
