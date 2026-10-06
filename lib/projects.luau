--!strict
-- Projects: a repository root registered with a board and a panel. Window half.

local const = require("./const")
local config = require("./config")
local panel = require("./panel")
local panel_view = require("./panel_view")
local paths = require("./paths")
local roles = require("./roles")
local run = require("./run")
local state = require("./state")
local store = require("./store")

local projects = {}

-- The repository root of directory `cwd`: linked worktrees resolve to their main repository;
-- submodules and --separate-git-dir repositories resolve to their own top level.
function projects.resolve_root(cwd: string, cb: (root: string?, err: string?, cx: WindowCx?) -> ())
	local argv = { "git", "-C", cwd, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir" }
	run.exec(argv, { timeout_ms = 10000 }, function(r, cx)
		local lines = string.split(run.trim(r.stdout), "\n")
		local top = run.trim(lines[1] or "")
		local common = run.trim(lines[2] or "")
		if r.status ~= 0 or top == "" then
			cb(nil, "Swarm needs a pane inside a non-bare git repository", cx)
		elseif string.sub(common, -5) == "/.git" then
			cb(string.sub(common, 1, -6), nil, cx)
		else
			cb(top, nil, cx)
		end
	end)
end

-- The registered project whose root or worktree dir contains `path` (or whose board directory does:
-- the board and the panel run there), or nil.
function projects.containing(path: string): string?
	local all = store.projects()
	local own = string.match(path, "^" .. string.gsub(tern.plugin.data, "%p", "%%%0") .. "/projects/([^/]+)")
	if own and all[own] then
		return own
	end
	for pid, p in all do
		for _, dir in { p.root, p.worktree_dir } do
			if type(dir) == "string" and (path == dir or string.sub(path, 1, #dir + 1) == dir .. "/") then
				return pid
			end
		end
	end
	return nil
end

-- projects.containing(path), else the only registered project.
function projects.find_for_path(path: string): string?
	local pid = projects.containing(path)
	if pid then
		return pid
	end
	local count, only = 0, nil
	for id in store.projects() do
		count += 1
		only = id
	end
	return if count == 1 then only else nil
end

local BOARD_TEMPLATE = "# Swarm · %s\n\n## Backlog\n\n## Ready\n\n## Doing\n\n## Blocked\n\n## Review\n\n## Done\n"

-- Writes the project's board when it does not exist.
function projects.ensure_board(pid: string, name: string)
	local board = paths.board(pid)
	if not tern.fs.exists(board) then
		store.write_text(board, string.format(BOARD_TEMPLATE, name))
	end
end

-- Refreshes the roles cache of project `pid` (async).
function projects.fetch_roles(pid: string, root: string)
	local entry = state.roles[pid]
	if entry and entry.fetching then
		return
	end
	state.roles[pid] = { list = entry and entry.list, names = entry and entry.names, at = entry and entry.at, fetching = true }
	roles.fetch(root, function(list, err)
		if list == nil then
			tern.log.warn("swarm: could not read omp roles", err)
			state.roles[pid] = { list = entry and entry.list, names = entry and entry.names, at = os.time() }
			return
		end
		local names: { [string]: boolean } = {}
		for _, r in list do
			names[r.name] = true
		end
		state.roles[pid] = { list = list, names = names, at = os.time() }
	end)
end

-- Registers repository `root`, writes its board and shows the board and the panel in this window.
-- Returns the project id, or nil (with a toast) when projects.json can't be saved.
function projects.open(cx: WindowCx, root: string, session: number?): string?
	local cfg = config.load(root)
	local pid = paths.project_id(root)
	local name = paths.basename(root)
	local all = store.projects()
	local sid = session
	if sid == nil then
		local ok, cur = pcall(function()
			return cx.sessions:current()
		end)
		sid = if ok and cur then cur.id else nil
	end
	all[pid] = { root = root, name = name, session = sid, worktree_dir = cfg.worktree_dir }
	local saved, err = pcall(store.save_projects, all)
	if not saved then
		cx:toast("error", "Swarm can't register this repository", tostring(err))
		return nil
	end
	state.projects = all
	projects.ensure_board(pid, name)

	local board = paths.board(pid)
	local board_pane: number? = nil
	for _, p in cx.session:panes() do
		if p.path == board then
			board_pane = p.pane
			break
		end
	end
	if board_pane then
		local pane: number = board_pane
		pcall(function()
			local tab = cx.session:tab_of(pane)
			for _, info in cx.session:tabs() do
				if info.id == tab and info.session ~= cx.sessions:current().id then
					cx.sessions:switch(info.session)
				end
			end
			cx.layout:focus(pane)
		end)
	else
		local pane = cx.board:open(board, { how = "tab" })
		pcall(function()
			local tab = cx.session:tab_of(pane)
			if tab then
				cx.layout:name_tab(tab, "Swarm · " .. name)
			end
		end)
	end

	local how = config.user().layout.panel
	if how ~= "none" and panel.find(cx, root) == nil then
		-- Opens empty (a busy project's full view can take most of a call's budget to build) and
		-- fills in on later timer calls through panel.update.
		local pane, err = cx.canvas:open({
			title = panel.title(name),
			about = panel.about(root),
			view = (panel_view.view(panel_view.empty(pid, name, root))),
			how = how :: any,
			focus = false,
		})
		if pane == nil then
			cx:toast("error", "Swarm panel not opened", err)
		else
			local sp = state.snapshot_project(pid)
			if sp then
				tern.timer(const.YIELD_MS, function(cx2: WindowCx?)
					if cx2 then
						panel.update(cx2, sp)
					end
				end)
			end
		end
	end

	projects.fetch_roles(pid, root)
	state.poke()
	return pid
end

return projects
