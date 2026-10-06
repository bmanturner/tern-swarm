--!strict
-- Intents from other windows and the panel (files in the intents folder): open a project, create a
-- task, run an action, clean up, reload config, approve a repository. Leader only. Window half.

local actions = require("./actions")
local cleanup = require("./cleanup")
local config = require("./config")
local const = require("./const")
local paths = require("./paths")
local projects = require("./projects")
local publish = require("./publish")
local state = require("./state")
local store = require("./store")
local taskctx = require("./taskctx")
local text = require("./text")

local intents = {}

local function create(cx: WindowCx, intent: any)
	local pid = intent.project
	local proj = state.projects[pid]
	if proj == nil or type(intent.title) ~= "string" then
		tern.log.warn("swarm: create intent for an unknown project", pid)
		return
	end
	local title = text.trim(intent.title)
	if title == "" then
		return
	end
	local cfg = taskctx.cfg_for(pid)
	local lane = if intent.lane == "Backlog" then "Backlog" elseif intent.lane == "Ready" then "Ready" else cfg.new_task.lane
	local want = intent.slug
	local slug: string
	if
		type(want) == "string"
		and #want <= 48
		and string.find(want, "^[a-z0-9][a-z0-9%-]*$") ~= nil
		and (state.tasks[pid] or {})[want] == nil
		and not tern.fs.exists(paths.task_dir(pid, want))
		and not tern.fs.exists(paths.archive_dir(pid) .. "/" .. want)
	then
		slug = want
	else
		slug = paths.unique_slug(pid, title)
	end
	local task = taskctx.new_task(pid, slug, title, lane)
	state.tasks[pid] = state.tasks[pid] or {}
	state.tasks[pid][slug] = task
	store.save_task(task)
	if type(intent.details) == "string" and text.trim(intent.details) ~= "" then
		store.write_text(paths.task_dir(pid, slug) .. "/details.md", intent.details)
	end
	local tags = { const.TAG_TASK .. slug }
	if type(intent.role) == "string" and string.find(intent.role, "^[%w_%-]+$") and intent.role ~= cfg.default_role then
		table.insert(tags, const.TAG_ROLE .. intent.role)
	end
	cx.board:add(paths.board(pid), { lane = lane, text = title, tags = tags }):next(function(_, err)
		if err then
			tern.log.warn("swarm: could not add the card for " .. slug, err)
		end
	end)
end

-- Runs an action intent. Returns true when the task has an operation in flight, so the intent is
-- kept and retried next tick.
local function action(cx: WindowCx, intent: any): boolean
	local pid, slug = intent.project, intent.slug
	local tasks = if type(pid) == "string" then state.tasks[pid] else nil
	local task = if tasks and type(slug) == "string" then tasks[slug] else nil
	if task == nil then
		tern.log.warn("swarm: action for an unknown task", pid, slug)
		return false
	end
	if task.damaged then
		state.notify("error", "Swarm: can't change " .. slug, "Its task.json is damaged; fix or delete it first.")
		return false
	end
	if state.inflight[pid .. "/" .. slug] then
		return true
	end
	local ctx = taskctx.make_ctx(cx, pid)
	local a = intent.action
	if a == "approve" and ctx.hold then
		state.notify("error", "Swarm: can't ship " .. tostring(task.title), ctx.hold)
		store.save_task(task)
		return false
	end
	local accepted = true
	if a == "approve" then
		accepted = actions.approve(ctx, task)
	elseif a == "discard" then
		accepted = actions.discard(ctx, task)
	elseif a == "retry" then
		accepted = actions.retry(ctx, task, false)
	elseif a == "park" then
		accepted = actions.park(ctx, task)
	else
		tern.log.warn("swarm: unknown action", a)
	end
	if not accepted then
		state.notify("info", "Swarm: can't " .. tostring(a) .. " " .. tostring(task.title), "It is " .. tostring(task.status) .. ".")
	end
	store.save_task(task)
	return false
end

-- Handles one intent; returns true when it must be kept for the next tick.
function intents.handle(cx: WindowCx, intent: any): boolean
	local kind = intent.kind
	if kind == "open" then
		if type(intent.root) == "string" then
			projects.open(cx, intent.root, if type(intent.session) == "number" then intent.session else nil)
		end
	elseif kind == "create" then
		create(cx, intent)
	elseif kind == "action" then
		return action(cx, intent)
	elseif kind == "clean" then
		cleanup.clean(cx, if type(intent.project) == "string" then intent.project else nil, function(p: string): any
			return (taskctx.cfg_for(p))
		end)
	elseif kind == "config" then
		state.cfg = {}
		config.forget()
		local all = store.projects()
		local changed = false
		for _, p in all do
			if type(p) == "table" and type(p.root) == "string" then
				local dir = config.load(p.root).worktree_dir
				if p.worktree_dir ~= dir then
					p.worktree_dir = dir
					changed = true
				end
			end
		end
		if changed then
			local saved, err = pcall(store.save_projects, all)
			if saved then
				state.projects = all
			else
				tern.log.warn("swarm: could not save projects.json", err)
			end
		end
		publish.request()
	elseif kind == "trust" then
		local proj = if type(intent.project) == "string" then state.projects[intent.project] else nil
		if proj == nil or type(intent.subject) ~= "string" then
			return false
		end
		local name = proj.name or intent.project
		config.forget()
		local cfg = config.load(proj.root)
		if cfg.trust.subject == intent.subject then
			config.approve(proj.root, intent.subject)
			state.notify("success", "Swarm: approved " .. name, "Tasks can start now.")
		else
			state.notify("info", "Swarm: " .. name .. "'s settings changed", "Review them again in the Swarm panel.")
		end
		state.cfg[intent.project] = nil
		publish.request()
	else
		tern.log.warn("swarm: unknown intent", kind)
	end
	return false
end

return intents
