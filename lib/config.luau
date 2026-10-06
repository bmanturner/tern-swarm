--!strict
-- Swarm settings: the user layer (<plugin data>/settings.json) and the project layer
-- (<root>/.tern/swarm.json), validated and combined per lib/schema. Both halves.

local const = require("./const")
local paths = require("./paths")
local schema = require("./schema")
local text = require("./text")

local config = {}

export type Check = { name: string, run: string, agent_runs: boolean }
export type Config = {
	base: string?,
	checks: { Check },
	checks_detected: boolean,
	setup: { string }?,
	default_role: string,
	max_concurrent: number,
	max_attempts: number,
	max_time: string,
	agent_args: { string },
	-- The approval tokens every agent command starts with: from your agent_args, else the default.
	approval_args: { string },
	ship: string,
	worktree_dir: string,
	instructions: { user: string?, project: string? },
	roles: { [string]: { max_time: string?, agent_args: { string }? } },
	timeouts: { checks: number, setup: number, ship: number },
	checks_mode: string,
	env: { [string]: string },
	adopt_cards: string,
	on_move_to_done: string,
	no_change: string,
	on_checks_pass: string,
	clean: { auto: string, remove_done_cards: boolean },
	new_task: { lane: string },
	branch_prefix: string,
	remote: string,
	worktree_tool: string,
	commit: { message: string },
	pr: { draft: boolean, title: string, reviewers: { string }, labels: { string }, assignees: { string } },
	discard: { delete_branch: boolean },
	tabs: { names: string },
	carly: { actions: { string } },
	-- What the repository makes Swarm run: `subject` is "" when nothing (no approval needed).
	trust: { subject: string, items: { string } },
}
export type UserConfig = {
	max_concurrent_total: number?,
	layout: { panel: string },
	carly: { context: string, actions: { string } },
	bin_dirs: { string },
	watchdog: string,
}

type Layer = "user" | "project"

local LABEL: { [Layer]: string } = { user = "settings.json", project = "swarm.json" }

-- Object paths that hold spec keys ("pr", "timeouts", ...), for the unknown-key walk.
local PREFIXES: { [string]: boolean } = {}
for _, spec in schema.FIELDS do
	local prefix: string? = nil
	for part in string.gmatch(spec.key, "[^%.]+") do
		if prefix ~= nil then
			PREFIXES[prefix] = true
		end
		prefix = if prefix then prefix .. "." .. part else part
	end
end

local function copy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = copy(x)
	end
	return out
end

local function allowed(spec: schema.Spec, layer: Layer): boolean
	return spec.scope == "both" or spec.scope == layer
end

function config.project_path(root: string): string
	return root .. "/.tern/swarm.json"
end

function config.user_path(): string
	return paths.data() .. "/settings.json"
end

-- The decoded JSON object at `path`: {} when missing, nil and a problem when unreadable or not an object.
function config.read_raw(path: string): (any, string?)
	local label = paths.basename(path)
	if not tern.fs.exists(path) then
		return {}, nil
	end
	local ok, text = pcall(tern.fs.read, path, 262144)
	if not ok then
		return nil, label .. ": is not valid JSON"
	end
	local decoded, value = pcall(tern.json.decode, text)
	if not decoded then
		return nil, label .. ": is not valid JSON"
	end
	if type(value) ~= "table" or (next(value) ~= nil and #value > 0) then
		return nil, label .. ": must hold an object"
	end
	return value, nil
end

function config.write_raw(path: string, raw: any)
	tern.fs.mkdir(paths.dirname(path))
	tern.fs.write(path, tern.json.encode(raw, true) .. "\n")
end

-- Checks from package.json scripts present at the root: type-check, typecheck, lint, test.
function config.detected_checks(root: string): { Check }
	local checks: { Check } = {}
	local ok, text = pcall(tern.fs.read, root .. "/package.json", 262144)
	if not ok then
		return checks
	end
	local decoded, pkg = pcall(tern.json.decode, text)
	if not decoded or type(pkg) ~= "table" or type(pkg.scripts) ~= "table" then
		return checks
	end
	for _, name in { "type-check", "typecheck", "lint", "test" } do
		local script = pkg.scripts[name]
		if type(script) == "string" and not (name == "test" and string.find(script, "no test specified", 1, true)) then
			table.insert(checks, { name = name, run = "npm run " .. name, agent_runs = true })
		end
	end
	return checks
end

-- Reports unknown keys and keys set in the wrong layer.
local function walk(raw: any, layer: Layer, prefix: string?, problems: { string })
	for k, v in raw do
		if type(k) ~= "string" or k == "$schema" or string.sub(k, 1, 1) == "_" then
			continue
		end
		local path = if prefix then prefix .. "." .. k else k
		local spec = schema.BY_KEY[path]
		if spec ~= nil then
			if not allowed(spec, layer) then
				table.insert(
					problems,
					if layer == "project"
						then `swarm.json: {path} can only be set in your Swarm settings`
						else `settings.json: {path} can only be set in a project's .tern/swarm.json`
				)
			end
		elseif PREFIXES[path] then
			if type(v) == "table" and #v == 0 then
				walk(v, layer, path, problems)
			else
				table.insert(problems, `{LABEL[layer]}: {path} must be an object`)
			end
		else
			table.insert(problems, `{LABEL[layer]}: unknown key {path}`)
		end
	end
end

-- The parsed value of `spec` in a layer's raw: (value) when set and valid, (nil, problem) when invalid.
local function take(spec: schema.Spec, raw: any, layer: Layer, root: string?): (any, string?)
	if raw == nil or not allowed(spec, layer) then
		return nil
	end
	local v = schema.get(raw, spec.key)
	if v == nil then
		return nil
	end
	return spec.parse(v, root, layer)
end

local function combine(spec: schema.Spec, uv: any, pv: any): any
	local merge = spec.merge
	if merge == "append" then
		return { user = uv, project = pv }
	elseif merge == "intersect" then
		-- Only carly.actions. A repository can only narrow: without your own value its list is
		-- intersected with the default (default order), so it can't widen past it; with both set,
		-- your entries (your order) that the project also allows.
		if uv == nil and pv == nil then
			return copy(spec.default)
		elseif pv == nil then
			return copy(uv)
		end
		local base = if uv ~= nil then uv else spec.default
		local out: { any } = {}
		for _, x in base do
			if table.find(pv, x) ~= nil then
				table.insert(out, x)
			end
		end
		return out
	elseif merge == "strictest" then
		local u = if uv ~= nil then uv else spec.default
		local p = if pv ~= nil then pv else spec.default
		return if (schema.STRICTNESS :: any)[u] >= (schema.STRICTNESS :: any)[p] then u else p
	elseif merge == "user_wins" then
		if uv ~= nil then
			return uv
		elseif pv ~= nil then
			return pv
		end
		return copy(spec.default)
	end
	if pv ~= nil then
		return pv
	elseif uv ~= nil then
		return uv
	end
	return copy(spec.default)
end

-- The user file, cached for CONFIG_CACHE_S: raw, read problem, and the derived UserConfig.
type UserCache = { raw: any, err: string?, at: number, user: UserConfig?, problems: string? }
local cache: UserCache? = nil

local function user_cache(force: boolean?): UserCache
	local c = cache
	if force or c == nil or os.time() - c.at > const.CONFIG_CACHE_S then
		local raw, err = config.read_raw(config.user_path())
		c = { raw = raw, err = err, at = os.time() }
		cache = c
	end
	return c :: UserCache
end

function config.forget()
	cache = nil
end

-- User-only settings: user-scope keys and the user's carly.actions. Cached unless `force`.
function config.user(force: boolean?): (UserConfig, string?)
	local c = user_cache(force)
	if c.user == nil then
		local problems: { string } = {}
		if c.err then
			table.insert(problems, c.err)
		end
		local raw = c.raw
		if raw ~= nil then
			walk(raw, "user", nil, problems)
		end
		local out: any = {}
		for _, spec in schema.FIELDS do
			if spec.scope == "user" or spec.key == "carly.actions" then
				local v, why = take(spec, raw, "user", nil)
				if why then
					table.insert(problems, `settings.json: {spec.key} {why}; using the default`)
				end
				schema.set(out, spec.key, if v ~= nil then v else copy(spec.default))
			end
		end
		c.user = out :: UserConfig
		c.problems = if #problems > 0 then table.concat(problems, "; ") else nil
	end
	return c.user :: UserConfig, c.problems
end

-- The merged settings of the project at `root`, the problems found ("; "-joined), and whether the
-- project file exists but can't be read (the caller decides what a broken file stops).
function config.load(root: string): (Config, string?, boolean)
	local problems: { string } = {}
	local uc = user_cache(false)
	local uraw = uc.raw
	if uc.err then
		table.insert(problems, uc.err)
	end
	local praw, perr = config.read_raw(config.project_path(root))
	local broken = praw == nil
	if perr then
		table.insert(problems, perr)
	end
	if uraw ~= nil then
		walk(uraw, "user", nil, problems)
	end
	if praw ~= nil then
		walk(praw, "project", nil, problems)
	end

	local cfg: any = {}
	local checks_set = false
	-- Valid project-layer values, and your own agent_args.
	local pvals: { [string]: any } = {}
	local user_args: { string }? = nil
	for _, spec in schema.FIELDS do
		local key = spec.key
		local uv, uwhy = take(spec, uraw, "user", root)
		local pv, pwhy = take(spec, praw, "project", root)
		if uwhy then
			local fallback = if spec.merge == "user_wins" and pv ~= nil then "the project's setting" else "the default"
			table.insert(problems, `settings.json: {key} {uwhy}; using {fallback}`)
		end
		if pwhy then
			if key == "ship" then
				pv = "commit"
				table.insert(problems, `swarm.json: ship {pwhy}; using "commit"`)
			else
				local fallback = if uv ~= nil then "your setting" else "the default"
				table.insert(problems, `swarm.json: {key} {pwhy}; using {fallback}`)
			end
		end
		if key == "checks" then
			checks_set = pv ~= nil
		end
		if pv ~= nil then
			pvals[key] = pv
		end
		if key == "agent_args" then
			user_args = uv
		end
		schema.set(cfg, key, combine(spec, uv, pv))
	end

	-- Approval tokens always come from you: a project's agent_args follow them.
	local approval: { string } = {}
	if user_args ~= nil then
		local list = user_args
		local i = 1
		while i <= #list do
			local tok = list[i]
			if schema.approval_flag(tok) then
				table.insert(approval, tok)
				if (tok == "--approval-mode" or tok == "--plan-yolo-into" or tok == "--config") and list[i + 1] ~= nil then
					i += 1
					table.insert(approval, list[i])
				end
			end
			i += 1
		end
	else
		approval = { "--approval-mode", "yolo" }
	end
	cfg.approval_args = approval
	if user_args == nil and pvals.agent_args ~= nil then
		local merged = table.clone(approval)
		for _, a in pvals.agent_args :: { string } do
			table.insert(merged, a)
		end
		cfg.agent_args = merged
	end

	if not checks_set then
		cfg.checks = config.detected_checks(root)
	end
	cfg.checks_detected = not checks_set
	local base = paths.basename(root)
	local template = string.gsub(cfg.worktree_dir, "{repo}", function(): string
		return base
	end)
	cfg.worktree_dir = paths.abs(root, schema.expand(template))

	-- What this repository makes Swarm run or tell agents, from project values and detection.
	local subject: { [string]: any } = {}
	local items: { string } = {}
	if pvals.setup then
		subject.setup = pvals.setup
		for _, cmd in pvals.setup :: { string } do
			table.insert(items, "Setup: " .. cmd)
		end
	elseif tern.fs.exists(root .. "/package-lock.json") then
		subject.setup_auto = "npm ci"
		table.insert(items, "Setup: npm ci (automatic: the repository has package-lock.json)")
	end
	if #cfg.checks > 0 then
		local list: { any } = {}
		for _, c in cfg.checks :: { Check } do
			table.insert(list, { name = c.name, run = c.run })
			table.insert(items, "Check " .. c.name .. ": " .. c.run .. (if cfg.checks_detected then " (from package.json)" else ""))
		end
		subject.checks = list
	end
	if pvals.env then
		subject.env = pvals.env
		local names: { string } = {}
		for name in pvals.env :: { [string]: string } do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			table.insert(items, "Env " .. name .. "=" .. pvals.env[name])
		end
	end
	if pvals.agent_args then
		subject.agent_args = pvals.agent_args
		table.insert(items, "Agent arguments: " .. table.concat(pvals.agent_args, " "))
	end
	if pvals.roles and next(pvals.roles) ~= nil then
		subject.roles = pvals.roles
		local names: { string } = {}
		for r in pvals.roles :: { [string]: any } do
			table.insert(names, r)
		end
		table.sort(names)
		for _, r in names do
			local rc = pvals.roles[r]
			local parts: { string } = {}
			if rc.max_time then
				table.insert(parts, "time limit " .. rc.max_time)
			end
			if rc.agent_args then
				table.insert(parts, "arguments " .. table.concat(rc.agent_args, " "))
			end
			table.insert(items, "Role " .. r .. ": " .. table.concat(parts, ", "))
		end
	end
	if type(pvals.instructions) == "string" then
		local s: string = pvals.instructions
		subject.instructions = s
		local first = string.match(s, "^[^\n]*") or ""
		table.insert(items, "Project instructions: " .. text.clip(first, 120) .. " (" .. #s .. " characters)")
	end
	if pvals.on_checks_pass == "ship" then
		subject.on_checks_pass = "ship"
		table.insert(items, "When checks pass: ship without waiting for you")
	end
	if pvals.base then
		subject.base = pvals.base
		table.insert(items, "Base branch: " .. pvals.base)
	end
	if pvals.remote then
		subject.remote = pvals.remote
		table.insert(items, "Remote: " .. pvals.remote)
	end
	if pvals.worktree_dir then
		subject.worktree_dir = pvals.worktree_dir
		table.insert(items, "Worktree folder: " .. pvals.worktree_dir)
	end
	cfg.trust = { subject = if next(subject) then tern.json.encode(subject) else "", items = items }

	return cfg :: Config, if #problems > 0 then table.concat(problems, "; ") else nil, broken
end

-- Whether you approved `subject` (cfg.trust.subject) for the repository at `root`. Both halves.
function config.trusted(root: string, subject: string): boolean
	if subject == "" then
		return true
	end
	local ok, record = pcall(tern.kv.get, "trust")
	return ok and type(record) == "table" and record[root] == subject
end

-- Records your approval of `subject` for the repository at `root` (kv "trust", per machine).
function config.approve(root: string, subject: string)
	local ok, record = pcall(tern.kv.get, "trust")
	if not ok then
		tern.log.warn("swarm: couldn't read the approval record", tostring(record))
		return
	end
	local out: { [string]: any } = {}
	if type(record) == "table" then
		for k, v in record do
			out[k] = v
		end
	end
	out[root] = subject
	pcall(tern.kv.set, "trust", out)
end

-- Keys whose values are JSON lists: tagged so an empty one encodes as [].
local STARTER_LISTS = { "checks", "setup", "agent_args", "instructions", "pr.reviewers", "pr.labels", "pr.assignees", "carly.actions" }

-- A starter .tern/swarm.json: the project file as it is, plus the detected checks when it sets none.
-- Never adds personal settings or defaults.
function config.starter(root: string): { [string]: any }
	local raw = config.read_raw(config.project_path(root))
	local out: { [string]: any } = if type(raw) == "table" then copy(raw) else {}
	for _, key in STARTER_LISTS do
		local v = schema.get(out, key)
		if type(v) == "table" and (next(v) == nil or #v > 0) then
			tern.json.array(v)
		end
	end
	if out.checks == nil then
		local checks: { any } = {}
		for _, c in config.detected_checks(root) do
			table.insert(checks, { name = c.name, run = c.run })
		end
		out.checks = tern.json.array(checks)
	end
	return out
end

return config
