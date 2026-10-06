--!strict
-- The `preparing` status step: worktree → shell → setup → agent, one sub-step at a time.
-- `ctx` is {cx, pid, proj, cfg, hold, agents, tabs, panes, cards}.

local actions = require("./actions")
local const = require("./const")
local git = require("./git")
local jobs = require("./jobs")
local paths = require("./paths")
local prompts = require("./prompts")
local sh = require("./sh")
local store = require("./store")

local prepare = {}

-- Setup commands for the worktree: configured, else `npm ci` when a lockfile exists without node_modules.
local function setup_commands(ctx: any, task: any): { string }
	if ctx.cfg.setup then
		return ctx.cfg.setup
	end
	if tern.fs.exists(task.worktree .. "/package-lock.json") and not tern.fs.exists(task.worktree .. "/node_modules") then
		return { "npm ci" }
	end
	return {}
end

local function start_agent(ctx: any, task: any)
	local cx: WindowCx = ctx.cx
	local cfg = ctx.cfg
	local prompt = if task.resume then prompts.resume(task, cfg) else prompts.initial(task, cfg)
	pcall(store.write_text, paths.task_dir(task.project, task.slug) .. "/prompt.md", prompt)
	local prev = cx.session:focused()
	local rc = cfg.roles[task.role] or {}
	local max_time = rc.max_time or cfg.max_time
	-- A role's agent_args replace the defaults but never the approval tokens, which come from the user.
	local args: { string } = cfg.agent_args
	if rc.agent_args then
		args = table.clone(cfg.approval_args)
		table.move(rc.agent_args, 1, #rc.agent_args, #args + 1, args)
	end
	local command = "omp --model " .. sh.quote("@" .. task.role) .. " --max-time " .. max_time
	if #args > 0 then
		command ..= " " .. table.concat(args, " ")
	end
	local ok, pane = pcall(function()
		return cx.agents:start({ prompt = prompt, cwd = task.worktree, how = "tab", command = command })
	end)
	if not ok or type(pane) ~= "number" then
		actions.block_loud(task, "Could not start the agent: " .. tostring(pane))
		return
	end
	task.agent_pane = pane
	task.max_time = max_time
	task.agent_model = nil
	task.status = "running"
	task.attempt = math.max(task.attempt or 0, 0) + 1
	task.busy_seen = false
	task.baseline = ""
	task.last_message = nil
	task.prompted_at = os.time()
	task.started_at = os.time()
	task.reason = nil
	task.resume = nil
	task.move_fails = nil
	task.split_tabs = nil
	if prev ~= nil and cx.session:focused() ~= prev then
		pcall(function()
			cx.layout:focus(prev)
		end)
	end
end

-- preparing: worktree → shell → setup → agent, one sub-step at a time. Nothing runs while the project
-- is held (broken config or not approved).
function prepare.run(ctx: any, task: any)
	if ctx.hold then
		return
	end
	local cx: WindowCx = ctx.cx
	if not task.worktree_ready then
		local root, cfg = ctx.proj.root, ctx.cfg
		local opts: git.PrepareOpts = {
			worktree_dir = cfg.worktree_dir,
			base = cfg.base,
			branch_prefix = cfg.branch_prefix,
			remote = cfg.remote,
			tool = cfg.worktree_tool,
		}
		actions.start_op(task, "prepare", function(done, alive)
			-- Persist the path and branch before git creates them, so a discard after a lost prepare
			-- (reload mid-creation) still removes them.
			local function claim(wt: string, branch: string)
				if alive() then
					task.worktree = wt
					task.branch = branch
					store.save_task(task)
				end
			end
			git.prepare(root, opts, task, alive, claim, function(res)
				-- `pre`: the untracked and ignored entries of a newly created worktree (never kept out of
				-- commits for resumed or reattached worktrees, where files may be the agent's).
				local function apply(pre: { string }?)
					done(function()
						if res.ok then
							task.worktree = res.worktree
							task.branch = res.branch
							task.base_ref = res.base_ref
							task.base_sha = res.base_sha
							task.worktree_ready = true
							if res.resume then
								task.resume = true
							end
							if pre ~= nil then
								task.preexisting = pre
							end
						else
							actions.block_loud(task, res.reason or "Could not create the worktree")
						end
					end)
				end
				if res.ok and not res.resume and task.preexisting == nil and res.worktree ~= nil then
					git.baseline(res.worktree, apply)
				else
					apply(nil)
				end
			end)
		end)
		return
	end
	if task.worktree == nil or not tern.fs.exists(task.worktree) then
		task.worktree_ready = nil
		task.setup_done = nil
		return
	end
	if task.job ~= nil and task.job.kind ~= "setup" then
		task.job = nil
	end
	if not task.setup_done then
		if task.job == nil then
			local cmds = setup_commands(ctx, task)
			if #cmds > 0 then
				local shell = actions.ensure_shell(ctx, task)
				if shell == nil then
					return
				end
				local list: { jobs.Step } = {}
				for i, c in cmds do
					table.insert(list, { name = "setup-" .. i, run = c })
				end
				if jobs.start(cx, task, "setup", list, true, { timeout_s = ctx.cfg.timeouts.setup, env = ctx.cfg.env }) == "busy" then
					actions.block_loud(task, const.BUSY_REASON)
				end
				return
			end
			task.setup_done = true
		else
			local res = jobs.poll(cx, task)
			if res == nil then
				return
			end
			task.job = nil
			if res.status ~= "passed" then
				local failed = res.status
				for _, s in res.steps or {} do
					if s.status ~= nil and s.status ~= 0 then
						failed = s.run
						break
					end
				end
				actions.block_loud(task, "Setup failed: " .. failed)
				return
			end
			task.setup_done = true
		end
	end
	local shell = actions.ensure_shell(ctx, task)
	if shell == nil then
		return
	end
	start_agent(ctx, task)
end

return prepare
