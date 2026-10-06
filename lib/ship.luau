--!strict
-- Shipping: commits the task's worktree (and pushes and opens a PR in "pr" mode) as a job in the
-- task's shell, then records the outcome. Leader window only.

local actions = require("./actions")
local const = require("./const")
local git = require("./git")
local jobs = require("./jobs")
local run = require("./run")
local schema = require("./schema")
local sh = require("./sh")
local state = require("./state")
local store = require("./store")
local text = require("./text")

local ship = {}

local function pr_body(task: any): string
	local parts: { string } = {}
	local details = text.trim(store.details(task.project, task.slug))
	if details ~= "" then
		table.insert(parts, details)
		table.insert(parts, "")
	end
	table.insert(parts, "## Summary")
	local summary = text.trim(task.summary or "")
	table.insert(parts, if summary ~= "" then text.clip(summary, 6000) else "_The agent left no summary._")
	table.insert(parts, "")
	table.insert(parts, "## Checks")
	if task.checks and #task.checks > 0 then
		for _, c in task.checks do
			local icon = if c.status == 0 then "✅" elseif c.status == nil then "–" else "❌"
			table.insert(parts, string.format("- %s %s (%ds)", icon, c.name, c.secs or 0))
		end
	else
		table.insert(parts, "- (none configured)")
	end
	table.insert(parts, "")
	table.insert(
		parts,
		string.format(
			"<sub>Opened by Tern Swarm · role `%s` · %d attempt(s) · branch `%s`</sub>",
			task.role or "default",
			task.attempt or 1,
			task.branch or "?"
		)
	)
	return table.concat(parts, "\n") .. "\n"
end

local function ship_vars(task: any): { [string]: string }
	return { title = task.title, slug = task.slug, role = task.role or "default", branch = task.branch or "" }
end

-- `pathspec`: dir/add-pathspec.txt exists and keeps the files present before the agent ran out.
local function ship_steps(task: any, dir: string, cfg: any, card: any, pathspec: boolean): { jobs.Step }
	local q = sh.quote
	local add = if pathspec then "git add -A --pathspec-from-file=" .. q(dir .. "/add-pathspec.txt") else "git add -A"
	local list: { jobs.Step } = {
		{
			name = "commit",
			run = add .. " && (git diff --cached --quiet || git commit -q -F "
				.. q(dir .. "/commit-msg.txt")
				.. ") && git rev-parse --short HEAD > "
				.. q(dir .. "/commit"),
		},
	}
	if cfg.ship == "pr" then
		local remote: string = cfg.remote
		local base_branch: string = task.base_ref or "main"
		if string.sub(base_branch, 1, #remote + 1) == remote .. "/" then
			base_branch = string.sub(base_branch, #remote + 2)
		end
		local extra = ""
		if cfg.pr.draft or actions.has_tag(card, const.TAG_DRAFT) then
			extra ..= " --draft"
		end
		if #cfg.pr.reviewers > 0 then
			extra ..= " --reviewer " .. q(table.concat(cfg.pr.reviewers, ","))
		end
		if #cfg.pr.labels > 0 then
			extra ..= " --label " .. q(table.concat(cfg.pr.labels, ","))
		end
		if #cfg.pr.assignees > 0 then
			extra ..= " --assignee " .. q(table.concat(cfg.pr.assignees, ","))
		end
		table.insert(list, { name = "push", run = "git push -u " .. q(remote) .. " " .. q(task.branch) })
		table.insert(list, {
			name = "pr",
			run = "gh pr view "
				.. q(task.branch)
				.. " --json url -q .url > "
				.. q(dir .. "/pr_url")
				.. " 2>/dev/null || { gh pr create --base "
				.. q(base_branch)
				.. " --head "
				.. q(task.branch)
				.. " --title "
				.. q(schema.render(cfg.pr.title, ship_vars(task)))
				.. " --body-file "
				.. q(dir .. "/pr-body.md")
				.. extra
				.. " && gh pr view "
				.. q(task.branch)
				.. " --json url -q .url > "
				.. q(dir .. "/pr_url")
				.. "; }",
		})
	end
	return list
end

-- Drives a `shipping` task: starts the ship job, then records its outcome.
function ship.step(ctx: any, task: any, card: any)
	local cx: WindowCx = ctx.cx
	if task.job ~= nil and task.job.kind ~= "ship" then
		task.job = nil
	end
	if task.job == nil then
		if task.no_change then
			actions.close(ctx, task)
			state.notify("success", "Swarm: closed " .. task.title, "Nothing to ship")
			return
		end
		-- Nothing ships while the project is held (broken config or not approved).
		if ctx.hold then
			return
		end
		local shell, missing = actions.ensure_shell(ctx, task)
		if shell == nil then
			if missing then
				task.status = "review"
				task.ship_error = "The worktree is gone"
			end
			return
		end
		local ready = jobs.ready(cx, task)
		if ready == "busy" then
			task.status = "review"
			task.ship_error = "The task's shell is busy; finish or interrupt what's running in it, then Approve again"
			state.notify("error", "Swarm: shipping " .. task.title .. " failed", task.ship_error)
			return
		elseif ready ~= "ready" then
			return
		end
		local seq, dir = jobs.alloc(task, "ship")
		store.write_text(dir .. "/commit-msg.txt", schema.render(ctx.cfg.commit.message, ship_vars(task)) .. "\n")
		store.write_text(dir .. "/pr-body.md", pr_body(task))
		local pre = task.preexisting
		local pathspec = type(pre) == "table" and #pre > 0
		if pathspec then
			local lines: { string } = { ":/" }
			for _, path in pre do
				table.insert(lines, ":(exclude,literal)" .. path)
			end
			store.write_text(dir .. "/add-pathspec.txt", table.concat(lines, "\n") .. "\n")
		end
		task.ship_mode = ctx.cfg.ship
		jobs.launch(
			cx,
			task,
			"ship",
			ship_steps(task, dir, ctx.cfg, card, pathspec),
			true,
			seq,
			dir,
			{ timeout_s = ctx.cfg.timeouts.ship, env = ctx.cfg.env }
		)
		return
	end
	local res = jobs.poll(cx, task)
	if res == nil then
		return
	end
	local job = task.job
	task.job = nil
	if res.status == "passed" then
		task.commit = run.trim(store.read_text(job.dir .. "/commit", 256))
		if task.ship_mode == "pr" then
			local url = run.trim(store.read_text(job.dir .. "/pr_url", 1024))
			task.pr_url = if url ~= "" then url else nil
		end
		actions.stop_agent(cx, task)
		actions.close_shell(cx, task)
		task.status = "shipped"
		task.finished_at = os.time()
		task.reason = nil
		task.ship_error = nil
		if task.worktree and ctx.cfg.clean.auto == "after_ship" then
			local root, wt, branch = ctx.proj.root, task.worktree, task.branch
			actions.start_op(task, "clean", function(done, alive)
				-- Never remove work made after shipping (uncommitted changes or later commits).
				git.shipped_safe(root, wt, branch, task.commit, function(safe, kept_why)
					if not safe then
						done(function()
							task.kept = kept_why
						end)
						return
					end
					git.remove(root, wt, branch, false, alive, function(ok, why)
						if not ok then
							tern.log.warn("swarm: could not remove the worktree of " .. task.slug .. " after shipping", why)
						end
						done(function()
							if ok then
								task.worktree = nil
								task.kept = nil
							end
						end)
					end)
				end)
			end)
		end
		if task.pr_url then
			local n = string.match(task.pr_url, "(%d+)$")
			if n and card then
				local title = text.trim(card.title or task.title)
				pcall(function()
					cx.board:edit(card.id, { text = title .. " · PR " .. n, tags = card.tags }):next(function(_, err)
						if err then
							tern.log.warn("swarm: could not note the PR on the card", err)
						end
					end)
				end)
			end
			state.notify("success", "Swarm: opened PR for " .. task.title, task.pr_url)
		else
			state.notify("success", "Swarm: committed " .. task.title, (task.branch or "?") .. " @ " .. (task.commit or "?"))
		end
		return
	end
	local failed_name: string? = nil
	for _, s in res.steps or {} do
		if s.status ~= 0 then
			failed_name = s.name
			break
		end
	end
	local detail = if failed_name then text.trim(text.tail(jobs.tail(job, failed_name), 600)) else ""
	if detail == "" then
		detail = "Shipping " .. res.status .. (if failed_name then " at " .. failed_name else "")
	end
	task.status = "review"
	task.ship_error = detail
	state.notify("error", "Swarm: shipping " .. task.title .. " failed", run.first_line(detail))
end

return ship
