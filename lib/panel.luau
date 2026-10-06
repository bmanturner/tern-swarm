--!strict
-- The Swarm panel: one canvas per project, drawn from the snapshot, and its click handling (runs in
-- whichever window was clicked; mutations go to the leader as intents).

local const = require("./const")
local panel_cards = require("./panel_cards")
local panel_view = require("./panel_view")
local paths = require("./paths")
local state = require("./state")
local store = require("./store")
local text = require("./text")

local panel = {}

function panel.title(name: string): string
	return text.clip("Swarm · " .. name, 80)
end

function panel.about(root: string): string
	return "Tern Swarm for "
		.. root
		.. ". Approve commits the worktree and opens a PR (or only commits, per .tern/swarm.json ship). "
		.. "Retry starts a fresh agent in the same worktree. Discard deletes the worktree and branch and returns "
		.. "the card to Backlog. Park stops the agent and keeps the worktree. Focus shows the agent's tab."
end

-- The pane of the panel canvas for repository `root`, or nil.
function panel.find(cx: WindowCx, root: string): number?
	local ok, list = pcall(function()
		return cx.canvas:list()
	end)
	if not ok then
		return nil
	end
	local prefix = "Tern Swarm for " .. root .. "."
	for _, c in list do
		if c.owner == tern.plugin.id and string.sub(c.about or "", 1, #prefix) == prefix then
			return c.pane
		end
	end
	return nil
end

-- The newest snapshot part each project's panel was asked to show; a pending redraw step for an
-- older part gives up.
local latest: { [string]: any } = {}

-- Redraws the panel of snapshot project `sp` when it is open, over several timer calls so none
-- overruns the 50 ms budget: one builds the view (cards for at most 25 ms; when that isn't enough
-- on a cold start, the cards built so far are kept and the build runs again), and a later one
-- hands it to the canvas, which costs ~20 ms for a busy project on its own.
function panel.update(cx: WindowCx, sp: any)
	latest[sp.id] = sp
	local pane = panel.find(cx, sp.root)
	if pane == nil then
		return
	end
	local ok, view, complete = pcall(panel_view.view, sp, 25)
	if not ok then
		tern.log.warn("swarm: panel update failed", view)
		return
	end
	tern.timer(const.YIELD_MS, function(cx2: WindowCx?)
		if cx2 == nil or latest[sp.id] ~= sp then
			return
		end
		if not complete then
			panel.update(cx2, sp)
			return
		end
		local set, err = pcall(function()
			cx2.canvas:set(pane, { title = panel.title(sp.name or sp.id), view = view })
		end)
		if not set then
			tern.log.warn("swarm: panel update failed", err)
		end
	end)
end

local function section_of(status: string?): string?
	if status == "waiting" or status == "blocked" then
		return "needs"
	elseif status == "review" or status == "shipping" then
		return "review"
	elseif status == "shipped" then
		return "done"
	end
	return nil
end

local function focus_pane(cx: WindowCx, pane: number)
	local tab = cx.session:tab_of(pane)
	if tab ~= nil then
		for _, info in cx.session:tabs() do
			if info.id == tab then
				pcall(function()
					if info.session ~= cx.sessions:current().id then
						cx.sessions:switch(info.session)
					end
				end)
				break
			end
		end
	end
	pcall(function()
		cx.layout:focus(pane)
	end)
end

local function live(cx: WindowCx, pane: any): number?
	if type(pane) == "number" and cx.session:pane(pane) ~= nil then
		return pane
	end
	return nil
end

-- The log of the newest job's first failing step (else its first log) of task `pid/slug`, or nil.
local function latest_log(pid: string, slug: string): string?
	local jobs = paths.task_dir(pid, slug) .. "/jobs"
	local ok, names = pcall(tern.fs.list, jobs)
	if not ok then
		return nil
	end
	local best: string?, best_n = nil, -1
	for _, name in names do
		local n = tonumber(string.match(name, "^(%d+)%-"))
		if n and n > best_n then
			best, best_n = name, n
		end
	end
	if best == nil then
		return nil
	end
	local dir = jobs .. "/" .. best
	local ok2, files = pcall(tern.fs.list, dir)
	if not ok2 then
		return nil
	end
	local present: { [string]: boolean } = {}
	local steps: { string } = {}
	local logs: { string } = {}
	for _, f in files do
		present[f] = true
		local step = string.match(f, "^(.*)%.status$")
		if step then
			table.insert(steps, step)
		elseif string.match(f, "%.log$") then
			table.insert(logs, f)
		end
	end
	table.sort(steps)
	for _, step in steps do
		local st = store.read_text(dir .. "/" .. step .. ".status", 64)
		if text.trim(st or "") ~= "0" and present[step .. ".log"] then
			return dir .. "/" .. step .. ".log"
		end
	end
	table.sort(logs)
	return if logs[1] then dir .. "/" .. logs[1] else nil
end

-- canvas_action handler: `ev.act` is "<action>|<pid>|<slug>".
function panel.on_action(ev: any, cx: WindowCx): boolean
	if type(ev.act) ~= "string" then
		return false
	end
	local act, pid, slug = string.match(ev.act, "^([^|]+)|([^|]*)|(.*)$")
	if act == nil or pid == nil or slug == nil then
		return false
	end
	local t = if slug ~= "" then state.snapshot_task(pid, slug) else nil

	if act == "focus" then
		local pane = t and (live(cx, t.ui_pane) or live(cx, t.agent_pane) or live(cx, t.shell_pane))
		if pane == nil then
			cx:toast("info", "No live agent for " .. slug)
		else
			focus_pane(cx, pane)
		end
		return true
	elseif act == "diff" then
		if t == nil or t.worktree == nil then
			cx:toast("info", "No worktree for " .. slug)
			return true
		end
		local worktree, shell = t.worktree, t.shell_pane
		local ok, err = pcall(function()
			cx.git:open(worktree, { how = "tab" }):next(function(_, open_err, cx2)
				if open_err == nil or cx2 == nil then
					return
				end
				local pane = live(cx2, shell)
				if pane then
					cx2:run(pane, "omp git\r")
					cx2.layout:focus(pane)
				else
					cx2:toast("error", "Could not open the diff", open_err)
				end
			end)
		end)
		if not ok then
			cx:toast("error", "Could not open the diff", tostring(err))
		end
		return true
	elseif act == "details" then
		local path = paths.task_dir(pid, slug) .. "/details.md"
		if not tern.fs.exists(path) then
			pcall(store.write_text, path, "")
		end
		cx:open(path, "beside")
		return true
	elseif act == "log" then
		local path = latest_log(pid, slug)
		if path == nil then
			cx:toast("info", "No job logs yet for " .. slug)
		else
			cx:open(path, "beside")
		end
		return true
	elseif act == "new-task" then
		if cx:new_block("swarm.new-task", { pid }, "below") == nil then
			cx:toast("error", "The New task form is not available", "Swarm's host half did not load; run `tern plugin list`.")
		end
		return true
	elseif act == "settings" then
		if cx:new_block("swarm.settings", { pid }, "tab") == nil then
			cx:toast("error", "Swarm Settings isn't available", "Swarm's host half did not load; run `tern plugin list`.")
		end
		return true
	elseif act == "pause" or act == "resume" then
		local ok, cur = pcall(tern.kv.get, "paused_projects")
		local set: { [string]: boolean } = {}
		if ok and type(cur) == "table" then
			for k, v in cur do
				set[k] = v
			end
		end
		set[pid] = if act == "pause" then true else nil
		pcall(tern.kv.set, "paused_projects", if next(set) then set else nil)
		state.poke()
		return true
	elseif act == "resume-all" then
		pcall(tern.kv.set, "paused", nil)
		state.poke()
		return true
	elseif act == "discard" then
		local sec = section_of(t and t.status)
		if sec == nil then
			return true
		end
		local path = sec .. "." .. slug .. ".actions.discard"
		local pane = ev.pane
		local ok = pcall(function()
			cx.canvas:set(pane, { set = { [path] = panel_cards.button("Confirm discard", "error", "discard!", pid, slug, "discard") } })
		end)
		if ok then
			tern.timer(6000, function(tcx: WindowCx?)
				if tcx == nil then
					return
				end
				pcall(function()
					tcx.canvas:set(pane, { set = { [path] = panel_cards.button("Discard", "error", "discard", pid, slug, "discard") } })
				end)
			end)
		end
		return true
	elseif act == "discard!" or act == "approve" or act == "retry" or act == "park" then
		store.write_intent({ kind = "action", project = pid, slug = slug, action = if act == "discard!" then "discard" else act })
		state.poke()
		return true
	elseif act == "trust" then
		local sp = state.snapshot_project(pid)
		if sp and sp.trust then
			store.write_intent({ kind = "trust", project = pid, subject = sp.trust.subject })
			state.poke()
		end
		return true
	elseif act == "open-config" then
		local sp = state.snapshot_project(pid)
		if sp == nil or sp.root == nil then
			return true
		end
		local path = sp.root .. "/.tern/swarm.json"
		if tern.fs.exists(path) then
			cx:open(path, "beside")
		else
			cx:toast("info", "This repository has no .tern/swarm.json", "The list comes from package.json.")
		end
		return true
	elseif act == "clean" then
		store.write_intent({ kind = "clean", project = pid })
		state.poke()
		return true
	end
	return false
end

return panel