--!strict
-- Carly integration: exports to open boards, add and act on tasks, and a short request context.
-- Window half, desktop only (guarded by the caller).

local commands = require("./commands")
local config = require("./config")
local const = require("./const")
local paths = require("./paths")
local projects = require("./projects")
local state = require("./state")
local store = require("./store")
local text = require("./text")

local carly = {}

local ACTIONS = { approve = true, retry = true, park = true, discard = true }
local ACTION_ORDER = { "approve", "retry", "park", "discard" }
local ACTION_DOCS: { [string]: string } = {
	approve = "approve (from review): ships per the project's ship setting (commit, or commit + PR); closes a no-change task instead",
	retry = "retry (from waiting, blocked, review, parked): requeues a fresh agent in the same worktree",
	park = "park (from preparing, running, checking, waiting, blocked, review): stops the agent, keeps the worktree",
	discard = "discard (from backlog, queued, preparing, running, checking, waiting, blocked, review, parked, or a shipped task whose worktree Swarm kept): stops the agent, removes the worktree, back to Backlog; keeps the branch if discard.delete_branch is false",
}

-- Tern rejects an export whose sig or doc exceeds 1024 bytes, which would abort registration.
local SPEC_MAX = 1024

-- `s` cut to at most SPEC_MAX bytes on a character boundary, ending in "…" when cut.
local function fit(s: string): string
	if #s <= SPEC_MAX then
		return s
	end
	local stop = SPEC_MAX - 3 -- room for "…"
	while stop > 0 do
		local b = string.byte(s, stop + 1)
		if b < 0x80 or b >= 0xC0 then
			break
		end
		stop -= 1
	end
	return string.sub(s, 1, stop) .. "…"
end

-- The task_action doc, listing only the actions the user's settings allow.
local function action_doc(): string
	local allowed = config.user().carly.actions
	local parts: { string } = {}
	for _, name in ACTION_ORDER do
		if table.find(allowed, name) ~= nil then
			table.insert(parts, ACTION_DOCS[name])
		end
	end
	if #parts == 0 then
		return "Swarm settings don't let Carly act on tasks."
	end
	return "project and slug come from list_tasks(). Actions and the statuses they need: "
		.. table.concat(parts, "; ")
		.. ". Returns true once queued, not done: it applies on a later tick (~3 s), so confirm with list_tasks(). "
		.. "Fails at once when the task's status (from the last snapshot) doesn't allow the action. "
		.. "Fails at once for an unknown action or task, or one your carly.actions setting doesn't allow. "
		.. "See the Carly section of the Swarm README."
end

function carly.register()
	tern.carly.export("open_board", {
		sig = "(path: string?) -> {project: string}",
		doc = fit("Opens the Swarm Kanban board for the git repository at path (default: the focused pane's directory), plus the Swarm panel unless your layout.panel setting is \"none\". Returns {project = <project id>}; use that id with list_tasks() and task_action(). Waits up to 15 s; fails with the reason when there is no directory, path is not in a git repository, or the board can't open."),
	}, function(path: any, cx: WindowCx, call: ExportCall)
		local cwd: string
		if type(path) == "string" and path ~= "" then
			cwd = path
		else
			local here, remote = commands.focused_cwd(cx)
			if remote then
				call:fail(remote)
				return call:wait(1000)
			end
			cwd = here
		end
		commands.open_board(cx, cwd, function(pid, err)
			if pid then
				call:reply({ project = pid })
			else
				call:fail(err or "could not open the board")
			end
		end)
		return call:wait(15000)
	end)

	tern.carly.export("add_task", {
		sig = "(title: string, details: string?, role: string?, start: boolean?) -> {project: string, slug: string, lane: string}",
		doc = fit("Queues a new task on the Swarm board of the focused pane's repository; there is no project argument, so call open_board() first when it has no board. "
			.. "title: non-empty string, the card text. details: optional markdown the agent gets under ## Task. "
			.. "role: optional omp model role name without @ (e.g. \"slow\"); an unknown name fails once Swarm has read the project's roles. "
			.. "start: true puts it in Ready (an agent picks it up); anything else puts it in Backlog. "
			.. "Returns {project = <project id>, slug, lane = \"Ready\" | \"Backlog\"} once queued; the task is created on a later tick (~3 s). slug is the task's slug unless another task claims it first, so confirm with list_tasks(). "
			.. "Fails when title is empty or the directory has no Swarm project. See the Carly section of the Swarm README."),
	}, function(title: any, details: any, role: any, start: any, cx: WindowCx, call: ExportCall)
		if type(title) ~= "string" or text.trim(title) == "" then
			call:fail("title must be a non-empty string")
			return call:wait(1000)
		end
		local cwd, remote = commands.focused_cwd(cx)
		if remote then
			call:fail(remote)
			return call:wait(1000)
		end
		local pid = projects.find_for_path(cwd)
		if pid == nil then
			call:fail("No Swarm project here; call plugins.swarm.open_board() first")
			return call:wait(1000)
		end
		if role ~= nil then
			local known = state.roles[pid]
			if type(role) ~= "string" or (known and known.names and not known.names[role]) then
				local names: { string } = {}
				for _, r in (known and known.list) or {} do
					table.insert(names, r.name)
				end
				call:fail("Unknown role " .. tostring(role) .. "; known: " .. table.concat(names, ", "))
				return call:wait(1000)
			end
		end
		local lane = if start == true then "Ready" else "Backlog"
		local clean = text.trim(title)
		local slug = paths.unique_slug(pid, clean)
		store.write_intent({
			kind = "create",
			project = pid,
			slug = slug,
			title = clean,
			details = if type(details) == "string" then details else nil,
			role = role,
			lane = lane,
		})
		state.poke()
		return { project = pid, slug = slug, lane = lane }
	end)

	tern.carly.export("list_tasks", {
		sig = "() -> {tasks: {{project: string, slug: string, title: string, status: string, role: string?, reason: string?, pr_url: string?}}, truncated: boolean}",
		doc = fit("Lists Swarm tasks across open projects, at most 40 in total; truncated is true when more exist. Per project: unfinished tasks by slug, then up to 8 most recently shipped or closed tasks. Cancelled tasks are left out. "
			.. "Fields: project (the id for task_action), slug, title, status, role (from the latest pickup; may be absent before it), reason (why waiting, blocked or parked), pr_url (once a PR opens). "
			.. "status: backlog, queued, preparing, running, checking, waiting, blocked, review, shipping, shipped, closed, parked, discarding. "
			.. "Reads the last published snapshot, which can lag a few seconds. See the Carly section of the Swarm README."),
	}, function(_cx: WindowCx, _call: ExportCall)
		local out: { any } = {}
		local truncated = false
		for _, p in state.snapshot.projects or {} do
			for _, t in p.tasks or {} do
				if #out >= 40 then
					truncated = true
					break
				end
				table.insert(out, {
					project = p.id,
					slug = t.slug,
					title = t.title,
					status = t.status,
					role = t.role,
					reason = t.reason,
					pr_url = t.pr_url,
				})
			end
			if truncated then
				break
			end
		end
		return { tasks = tern.json.array(out), truncated = truncated }
	end)

	tern.carly.export("task_action", {
		sig = "(project: string, slug: string, action: string) -> boolean",
		doc = fit(action_doc()),
	}, function(project: any, slug: any, act: any, _cx: WindowCx, call: ExportCall)
		if type(act) ~= "string" or not ACTIONS[act] then
			call:fail("action must be approve, retry, park or discard")
			return call:wait(1000)
		end
		local t = if type(project) == "string" and type(slug) == "string" then state.snapshot_task(project, slug) else nil
		if t == nil then
			call:fail("No Swarm task " .. tostring(project) .. "/" .. tostring(slug))
			return call:wait(1000)
		end
		local can = const.CAN[act]
		if not (can[t.status] or (act == "discard" and t.status == "shipped" and t.kept ~= nil)) then
			local need: { string } = {}
			for st in can do
				table.insert(need, st)
			end
			table.sort(need)
			call:fail(string.format("%s is %s; %s needs %s", slug, tostring(t.status), act, table.concat(need, ", ")))
			return call:wait(1000)
		end
		if act == "approve" then
			local sp = state.snapshot_project(project)
			if sp and sp.hold then
				call:fail("Can't ship in " .. (sp.name or project) .. ": " .. sp.hold)
				return call:wait(1000)
			end
		end
		local p = store.projects()[project]
		local allowed = if p then config.load(p.root).carly.actions else config.user().carly.actions
		if table.find(allowed, act) == nil then
			call:fail("Swarm settings don't let Carly " .. act .. " tasks in " .. ((p and p.name) or project))
			return call:wait(1000)
		end
		store.write_intent({ kind = "action", project = project, slug = slug, action = act })
		state.poke()
		return true
	end)

	tern.carly.context(function(_cx: WindowCx): string?
		local mode = config.user().carly.context
		if mode == "off" then
			return nil
		end
		local pieces: { string } = {}
		for _, p in state.snapshot.projects or {} do
			local running, needs, review = {}, {}, {}
			for _, t in p.tasks or {} do
				if const.ACTIVE[t.status] then
					if mode ~= "attention" then
						table.insert(running, t.slug .. " [" .. (t.role or "default") .. "]")
					end
				elseif t.status == "waiting" or t.status == "blocked" then
					table.insert(needs, t.slug .. " — " .. (t.reason or t.status))
				elseif t.status == "review" or t.status == "shipping" then
					table.insert(review, t.slug)
				end
			end
			local bits: { string } = {}
			if #running > 0 then
				table.insert(bits, "running " .. table.concat(running, ", "))
			end
			if #needs > 0 then
				table.insert(bits, "needs you: " .. table.concat(needs, ", "))
			end
			if #review > 0 then
				table.insert(bits, "review: " .. table.concat(review, ", "))
			end
			if #bits > 0 then
				table.insert(pieces, "Swarm (" .. (p.name or p.id) .. ", id " .. p.id .. "): " .. table.concat(bits, "; ") .. ".")
			end
		end
		if #pieces == 0 then
			return nil
		end
		return text.clip(table.concat(pieces, " ") .. " plugins.swarm.list_tasks() / task_action(project id, slug, action).", 400)
	end)
end

return carly
