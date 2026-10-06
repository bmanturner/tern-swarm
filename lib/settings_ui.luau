--!strict
-- The Settings block's pages, sections and rows, built from the two settings layers. Pure builders:
-- no I/O (only the file path strings from lib/config). Host half.

local config = require("./config")
local schema = require("./schema")
local text = require("./text")

local settings_ui = {}

local ui = tern.ui

type Layer = "project" | "user"

export type Model = {
	pid: string?,
	name: string?,
	root: string?,
	praw: any?,
	perr: string?,
	uraw: any?,
	uerr: string?,
	cfg: any?,
	roles: { any }?,
	roles_error: string?,
}

export type Row = {
	id: string,
	page: string,
	layer: Layer,
	key: string,
	op: string,
	index: number?,
	name: string?,
	label: string,
	hint: string?,
	warning: string?,
	disabled: string?,
	changed: boolean,
	defaultLabel: string?,
	control: { [string]: any },
}

type Section = { id: string, title: string, rows: { Row } }

local PROJECT_GROUP_PREFIX = "Project · "
local USER_GROUP = "You · all projects"

-- Helpers ---------------------------------------------------------------------------------------

local function opt(value: string, label: string, detail: string?): { [string]: any }
	return { value = value, label = label, detail = detail }
end

local function cap(s: string): string
	return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

local function first_line(s: string): string
	return string.match(s, "^[^\n]*") or ""
end

local function layer_raw(m: Model, layer: Layer): any
	return if layer == "project" then m.praw else m.uraw
end

local function file_name(layer: Layer): string
	return if layer == "project" then ".tern/swarm.json" else "settings.json"
end

-- "Fix <file> first: <error>" while that layer's file can't be read, else nil.
local function broken_reason(m: Model, layer: Layer): string?
	if layer_raw(m, layer) ~= nil then
		return nil
	end
	local err = (if layer == "project" then m.perr else m.uerr) or "it can't be read"
	err = string.gsub(err, "^[%w%._-]+%.json: ", "")
	return "Fix " .. file_name(layer) .. " first: " .. err
end

-- Duration in whole minutes: seconds (number) or "Ns" / "Nm" / "Nh" / "N" (seconds, as omp reads a bare --max-time).
local function minutes(v: any): number?
	if type(v) == "number" then
		return math.ceil(v / 60)
	end
	if type(v) ~= "string" then
		return nil
	end
	local n, unit = string.match(v, "^(%d+)([smh]?)$")
	if n == nil then
		return nil
	end
	local x = tonumber(n) :: number
	if unit == "s" then
		return math.ceil(x / 60)
	elseif unit == "h" then
		return x * 60
	end
	return math.ceil(x / 60)
end

local function arr(t: { any }?): { any }
	return tern.json.array(t or {})
end

-- One spec's value as a row of `layer` shows it.
type Resolved = {
	value: any, -- parsed value shown (or the fallback)
	set: boolean, -- the layer's raw has the key
	fallback: any, -- what the row falls back to when unset
	inherited: boolean, -- showing the user's value on a project row
	warning: string?,
}

local function resolve(m: Model, layer: Layer, key: string): Resolved
	local spec = schema.BY_KEY[key]
	local raw = layer_raw(m, layer)
	local rv = if raw ~= nil then schema.get(raw, key) else nil
	local fallback = spec.default
	local from_user = false
	if layer == "project" and spec.scope == "both" and spec.merge == "override" and m.uraw ~= nil then
		local urv = schema.get(m.uraw, key)
		if urv ~= nil then
			local uv = spec.parse(urv, m.root, "user")
			if uv ~= nil then
				fallback = uv
				from_user = true
			end
		end
	end
	if rv == nil then
		return { value = fallback, set = false, fallback = fallback, inherited = from_user }
	end
	local v, why = spec.parse(rv, m.root, layer)
	if v ~= nil then
		return { value = v, set = true, fallback = fallback, inherited = false }
	end
	if key == "ship" and layer == "project" then
		return {
			value = "commit",
			set = true,
			fallback = fallback,
			inherited = false,
			warning = 'Must be "pr" or "commit"; using "commit"',
		}
	end
	return {
		value = fallback,
		set = true,
		fallback = fallback,
		inherited = from_user,
		warning = cap(why or "is invalid") .. "; using " .. (if from_user then "your setting" else "the default"),
	}
end

-- Field rows ------------------------------------------------------------------------------------

type Kind = "switch" | "choice" | "duration" | "int" | "int0" | "text" | "list_ws" | "list_comma" | "multi" | "overlay"

type Opts = {
	options: { any }?,
	style: string?,
	min: number?,
	max: number?,
	step: number?,
	labels: { [string]: string }?,
	mono: boolean?,
	placeholder: string?,
	hint: string?,
	label: string?,
}

local OPS: { [string]: string } = {
	switch = "set",
	choice = "set",
	multi = "set",
	duration = "duration",
	int = "int",
	int0 = "int0",
	text = "text",
	list_ws = "list_ws",
	list_comma = "list_comma",
	overlay = "overlay",
}

local function option_label(options: { any }?, v: any): string?
	for _, o in options or {} do
		if o.value == v then
			return o.label or o.value
		end
	end
	return nil
end

-- The text a text-like control shows for `v`; nil when empty.
local function text_value(kind: Kind, key: string, v: any): string?
	if v == nil then
		return nil
	end
	if kind == "list_ws" or kind == "list_comma" then
		if type(v) ~= "table" or #v == 0 then
			return nil
		end
		return table.concat(v, if kind == "list_ws" then " " else ", ")
	end
	if type(v) ~= "string" or v == "" then
		return nil
	end
	return v
end

local function display(kind: Kind, key: string, v: any, o: Opts): string
	if kind == "switch" then
		return if v == true then "On" else "Off"
	elseif kind == "choice" then
		return option_label(o.options, v) or (if v == nil then "Not set" else tostring(v))
	elseif kind == "duration" then
		local n = minutes(v)
		return if n then n .. " min" else "Not set"
	elseif kind == "int" then
		return if v == nil then "Not set" else tostring(v)
	elseif kind == "int0" then
		if v == nil or v == 0 then
			return if o.labels and o.labels["0"] then o.labels["0"] else "Not set"
		end
		return tostring(v)
	elseif kind == "multi" then
		if type(v) ~= "table" or #v == 0 then
			return "Not set"
		end
		local parts: { string } = {}
		for _, x in v do
			table.insert(parts, option_label(o.options, x) or tostring(x))
		end
		return table.concat(parts, ", ")
	elseif kind == "overlay" then
		if type(v) ~= "string" or v == "" then
			return "Not set"
		end
		return text.clip(first_line(v), 80)
	end
	return text_value(kind, key, v) or "Not set"
end

local function control(kind: Kind, key: string, v: any, o: Opts): { [string]: any }
	if kind == "switch" then
		return { k = "switch", on = v == true }
	elseif kind == "choice" then
		return { k = "choice", value = v, options = arr(o.options), style = o.style or "auto", mono = o.mono }
	elseif kind == "duration" then
		return { k = "number", value = minutes(v), min = o.min, max = o.max, step = o.step or 1, unit = "min" }
	elseif kind == "int" then
		return { k = "number", value = v, min = o.min, max = o.max, step = o.step or 1 }
	elseif kind == "int0" then
		return { k = "number", value = v or 0, min = o.min, max = o.max, step = o.step or 1, labels = o.labels }
	elseif kind == "multi" then
		local values: { any } = {}
		for _, x in (if type(v) == "table" then v else {}) :: { any } do
			table.insert(values, x)
		end
		return { k = "multi", values = arr(values), options = arr(o.options) }
	elseif kind == "overlay" then
		return { k = "action", act = "edit", label = "Edit…" }
	end
	return { k = "text", value = text_value(kind, key, v), placeholder = o.placeholder, mono = o.mono }
end

local function field(m: Model, page: string, layer: Layer, key: string, label: string, kind: Kind, o: Opts?): Row
	local opts: Opts = o or {}
	local r = resolve(m, layer, key)
	local hint = opts.hint
	if r.inherited then
		hint = if hint then hint .. ". Inherited from your settings." else "Inherited from your settings."
	end
	return {
		id = (if layer == "project" then "p:" else "u:") .. key,
		page = page,
		layer = layer,
		key = key,
		op = OPS[kind],
		label = label,
		hint = hint,
		warning = r.warning,
		disabled = broken_reason(m, layer),
		changed = r.set,
		defaultLabel = display(kind, key, r.fallback, opts),
		control = control(kind, key, r.value, opts),
	}
end

-- A row that is not one spec value (items, actions, notices).
local function plain(
	page: string,
	layer: Layer,
	id: string,
	key: string,
	op: string,
	label: string,
	ctl: { [string]: any },
	extra: { [string]: any }?
): Row
	local row: Row = {
		id = (if layer == "project" then "p:" else "u:") .. id,
		page = page,
		layer = layer,
		key = key,
		op = op,
		label = label,
		changed = false,
		control = ctl,
	}
	for k, v in extra or {} do
		(row :: any)[k] = v
	end
	return row
end

local function action(act: string, label: string): { [string]: any }
	return { k = "action", act = act, label = label }
end

local function mono_text(value: string?, placeholder: string?): { [string]: any }
	return { k = "text", value = if value == "" then nil else value, placeholder = placeholder, mono = true }
end

local function section(id: string, title: string, rows: { Row }): Section
	return { id = id, title = title, rows = rows }
end

-- Shared option lists ---------------------------------------------------------------------------

local CARLY_OPTIONS = {
	opt("approve", "Approve"),
	opt("retry", "Retry"),
	opt("park", "Park"),
	opt("discard", "Discard"),
}

local TAB_OPTIONS = {
	opt("model", "Short names from omp @tiny"),
	opt("keywords", "Key words from the title"),
	opt("slug", "Task slug"),
	opt("off", "Leave tab names alone"),
}

local ADOPT_OPTIONS = {
	opt("backlog_and_ready", "Adopt in Backlog and Ready", "Ready cards start right away"),
	opt("backlog", "Adopt in Backlog only"),
	opt("off", "Never adopt", "Tasks come only from New task and Carly"),
}

local DONE_OPTIONS = {
	opt("approve", "Ships from Review, closes otherwise"),
	opt("approve_only", "Ships from Review, undone otherwise"),
	opt("close", "Always closes, never ships"),
	opt("revert", "Always undone; use Approve"),
}

local LANE_OPTIONS = { opt("Ready", "Ready"), opt("Backlog", "Backlog") }

local TOOL_OPTIONS = {
	opt("omp", "omp", "Copies node_modules and .env files"),
	opt("git", "git", "Plain git worktree add"),
}

local CLEAN_OPTIONS = {
	opt("manual", "When I run Clean up"),
	opt("after_ship", "Right after shipping"),
	opt("after_merge", "When the PR is merged or closed"),
}

local PANEL_OPTIONS = { opt("beside", "Beside"), opt("below", "Below"), opt("tab", "Tab"), opt("none", "Off") }

local TOTAL_LABELS: { [string]: string } = { ["0"] = "No limit" }
for i = 1, 16 do
	TOTAL_LABELS[tostring(i)] = tostring(i)
end

local INSTRUCTIONS_NONE = "None. Added to every agent prompt after Swarm's workspace rules."

-- The default_role menu: omp roles, plus the current value when omp doesn't list it.
local function role_options(m: Model, current: any): { any }
	local out: { any } = {}
	local found = false
	for _, r in m.roles or {} do
		table.insert(out, opt(r.name, r.name, r.model))
		if r.name == current then
			found = true
		end
	end
	if not found and type(current) == "string" then
		table.insert(out, opt(current, current, if m.roles ~= nil then "not an omp role" else nil))
	end
	return out
end

local function role_row(m: Model, page: string, layer: Layer): Row
	local current = resolve(m, layer, "default_role").value
	return field(m, page, layer, "default_role", "Default role", "choice", {
		options = role_options(m, current),
		style = "menu",
		hint = "omp role for cards without a #role- tag",
	})
end

local function instructions_row(m: Model, page: string, layer: Layer, label: string): Row
	local r = resolve(m, layer, "instructions")
	local hint = INSTRUCTIONS_NONE
	if type(r.value) == "string" and text.trim(r.value) ~= "" then
		hint = text.clip(first_line(text.trim(r.value)), 80)
	end
	return field(m, page, layer, "instructions", label, "overlay", { hint = hint })
end

-- The value a setting takes in the merged config (m.cfg), else the project row's value.
local function effective(m: Model, key: string): any
	if m.cfg ~= nil then
		local v = schema.get(m.cfg, key)
		if v ~= nil then
			return v
		end
	end
	return resolve(m, "project", key).value
end

-- Page builders ---------------------------------------------------------------------------------

local function page_agent(m: Model): { Section }
	local P = "project-agent"
	local args_row = field(m, P, "project", "agent_args", "Extra omp arguments", "list_ws", {
		mono = true,
		hint = "Space-separated. Can't include the approval mode, which comes from your settings",
	})
	local user_args = if m.uraw ~= nil then schema.get(m.uraw, "agent_args") else nil
	if args_row.disabled == nil and user_args ~= nil then
		args_row.disabled = "Your settings choose the arguments: "
			.. (if type(user_args) == "table" then table.concat(user_args, " ") else tostring(user_args))
	end
	local model = section("agent-model", "Model and limits", {
		role_row(m, P, "project"),
		field(m, P, "project", "max_time", "Time limit per agent", "duration", { min = 5, max = 480, step = 5 }),
		field(m, P, "project", "max_attempts", "Attempts", "int", {
			min = 1,
			max = 20,
			hint = "Agent turns, including check-failure feedback rounds, before the task is blocked",
		}),
		args_row,
	})
	local instructions = section("agent-instructions", "Instructions", {
		instructions_row(m, P, "project", "Project instructions"),
	})

	local role_rows: { Row } = {}
	local broken = broken_reason(m, "project")
	if m.roles == nil then
		local failed = m.roles_error ~= nil
		table.insert(
			role_rows,
			plain(P, "project", "roles.wait", "roles", "none", if failed then "Couldn't read omp roles" else "Reading omp roles…", action("none", "Wait"), {
				warning = m.roles_error,
				disabled = if failed then "Swarm couldn't list omp roles" else "Waiting for omp",
			})
		)
	else
		local r = resolve(m, "project", "roles")
		local parsed: { [string]: any } = if type(r.value) == "table" then r.value else {}
		local raw_roles = if m.praw ~= nil then schema.get(m.praw, "roles") else nil
		local names: { string } = {}
		for _, role in m.roles do
			table.insert(names, role.name)
		end
		local extra: { string } = {}
		if type(raw_roles) == "table" then
			for name in raw_roles do
				if type(name) == "string" and table.find(names, name) == nil then
					table.insert(extra, name)
				end
			end
		end
		table.sort(extra)
		for _, name in extra do
			table.insert(names, name)
		end
		local inherit_time = effective(m, "max_time")
		for i, name in names do
			local entry = parsed[name] or {}
			local raw_entry = if type(raw_roles) == "table" and type(raw_roles[name]) == "table" then raw_roles[name] else {}
			local warning = if i == 1 then r.warning else nil
			table.insert(
				role_rows,
				plain(P, "project", "roles." .. name .. ".max_time", "roles", "role_time", "@" .. name .. " time limit", mono_text(entry.max_time, "Inherit (" .. tostring(inherit_time) .. ")"), {
					name = name,
					changed = raw_entry.max_time ~= nil,
					defaultLabel = "Inherit (" .. tostring(inherit_time) .. ")",
					warning = warning,
					disabled = broken,
				})
			)
			local args = if type(entry.agent_args) == "table" and #entry.agent_args > 0 then table.concat(entry.agent_args, " ") else nil
			table.insert(
				role_rows,
				plain(P, "project", "roles." .. name .. ".agent_args", "roles", "role_args", "@" .. name .. " extra arguments", mono_text(args, "Inherit"), {
					name = name,
					changed = raw_entry.agent_args ~= nil,
					defaultLabel = "Inherit",
					disabled = broken,
					hint = "Can't include the approval mode",
				})
			)
		end
	end
	return { model, instructions, section("agent-roles", "Per-role overrides", role_rows) }
end

local function page_checks(m: Model): { Section }
	local P = "project-checks"
	local broken = broken_reason(m, "project")
	local out: { Section } = {
		section("checks-run", "How checks run", {
			field(m, P, "project", "checks_mode", "When a check fails", "choice", {
				options = { opt("all", "Run the rest"), opt("fail_fast", "Stop") },
				style = "segmented",
			}),
			field(m, P, "project", "timeouts.checks", "Time limit", "duration", { min = 5, max = 240, step = 5 }),
		}),
	}

	local checks = resolve(m, "project", "checks")
	if checks.value == nil then
		local detected: { any } = if m.cfg ~= nil and type(m.cfg.checks) == "table" then m.cfg.checks else {}
		local names: { string } = {}
		for _, c in detected do
			table.insert(names, c.name)
		end
		local hint = if #names > 0
			then table.concat(names, ", ") .. " (from package.json)"
			else "None found, so tasks go straight to Review"
		table.insert(
			out,
			section("checks-detected", "Checks", {
				plain(P, "project", "checks.detected", "checks", "customize", "Detected checks", action("customize", "Customize"), {
					hint = hint,
					warning = checks.warning,
					disabled = broken,
				}),
			})
		)
	else
		for i, c in checks.value :: { any } do
			local base = "checks." .. i
			table.insert(
				out,
				section("check-" .. i, c.name, {
					plain(P, "project", base .. ".run", "checks", "check_run", "Command", mono_text(c.run), {
						index = i,
						changed = true,
						disabled = broken,
					}),
					plain(P, "project", base .. ".agent_runs", "checks", "check_agent", "Agent runs it too", { k = "switch", on = c.agent_runs ~= false }, {
						index = i,
						hint = "Turn off for slow suites; the agent is told the orchestrator runs it",
						disabled = broken,
					}),
					plain(P, "project", base .. ".name", "checks", "check_name", "Name", mono_text(c.name), {
						index = i,
						changed = true,
						disabled = broken,
					}),
					plain(P, "project", base .. ".remove", "checks", "remove_check", "Remove this check", action("remove", "Remove"), {
						index = i,
						disabled = broken,
					}),
				})
			)
		end
	end
	table.insert(
		out,
		section("checks-add", "Add a check", {
			plain(P, "project", "checks.new", "checks", "check_new", "New check", mono_text(nil, "npm test"), {
				hint = "The name comes from the command's last word",
				disabled = broken,
			}),
		})
	)

	local setup = resolve(m, "project", "setup")
	local setup_rows: { Row } = {}
	for i, cmd in (setup.value or {}) :: { string } do
		table.insert(
			setup_rows,
			plain(P, "project", "setup." .. i, "setup", "setup_item", "Step " .. i, mono_text(cmd), {
				index = i,
				hint = "Clear to remove",
				changed = true,
				disabled = broken,
			})
		)
	end
	table.insert(
		setup_rows,
		plain(P, "project", "setup.new", "setup", "setup_new", "Add a setup command", mono_text(nil, "pnpm install"), {
			hint = if setup.value == nil then "Adding one replaces the automatic npm ci step" else nil,
			warning = setup.warning,
			disabled = broken,
		})
	)
	table.insert(setup_rows, field(m, P, "project", "timeouts.setup", "Time limit", "duration", { min = 5, max = 240, step = 5 }))
	table.insert(out, section("setup", "Setup", setup_rows))

	local env = resolve(m, "project", "env")
	local env_rows: { Row } = {}
	local names: { string } = {}
	for name in (env.value or {}) :: { [string]: string } do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		table.insert(
			env_rows,
			plain(P, "project", "env." .. name, "env", "env_item", name, mono_text(env.value[name]), {
				name = name,
				hint = "Exported in setup, check and ship jobs · clear to remove",
				changed = true,
				disabled = broken,
			})
		)
	end
	table.insert(
		env_rows,
		plain(P, "project", "env.new", "env", "env_new", "Add a variable", mono_text(nil, "CI=true"), {
			warning = env.warning,
			disabled = broken,
		})
	)
	table.insert(out, section("env", "Environment", env_rows))
	return out
end

local function page_workflow(m: Model): { Section }
	local P = "project-workflow"
	local pass = field(m, P, "project", "on_checks_pass", "When checks pass", "choice", {
		options = { opt("review", "Wait for me"), opt("ship", "Ship") },
		style = "segmented",
		hint = "Cards tagged #auto-ship always ship",
	})
	if pass.warning == nil and effective(m, "on_checks_pass") == "ship" then
		local checks = if m.cfg ~= nil then m.cfg.checks else resolve(m, "project", "checks").value
		if type(checks) ~= "table" or #checks == 0 then
			pass.warning = "No checks are configured, so tasks still wait for you"
		end
	end
	return {
		section("wf-board", "Board", {
			field(m, P, "project", "adopt_cards", "Hand-written cards", "choice", { options = ADOPT_OPTIONS, style = "menu" }),
			field(m, P, "project", "on_move_to_done", "Dragging a card to Done", "choice", { options = DONE_OPTIONS, style = "menu" }),
			field(m, P, "project", "new_task.lane", "New tasks go to", "choice", {
				options = LANE_OPTIONS,
				style = "segmented",
				hint = "The New task form's main button and Carly",
			}),
			field(m, P, "project", "max_concurrent", "Agents at once", "int", { min = 1, max = 16 }),
		}),
		section("wf-after", "After the agent finishes", {
			field(m, P, "project", "no_change", "When nothing changed", "choice", {
				options = { opt("block", "Block"), opt("review", "Review"), opt("done", "Done") },
				style = "segmented",
				hint = "Cards tagged #no-change-ok go to Review",
			}),
			pass,
		}),
		section("wf-carly", "Carly", {
			field(m, P, "project", "carly.actions", "Carly may", "multi", {
				options = CARLY_OPTIONS,
				hint = "Combined with your own setting: Carly can only do what both allow",
			}),
		}),
		section("wf-tabs", "Tabs", {
			field(m, P, "project", "tabs.names", "Tab names", "choice", {
				options = TAB_OPTIONS,
				style = "menu",
				hint = "Combined with yours: the more private choice wins",
			}),
		}),
	}
end

local function page_git(m: Model): { Section }
	local P = "project-git"
	local remote = effective(m, "remote") or "origin"
	local folder = field(m, P, "project", "worktree_dir", "Worktree folder", "text", {
		mono = true,
		placeholder = "../{repo}-swarm",
		hint = "Relative to the repository; {repo} is its folder name",
	})
	local user_dir = if m.uraw ~= nil then schema.get(m.uraw, "worktree_dir") else nil
	if folder.disabled == nil and user_dir ~= nil then
		folder.disabled = "Your settings choose the folder: " .. tostring(user_dir)
	end
	local message = resolve(m, "project", "commit.message").value
	local pr_rows: { Row } = {
		field(m, P, "project", "pr.draft", "Open as draft", "switch", { hint = "Cards tagged #draft are always drafts" }),
		field(m, P, "project", "pr.title", "Title", "text", {
			placeholder = "{title}",
			hint = "Placeholders: {title} {slug} {role} {branch}",
		}),
		field(m, P, "project", "pr.reviewers", "Reviewers", "list_comma", { mono = true, placeholder = "octocat, org/team" }),
		field(m, P, "project", "pr.labels", "Labels", "list_comma", { placeholder = "agent, needs-review" }),
		field(m, P, "project", "pr.assignees", "Assignees", "list_comma", { mono = true, placeholder = "@me" }),
	}
	if effective(m, "ship") ~= "pr" then
		for _, row in pr_rows do
			if row.disabled == nil then
				row.disabled = "Only used when Approve opens a pull request"
			end
		end
	end
	return {
		section("git-branch", "Branches and worktrees", {
			field(m, P, "project", "base", "Base branch", "text", {
				mono = true,
				placeholder = tostring(remote) .. "'s default branch",
			}),
			field(m, P, "project", "remote", "Remote", "text", { mono = true }),
			field(m, P, "project", "branch_prefix", "Branch prefix", "text", { mono = true }),
			field(m, P, "project", "worktree_tool", "Create worktrees with", "choice", {
				options = TOOL_OPTIONS,
				style = "segmented",
			}),
			folder,
		}),
		section("git-ship", "Shipping", {
			field(m, P, "project", "ship", "Approve", "choice", {
				options = { opt("pr", "Commit + PR"), opt("commit", "Commit only") },
				style = "segmented",
			}),
			field(m, P, "project", "commit.message", "Commit message", "overlay", {
				hint = if type(message) == "string" then first_line(message) else nil,
			}),
			field(m, P, "project", "timeouts.ship", "Time limit", "duration", { min = 1, max = 60 }),
		}),
		section("git-pr", "Pull requests", pr_rows),
	}
end

local function page_cleanup(m: Model): { Section }
	local P = "project-cleanup"
	local path = if m.root then config.project_path(m.root) else ".tern/swarm.json"
	return {
		section("cleanup", "Cleanup", {
			field(m, P, "project", "discard.delete_branch", "Discard deletes the branch", "switch"),
			field(m, P, "project", "clean.auto", "Remove worktrees", "choice", { options = CLEAN_OPTIONS, style = "menu" }),
			field(m, P, "project", "clean.remove_done_cards", "Clean up removes Done cards", "switch", {
				hint = "Keeps the board small; cards of archived tasks are deleted",
			}),
		}),
		section("file", "File", {
			plain(P, "project", "file", "file", "open_file", ".tern/swarm.json", action("open-file", "Open"), { hint = path }),
		}),
	}
end

local function page_defaults(m: Model): { Section }
	local P = "user-defaults"
	return {
		section("u-agent", "Agent", {
			role_row(m, P, "user"),
			field(m, P, "user", "max_time", "Time limit per agent", "duration", { min = 5, max = 480, step = 5 }),
			field(m, P, "user", "max_concurrent", "Agents at once", "int", { min = 1, max = 16 }),
			field(m, P, "user", "agent_args", "Extra omp arguments", "list_ws", {
				mono = true,
				hint = "Space-separated; replaces the default --approval-mode yolo and wins over every project's arguments",
			}),
			instructions_row(m, P, "user", "Personal instructions"),
		}),
		section("u-board", "Board", {
			field(m, P, "user", "adopt_cards", "Hand-written cards", "choice", { options = ADOPT_OPTIONS, style = "menu" }),
			field(m, P, "user", "on_move_to_done", "Dragging a card to Done", "choice", { options = DONE_OPTIONS, style = "menu" }),
			field(m, P, "user", "new_task.lane", "New tasks go to", "choice", {
				options = LANE_OPTIONS,
				style = "segmented",
				hint = "The New task form's main button and Carly",
			}),
		}),
		section("u-git", "Git", {
			field(m, P, "user", "branch_prefix", "Branch prefix", "text", { mono = true }),
			field(m, P, "user", "worktree_tool", "Create worktrees with", "choice", {
				options = TOOL_OPTIONS,
				style = "segmented",
			}),
			field(m, P, "user", "worktree_dir", "Worktree folder", "text", {
				mono = true,
				placeholder = "../{repo}-swarm",
				hint = "Must contain {repo}. Overrides every project's setting",
			}),
			field(m, P, "user", "pr.draft", "Open as draft", "switch", { hint = "Cards tagged #draft are always drafts" }),
		}),
		section("u-cleanup", "Cleanup", {
			field(m, P, "user", "discard.delete_branch", "Discard deletes the branch", "switch"),
			field(m, P, "user", "clean.auto", "Remove worktrees", "choice", { options = CLEAN_OPTIONS, style = "menu" }),
			field(m, P, "user", "clean.remove_done_cards", "Clean up removes Done cards", "switch", {
				hint = "Keeps the board small; cards of archived tasks are deleted",
			}),
		}),
	}
end

local function page_interface(m: Model): { Section }
	local P = "user-interface"
	return {
		section("u-tabs", "Tabs", {
			field(m, P, "user", "tabs.names", "Tab names", "choice", {
				options = TAB_OPTIONS,
				style = "menu",
				hint = "Combined with yours: the more private choice wins",
			}),
		}),
		section("u-panel", "Swarm panel", {
			field(m, P, "user", "layout.panel", "Open board shows the panel", "choice", {
				options = PANEL_OPTIONS,
				style = "segmented",
			}),
		}),
		section("u-carly", "Carly", {
			field(m, P, "user", "carly.context", "Tell Carly about tasks", "choice", {
				options = { opt("all", "All"), opt("attention", "Needs me"), opt("off", "Off") },
				style = "segmented",
			}),
			field(m, P, "user", "carly.actions", "Carly may", "multi", { options = CARLY_OPTIONS }),
		}),
	}
end

local function page_machine(m: Model): { Section }
	local P = "user-machine"
	local broken = broken_reason(m, "user")
	local bins = resolve(m, "user", "bin_dirs")
	local bin_rows: { Row } = {}
	for i, dir in (bins.value or {}) :: { string } do
		table.insert(
			bin_rows,
			plain(P, "user", "bin_dirs." .. i, "bin_dirs", "bin_item", "Folder " .. i, mono_text(dir), {
				index = i,
				hint = "Clear to remove",
				changed = true,
				disabled = broken,
			})
		)
	end
	table.insert(
		bin_rows,
		plain(P, "user", "bin_dirs.new", "bin_dirs", "bin_new", "Add a folder", mono_text(nil, "~/.bun/bin"), {
			hint = "Where Swarm finds omp, git and gh for background work (worktrees, roles, tab names, PR checks). Agents and jobs use your shell's PATH.",
			warning = bins.warning,
			disabled = broken,
		})
	)
	return {
		section("u-limits", "Limits", {
			field(m, P, "user", "max_concurrent_total", "Agents at once, all projects", "int0", {
				min = 0,
				max = 16,
				labels = TOTAL_LABELS,
			}),
		}),
		section("u-bin", "Programs", bin_rows),
		section("u-recovery", "Recovery", {
			field(m, P, "user", "watchdog", "If Swarm stops responding", "choice", {
				options = { opt("reload", "Reload plugins"), opt("notify", "Tell me"), opt("off", "Nothing") },
				style = "segmented",
			}),
		}),
		section("u-file", "File", {
			plain(P, "user", "file", "file", "open_file", "settings.json", action("open-file", "Open"), {
				hint = config.user_path(),
			}),
		}),
	}
end

type PageDef = { id: string, label: string, icon: string, layer: Layer, build: (m: Model) -> { Section } }

local PAGES: { PageDef } = {
	{ id = "project-agent", label = "Agent", icon = "sparkle", layer = "project", build = page_agent },
	{ id = "project-checks", label = "Checks", icon = "list-checks", layer = "project", build = page_checks },
	{ id = "project-workflow", label = "Workflow", icon = "kanban", layer = "project", build = page_workflow },
	{ id = "project-git", label = "Git & PRs", icon = "branch", layer = "project", build = page_git },
	{ id = "project-cleanup", label = "Cleanup", icon = "trash", layer = "project", build = page_cleanup },
	{ id = "user-defaults", label = "Defaults", icon = "user", layer = "user", build = page_defaults },
	{ id = "user-interface", label = "Interface", icon = "eye", layer = "user", build = page_interface },
	{ id = "user-machine", label = "Machine", icon = "laptop", layer = "user", build = page_machine },
}

local function visible(m: Model): { PageDef }
	local out: { PageDef } = {}
	for _, p in PAGES do
		if p.layer == "user" or m.root ~= nil then
			table.insert(out, p)
		end
	end
	return out
end

local function page_def(m: Model, id: string): PageDef?
	for _, p in visible(m) do
		if p.id == id then
			return p
		end
	end
	return nil
end

-- The prefs row table for a Row (the page ignores the block's own fields).
local function prefs_row(r: Row): { [string]: any }
	return {
		id = r.id,
		label = r.label,
		hint = r.hint,
		warning = r.warning,
		disabled = r.disabled,
		changed = r.changed,
		defaultLabel = r.defaultLabel,
		control = r.control,
	}
end

local function prefs_rows(rows: { Row }): { any }
	local out: { any } = {}
	for _, r in rows do
		table.insert(out, prefs_row(r))
	end
	return arr(out)
end

-- Exports ---------------------------------------------------------------------------------------

function settings_ui.pages(m: Model): { any }
	local out: { any } = {}
	local project_group = PROJECT_GROUP_PREFIX .. (m.name or m.pid or "this repository")
	for _, p in visible(m) do
		local changed = 0
		for _, s in p.build(m) do
			for _, r in s.rows do
				if r.changed then
					changed += 1
				end
			end
		end
		table.insert(out, {
			id = p.id,
			label = p.label,
			icon = p.icon,
			group = if p.layer == "project" then project_group else USER_GROUP,
			changed = if changed > 0 then changed else nil,
		})
	end
	return arr(out)
end

function settings_ui.sections(m: Model, page: string): { any }
	local def = page_def(m, page)
	local out: { any } = {}
	if def ~= nil then
		for _, s in def.build(m) do
			table.insert(out, { id = s.id, title = s.title, rows = prefs_rows(s.rows) })
		end
	end
	return arr(out)
end

function settings_ui.rows(m: Model, page: string?): { Row }
	local out: { Row } = {}
	for _, p in visible(m) do
		if page == nil or p.id == page then
			for _, s in p.build(m) do
				for _, r in s.rows do
					table.insert(out, r)
				end
			end
		end
	end
	return out
end

function settings_ui.find(m: Model, id: string): Row?
	local layer: Layer = if string.sub(id, 1, 2) == "u:" then "user" else "project"
	for _, p in visible(m) do
		if p.layer == layer then
			for _, s in p.build(m) do
				for _, r in s.rows do
					if r.id == id then
						return r
					end
				end
			end
		end
	end
	return nil
end

function settings_ui.search(m: Model, query: string): { any }
	local q = string.lower(text.trim(query))
	local out: { any } = {}
	if q == "" then
		return arr(out)
	end
	for _, p in visible(m) do
		for _, s in p.build(m) do
			local hits: { Row } = {}
			for _, r in s.rows do
				local hay = string.lower(r.label .. " " .. (r.hint or ""))
				if string.find(hay, q, 1, true) then
					table.insert(hits, r)
				end
			end
			if #hits > 0 then
				table.insert(out, { id = s.id, title = p.label .. " · " .. s.title, page = p.id, rows = prefs_rows(hits) })
			end
		end
	end
	return arr(out)
end

function settings_ui.lead(m: Model, page: string): string
	local def = page_def(m, page)
	if def ~= nil and def.layer == "project" and m.root ~= nil then
		return "Saved to " .. config.project_path(m.root) .. ". Commit it to share these settings with your team."
	end
	local s = "Saved to your Swarm settings ("
		.. config.user_path()
		.. "). They apply to every project unless a project sets its own value."
	if page == "user-defaults" and m.root == nil then
		s ..= " Open a Swarm board in a repository to edit its project settings."
	end
	return s
end

local function preview(pairs: { any }): any
	local node = ui.card({ ui.span("Preview", "strong") }, { ui.kv(pairs) })
	local p = node.p or {}
	p.key = "preview"
	node.p = p
	return node
end

function settings_ui.extras(m: Model, page: string): { any }
	if page == "project-git" and m.root ~= nil then
		local prefix = effective(m, "branch_prefix") or ""
		local branch = prefix .. "fix-login-redirect"
		local vars = {
			title = "Fix the login redirect",
			slug = "fix-login-redirect",
			role = tostring(effective(m, "default_role") or "default"),
			branch = branch,
		}
		local message = effective(m, "commit.message")
		local pairs: { any } = {
			{ "branch", branch },
			{ "commit", first_line(schema.render(if type(message) == "string" then message else "", vars)) },
		}
		if effective(m, "ship") == "pr" then
			local title = effective(m, "pr.title")
			table.insert(pairs, { "PR title", schema.render(if type(title) == "string" then title else "{title}", vars) })
		end
		return { preview(pairs) }
	elseif page == "user-interface" then
		local names = resolve(m, "user", "tabs.names").value
		local tab = if names == "keywords"
			then "✓ fix-login-redirect"
			elseif names == "slug" then "✓ fix-the-login-redirect"
			elseif names == "off" then "(your own tab name)"
			else "✓ login-redirect"
		local panel = option_label(PANEL_OPTIONS, resolve(m, "user", "layout.panel").value) or "Below"
		return { preview({ { "tab in review", tab }, { "panel", panel } }) }
	end
	return {}
end

return settings_ui
