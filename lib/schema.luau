--!strict
-- Every Swarm setting: its key, layer scope, default, validation and how the user and project layers
-- combine. The single source of truth for lib/config and the Settings block. Both halves.

local paths = require("./paths")

local schema = {}

export type Scope = "project" | "user" | "both"
export type Merge = "override" | "user_wins" | "append" | "intersect" | "strictest"
export type Spec = {
	key: string,
	scope: Scope,
	merge: Merge,
	default: any,
	parse: (v: any, root: string?, layer: "user" | "project") -> (any, string?),
}

schema.PLACEHOLDERS = { "title", "slug", "role", "branch" }
schema.STRICTNESS = { model = 0, keywords = 1, slug = 2, off = 3 }

-- Nested read by dotted path; nil when any level is missing.
function schema.get(t: any, key: string): any
	local cur = t
	for part in string.gmatch(key, "[^%.]+") do
		if type(cur) ~= "table" then
			return nil
		end
		cur = cur[part]
	end
	return cur
end

-- Nested write, creating objects; v == nil deletes the leaf and removes parents that become empty.
function schema.set(t: any, key: string, v: any)
	local parts: { string } = {}
	for part in string.gmatch(key, "[^%.]+") do
		table.insert(parts, part)
	end
	if v == nil then
		local chain: { any } = { t }
		local cur = t
		for i = 1, #parts - 1 do
			cur = cur[parts[i]]
			if type(cur) ~= "table" then
				return
			end
			table.insert(chain, cur)
		end
		cur[parts[#parts]] = nil
		for i = #parts - 1, 1, -1 do
			if next(chain[i + 1]) ~= nil then
				break
			end
			chain[i][parts[i]] = nil
		end
		return
	end
	local cur = t
	for i = 1, #parts - 1 do
		local nxt = cur[parts[i]]
		if type(nxt) ~= "table" then
			nxt = {}
			cur[parts[i]] = nxt
		end
		cur = nxt
	end
	cur[parts[#parts]] = v
end

-- `template` with {title} {slug} {role} {branch} replaced from `vars`; other braces stay.
function schema.render(template: string, vars: { [string]: string }): string
	return (string.gsub(template, "{([%w_]+)}", function(k: string): string
		if table.find(schema.PLACEHOLDERS, k) ~= nil and vars[k] ~= nil then
			return vars[k]
		end
		return "{" .. k .. "}"
	end))
end

-- "90s", "30m", "2h" in seconds (> 0); nil for anything else.
function schema.seconds(s: string): number?
	if type(s) ~= "string" then
		return nil
	end
	local n, unit = string.match(s, "^(%d+)([smh])$")
	if n == nil then
		return nil
	end
	local secs = (tonumber(n) :: number) * (if unit == "h" then 3600 elseif unit == "m" then 60 else 1)
	return if secs > 0 then secs else nil
end

-- A leading "~/" expanded to the home folder.
function schema.expand(p: string): string
	if string.sub(p, 1, 2) == "~/" then
		return paths.HOME .. "/" .. string.sub(p, 3)
	end
	return p
end

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

local function is_list(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	local n = 0
	for k in v do
		if type(k) ~= "number" then
			return false
		end
		n += 1
	end
	return n == #v
end

local function is_object(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	for k in v do
		if type(k) ~= "string" then
			return false
		end
	end
	return true
end

local function quoted(values: { string }): string
	local parts: { string } = {}
	for _, v in values do
		table.insert(parts, '"' .. v .. '"')
	end
	if #parts == 1 then
		return parts[1]
	end
	return table.concat(parts, ", ", 1, #parts - 1) .. " or " .. parts[#parts]
end

type Parser = (v: any, root: string?, layer: "user" | "project") -> (any, string?)

local function enum(values: { string }): Parser
	local want = "must be " .. quoted(values)
	return function(v: any): (any, string?)
		if type(v) == "string" and table.find(values, v) ~= nil then
			return v
		end
		return nil, want
	end
end

local function int_range(lo: number, hi: number): Parser
	local want = string.format("must be a whole number from %d to %d", lo, hi)
	return function(v: any): (any, string?)
		if type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi then
			return v
		end
		return nil, want
	end
end

local function boolean(v: any): (any, string?)
	if type(v) == "boolean" then
		return v
	end
	return nil, "must be true or false"
end

local function nonempty_string(v: any): (any, string?)
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil, "must be a non-empty string"
end

local function pattern(pat: string, want: string): Parser
	return function(v: any): (any, string?)
		if type(v) == "string" and string.find(v, pat) then
			return v
		end
		return nil, "must be " .. want
	end
end

-- A JSON list of strings, each accepted by `ok`.
local function string_list(ok: (s: string) -> boolean, want: string): Parser
	return function(v: any): (any, string?)
		if not is_list(v) then
			return nil, "must be " .. want
		end
		local out: { string } = {}
		for _, s in v do
			if type(s) ~= "string" or not ok(s) then
				return nil, "must be " .. want
			end
			table.insert(out, s)
		end
		return out
	end
end

local function is_duration(v: any): boolean
	if type(v) ~= "string" then
		return false
	end
	local n = string.match(v, "^(%d+)[smh]?$")
	return n ~= nil and tonumber(n) ~= 0
end

local function duration(v: any): (any, string?)
	if is_duration(v) then
		return v
	end
	return nil, 'must be a duration like "45m"'
end

local function is_arg(s: string): boolean
	return string.find(s, "^[%w%-_=.:/@]+$") ~= nil
end

local plain_args = string_list(is_arg, "a list of plain arguments (letters, digits, -_=.:/@)")

local APPROVAL_FLAGS: { [string]: boolean } = {
	["--approval-mode"] = true,
	["--yolo"] = true,
	["--auto-approve"] = true,
	["--plan-yolo"] = true,
	["--plan-yolo-into"] = true,
	["--config"] = true,
}

-- Whether `tok` is one of omp's approval or config-overlay flags, which only the user may set.
function schema.approval_flag(tok: string): boolean
	if APPROVAL_FLAGS[tok] then
		return true
	end
	for _, prefix in { "--approval-mode=", "--plan-yolo-into=", "--config=" } do
		if string.sub(tok, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

-- Plain arguments; a project can't set the approval mode or load an omp config.
local function agent_args(v: any, root: string?, layer: "user" | "project"): (any, string?)
	local list, problem = plain_args(v, root, layer)
	if list == nil then
		return nil, problem
	end
	if layer == "project" then
		for _, tok in list :: { string } do
			if schema.approval_flag(tok) then
				return nil,
					"can't set the approval mode or load an omp config (--approval-mode, --yolo, --auto-approve, --plan-yolo, --plan-yolo-into, --config); set those in your own settings"
			end
		end
	end
	return list
end

local function timeout(v: any): (any, string?)
	local secs = schema.seconds(v)
	if secs ~= nil then
		return secs
	end
	return nil, 'must be a duration like "30m"'
end

-- Problem text for `{x}` placeholders outside schema.PLACEHOLDERS, or nil.
local function bad_placeholder(s: string): string?
	for name in string.gmatch(s, "{([%w_]+)}") do
		if table.find(schema.PLACEHOLDERS, name) == nil then
			return string.format("uses unknown placeholder {%s} (known: {title} {slug} {role} {branch})", name)
		end
	end
	return nil
end

local function sanitize_name(name: string): string
	return (string.gsub(name, "[^%w_%-]", "-"))
end

local function parse_checks(v: any): (any, string?)
	local want = "must be a list of {name, run, agent_runs} objects"
	if not is_list(v) then
		return nil, want
	end
	local list: { any } = {}
	local seen: { [string]: boolean } = {}
	for _, c in v do
		if type(c) ~= "table" or type(c.name) ~= "string" or c.name == "" or type(c.run) ~= "string" or c.run == "" then
			return nil, want
		end
		if c.agent_runs ~= nil and type(c.agent_runs) ~= "boolean" then
			return nil, want
		end
		local name = sanitize_name(c.name)
		if seen[name] then
			return nil, string.format('has duplicate name "%s" after sanitizing', name)
		end
		seen[name] = true
		table.insert(list, { name = name, run = c.run, agent_runs = c.agent_runs ~= false })
	end
	return list
end

local function parse_instructions(v: any): (any, string?)
	local want = "must be text of at most 8000 characters, or a list of strings"
	if type(v) == "string" then
		if #v > 8000 then
			return nil, want
		end
		return v
	end
	if not is_list(v) then
		return nil, want
	end
	local lines: { string } = {}
	for _, s in v do
		if type(s) ~= "string" then
			return nil, want
		end
		table.insert(lines, "- " .. s)
	end
	return table.concat(lines, "\n")
end

local function parse_roles(v: any): (any, string?)
	if not is_object(v) then
		return nil, "must map role names to {max_time, agent_args} objects"
	end
	local out: { [string]: any } = {}
	for r, rc in v do
		if not string.find(r, "^[%w_%-]+$") then
			return nil, string.format('has an invalid role name "%s"', r)
		end
		if not is_object(rc) then
			return nil, string.format('must map role "%s" to a {max_time, agent_args} object', r)
		end
		local entry: { [string]: any } = {}
		for k, x in rc do
			if k == "max_time" then
				if not is_duration(x) then
					return nil, string.format('has an invalid max_time for role "%s" (want a duration like "45m")', r)
				end
				entry.max_time = x
			elseif k == "agent_args" then
				local args, problem = agent_args(x, nil, "project")
				if args == nil then
					return nil, string.format('has invalid agent_args for role "%s": %s', r, problem or "want plain arguments")
				end
				entry.agent_args = args
			else
				return nil, string.format('has unknown key "%s" for role "%s"', k, r)
			end
		end
		out[r] = entry
	end
	return out
end

local function parse_env(v: any): (any, string?)
	if not is_object(v) then
		return nil, "must map variable names to strings"
	end
	local out: { [string]: string } = {}
	for name, value in v do
		if not string.find(name, "^[%a_][%w_]*$") then
			return nil, string.format('has an invalid variable name "%s"', name)
		end
		if type(value) ~= "string" or string.find(value, "\n", 1, true) or string.find(value, "\0", 1, true) then
			return nil, string.format("must give %s a one-line string", name)
		end
		out[name] = value
	end
	return out
end

local function parse_worktree_dir(v: any, _root: string?, layer: "user" | "project"): (any, string?)
	if type(v) ~= "string" or v == "" then
		return nil, "must be a non-empty string"
	end
	if layer == "user" and not string.find(v, "{repo}", 1, true) then
		return nil, "must contain {repo} so projects don't share a folder"
	end
	return v
end

local function parse_branch_prefix(v: any): (any, string?)
	local want = "must be a branch prefix like \"swarm/\" (letters, digits, ._/-; no .., //, leading / or -, or trailing .lock)"
	if type(v) ~= "string" or not string.find(v, "^[%w._/-]*$") then
		return nil, want
	end
	if string.find(v, "..", 1, true) or string.find(v, "//", 1, true) then
		return nil, want
	end
	local first = string.sub(v, 1, 1)
	if first == "/" or first == "-" or string.sub(v, -5) == ".lock" then
		return nil, want
	end
	return v
end

local function parse_commit_message(v: any): (any, string?)
	if type(v) ~= "string" or #v > 2000 then
		return nil, "must be text of at most 2000 characters"
	end
	local first = string.match(v, "^[^\n]*") or ""
	if trim(first) == "" then
		return nil, "must have a non-empty first line"
	end
	local bad = bad_placeholder(v)
	if bad then
		return nil, bad
	end
	return v
end

local function parse_pr_title(v: any): (any, string?)
	if type(v) ~= "string" or #v > 200 or string.find(v, "\n", 1, true) or trim(v) == "" then
		return nil, "must be one non-empty line of at most 200 characters"
	end
	local bad = bad_placeholder(v)
	if bad then
		return nil, bad
	end
	return v
end

local function is_handle(s: string): boolean
	return string.find(s, "^@?[%w._/-]+$") ~= nil
end

local CARLY_ALL = { "approve", "retry", "park", "discard" }
schema.CARLY_ALL = CARLY_ALL

local function parse_carly_actions(v: any): (any, string?)
	local want = "must be a list of " .. quoted(CARLY_ALL)
	if not is_list(v) then
		return nil, want
	end
	local out: { string } = {}
	for _, a in v do
		if type(a) ~= "string" or table.find(CARLY_ALL, a) == nil then
			return nil, want
		end
		if table.find(out, a) == nil then
			table.insert(out, a)
		end
	end
	return out
end

local function parse_bin_dirs(v: any): (any, string?)
	local want = "must be a list of absolute folders"
	if not is_list(v) then
		return nil, want
	end
	local out: { string } = {}
	for _, s in v do
		if type(s) ~= "string" then
			return nil, want
		end
		local p = schema.expand(s)
		if string.sub(p, 1, 1) ~= "/" then
			return nil, want
		end
		table.insert(out, p)
	end
	return out
end

local function parse_ref(v: any): (any, string?)
	local want = 'must be a branch name like "main" or "origin/main"'
	if type(v) ~= "string" or not string.find(v, "^[%w._/%-]+$") then
		return nil, want
	end
	local first = string.sub(v, 1, 1)
	if first == "-" or first == "/" or string.find(v, "..", 1, true) or string.find(v, "//", 1, true) then
		return nil, want
	end
	local last = string.sub(v, -1)
	if last == "/" or last == "." or string.sub(v, -5) == ".lock" then
		return nil, want
	end
	return v
end

local function spec(key: string, scope: Scope, merge: Merge, default: any, parse: Parser): Spec
	return { key = key, scope = scope, merge = merge, default = default, parse = parse }
end

local FIELDS: { Spec } = {
	spec("base", "project", "override", nil, parse_ref),
	spec("checks", "project", "override", nil, parse_checks),
	spec("setup", "project", "override", nil, string_list(function(s: string): boolean
		return s ~= ""
	end, "a list of command strings")),
	spec("default_role", "both", "override", "default", pattern("^[%w_%-]+$", "a role name")),
	spec("max_concurrent", "both", "override", 3, int_range(1, 32)),
	spec("max_attempts", "project", "override", 3, int_range(1, 20)),
	spec("max_time", "both", "override", "45m", duration),
	spec("agent_args", "both", "user_wins", { "--approval-mode", "yolo" }, agent_args),
	spec("ship", "project", "override", "pr", enum({ "pr", "commit" })),
	spec("worktree_dir", "both", "user_wins", "../{repo}-swarm", parse_worktree_dir),
	spec("instructions", "both", "append", nil, parse_instructions),
	spec("roles", "project", "override", {}, parse_roles),
	spec("timeouts.checks", "project", "override", 1800, timeout),
	spec("timeouts.setup", "project", "override", 1200, timeout),
	spec("timeouts.ship", "project", "override", 300, timeout),
	spec("checks_mode", "project", "override", "all", enum({ "all", "fail_fast" })),
	spec("env", "project", "override", {}, parse_env),
	spec("max_concurrent_total", "user", "override", nil, int_range(1, 64)),
	spec("adopt_cards", "both", "override", "backlog_and_ready", enum({ "backlog_and_ready", "backlog", "off" })),
	spec("on_move_to_done", "both", "override", "approve", enum({ "approve", "approve_only", "close", "revert" })),
	spec("no_change", "project", "override", "block", enum({ "block", "review", "done" })),
	spec("on_checks_pass", "project", "override", "review", enum({ "review", "ship" })),
	spec("clean.auto", "both", "override", "manual", enum({ "manual", "after_ship", "after_merge" })),
	spec("clean.remove_done_cards", "both", "override", false, boolean),
	spec("new_task.lane", "both", "override", "Ready", enum({ "Ready", "Backlog" })),
	spec("branch_prefix", "both", "override", "swarm/", parse_branch_prefix),
	spec("remote", "project", "override", "origin", pattern("^[%w._-]+$", "a remote name")),
	spec("worktree_tool", "both", "override", "omp", enum({ "omp", "git" })),
	spec("commit.message", "project", "override", "{title}\n\nSwarm-Task: {slug}\nSwarm-Role: {role}", parse_commit_message),
	spec("pr.draft", "both", "override", false, boolean),
	spec("pr.title", "project", "override", "{title}", parse_pr_title),
	spec("pr.reviewers", "project", "override", {}, string_list(is_handle, "a list of GitHub users or teams")),
	spec("pr.labels", "project", "override", {}, string_list(function(s: string): boolean
		return s ~= "" and not string.find(s, "[,\n]")
	end, "a list of labels without commas")),
	spec("pr.assignees", "project", "override", {}, string_list(is_handle, "a list of GitHub users")),
	spec("discard.delete_branch", "both", "override", true, boolean),
	spec("tabs.names", "both", "strictest", "model", enum({ "model", "keywords", "slug", "off" })),
	spec("layout.panel", "user", "override", "below", enum({ "beside", "below", "tab", "none" })),
	spec("carly.actions", "both", "intersect", { "retry", "park" }, parse_carly_actions),
	spec("carly.context", "user", "override", "all", enum({ "all", "attention", "off" })),
	spec("bin_dirs", "user", "override", {}, parse_bin_dirs),
	spec("watchdog", "user", "override", "reload", enum({ "reload", "notify", "off" })),
}
schema.FIELDS = FIELDS

local BY_KEY: { [string]: Spec } = {}
for _, s in FIELDS do
	BY_KEY[s.key] = s
end
schema.BY_KEY = BY_KEY

return schema
