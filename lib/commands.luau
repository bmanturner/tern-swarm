--!strict
-- Palette commands and the status-line segment. Window half.

local config = require("./config")
local projects = require("./projects")
local state = require("./state")
local store = require("./store")

local commands = {}

-- The focused pane's working directory ("" when unknown), plus a reason when the pane is on a remote
-- host, which Swarm refuses.
function commands.focused_cwd(cx: WindowCx): (string, string?)
	local okh, host = pcall(function()
		return cx.hosts:current()
	end)
	if okh and type(host) == "table" and host.kind == "remote" then
		return "", "Swarm works only with repositories on this machine; the focused pane is on " .. tostring(host.name) .. "."
	end
	local pane = cx.session:focused()
	if pane == nil then
		return "", nil
	end
	local info = cx.session:pane(pane)
	return (if info and type(info.cwd) == "string" then info.cwd else ""), nil
end

-- Whether `path` is `dir` or inside it.
local function under(path: string, dir: any): boolean
	return type(dir) == "string" and (path == dir or string.sub(path, 1, #dir + 1) == dir .. "/")
end

-- Opens the board of the repository around `cwd`. A registered project is used directly when `cwd`
-- is inside Swarm's own data folder (e.g. the board itself), inside its worktree folder, or is its
-- root; anywhere else git resolves the repository, so a submodule opens its own board.
function commands.open_board(cx: WindowCx, cwd: string, done: ((pid: string?, err: string?) -> ())?)
	local function finish(pid: string?, err: string?)
		if done then
			done(pid, err)
		end
	end
	local pid: string? = nil
	if cwd ~= "" and under(cwd, tern.plugin.data) then
		pid = projects.find_for_path(cwd)
	else
		local near = projects.containing(cwd)
		local p = if near then store.projects()[near] else nil
		if p and (cwd == p.root or under(cwd, p.worktree_dir)) then
			pid = near
		end
	end
	if pid then
		local root = store.projects()[pid].root
		local ok, opened = pcall(projects.open, cx, root, nil)
		if not ok then
			cx:toast("error", "Swarm: could not open the board", tostring(opened))
			finish(nil, tostring(opened))
		elseif opened == nil then
			finish(nil, "Swarm can't register this repository (projects.json is damaged)")
		else
			finish(pid, nil)
		end
		return
	end
	if cwd == "" then
		cx:toast("error", "Swarm: focus a pane inside a git repository")
		finish(nil, "focus a pane inside a git repository")
		return
	end
	projects.resolve_root(cwd, function(root, err, cx2)
		if cx2 == nil then
			finish(nil, "the window went away")
			return
		end
		if root == nil then
			cx2:toast("error", "Swarm: " .. (err or "no repository here"), cwd)
			finish(nil, err)
			return
		end
		local ok, opened = pcall(projects.open, cx2, root, nil)
		if not ok then
			cx2:toast("error", "Swarm: could not open the board", tostring(opened))
			finish(nil, tostring(opened))
			return
		end
		if opened == nil then
			finish(nil, "Swarm can't register this repository (projects.json is damaged)")
			return
		end
		finish(opened, nil)
	end)
end

local function project_here(cx: WindowCx): string?
	local cwd, remote = commands.focused_cwd(cx)
	if remote then
		cx:toast("error", "Swarm can't use this pane", remote)
		return nil
	end
	local pid = projects.find_for_path(cwd)
	if pid == nil then
		cx:toast("error", "Swarm: run Swarm: Open board in this repository first")
	end
	return pid
end

local function status_segments(_pane: StatusPaneInfo): { StatusSegment }?
	local snap = state.snapshot or {}
	local c = snap.counts or {}
	local parts: { string } = {}
	if (c.running or 0) > 0 then
		table.insert(parts, c.running .. " running")
	end
	if (c.needs or 0) > 0 then
		table.insert(parts, c.needs .. " need you")
	end
	if (c.review or 0) > 0 then
		table.insert(parts, c.review .. " to review")
	end
	if snap.paused then
		table.insert(parts, "paused")
	else
		local n = 0
		for _, sp in snap.projects or {} do
			if sp.paused == true then
				n += 1
			end
		end
		if n == 1 then
			table.insert(parts, "1 project paused")
		elseif n > 1 then
			table.insert(parts, n .. " projects paused")
		end
	end
	if #parts == 0 then
		return nil
	end
	local tone = if (c.needs or 0) > 0 then "warning" elseif (c.review or 0) > 0 then "success" else "accent"
	return { { text = "Swarm " .. table.concat(parts, " · "), icon = "kanban", tone = tone, command = "plugin.swarm.goto" } }
end

-- Opens the board of the project needing the most attention, ranked by its (needs, review, running, queued)
-- counts compared in that order, else the focused pane's board.
local function goto_attention(cx: WindowCx)
	local best: any, best_counts: { number }? = nil, nil
	for _, sp in (state.snapshot or {}).projects or {} do
		local c = { 0, 0, 0, 0 }
		for _, t in sp.tasks or {} do
			local st = t.status
			if st == "waiting" or st == "blocked" then
				c[1] += 1
			elseif st == "review" or st == "shipping" then
				c[2] += 1
			elseif st == "preparing" or st == "running" or st == "checking" then
				c[3] += 1
			elseif st == "queued" then
				c[4] += 1
			end
		end
		local better = false
		local cmp = best_counts or { 0, 0, 0, 0 }
		for i = 1, 4 do
			if c[i] ~= cmp[i] then
				better = c[i] > cmp[i]
				break
			end
		end
		if better then
			best, best_counts = sp, c
		end
	end
	if best == nil then
		local cwd, remote = commands.focused_cwd(cx)
		if remote then
			cx:toast("error", "Swarm can't use this pane", remote)
			return
		end
		commands.open_board(cx, cwd, nil)
		return
	end
	local ok, err = pcall(projects.open, cx, best.root, nil)
	if not ok then
		cx:toast("error", "Swarm: could not open the board", tostring(err))
	end
end

function commands.register()
	tern.command({
		id = "open",
		title = "Swarm: Open board",
		icon = "kanban",
		group = "Swarm",
		keys = { "ctrl+alt+shift+k" },
		run = function(cx)
			local cwd, remote = commands.focused_cwd(cx)
			if remote then
				cx:toast("error", "Swarm can't use this pane", remote)
				return
			end
			commands.open_board(cx, cwd, nil)
		end,
	})

	tern.command({
		id = "goto",
		title = "Swarm: Go to tasks needing attention",
		icon = "kanban",
		group = "Swarm",
		run = goto_attention,
	})

	tern.command({
		id = "new-task",
		title = "Swarm: New task…",
		icon = "plus",
		group = "Swarm",
		keys = { "ctrl+alt+shift+n" },
		run = function(cx)
			local pid = project_here(cx)
			if pid and cx:new_block("swarm.new-task", { pid }, "below") == nil then
				cx:toast("error", "The New task form is not available", "Swarm's host half did not load; run `tern plugin list`.")
			end
		end,
	})

	tern.command({
		id = "toggle-pause",
		title = "Swarm: Pause or resume pickups",
		icon = "pause",
		group = "Swarm",
		run = function(cx)
			local ok, paused = pcall(tern.kv.get, "paused")
			local now = not (ok and paused == true)
			pcall(tern.kv.set, "paused", if now then true else nil)
			if now then
				cx:toast("info", "Swarm paused — running agents continue; nothing new starts")
			else
				cx:toast("info", "Swarm resumed")
			end
			state.poke()
		end,
	})

	tern.command({
		id = "clean",
		title = "Swarm: Clean up finished worktrees",
		icon = "trash",
		group = "Swarm",
		run = function(_cx)
			store.write_intent({ kind = "clean" })
			state.poke()
		end,
	})

	tern.command({
		id = "settings",
		title = "Swarm: Settings",
		icon = "gear",
		group = "Swarm",
		run = function(cx)
			local cwd, remote = commands.focused_cwd(cx)
			if remote then
				cx:toast("error", "Swarm can't use this pane", remote)
				return
			end
			local pid = projects.find_for_path(cwd)
			if cx:new_block("swarm.settings", if pid then { pid } else {}, "tab") == nil then
				cx:toast("error", "Swarm Settings isn't available", "Swarm's host half did not load; run `tern plugin list`.")
			end
		end,
	})

	tern.command({
		id = "config",
		title = "Swarm: Edit project config file",
		icon = "gear",
		group = "Swarm",
		run = function(cx)
			local pid = project_here(cx)
			if pid == nil then
				return
			end
			local root = store.projects()[pid].root
			local path = root .. "/.tern/swarm.json"
			if not tern.fs.exists(path) then
				local ok, err = pcall(function()
					store.write_text(path, tern.json.encode(config.starter(root), true) .. "\n")
				end)
				if not ok then
					cx:toast("error", "Swarm: could not write " .. path, tostring(err))
					return
				end
			end
			cx:open(path, "beside")
		end,
	})

	if tern.chrome then
		tern.chrome.status(status_segments)
	end
end

return commands
