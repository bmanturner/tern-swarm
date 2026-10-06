--!strict
-- The `checking` status step: changes gate → checks job → review, feedback round, or blocked.
-- `ctx` is {cx, pid, proj, cfg, hold, agents, tabs, panes, cards}.

local actions = require("./actions")
local const = require("./const")
local git = require("./git")
local jobs = require("./jobs")
local prompts = require("./prompts")
local state = require("./state")

local checking = {}

local function fmt_secs(s: number): string
	return if s % 60 == 0 then (s // 60) .. " min" else s .. " s"
end

-- Checks passed (or nothing to check): read the change summary, then review, or ship right away when
-- the project or the card asks for it.
local function pass(ctx: any, task: any, card: any)
	local wt, base = task.worktree, task.base_sha or "HEAD"
	actions.start_op(task, "review", function(done)
		git.review(wt, base, function(r)
			done(function()
				task.review = r
				task.status = "review"
				task.reason = nil
				local stats = string.format("%d files · +%d −%d", r.count, r.add, r.del)
				local auto = (actions.has_tag(card, const.TAG_AUTO_SHIP) or ctx.cfg.on_checks_pass == "ship")
					and not task.no_change
					and #ctx.cfg.checks > 0
				if auto and ctx.hold then
					state.notify("error", "Swarm: can't ship " .. task.title, ctx.hold)
				elseif auto then
					actions.approve(ctx, task)
					state.notify("success", "Swarm: shipping " .. task.title .. " automatically", stats)
				else
					state.notify("success", "Swarm: " .. task.title .. " is ready for review", stats)
				end
			end)
		end)
	end)
end

-- checking: changes gate → checks job → pass, feedback round, or blocked.
function checking.run(ctx: any, task: any, card: any)
	local cx: WindowCx = ctx.cx
	local cfg = ctx.cfg
	local policy = if actions.has_tag(card, const.TAG_NO_CHANGE_OK) then "review" else cfg.no_change
	if not task.changes_checked then
		local wt, base = task.worktree, task.base_sha
		actions.start_op(task, "changes", function(done)
			git.changed(wt, base, function(changed)
				done(function()
					if changed == false then
						if policy == "block" then
							actions.block_loud(task, "The agent finished without changing anything")
						else
							task.no_change = true
							task.changes_checked = true
						end
					else
						task.changes_checked = true
					end
				end)
			end)
		end)
		return
	end
	if task.job ~= nil and task.job.kind ~= "checks" then
		task.job = nil
	end
	if task.job == nil then
		if task.no_change then
			-- Decided on the tick after the changes op, so closing panes uses this tick's fresh cx.
			if policy == "done" then
				actions.close(ctx, task)
				state.notify("success", "Swarm: " .. task.title .. " finished without changes")
			else
				task.checks = nil
				pass(ctx, task, card)
			end
			return
		end
		if #cfg.checks == 0 then
			task.checks = nil
			pass(ctx, task, card)
			return
		end
		-- No checks start while the project is held (broken config or not approved).
		if ctx.hold then
			return
		end
		local shell, missing = actions.ensure_shell(ctx, task)
		if shell == nil then
			if missing then
				actions.block_loud(task, "The worktree is gone")
			end
			return
		end
		local list: { jobs.Step } = {}
		for _, c in cfg.checks do
			table.insert(list, { name = c.name, run = c.run })
		end
		if jobs.start(cx, task, "checks", list, cfg.checks_mode == "fail_fast", { timeout_s = cfg.timeouts.checks, env = cfg.env }) == "busy" then
			actions.block_loud(task, const.BUSY_REASON)
		end
		return
	end
	local res = jobs.poll(cx, task)
	if res == nil then
		return
	end
	local job = task.job
	task.job = nil
	task.checks = res.steps
	if res.status == "passed" then
		pass(ctx, task, card)
		return
	end
	if res.status == "failed" then
		local failed: { any } = {}
		local failed_names: { string } = {}
		for _, s in res.steps do
			if s.status ~= nil and s.status ~= 0 then
				table.insert(failed, s)
				table.insert(failed_names, s.name)
			end
		end
		if (task.attempt or 1) < cfg.max_attempts then
			local agent = task.agent_pane
			local a = if type(agent) == "number" then ctx.agents[agent] else nil
			local asked = false
			if a ~= nil and a.state ~= "exited" then
				asked = pcall(function()
					cx.agents:ask(agent, prompts.feedback(task, job, failed, cfg.max_attempts))
				end)
			end
			if asked then
				task.attempt = (task.attempt or 1) + 1
				task.status = "running"
				task.busy_seen = false
				task.baseline = task.last_message or ""
				task.prompted_at = os.time()
				task.reason = nil
			else
				actions.block_loud(task, "Checks failed and the agent is gone")
			end
			return
		end
		actions.block_loud(task, string.format("Checks failed on attempt %d of %d: %s", task.attempt or 1, cfg.max_attempts, table.concat(failed_names, ", ")))
	elseif res.status == "aborted" then
		actions.block_loud(task, "Checks were interrupted")
	else
		actions.block_loud(task, "Checks timed out after " .. fmt_secs(cfg.timeouts.checks))
	end
end

return checking
