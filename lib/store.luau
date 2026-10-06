--!strict
-- JSON files under the data folder: projects, tasks, details and the intent queue. Both halves.
-- The leader window is the only writer of task files; any VM may write intents.

local const = require("./const")
local paths = require("./paths")

local store = {}

local MAX_JSON = 262144

-- Decoded JSON at `path` (at most `max` bytes, default 256 KiB), or nil when missing or unreadable.
function store.read_json(path: string, max: number?): any
	local ok, text = pcall(tern.fs.read, path, max or MAX_JSON)
	if not ok then
		return nil
	end
	local decoded, value = pcall(tern.json.decode, text)
	return if decoded then value else nil
end

-- Writes `value` as pretty JSON, creating the parent directory.
function store.write_json(path: string, value: any)
	tern.fs.mkdir(paths.dirname(path))
	tern.fs.write(path, tern.json.encode(value, true))
end

-- Text of `path` (at most `max` bytes, default 20000), or nil.
function store.read_text(path: string, max: number?): string?
	local ok, text = pcall(tern.fs.read, path, max or 20000)
	return if ok then text else nil
end

function store.write_text(path: string, text: string)
	tern.fs.mkdir(paths.dirname(path))
	tern.fs.write(path, text)
end

-- Format number written into projects.json and task.json; newer files are left alone.
local FORMAT = 1

-- Why projects.json can't be read (Swarm then never writes it), or nil.
local projects_damaged: string? = nil
-- The last good projects map read in this VM, served while projects.json is damaged.
local last_projects: { [string]: any } = {}
local projects_warned = false

-- The projects map in the projects file at `path`, or nil and why it can't be used.
local function parse_projects(path: string): ({ [string]: any }?, string?)
	local value = store.read_json(path)
	if type(value) ~= "table" then
		return nil, "it isn't valid JSON"
	end
	if value.format == nil then
		return value, nil
	end
	if type(value.format) ~= "number" or type(value.projects) ~= "table" then
		return nil, "it isn't a Swarm projects file"
	end
	if value.format > FORMAT then
		return nil, "written by a newer Swarm"
	end
	return value.projects, nil
end

-- Registered projects by id. A damaged file is restored from projects.json.bak when that is good;
-- otherwise it is marked damaged (store.projects_problem) and the last good map of this VM is returned.
function store.projects(): { [string]: any }
	local path = paths.projects_file()
	if not tern.fs.exists(path) then
		projects_damaged = nil
		last_projects = {}
		return {}
	end
	local map, why = parse_projects(path)
	if map then
		projects_damaged = nil
		last_projects = map
		return map
	end
	if why ~= "written by a newer Swarm" then
		local bak = parse_projects(path .. ".bak")
		if bak then
			tern.log.warn("swarm: projects.json was damaged; restored it from projects.json.bak")
			projects_damaged = nil
			local ok, err = pcall(store.save_projects, bak)
			if not ok then
				tern.log.warn("swarm: could not restore projects.json", tostring(err))
			end
			last_projects = bak
			return bak
		end
	end
	projects_damaged = why or "it isn't valid JSON"
	if not projects_warned then
		projects_warned = true
		tern.log.warn("swarm: projects.json is damaged; Swarm won't change it until you fix or delete it", path)
	end
	return table.clone(last_projects)
end

-- Why projects.json is damaged, or nil when it is fine.
function store.projects_problem(): string?
	return projects_damaged
end

-- Writes projects.json.bak, then projects.json. Raises while projects.json is damaged.
function store.save_projects(projects: { [string]: any })
	local path = paths.projects_file()
	if projects_damaged then
		error("projects.json is damaged (" .. projects_damaged .. "); fix or delete " .. path)
	end
	local value = { format = FORMAT, projects = projects }
	store.write_json(path .. ".bak", value)
	store.write_json(path, value)
	last_projects = projects
end

-- True while pane `pane` still exists (host half: a block's async callback checks its pane).
function store.pane_alive(pane: number): boolean
	for _, info in tern.pane.list() do
		if info.pane == pane then
			return true
		end
	end
	return false
end

-- Last logged status per task ("pid/slug"), for the transition log.
local saved_status: { [string]: string } = {}

-- Damaged task files already warned about in this VM ("pid/slug").
local damage_warned: { [string]: boolean } = {}

-- Reads task.json of `slug` in project `pid`: (task, nil) when valid, (nil, reason) when damaged,
-- (nil, nil) when missing. A damaged file is copied once to task.json.corrupt and never touched.
function store.load_task(pid: string, slug: string): (any?, string?)
	local path = paths.task_dir(pid, slug) .. "/task.json"
	if not tern.fs.exists(path) then
		return nil, nil
	end
	local okr, raw = pcall(tern.fs.read, path, MAX_JSON)
	local why: string? = nil
	local task: any = nil
	if okr then
		local okd, value = pcall(tern.json.decode, raw)
		task = if okd then value else nil
	end
	if type(task) ~= "table" then
		why = "it isn't valid JSON"
	elseif task.slug ~= slug then
		why = "its slug doesn't match its folder"
	elseif task.project ~= pid then
		why = "it belongs to another project"
	elseif type(task.format) == "number" and task.format > FORMAT then
		why = "it was written by a newer Swarm"
	elseif type(task.status) ~= "string" or (const.LANE[task.status] == nil and task.status ~= "cancelled") then
		why = "its status is unknown"
	end
	local key = pid .. "/" .. slug
	if why then
		local corrupt = path .. ".corrupt"
		if okr and not tern.fs.exists(corrupt) then
			pcall(store.write_text, corrupt, raw)
		end
		if not damage_warned[key] then
			damage_warned[key] = true
			tern.log.warn("swarm: task.json is damaged", pid, slug, why)
		end
		return nil, why
	end
	damage_warned[key] = nil
	if not task.archived then
		saved_status[key] = task.status
	end
	return task, nil
end

-- Every task of project `pid` by slug, and the damaged ones by slug with the reason (store.load_task).
function store.load_tasks(pid: string): ({ [string]: any }, { [string]: string })
	local tasks: { [string]: any } = {}
	local damaged: { [string]: string } = {}
	local ok, names = pcall(tern.fs.list, paths.tasks_dir(pid))
	if not ok then
		return tasks, damaged
	end
	for _, slug in names do
		local task, why = store.load_task(pid, slug)
		if task then
			tasks[slug] = task
		elseif why then
			damaged[slug] = why
		end
	end
	return tasks, damaged
end

-- Last saved JSON per task ("pid/slug"), without `updated`, so unchanged tasks are not rewritten.
local saved: { [string]: string } = {}

-- Writes task.json when the task changed since the last save; sets `updated` and `format`.
-- Archived tasks and damaged placeholders are never written.
function store.save_task(task: any)
	if task.archived or task.damaged then
		return
	end
	task.format = FORMAT
	local key = task.project .. "/" .. task.slug
	if task.status ~= saved_status[key] then
		tern.log.info(
			string.format(
				"swarm: %s %s -> %s%s",
				key,
				saved_status[key] or "new",
				tostring(task.status),
				if task.reason then " (" .. tostring(task.reason) .. ")" else ""
			)
		)
		saved_status[key] = task.status
	end
	local updated = task.updated
	task.updated = nil
	local json = tern.json.encode(task)
	task.updated = updated
	if saved[key] == json then
		return
	end
	task.updated = os.time()
	store.write_json(paths.task_dir(task.project, task.slug) .. "/task.json", task)
	saved[key] = json
end

-- Forgets the save cache of a task (after it was archived).
function store.forget(pid: string, slug: string)
	saved[pid .. "/" .. slug] = nil
	saved_status[pid .. "/" .. slug] = nil
end

-- The task's details.md (at most 20000 bytes), or "".
function store.details(pid: string, slug: string): string
	return store.read_text(paths.task_dir(pid, slug) .. "/details.md", 20000) or ""
end

local counter = 0

-- Queues a mutation for the leader window. File names sort by creation time across processes.
function store.write_intent(intent: { [string]: any })
	counter = (counter + 1) % 1000
	local name = string.format("%d%03d-%09d.json", os.time(), counter, math.random(0, 999999999))
	store.write_json(paths.intents_dir() .. "/" .. name, intent)
end

-- Queued intents in creation order, as {path, intent}; the caller removes each once handled
-- (store.remove_intent). Undecodable files are retried until 30 s old, then dropped.
function store.pending_intents(): { { path: string, intent: any } }
	local out: { { path: string, intent: any } } = {}
	local ok, names = pcall(tern.fs.list, paths.intents_dir())
	if not ok then
		return out
	end
	table.sort(names)
	for _, name in names do
		if string.sub(name, -5) == ".json" then
			local path = paths.intents_dir() .. "/" .. name
			local intent = store.read_json(path)
			if type(intent) == "table" then
				table.insert(out, { path = path, intent = intent })
			else
				local at = tonumber(string.sub(name, 1, 10))
				if at == nil or os.time() - at > 30 then
					tern.log.warn("swarm: dropping unreadable intent", name)
					pcall(tern.fs.remove, path)
				end
			end
		end
	end
	return out
end

-- Deletes a handled intent file.
function store.remove_intent(path: string)
	pcall(tern.fs.remove, path)
end

return store
