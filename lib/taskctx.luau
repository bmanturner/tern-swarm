--!strict
-- Per-project task context for the orchestrator: the cached merged config (cfg_for), the ctx that
-- status steps and actions receive (make_ctx), and new task records. Window half.

local config = require("./config")
local const = require("./const")
local state = require("./state")

local taskctx = {}

-- pid -> the config of the last load whose swarm.json parsed (kept across leadership periods).
local last_good: { [string]: any } = {}

-- The merged config of project `pid`, its problems, and why nothing may start or ship (nil when
-- work may run): the project file is broken and no earlier valid config is known, or the user
-- hasn't approved what this repository makes Swarm run (cache entry `untrusted`).
function taskctx.cfg_for(pid: string): (config.Config, string?, string?)
	local entry = state.cfg[pid]
	local proj = state.projects[pid]
	if entry == nil or os.time() - entry.at > const.CONFIG_CACHE_S then
		local cfg, err, broken = config.load(proj.root)
		local hold: string? = nil
		local untrusted = false
		if not broken then
			last_good[pid] = cfg
		elseif last_good[pid] ~= nil then
			cfg = last_good[pid]
			err = (err or "swarm.json is broken") .. "; using the last valid settings"
		else
			err = (err or "swarm.json is broken") .. "; nothing new starts or ships until it's fixed"
			hold = "Fix .tern/swarm.json first."
		end
		if hold == nil and not config.trusted(proj.root, cfg.trust.subject) then
			hold = "Approve what this repository runs in the Swarm panel first."
			untrusted = true
		end
		entry = { cfg = cfg, load_err = err, err = err, hold = hold, untrusted = untrusted, at = os.time() }
		state.cfg[pid] = entry
	end
	-- Roles arrive asynchronously, so the default_role problem is rechecked on every call.
	local err = entry.load_err
	local known = state.roles[pid]
	local role = entry.cfg.default_role
	if known and known.names and not known.names[role] then
		local known_names: { string } = {}
		for _, r in known.list or {} do
			table.insert(known_names, r.name)
		end
		local problem = string.format('default_role "%s" is not an omp role (known: %s)', role, table.concat(known_names, ", "))
		err = if err then err .. "; " .. problem else problem
	end
	entry.err = err
	return entry.cfg, err, entry.hold
end

function taskctx.make_ctx(cx: WindowCx, pid: string): any
	local agents: { [number]: any } = {}
	local ok, list = pcall(function()
		return cx.agents:list()
	end)
	if ok then
		for _, a in list do
			agents[a.pane] = a
		end
	end
	local tabs: { [number]: any } = {}
	for _, t in cx.session:tabs() do
		tabs[t.id] = t
	end
	local okp, panes = pcall(function()
		return cx.session:panes()
	end)
	local cfg, _, hold = taskctx.cfg_for(pid)
	return {
		cx = cx,
		pid = pid,
		proj = state.projects[pid],
		cfg = cfg,
		hold = hold,
		agents = agents,
		tabs = tabs,
		panes = if okp and type(panes) == "table" then panes else {},
		cards = {},
	}
end

function taskctx.new_task(pid: string, slug: string, title: string, lane: string): any
	return {
		slug = slug,
		project = pid,
		title = title,
		status = if lane == "Ready" then "queued" else "backlog",
		lane = lane,
		attempt = 0,
		created = os.time(),
	}
end

return taskctx
