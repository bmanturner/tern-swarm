--!strict
-- The per-task status machine run on every leader reconcile: agent tracking, tab placement and
-- discarding here; preparing, checking and shipping in prepare, checking and ship.
-- `ctx` is {cx, pid, proj, cfg, hold, agents, tabs, panes, cards}.

local actions = require("./actions")
local checking = require("./checking")
local const = require("./const")
local git = require("./git")
local names = require("./names")
local prepare = require("./prepare")
local ship = require("./ship")
local state = require("./state")
local text = require("./text")

local steps = {}

local TRACK = { running = true, waiting = true, review = true, blocked = true, checking = true }

local function str(v: any): string?
	return if type(v) == "string" then v else nil
end

-- Comparable form of an agent's last message (what task.last_message and task.baseline hold).
local function msg_key(msg: string?): string
	return text.clip(msg or "", 1200)
end

-- The agent's final message as a summary: without omp's trailing "… · $0.04 this turn" stats line.
local function summary_of(msg: string?): string
	local s = text.trim(msg or "")
	local body, last = string.match(s, "^(.*)\n([^\n]*)$")
	if last and string.find(last, "this turn%s*$") and string.find(last, " · ", 1, true) then
		s = text.trim(body)
	end
	return text.clip(s, 4000)
end

-- How a pane of kind `kind` reads in "The agent opened …".
local function pane_what(kind: string?): string
	if kind == nil then
		return "a pane"
	end
	local named: { [string]: string } = {
		terminal = "a terminal",
		agent = "another agent",
		plugin = "a plugin block",
		browser = "a browser",
		file = "a file",
		git = "a git view",
		board = "a board",
	}
	return named[kind] or ("a " .. kind .. " pane")
end

-- The first pane in the task's agent/shell tab(s) that is neither its agent nor its shell, or nil.
local function foreign_pane(ctx: any, task: any): any
	local cx: WindowCx = ctx.cx
	local tabs: { [number]: boolean } = {}
	for _, own in { task.agent_pane, task.shell_pane } do
		if type(own) == "number" then
			local tab = cx.session:tab_of(own)
			if tab ~= nil then
				tabs[tab] = true
			end
		end
	end
	if next(tabs) == nil then
		return nil
	end
	for _, p in ctx.panes or {} do
		if p.pane ~= task.agent_pane and p.pane ~= task.shell_pane then
			local tab = p.tab or cx.session:tab_of(p.pane)
			if tab ~= nil and tabs[tab] then
				return p
			end
		end
	end
	return nil
end

-- Follows the task's agent: model, last message, working / waiting / idle transitions.
function steps.track_agent(ctx: any, task: any)
	if not TRACK[task.status] or type(task.agent_pane) ~= "number" then
		return
	end
	local cx: WindowCx = ctx.cx
	local pane: number = task.agent_pane
	local a = ctx.agents[pane]
	local alive = cx.session:pane(pane) ~= nil
	if a == nil or a.state ~= "working" then
		task.ui_pane = nil
	end
	if a == nil and alive then
		-- The block exists but is not listed as an agent yet (still starting).
		if task.status == "running" and os.time() - (task.prompted_at or os.time()) > const.PROMPT_STALL_S then
			actions.block_loud(task, "The agent did not start working within 3 minutes")
		end
		return
	end
	if a == nil or a.state == "exited" then
		if task.status == "running" or task.status == "waiting" then
			actions.block_loud(
				task,
				if a == nil
					then "The agent pane was closed"
					else "The agent exited (time limit " .. (task.max_time or ctx.cfg.max_time) .. " or crash). Retry to continue in the same worktree."
			)
		elseif task.status == "review" or task.status == "blocked" then
			task.agent_pane = nil
		end
		return
	end

	local model = str(a.model)
	if model and model ~= task.agent_model then
		task.agent_model = model
	end
	local msg = str(a.last_message)
	if msg then
		local short = msg_key(msg)
		if short ~= task.last_message then
			task.last_message = short
		end
		-- The final message can arrive after the agent already reported idle.
		if (task.status == "checking" or task.status == "review") and short ~= task.baseline then
			task.summary = summary_of(msg)
			task.baseline = short
		end
	end

	if a.state == "working" then
		task.busy_seen = true
		local p = foreign_pane(ctx, task)
		if p ~= nil then
			if task.ui_pane ~= p.pane or task.status ~= "waiting" then
				local what = pane_what(p.kind)
				task.ui_pane = p.pane
				task.status = "waiting"
				task.reason = "The agent opened " .. what .. " in its tab and may be waiting for you"
				state.notify("info", "Swarm: " .. task.title .. " may need you", "Its agent opened " .. what .. ". Click Focus in the Swarm panel.")
			end
			return
		end
		task.ui_pane = nil
		if task.status ~= "running" then
			-- The agent went back to work: a checks job for the old round is now orphaned.
			if task.job ~= nil and type(task.shell_pane) == "number" and cx.session:pane(task.shell_pane) ~= nil then
				local shell: number = task.shell_pane
				pcall(function()
					cx:run(shell, "\3")
				end)
			end
			task.status = "running"
			task.reason = nil
			task.job = nil
			task.no_change = nil
		end
	elseif a.state == "waiting_input" then
		if task.status ~= "waiting" then
			task.status = "waiting"
			task.reason = "The agent is asking for input"
			state.notify("info", "Swarm: " .. task.title .. " needs your input", "Open its tab or click Focus in the Swarm panel.")
		end
	elseif a.state == "idle" and (task.status == "running" or task.status == "waiting") then
		local key = msg_key(msg)
		if task.busy_seen or key ~= (task.baseline or "") then
			task.summary = summary_of(msg)
			task.baseline = key
			task.busy_seen = false
			task.status = "checking"
			task.changes_checked = nil
			task.job = nil
			task.reason = nil
		elseif task.status == "running" then
			local delivery = str(a.delivery_error)
			if delivery then
				actions.block_loud(task, "The prompt was not delivered: " .. delivery)
			elseif os.time() - (task.prompted_at or os.time()) > const.PROMPT_STALL_S then
				actions.block_loud(task, "The agent did not start working within 3 minutes")
			end
		end
	end
end

-- Keeps a task's agent above its shell in one tab named by names.label (short name with a status
-- glyph), colored by status.
function steps.placement(ctx: any, task: any)
	local cx: WindowCx = ctx.cx
	local agent: number? = if type(task.agent_pane) == "number" and cx.session:pane(task.agent_pane) then task.agent_pane else nil
	local shell: number? = if type(task.shell_pane) == "number" and cx.session:pane(task.shell_pane) then task.shell_pane else nil
	if agent == nil and shell == nil then
		return
	end
	local atab = if agent then cx.session:tab_of(agent) else nil
	local stab = if shell then cx.session:tab_of(shell) else nil
	if agent and shell and atab and stab and atab ~= stab and not task.split_tabs then
		local ok, moved = pcall(function()
			return cx.layout:move(agent, shell, "up", { focus = false })
		end)
		if ok and moved then
			atab = cx.session:tab_of(agent)
			stab = atab
			if not task.resized then
				pcall(function()
					cx.layout:resize(shell, "down", 8)
				end)
				task.resized = true
			end
		else
			task.move_fails = (task.move_fails or 0) + 1
			if task.move_fails >= 2 then
				task.split_tabs = true
			end
		end
	end
	local color = const.COLOR[task.status]
	local mode = ctx.cfg.tabs.names
	local function style(tab: number?, name: string)
		if tab == nil then
			return
		end
		local info = ctx.tabs[tab]
		if mode ~= "off" and (info == nil or info.name ~= name) then
			pcall(function()
				cx.layout:name_tab(tab, name)
			end)
		end
		if color and (info == nil or info.color ~= color) then
			pcall(function()
				cx.layout:color_tab(tab, color :: any)
			end)
		end
	end
	local label = names.label(task, mode)
	if task.split_tabs then
		style(atab, label)
		style(stab, label .. " · jobs")
	else
		style(stab or atab, label)
	end
end

-- discarding: the agent and shell are stopped; delete the worktree and branch, then back to Backlog.
-- A shipped task's kept worktree (discard_from = "shipped") loses only its worktree and stays shipped.
function steps.discarding(ctx: any, task: any)
	if task.discard_from == "shipped" then
		local root, wt, branch = ctx.proj.root, task.worktree, task.branch
		actions.start_op(task, "discard", function(done, alive)
			git.remove(root, wt, nil, false, alive, function(ok, why)
				done(function()
					task.status = "shipped"
					task.discard_from = nil
					if ok then
						task.worktree = nil
						task.kept = nil
						task.agent_pane = nil
						task.shell_pane = nil
						state.notify("info", "Swarm: removed the worktree of " .. task.title, if branch then "Kept branch " .. branch else nil)
					else
						task.kept = "Swarm couldn't remove the worktree: " .. (why or "unknown error")
						state.notify("error", "Swarm: couldn't remove the worktree of " .. task.title, why)
					end
				end)
			end)
		end)
		return
	end
	if task.worktree == nil and task.branch == nil then
		actions.clear(task)
		return
	end
	local root, wt, branch = ctx.proj.root, task.worktree, task.branch
	local keep = not ctx.cfg.discard.delete_branch
	actions.start_op(task, "discard", function(done, alive)
		git.remove(root, wt, branch, not keep, alive, function(ok, why)
			done(function()
				if ok then
					actions.clear(task)
					if keep and branch then
						state.notify("info", "Swarm: discarded " .. task.title, "Kept branch " .. branch)
					end
				else
					actions.block_loud(task, "Could not remove the worktree: " .. (why or "unknown error"))
				end
			end)
		end)
	end)
end

-- One reconcile step for a non-terminal task without an operation in flight.
function steps.run(ctx: any, task: any, card: any)
	if task.damaged then
		return
	end
	steps.track_agent(ctx, task)
	local st = task.status
	if st == "preparing" then
		prepare.run(ctx, task)
	elseif st == "checking" then
		checking.run(ctx, task, card)
	elseif st == "shipping" then
		ship.step(ctx, task, card)
	elseif st == "discarding" then
		steps.discarding(ctx, task)
	end
	if not const.TERMINAL[task.status] then
		steps.placement(ctx, task)
	end
end

return steps
