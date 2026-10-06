--!strict
-- Clean up: removes worktrees of finished tasks and archives their task folders. A shipped task's
-- worktree holding work made after shipping is kept (task.kept). Leader window only.

local actions = require("./actions")
local const = require("./const")
local git = require("./git")
local paths = require("./paths")
local run = require("./run")
local state = require("./state")
local store = require("./store")

local cleanup = {}

local function archive(pid: string, task: any, cb: (boolean) -> ())
	local slug = task.slug
	local src = paths.task_dir(pid, slug)
	pcall(tern.fs.mkdir, paths.archive_dir(pid))
	local dst = paths.archive_dir(pid) .. "/" .. slug
	if tern.fs.exists(dst) then
		dst ..= "-" .. os.time()
	end
	run.exec({ "mv", src, dst }, { timeout_ms = 30000 }, function(r)
		if r.status ~= 0 then
			tern.log.warn("swarm: could not archive " .. slug, run.why(r))
			cb(false)
			return
		end
		task.archived = true
		local tasks = state.tasks[pid]
		if tasks then
			tasks[slug] = nil
		end
		store.forget(pid, slug)
		cb(true)
	end)
end

-- Removes worktrees of finished tasks and archives them, across all projects (or only `only_pid`).
-- `cfg_of(pid)` returns that project's merged config.
function cleanup.clean(_cx: WindowCx, only_pid: string?, cfg_of: (pid: string) -> any)
	local pending, cleaned, skipped = 0, 0, 0
	local function finished(ok: boolean)
		if ok then
			cleaned += 1
		else
			skipped += 1
		end
		pending -= 1
		if pending == 0 then
			state.notify(
				"success",
				"Swarm: cleaned " .. cleaned .. " worktree" .. (if cleaned == 1 then "" else "s"),
				if skipped > 0 then skipped .. " skipped (open PR, work made after shipping, uncommitted changes, or removal failed)" else nil
			)
		end
	end
	local started = 0
	for pid, tasks in state.tasks do
		local proj = state.projects[pid]
		if proj and (only_pid == nil or pid == only_pid) then
			local remove_cards = false
			local cfg_ok, pcfg = pcall(cfg_of, pid)
			if cfg_ok and pcfg then
				remove_cards = pcfg.clean.remove_done_cards == true
			end
			for _, task in tasks do
				if const.TERMINAL[task.status] and not task.damaged and state.inflight[pid .. "/" .. task.slug] == nil then
					local root, wt, branch = proj.root, task.worktree, task.branch
					local function remove_then_archive(delete_branch: boolean, done: (apply: () -> ()) -> (), alive: () -> boolean)
						git.remove(root, wt, branch, delete_branch, alive, function(ok, why)
							if not ok then
								tern.log.warn("swarm: clean could not remove the worktree of " .. pid .. "/" .. task.slug, why)
								done(function() end)
								finished(false)
								return
							end
							local slug = task.slug
							archive(pid, task, function(archived)
								if archived and remove_cards then
									local set = state.card_removals[pid]
									if set == nil then
										set = {}
										state.card_removals[pid] = set
									end
									set[slug] = true
								end
								done(function()
									task.kept = nil
								end)
								finished(archived)
							end)
						end)
					end
					-- Removes a shipped task's worktree only when no work made after shipping would be lost.
					local function safe_then_archive(delete_branch: boolean, done: (apply: () -> ()) -> (), alive: () -> boolean)
						git.shipped_safe(root, wt, branch, task.commit, function(safe, why)
							if safe then
								remove_then_archive(delete_branch, done, alive)
								return
							end
							done(function()
								task.kept = why
							end)
							finished(false)
						end)
					end
					pending += 1
					started += 1
					actions.start_op(task, "clean", function(done, alive)
						if task.status == "shipped" and task.pr_url then
							git.pr_state(root, task.pr_url, function(pr)
								if pr == "MERGED" or pr == "CLOSED" then
									safe_then_archive(true, done, alive)
								else
									done(function() end)
									finished(false)
								end
							end)
						elseif task.status == "shipped" then
							safe_then_archive(false, done, alive)
						else
							git.clean_tree(wt, function(is_clean)
								if is_clean then
									remove_then_archive(false, done, alive)
								else
									done(function() end)
									finished(false)
								end
							end)
						end
					end)
				end
			end
		end
	end
	if started == 0 then
		state.notify("info", "Swarm: nothing to clean up")
	end
end

return cleanup
