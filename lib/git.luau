--!strict
-- Git operations for tasks, run as background processes. Window half. Every callback runs later.

local run = require("./run")
local text = require("./text")

local git = {}

local function g(args: { string }, timeout: number?, cb: (run.Result) -> ())
	local argv = { "git" }
	for _, a in args do
		table.insert(argv, a)
	end
	run.exec(argv, { timeout_ms = timeout or 60000 }, function(r)
		cb(r)
	end)
end

local function rand_hex4(): string
	return string.format("%04x", math.random(0, 0xffff))
end

-- The base ref: `configured`, else `remote`'s default branch, else the current branch.
local function resolve_base(root: string, configured: string?, remote: string, cb: (string?) -> ())
	if configured then
		cb(configured)
		return
	end
	g({ "-C", root, "symbolic-ref", "--short", "refs/remotes/" .. remote .. "/HEAD" }, 10000, function(r)
		local ref = run.trim(r.stdout)
		if r.status == 0 and ref ~= "" then
			cb(ref)
			return
		end
		g({ "-C", root, "rev-parse", "--abbrev-ref", "HEAD" }, 10000, function(r2)
			local head = run.trim(r2.stdout)
			cb(if r2.status == 0 and head ~= "" and head ~= "HEAD" then head else nil)
		end)
	end)
end

export type PrepareOpts = {
	worktree_dir: string,
	base: string?,
	branch_prefix: string,
	remote: string,
	tool: string,
}

export type Prepared = {
	ok: boolean,
	reason: string?,
	worktree: string?,
	branch: string?,
	base_ref: string?,
	base_sha: string?,
	resume: boolean?,
}

-- Checks that `wt` is the top of a worktree of `root`'s repository, checked out on `branch`.
local function verify_worktree(root: string, wt: string, branch: string, cb: (ok: boolean, why: string?) -> ())
	g({ "-C", wt, "rev-parse", "--show-prefix" }, 10000, function(r)
		if r.status ~= 0 or run.trim(r.stdout) ~= "" then
			cb(false, "not the top of a git worktree")
			return
		end
		g({ "-C", wt, "rev-parse", "--path-format=absolute", "--git-common-dir" }, 10000, function(r2)
			g({ "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir" }, 10000, function(r3)
				local mine = run.trim(r2.stdout)
				if r2.status ~= 0 or r3.status ~= 0 or mine == "" or mine ~= run.trim(r3.stdout) then
					cb(false, "a worktree of another repository")
					return
				end
				g({ "-C", wt, "symbolic-ref", "--short", "-q", "HEAD" }, 10000, function(r4)
					local actual = run.trim(r4.stdout)
					if r4.status ~= 0 or actual ~= branch then
						cb(false, "on branch " .. (if actual ~= "" then actual else "(detached)") .. " instead of " .. branch)
						return
					end
					cb(true, nil)
				end)
			end)
		end)
	end)
end

local SUPERSEDED: Prepared = { ok = false, reason = "superseded" }

-- Creates (or finds) the task's worktree on its branch, normalized to the base. See the plan's Step 4.1.
-- Stops with reason "superseded" before any mutating command once `alive()` is false. `claim(wt, branch)`
-- runs once, right before the worktree is created, so the caller can persist the path and branch before
-- git touches them; it never runs when `wt` already exists (that directory is only verified, not claimed).
-- A branch the task already claimed (`task.branch`) is checked out again rather than suffixed, and a
-- claimed worktree path (`task.worktree`) is reused even when `opts.worktree_dir` has changed since.
-- `opts.tool == "git"` creates new worktrees with plain `git worktree add` instead of omp.
function git.prepare(
	root: string,
	opts: PrepareOpts,
	task: any,
	alive: () -> boolean,
	claim: (wt: string, branch: string) -> (),
	cb: (Prepared) -> ()
)
	local slug: string = task.slug
	local wt: string = task.worktree or (opts.worktree_dir .. "/" .. slug)
	local wt_parent = string.match(wt, "^(.*)/[^/]*$") or opts.worktree_dir
	local claimed = task.branch ~= nil
	local branch: string = task.branch or (opts.branch_prefix .. slug)
	local remote = opts.remote

	resolve_base(root, opts.base, remote, function(base)
		if base == nil then
			cb({ ok = false, reason = "Could not resolve a base branch (set base in .tern/swarm.json)" })
			return
		end

		local function finish(resume: boolean)
			g({ "-C", wt, "rev-parse", "HEAD" }, 10000, function(r)
				local sha = run.trim(r.stdout)
				if r.status ~= 0 or sha == "" then
					cb({ ok = false, reason = "The worktree has no HEAD: " .. run.why(r) })
					return
				end
				cb({
					ok = true,
					worktree = wt,
					branch = branch,
					base_ref = task.base_ref or base,
					base_sha = if resume and task.base_sha then task.base_sha else sha,
					resume = resume,
				})
			end)
		end

		local function normalize()
			if not alive() then
				cb(SUPERSEDED)
				return
			end
			g({ "-C", wt, "reset", "--hard", "--quiet", base }, 60000, function(r)
				if r.status ~= 0 then
					cb({ ok = false, reason = "Could not reset the worktree to " .. base .. ": " .. run.why(r) })
					return
				end
				if not alive() then
					cb(SUPERSEDED)
					return
				end
				g({ "-C", wt, "clean", "-fdq" }, 60000, function(r2)
					if r2.status ~= 0 then
						tern.log.warn("swarm: git clean failed in", wt, run.why(r2))
					end
					finish(false)
				end)
			end)
		end

		local function create()
			if tern.fs.exists(wt) then
				verify_worktree(root, wt, branch, function(ok, why)
					if ok then
						finish(true)
					else
						cb({
							ok = false,
							reason = wt .. " exists but is not this task's worktree (" .. (why or "unknown") .. "). Move or delete it, then Retry.",
						})
					end
				end)
				return
			end
			g({ "-C", root, "show-ref", "--verify", "--quiet", "refs/heads/" .. branch }, 10000, function(r)
				local exists = r.status == 0
				if exists and not claimed then
					branch = branch .. "-" .. rand_hex4()
					exists = false
				end
				pcall(tern.fs.mkdir, wt_parent)
				if not alive() then
					cb(SUPERSEDED)
					return
				end
				claim(wt, branch)
				if exists then
					-- The task's own branch outlived its worktree (a failed or lost prepare, or a deleted dir):
					-- reattach the branch as-is, never resetting it, so commits from earlier attempts survive.
					g({ "-C", root, "worktree", "prune" }, 30000, function()
						if not alive() then
							cb(SUPERSEDED)
							return
						end
						g({ "-C", root, "worktree", "add", wt, branch }, 300000, function(r3)
							if r3.status ~= 0 then
								cb({ ok = false, reason = "Could not create the worktree: " .. run.why(r3) })
								return
							end
							g({ "-C", wt, "rev-parse", "HEAD" }, 10000, function(rh)
								g({ "-C", root, "rev-parse", "--verify", "--quiet", base .. "^{commit}" }, 10000, function(rb)
									local head = run.trim(rh.stdout)
									local bsha = run.trim(rb.stdout)
									local fresh = rh.status == 0 and rb.status == 0 and head ~= "" and head == bsha
									finish(not fresh)
								end)
							end)
						end)
					end)
					return
				end
				local function git_add()
					g({ "-C", root, "worktree", "add", "-b", branch, wt, base }, 300000, function(r3)
						if r3.status ~= 0 then
							cb({ ok = false, reason = "Could not create the worktree: " .. run.why(r3) })
							return
						end
						normalize()
					end)
				end
				if opts.tool == "git" then
					git_add()
					return
				end
				run.exec({ "omp", "worktree", "add", "-C", root, "-q", "-b", branch, wt, base }, { cwd = root, timeout_ms = 300000 }, function(r2)
					if r2.status == 0 and tern.fs.exists(wt) then
						normalize()
						return
					end
					tern.log.warn("swarm: omp worktree add failed; falling back to git worktree add", run.why(r2))
					if not alive() then
						cb(SUPERSEDED)
						return
					end
					git_add()
				end)
			end)
		end

		if string.sub(base, 1, #remote + 1) == remote .. "/" then
			g({ "-C", root, "fetch", "--quiet", remote, string.sub(base, #remote + 2) }, 60000, function(r)
				if r.status ~= 0 then
					tern.log.warn("swarm: git fetch failed; using the local " .. base, run.why(r))
				end
				create()
			end)
		else
			create()
		end
	end)
end

-- Whether the worktree differs from `base_sha` (uncommitted changes or new commits); nil on git failure.
function git.changed(wt: string, base_sha: string?, cb: (boolean?) -> ())
	g({ "-C", wt, "status", "--porcelain", "--untracked-files=all" }, 30000, function(r)
		if r.status ~= 0 then
			cb(nil)
			return
		end
		if run.trim(r.stdout) ~= "" then
			cb(true)
			return
		end
		g({ "-C", wt, "rev-parse", "HEAD" }, 10000, function(r2)
			if r2.status ~= 0 then
				cb(nil)
				return
			end
			cb(base_sha == nil or run.trim(r2.stdout) ~= base_sha)
		end)
	end)
end

-- Changed files against `base_sha`: {files = {{path, add, del}} (≤50; untracked add = -1), add, del, count}.
function git.review(wt: string, base_sha: string, cb: (any) -> ())
	g({ "-C", wt, "diff", "--numstat", base_sha }, 30000, function(r)
		local files: { any } = {}
		local add, del, count = 0, 0, 0
		for line in string.gmatch(r.stdout or "", "[^\n]+") do
			local a, d, path = string.match(line, "^(%S+)\t(%S+)\t(.+)$")
			if path then
				count += 1
				local na, nd = tonumber(a) or 0, tonumber(d) or 0
				add += na
				del += nd
				if #files < 50 then
					table.insert(files, { path = path, add = na, del = nd })
				end
			end
		end
		g({ "-C", wt, "ls-files", "--others", "--exclude-standard" }, 30000, function(r2)
			for line in string.gmatch(r2.stdout or "", "[^\n]+") do
				count += 1
				if #files < 50 then
					table.insert(files, { path = text.trim(line), add = -1, del = 0 })
				end
			end
			cb({ files = files, add = add, del = del, count = count })
		end)
	end)
end

-- Whether the worktree has no uncommitted changes (true when it no longer exists).
function git.clean_tree(wt: string?, cb: (boolean) -> ())
	if wt == nil or not tern.fs.exists(wt) then
		tern.timer(0, function()
			cb(true)
		end)
		return
	end
	g({ "-C", wt, "status", "--porcelain" }, 30000, function(r)
		cb(r.status == 0 and run.trim(r.stdout) == "")
	end)
end

-- Whether a shipped task's worktree and branch may be removed: the worktree (when it still exists) has
-- no uncommitted changes and the branch (when it still exists) has no commits after `commit`, the
-- shipped short sha. `cb(false, why)` names what would be lost.
function git.shipped_safe(root: string, wt: string?, branch: string?, commit: string?, cb: (ok: boolean, why: string?) -> ())
	local function compare()
		if commit == nil or commit == "" then
			cb(false, "Swarm has no record of the shipped commit")
			return
		end
		if branch == nil then
			cb(true, nil)
			return
		end
		local sha: string = commit
		local ref = "refs/heads/" .. branch
		g({ "-C", root, "show-ref", "--verify", "--quiet", ref }, 10000, function(r)
			if r.status ~= 0 then
				cb(true, nil)
				return
			end
			g({ "-C", root, "rev-list", "--count", sha .. ".." .. ref }, 10000, function(r2)
				if r2.status ~= 0 then
					cb(false, "Swarm couldn't compare the branch with the shipped commit")
					return
				end
				local n = tonumber(run.trim(r2.stdout)) or 0
				if n > 0 then
					cb(false, string.format("its branch has %d commit%s made after shipping", n, if n == 1 then "" else "s"))
					return
				end
				cb(true, nil)
			end)
		end)
	end
	if wt == nil or not tern.fs.exists(wt) then
		tern.timer(0, function()
			compare()
		end)
		return
	end
	g({ "-C", wt, "status", "--porcelain" }, 30000, function(r)
		if r.status ~= 0 then
			cb(false, "git status failed: " .. run.why(r))
			return
		end
		if run.trim(r.stdout) ~= "" then
			cb(false, "its worktree has uncommitted changes")
			return
		end
		compare()
	end)
end

-- The untracked and ignored entries of a new worktree (what `omp worktree add`'s copy left behind, such
-- as .env or node_modules), at most 2000; a directory is listed once, without its trailing slash. Ship
-- keeps them out of commits. `cb({})` when git fails.
function git.baseline(wt: string, cb: (list: { string }) -> ())
	g({ "-C", wt, "status", "--porcelain=v1", "--ignored=traditional", "--untracked-files=normal" }, 30000, function(r)
		local list: { string } = {}
		if r.status ~= 0 then
			tern.log.warn("swarm: could not list the files of a new worktree", wt, run.why(r))
			cb(list)
			return
		end
		for line in string.gmatch(r.stdout or "", "[^\n]+") do
			local code = string.sub(line, 1, 2)
			if code == "??" or code == "!!" then
				local path = string.sub(line, 4)
				if string.sub(path, 1, 1) ~= '"' and path ~= "" then
					if #list >= 2000 then
						tern.log.warn("swarm: a new worktree has more than 2000 untracked or ignored entries; only the first 2000 are kept out of commits")
						break
					end
					if string.sub(path, -1) == "/" then
						path = string.sub(path, 1, -2)
					end
					table.insert(list, path)
				end
			end
		end
		cb(list)
	end)
end

-- Removes the worktree (prune when removal fails) and, when `delete_branch`, its branch. `cb(ok, why)`:
-- ok when the worktree directory is gone afterwards (a failed branch deletion only warns); false with
-- "superseded" once `alive()` is false before a mutating command.
function git.remove(root: string, wt: string?, branch: string?, delete_branch: boolean, alive: () -> boolean, cb: (ok: boolean, why: string?) -> ())
	local function drop_branch()
		if not delete_branch or branch == nil then
			cb(true, nil)
			return
		end
		if not alive() then
			cb(false, "superseded")
			return
		end
		g({ "-C", root, "branch", "-D", branch }, 30000, function(r)
			if r.status ~= 0 and not string.find(r.stderr or "", "not found", 1, true) then
				tern.log.warn("swarm: could not delete branch", branch, run.why(r))
			end
			cb(true, nil)
		end)
	end
	if wt == nil or not tern.fs.exists(wt) then
		g({ "-C", root, "worktree", "prune" }, 30000, function()
			drop_branch()
		end)
		return
	end
	if not alive() then
		tern.timer(0, function()
			cb(false, "superseded")
		end)
		return
	end
	local path: string = wt
	g({ "-C", root, "worktree", "remove", "--force", path }, 120000, function(r)
		local function settle()
			if tern.fs.exists(path) then
				cb(false, if r.status ~= 0 then run.why(r) else "the worktree directory still exists")
				return
			end
			drop_branch()
		end
		if r.status ~= 0 then
			tern.log.warn("swarm: git worktree remove failed; pruning", run.why(r))
			g({ "-C", root, "worktree", "prune" }, 30000, function()
				settle()
			end)
			return
		end
		settle()
	end)
end

-- The state of a GitHub pull request ("MERGED", "CLOSED", "OPEN"), or nil.
function git.pr_state(root: string, url: string, cb: (string?) -> ())
	run.exec({ "gh", "pr", "view", url, "--json", "state", "-q", ".state" }, { cwd = root, timeout_ms = 30000 }, function(r)
		local s = run.trim(r.stdout)
		cb(if r.status == 0 and s ~= "" then s else nil)
	end)
end

return git
