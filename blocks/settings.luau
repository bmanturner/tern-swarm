--!strict
-- The `settings` block (host half): Swarm's settings page, one `prefs` node. It edits the project
-- file <root>/.tern/swarm.json and the user file <plugin data>/settings.json; after each write it
-- queues a `config` intent and wakes the leader window, which applies it on its next tick.
-- Args: {pid} (optional; without it only the user pages show).

local config = require("../lib/config")
local schema = require("../lib/schema")
local roles = require("../lib/roles")
local store = require("../lib/store")
local textfield = require("../lib/textfield")
local settings_ui = require("../lib/settings_ui")

local ui = tern.ui

type Row = settings_ui.Row
type Layer = "project" | "user"

type State = {
	cx: BlockCx,
	model: settings_ui.Model,
	page: string,
	query: textfield.Field,
	searching: boolean,
	focus: string?,
	-- The row edited with the keyboard: a text row (with `field`), an open menu, or a multi row.
	-- `initial` is a text row's starting text, so an unchanged commit doesn't rewrite the file.
	editing: { row: string, option: string?, initial: string? }?,
	field: textfield.Field?,
	overlay: { row: string, field: textfield.Field, error: string? }?,
	-- Row id → the problem of its last rejected edit.
	warnings: { [string]: string },
}

-- Keys whose values are JSON lists: tagged so an empty one encodes as [].
local LIST_KEYS = {
	"checks",
	"setup",
	"agent_args",
	"instructions",
	"pr.reviewers",
	"pr.labels",
	"pr.assignees",
	"carly.actions",
	"bin_dirs",
}

local NEW_OPS: { [string]: boolean } = { check_new = true, setup_new = true, env_new = true, bin_new = true }

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or "")
end

local function cap(s: string): string
	return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
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

local function is_list(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	for k in v do
		if type(k) ~= "number" then
			return false
		end
	end
	return true
end

local function is_reset(v: any): boolean
	return v == nil or v == tern.json.null
end

local function words(s: string): { string }
	local out: { string } = {}
	for w in string.gmatch(s, "%S+") do
		table.insert(out, w)
	end
	return out
end

local function commas(s: string): { string }
	local out: { string } = {}
	for part in string.gmatch(s, "[^,]+") do
		local t = trim(part)
		if t ~= "" then
			table.insert(out, t)
		end
	end
	return out
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function badge(label: string, tone: string, act: string, key: string): Node
	return with(ui.badge(label, tone), { key = key, actions = { click = act } })
end

local function frame_focus(cx: BlockCx, target: any)
	pcall(function()
		cx:frame({ { "focus", target } })
	end)
end

-- Model ----------------------------------------------------------------------------------------

-- Re-reads both raws and, with a project, its merged config.
local function load_model(m: settings_ui.Model)
	if m.root ~= nil then
		local root: string = m.root
		m.praw, m.perr = config.read_raw(config.project_path(root))
		m.cfg = config.load(root)
	end
	m.uraw, m.uerr = config.read_raw(config.user_path())
end

local function layer_path(m: settings_ui.Model, layer: Layer): string?
	if layer == "project" then
		return if m.root then config.project_path(m.root) else nil
	end
	return config.user_path()
end

local function layer_raw(m: settings_ui.Model, layer: Layer): any
	return if layer == "project" then m.praw else m.uraw
end

local function visible_pages(m: settings_ui.Model): { string }
	local out: { string } = {}
	for _, p in settings_ui.pages(m) do
		if not p.disabled then
			table.insert(out, p.id)
		end
	end
	return out
end

-- The rows keyboard navigation walks: search results while a query is set, else the page's rows.
local function nav_rows(state: State): { any }
	local q = trim(state.query.text)
	if q == "" then
		return settings_ui.rows(state.model, state.page)
	end
	local out: { any } = {}
	for _, sec in settings_ui.search(state.model, q) do
		for _, r in sec.rows or {} do
			table.insert(out, r)
		end
	end
	return out
end

-- Writes ---------------------------------------------------------------------------------------

-- Copies the row's layer raw, applies `mutate` (a returned string is a problem shown on the row),
-- writes the file, reloads the model and tells the leader. True when the file was written.
local function persist(state: State, row: Row, mutate: (raw: any) -> string?): boolean
	local m = state.model
	local path = layer_path(m, row.layer)
	local src = layer_raw(m, row.layer)
	if path == nil or src == nil then
		return false
	end
	local raw = copy(src)
	local problem = mutate(raw)
	if problem ~= nil then
		state.warnings[row.id] = problem
		return false
	end
	for _, key in LIST_KEYS do
		local v = schema.get(raw, key)
		if is_list(v) then
			tern.json.array(v)
		end
	end
	if type(raw.roles) == "table" then
		for _, rc in raw.roles do
			if type(rc) == "table" and is_list(rc.agent_args) then
				tern.json.array(rc.agent_args)
			end
		end
	end
	-- Your own edit keeps an approved repository approved; hand edits still need the panel.
	local root = if row.layer == "project" then m.root else nil
	local was = root ~= nil and config.trusted(root, config.load(root).trust.subject)
	local ok, err = pcall(config.write_raw, path, raw)
	if not ok then
		state.cx:toast("error", "Swarm: couldn't save settings", tostring(err))
		return false
	end
	config.forget()
	if was and root ~= nil then
		config.approve(root, config.load(root).trust.subject)
	end
	load_model(m)
	pcall(store.write_intent, { kind = "config" })
	state.cx:open("swarm://wake")
	state.warnings[row.id] = nil
	return true
end

-- Validates `candidate` for spec `key` in the row's layer, then sets it (nil deletes).
local function put(state: State, raw: any, row: Row, key: string, candidate: any): string?
	if candidate ~= nil then
		local spec = schema.BY_KEY[key]
		local _, why = spec.parse(candidate, state.model.root, row.layer)
		if why ~= nil then
			return cap(why)
		end
	end
	schema.set(raw, key, candidate)
	return nil
end

-- The checks list to edit: the file's, else the detected ones.
local function current_checks(state: State, raw: any): { any }
	local out: { any } = {}
	if type(raw.checks) == "table" then
		for _, c in raw.checks do
			if type(c) == "table" then
				table.insert(out, copy(c))
			end
		end
	elseif state.model.root ~= nil then
		for _, c in config.detected_checks(state.model.root) do
			table.insert(out, { name = c.name, run = c.run })
		end
	end
	return out
end

local function clean_checks(list: { any }): { any }
	local out: { any } = {}
	for _, c in list do
		local entry: { [string]: any } = { name = c.name, run = c.run }
		if c.agent_runs == false then
			entry.agent_runs = false
		end
		table.insert(out, entry)
	end
	return out
end

local function new_check_name(run: string, list: { any }): string
	local last = "check"
	for w in string.gmatch(run, "%S+") do
		last = w
	end
	local base = (string.gsub(last, "[^%w_%-]", "-"))
	local function taken(n: string): boolean
		for _, c in list do
			if c.name == n then
				return true
			end
		end
		return false
	end
	local name = base
	local i = 2
	while taken(name) do
		name = base .. "-" .. i
		i += 1
	end
	return name
end

-- A copy of the string list at `key`, or {}.
local function list_at(raw: any, key: string): { string }
	local v = schema.get(raw, key)
	local out: { string } = {}
	if type(v) == "table" then
		for _, s in v do
			table.insert(out, s)
		end
	end
	return out
end

-- Applies the row's op with `value` (nil or json null = Reset). True when the file was written.
local function apply(state: State, row: Row, value: any): boolean
	if row.disabled ~= nil then
		return false
	end
	local op = row.op
	local reset = is_reset(value)
	local key = row.key
	local i = row.index
	return persist(state, row, function(raw: any): string?
		if reset and op ~= "check_agent" and op ~= "remove_check" and op ~= "customize" then
			-- Reset: delete the key, or remove the item for item rows.
			if op == "check_run" or op == "check_name" then
				local list = current_checks(state, raw)
				if i ~= nil and list[i] ~= nil then
					table.remove(list, i)
				end
				return put(state, raw, row, "checks", clean_checks(list))
			elseif op == "setup_item" or op == "bin_item" then
				local list = list_at(raw, key)
				if i ~= nil and list[i] ~= nil then
					table.remove(list, i)
				end
				return put(state, raw, row, key, if #list > 0 then list else nil)
			elseif op == "env_item" then
				local env = if type(raw.env) == "table" then copy(raw.env) else {}
				env[row.name or ""] = nil
				return put(state, raw, row, "env", if next(env) then env else nil)
			elseif op == "role_time" or op == "role_args" then
				value = ""
			else
				schema.set(raw, key, nil)
				return nil
			end
		end

		if op == "set" then
			return put(state, raw, row, key, if type(value) == "table" then copy(value) else value)
		elseif op == "duration" then
			return put(state, raw, row, key, string.format("%dm", math.floor(tonumber(value) or 0)))
		elseif op == "int" then
			return put(state, raw, row, key, math.floor(tonumber(value) or 0))
		elseif op == "int0" then
			local n = math.floor(tonumber(value) or 0)
			return put(state, raw, row, key, if n == 0 then nil else n)
		elseif op == "text" then
			local t = trim(tostring(value))
			return put(state, raw, row, key, if t == "" then nil else t)
		elseif op == "list_ws" then
			local list = words(tostring(value))
			return put(state, raw, row, key, if #list > 0 then list else nil)
		elseif op == "list_comma" then
			local list = commas(tostring(value))
			return put(state, raw, row, key, if #list > 0 then list else nil)
		elseif op == "role_time" or op == "role_args" then
			local rolesv = if type(raw.roles) == "table" then copy(raw.roles) else {}
			local name = row.name or ""
			local rc = if type(rolesv[name]) == "table" then rolesv[name] else {}
			local t = trim(tostring(value))
			if op == "role_time" then
				rc.max_time = if t == "" then nil else t
			else
				local list = words(t)
				rc.agent_args = if #list > 0 then list else nil
			end
			rolesv[name] = if next(rc) then rc else nil
			return put(state, raw, row, "roles", if next(rolesv) then rolesv else nil)
		elseif
			op == "check_run"
			or op == "check_name"
			or op == "check_agent"
			or op == "remove_check"
			or op == "check_new"
			or op == "customize"
		then
			local list = current_checks(state, raw)
			if op == "customize" then
				list = {}
				if state.model.root ~= nil then
					for _, c in config.detected_checks(state.model.root) do
						table.insert(list, { name = c.name, run = c.run })
					end
				end
			elseif op == "check_new" then
				local run = trim(tostring(value))
				table.insert(list, { name = new_check_name(run, list), run = run })
			elseif i == nil or list[i] == nil then
				return "That check no longer exists"
			elseif op == "remove_check" then
				table.remove(list, i)
			elseif op == "check_agent" then
				list[i].agent_runs = if reset or value == true then nil else false
			else
				local t = trim(tostring(value))
				if t == "" then
					table.remove(list, i)
				elseif op == "check_run" then
					list[i].run = t
				else
					list[i].name = (string.gsub(t, "[^%w_%-]", "-"))
				end
			end
			return put(state, raw, row, "checks", clean_checks(list))
		elseif op == "setup_item" or op == "setup_new" or op == "bin_item" or op == "bin_new" then
			local list = list_at(raw, key)
			local t = trim(tostring(value))
			if op == "bin_item" or op == "bin_new" then
				t = if t == "" then t else schema.expand(t)
			end
			if op == "setup_new" or op == "bin_new" then
				table.insert(list, t)
			elseif i == nil or i > #list then
				return "That entry no longer exists"
			elseif t == "" then
				table.remove(list, i)
			else
				list[i] = t
			end
			return put(state, raw, row, key, if #list > 0 then list else nil)
		elseif op == "env_item" or op == "env_new" then
			local env = if type(raw.env) == "table" then copy(raw.env) else {}
			local name, v
			if op == "env_new" then
				name, v = string.match(trim(tostring(value)), "^([%a_][%w_]*)=(.*)$")
				if name == nil then
					return "Use NAME=value"
				end
			else
				name, v = row.name, tostring(value)
			end
			env[name or ""] = if v == nil or v == "" then nil else v
			return put(state, raw, row, "env", if next(env) then env else nil)
		end
		return "This setting can't be changed here"
	end)
end

-- Overlay editor (instructions, commit message) ------------------------------------------------

local function overlay_text(state: State, row: Row): (string, string?)
	local raw = layer_raw(state.model, row.layer)
	local v = if raw ~= nil then schema.get(raw, row.key) else nil
	if v == nil then
		return if row.key == "commit.message" then schema.BY_KEY["commit.message"].default else "", nil
	end
	local parsed, why = schema.BY_KEY[row.key].parse(v, state.model.root, row.layer)
	if why ~= nil then
		return "", cap(why)
	end
	return tostring(parsed), nil
end

local function open_overlay(state: State, row: Row)
	if row.disabled ~= nil then
		return
	end
	local text, err = overlay_text(state, row)
	state.editing = nil
	state.field = nil
	state.overlay = { row = row.id, field = textfield.new(text), error = err }
	-- The editor node exists only after the next render.
	tern.timer(50, function()
		local ov = state.overlay
		if ov ~= nil and ov.row == row.id then
			frame_focus(state.cx, "main.prefs.overlay.text")
		end
	end)
end

local function close_overlay(state: State)
	state.overlay = nil
	frame_focus(state.cx, tern.json.null)
end

local function overlay_save(state: State, clear: boolean)
	local ov = state.overlay
	if ov == nil then
		return
	end
	local row = settings_ui.find(state.model, ov.row)
	if row == nil then
		close_overlay(state)
		return
	end
	local text = if clear then "" else trim(ov.field.text)
	if text ~= "" then
		local _, why = schema.BY_KEY[row.key].parse(text, state.model.root, row.layer)
		if why ~= nil then
			ov.error = cap(why)
			return
		end
	end
	local key = row.key
	if persist(state, row, function(raw: any): string?
		schema.set(raw, key, if text == "" then nil else text)
		return nil
	end) then
		close_overlay(state)
	end
end

local function overlay_node(state: State): Node?
	local ov = state.overlay
	if ov == nil then
		return nil
	end
	local row = settings_ui.find(state.model, ov.row)
	if row == nil then
		return nil
	end
	local is_commit = row.key == "commit.message"
	local where = if row.layer == "project" then "  Project · .tern/swarm.json" else "  You · settings.json"
	local children: { Node } = {
		with(ui.text({ ui.span(row.label, "strong"), ui.span(where, "muted") }), { key = "title" }),
		with(
			ui.text({
				ui.span(
					if is_commit
						then "Placeholders: {title} {slug} {role} {branch}"
						else "Markdown. Added to every agent prompt after Swarm's workspace rules.",
					"muted"
				),
			}),
			{ key = "hint" }
		),
		ui.node("editor", {
			key = "text",
			text = ov.field.text,
			cursor = textfield.utf16(ov.field),
			maxLines = 14,
			placeholder = if is_commit then "{title}" else "Conventions, commands, things every agent should know…",
		}),
	}
	if ov.error ~= nil then
		table.insert(children, with(ui.text({ ui.span(ov.error, "warning") }), { key = "error" }))
	end
	table.insert(
		children,
		with(
			ui.row({
				badge("Save", "accent", "ov-save", "save"),
				badge("Cancel", "neutral", "ov-cancel", "cancel"),
				badge("Clear", "neutral", "ov-clear", "clear"),
			}),
			{ key = "buttons" }
		)
	)
	table.insert(children, with(ui.text({ ui.span("⌘↵ save · Esc cancel", "muted") }), { key = "keys" }))
	return with(ui.col(children), { key = "overlay", role = "omp.prefs.editor" })
end

-- Row actions -----------------------------------------------------------------------------------

local function open_file(state: State, id: string)
	local m = state.model
	local path: string
	if id == "p:file" then
		if m.root == nil then
			return
		end
		path = config.project_path(m.root)
	else
		path = config.user_path()
	end
	if not tern.fs.exists(path) then
		local ok, err = pcall(function()
			config.write_raw(path, if id == "p:file" then config.starter(m.root :: string) else {})
		end)
		if not ok then
			state.cx:toast("error", "Swarm: couldn't create " .. path, tostring(err))
			return
		end
	end
	state.cx:open(path)
end

local function run_act(state: State, act: string, id: any)
	if type(id) ~= "string" then
		return
	end
	if act == "open-file" then
		open_file(state, id)
		return
	end
	local row = settings_ui.find(state.model, id)
	if row == nil or row.disabled ~= nil then
		return
	end
	if act == "edit" then
		open_overlay(state, row)
	elseif act == "customize" or act == "remove" then
		apply(state, row, true)
	end
end

-- Keyboard editing ------------------------------------------------------------------------------

local function start_text(state: State, row: Row)
	local v = row.control.value
	local text = if row.changed and type(v) == "string" and not NEW_OPS[row.op] then v else ""
	state.editing = { row = row.id, initial = text }
	state.field = textfield.new(text)
	state.focus = row.id
end

local function close_editing(state: State)
	state.editing = nil
	state.field = nil
end

-- Commits the text row being edited. True when it closed (saved, unchanged or empty new row).
local function commit_text(state: State): boolean
	local e = state.editing
	local f = state.field
	if e == nil or f == nil then
		return false
	end
	local row = settings_ui.find(state.model, e.row)
	if row == nil then
		close_editing(state)
		return true
	end
	if f.text == e.initial or (NEW_OPS[row.op] and trim(f.text) == "") then
		state.warnings[row.id] = nil
		close_editing(state)
		return true
	end
	if apply(state, row, f.text) then
		close_editing(state)
		return true
	end
	return false
end

local function option_values(c: { [string]: any }): { string }
	local out: { string } = {}
	for _, o in c.options or {} do
		table.insert(out, o.value)
	end
	return out
end

local function move_focus(state: State, delta: number): boolean
	local rows = nav_rows(state)
	if #rows == 0 then
		return false
	end
	local at = 0
	for idx, r in rows do
		if r.id == state.focus then
			at = idx
			break
		end
	end
	local j = if at == 0 and delta < 0 then #rows + 1 else at
	while true do
		j += delta
		if j < 1 or j > #rows then
			return false
		end
		if rows[j].disabled == nil then
			state.focus = rows[j].id
			return true
		end
	end
end

local function step_number(c: { [string]: any }, dir: number): number?
	local v = tonumber(c.value) or c.min or 0
	if type(c.labels) == "table" then
		local keys: { number } = {}
		for k in c.labels do
			local n = tonumber(k)
			if n ~= nil then
				table.insert(keys, n)
			end
		end
		table.sort(keys)
		if dir > 0 then
			for _, n in keys do
				if n > v then
					return n
				end
			end
		else
			for idx = #keys, 1, -1 do
				if keys[idx] < v then
					return keys[idx]
				end
			end
		end
		return nil
	end
	local n = math.clamp(v + dir * (c.step or 1), c.min or -math.huge, c.max or math.huge)
	return if n ~= v then n else nil
end

-- Space/Enter on the focused row.
local function activate_row(state: State, row: Row): boolean
	if row.disabled ~= nil then
		return false
	end
	local c = row.control
	local k = c.k
	if k == "switch" then
		apply(state, row, not c.on)
	elseif k == "choice" then
		local values = option_values(c)
		if c.style == "menu" then
			state.editing = { row = row.id, option = c.value or values[1] }
		elseif #values > 0 then
			local at = table.find(values, c.value) or 0
			apply(state, row, values[at % #values + 1])
		else
			return false
		end
	elseif k == "text" then
		start_text(state, row)
	elseif k == "multi" then
		local values = option_values(c)
		if #values == 0 then
			return false
		end
		state.editing = { row = row.id, option = values[1] }
	elseif k == "action" then
		run_act(state, c.act or "edit", row.id)
	else
		return false
	end
	return true
end

local function reset_search(state: State)
	state.query = textfield.new()
	state.searching = false
end

local function go_page(state: State, page: string)
	state.page = page
	state.focus = nil
	close_editing(state)
	reset_search(state)
end

local function key_overlay(state: State, k: Key): boolean
	local ov = state.overlay :: { row: string, field: textfield.Field, error: string? }
	if k.name == "escape" then
		close_overlay(state)
		return true
	elseif k.name == "enter" then
		if k.ctrl or k.meta then
			overlay_save(state, false)
			return true
		end
		return textfield.insert(ov.field, "\n")
	end
	return textfield.key(ov.field, k, true)
end

local function key_text(state: State, k: Key): boolean
	local name = k.name
	if name == "enter" then
		commit_text(state)
		return true
	elseif name == "escape" then
		local id = state.editing and state.editing.row
		close_editing(state)
		if id then
			state.warnings[id] = nil
		end
		return true
	elseif name == "tab" then
		if commit_text(state) then
			move_focus(state, if k.shift then -1 else 1)
		end
		return true
	end
	return textfield.key(state.field :: textfield.Field, k, false)
end

local function key_menu(state: State, row: Row, k: Key): boolean
	local e = state.editing :: { row: string, option: string?, initial: string? }
	local values = option_values(row.control)
	local name = k.name
	if name == "up" or name == "down" then
		local at = table.find(values, e.option) or 0
		local j = math.clamp(at + (if name == "up" then -1 else 1), 1, #values)
		if values[j] == e.option then
			return false
		end
		e.option = values[j]
		return true
	elseif name == "enter" or name == "space" then
		local v = e.option
		state.editing = nil
		if v ~= nil and v ~= row.control.value then
			apply(state, row, v)
		end
		return true
	elseif name == "escape" then
		state.editing = nil
		return true
	end
	return false
end

local function key_multi(state: State, row: Row, k: Key): boolean
	local e = state.editing :: { row: string, option: string?, initial: string? }
	local values = option_values(row.control)
	local name = k.name
	if name == "left" or name == "right" then
		local at = table.find(values, e.option) or 0
		local j = math.clamp(at + (if name == "left" then -1 else 1), 1, #values)
		if values[j] == e.option then
			return false
		end
		e.option = values[j]
		return true
	elseif name == "enter" or name == "space" then
		local on: { [string]: boolean } = {}
		for _, v in row.control.values or {} do
			on[v] = true
		end
		if e.option ~= nil then
			on[e.option] = not on[e.option]
		end
		local list: { string } = {}
		for _, v in values do
			if on[v] then
				table.insert(list, v)
			end
		end
		apply(state, row, list)
		return true
	elseif name == "escape" then
		state.editing = nil
		return true
	end
	return false
end

local function key_search(state: State, k: Key): boolean
	local name = k.name
	if name == "escape" then
		reset_search(state)
		state.focus = nil
		return true
	elseif name == "enter" or name == "down" then
		state.searching = false
		state.focus = nil
		move_focus(state, 1)
		return true
	end
	return textfield.key(state.query, k, false)
end

local function key_nav(state: State, k: Key, cx: BlockCx): boolean
	local name = k.name
	if name == "up" or name == "down" then
		return move_focus(state, if name == "up" then -1 else 1)
	elseif name == "tab" then
		local pages = visible_pages(state.model)
		if #pages == 0 then
			return false
		end
		local at = table.find(pages, state.page) or 0
		local j = if k.shift then (at - 2) % #pages + 1 else at % #pages + 1
		go_page(state, pages[j])
		return true
	elseif name == "escape" then
		if state.query.text ~= "" then
			reset_search(state)
			state.focus = nil
			return true
		end
		cx:exit(0)
		return true
	elseif (name == "/" and not (k.ctrl or k.meta)) or (name == "f" and k.meta) then
		state.searching = true
		return true
	end

	local row = if state.focus then settings_ui.find(state.model, state.focus) else nil
	if (name == "left" or name == "right") and row ~= nil and row.disabled == nil then
		local c = row.control
		local dir = if name == "left" then -1 else 1
		if c.k == "choice" then
			local values = option_values(c)
			local at = table.find(values, c.value) or 0
			local j = math.clamp(at + dir, 1, #values)
			if values[j] == nil or values[j] == c.value then
				return false
			end
			apply(state, row, values[j])
			return true
		elseif c.k == "number" then
			local n = step_number(c, dir)
			if n == nil then
				return false
			end
			apply(state, row, n)
			return true
		end
		return false
	elseif (name == "space" or name == "enter") and row ~= nil then
		return activate_row(state, row)
	end

	if k.text ~= nil and k.text ~= "" and not (k.ctrl or k.meta) and name ~= "space" and name ~= "enter" then
		state.searching = true
		state.query = textfield.new(k.text)
		state.focus = nil
		return true
	end
	return false
end

-- Block ------------------------------------------------------------------------------------------

local settingsBlock: BlockDef<State> = {
	init = function(cx, args, saved)
		local pid: string? = args[1]
		local project = if pid then store.projects()[pid] else nil
		local root: string? = nil
		local name: string? = nil
		if type(project) == "table" and type(project.root) == "string" then
			root = project.root
			name = if type(project.name) == "string" then project.name else pid
		else
			pid = nil
		end
		config.forget()
		local model: settings_ui.Model = { pid = pid, name = name, root = root }
		load_model(model)

		local pages = visible_pages(model)
		local s: any = if type(saved) == "table" then saved else {}
		local page = if type(s.page) == "string" and table.find(pages, s.page) ~= nil then s.page else (pages[1] or "")

		local state: State = {
			cx = cx,
			model = model,
			page = page,
			query = textfield.new(),
			searching = false,
			focus = nil,
			editing = nil,
			field = nil,
			overlay = nil,
			warnings = {},
		}

		roles.fetch(root, function(list, err)
			if not store.pane_alive(cx.pane) then
				return
			end
			if list == nil then
				model.roles_error = err or "Could not read omp roles"
			else
				model.roles = list :: any
			end
			cx:render()
		end)
		return state
	end,

	title = function(state)
		local name = state.model.name
		return if name then "Settings · " .. name else "Swarm settings"
	end,

	save = function(state)
		return { page = state.page }
	end,

	view = function(state, _cx)
		local m = state.model
		local q = trim(state.query.text)
		local sections = if q ~= "" then settings_ui.search(m, q) else settings_ui.sections(m, state.page)
		for _, sec in sections do
			for _, r in sec.rows or {} do
				local w = state.warnings[r.id]
				if w ~= nil then
					r.warning = w
				end
			end
		end

		local editing: any = nil
		local e = state.editing
		if e ~= nil then
			local f = state.field
			if f ~= nil then
				editing = { row = e.row, draft = f.text, cursor = textfield.utf16(f) }
			else
				editing = { row = e.row, option = e.option }
			end
		end

		local props: { [string]: any } = {
			key = "prefs",
			title = "Swarm settings",
			pages = settings_ui.pages(m),
			page = state.page,
			lead = settings_ui.lead(m, state.page),
			sections = sections,
			query = state.query.text,
			cursor = if state.searching then textfield.utf16(state.query) else nil,
			focus = state.focus,
			editing = editing,
		}

		local children: { Node } = {}
		if q == "" and not state.searching then
			for _, x in settings_ui.extras(m, state.page) do
				table.insert(children, x)
			end
		end
		local ov = overlay_node(state)
		if ov ~= nil then
			table.insert(children, ov)
		end
		return { main = ui.col({ ui.node("prefs", props, children) }) }
	end,

	event = function(state, ev, cx)
		local kind = ev.ev
		if kind == "action" then
			local act = ev.act
			if act == "page" then
				if type(ev.value) == "string" and table.find(visible_pages(state.model), ev.value) ~= nil then
					go_page(state, ev.value)
				end
			elseif act == "close" then
				if is_reset(ev.value) then
					cx:exit(0)
				else
					close_editing(state)
				end
			elseif act == "ov-save" then
				overlay_save(state, false)
			elseif act == "ov-clear" then
				overlay_save(state, true)
			elseif act == "ov-cancel" then
				close_overlay(state)
			elseif act == "edit" or act == "customize" or act == "remove" or act == "open-file" then
				run_act(state, act, ev.value)
			end
		elseif kind == "change" then
			local row = if type(ev.item) == "string" then settings_ui.find(state.model, ev.item) else nil
			if row ~= nil then
				if row.op == "overlay" then
					if is_reset(ev.value) then
						local key = row.key
						persist(state, row, function(raw: any): string?
							schema.set(raw, key, nil)
							return nil
						end)
					end
				else
					apply(state, row, ev.value)
				end
				state.focus = row.id
			end
			close_editing(state)
		elseif kind == "activate" then
			local row = if type(ev.item) == "string" then settings_ui.find(state.model, ev.item) else nil
			if row == nil or row.disabled ~= nil then
				return
			end
			state.focus = row.id
			if row.control.k == "text" then
				start_text(state, row)
			elseif row.control.k == "choice" then
				state.field = nil
				state.editing = { row = row.id, option = row.control.value }
			end
		elseif kind == "select" then
			local item = ev.item
			if type(item) == "string" and string.find(item, "=", 1, true) == nil then
				state.focus = item
			end
		end
	end,

	key = function(state, k, cx)
		if state.overlay ~= nil then
			return key_overlay(state, k)
		end
		local e = state.editing
		if e ~= nil then
			if state.field ~= nil then
				return key_text(state, k)
			end
			local row = settings_ui.find(state.model, e.row)
			if row == nil then
				close_editing(state)
				return true
			end
			if row.control.k == "choice" then
				return key_menu(state, row, k)
			elseif row.control.k == "multi" then
				return key_multi(state, row, k)
			end
			close_editing(state)
			return true
		end
		if state.searching then
			return key_search(state, k)
		end
		return key_nav(state, k, cx)
	end,
}

return settingsBlock
