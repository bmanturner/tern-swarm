--!strict
-- The `new-task` block (host half): a form for a Swarm task's title, details and omp role. Submitting
-- queues a `create` intent for the leader window and wakes it with swarm://wake. Args: {pid}.

local store = require("../lib/store")
local roles = require("../lib/roles")
local config = require("../lib/config")
local textfield = require("../lib/textfield")

local ui = tern.ui

local UNKNOWN_PROJECT = "Unknown project. Run Swarm: Open board in the repository first."
local ROLE_PREFIX = "main.roles."
type Focus = "title" | "details" | "role"

local FOCUS_ORDER: { Focus } = { "title", "details", "role" }

type State = {
	cx: BlockCx,
	pid: string,
	name: string?,
	root: string?,
	-- The project is unknown: the form can't submit.
	fatal: boolean,
	title: textfield.Field,
	details: textfield.Field,
	role: string?,
	-- The project's default role and New task lane (config `default_role`, `new_task.lane`).
	default_role: string,
	primary: string,
	-- Shown under the roles list when the default role is not an omp role.
	role_note: string?,
	focus: Focus,
	roles: { roles.Role }?,
	roles_error: string?,
	error: string?,
	-- Submitted; further submits are ignored.
	done: boolean,
}

local function as_focus(v: any): Focus?
	if v == "title" or v == "details" or v == "role" then
		return v
	end
	return nil
end

local function send_focus(state: State)
	local target: any = if state.focus == "role" then tern.json.null else "main." .. state.focus
	state.cx:frame({ { "focus", target } })
end

local function set_focus(state: State, focus: Focus)
	state.focus = focus
	send_focus(state)
end

local function cycle_focus(state: State, back: boolean)
	local at = table.find(FOCUS_ORDER, state.focus) or 1
	local n = #FOCUS_ORDER
	local next_at = if back then (at - 2) % n + 1 else at % n + 1
	set_focus(state, FOCUS_ORDER[next_at])
end

local function has_role(list: { roles.Role }, name: string?): boolean
	if name == nil then
		return false
	end
	for _, r in list do
		if r.name == name then
			return true
		end
	end
	return false
end

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or "")
end

local function submit(state: State, lane: string)
	if state.done or state.fatal then
		return
	end
	local title = trim(state.title.text)
	if title == "" then
		state.error = "Give the task a title."
		set_focus(state, "title")
		return
	end
	if state.roles ~= nil and #state.roles > 0 and state.role == nil then
		state.error = "Pick an omp role."
		set_focus(state, "role")
		return
	end
	local details: string? = if trim(state.details.text) == "" then nil else state.details.text
	local ok, err = pcall(store.write_intent, {
		kind = "create",
		project = state.pid,
		title = title,
		details = details,
		role = state.role,
		lane = lane,
	})
	if not ok then
		state.error = "Could not queue the task: " .. tostring(err)
		return
	end
	state.done = true
	state.error = nil
	local cx = state.cx
	cx:open("swarm://wake")
	cx:toast("success", "Task added to " .. lane, title)
	cx:exit(0)
end

-- Moves the role selection by `delta`, clamped.
local function move_role(state: State, delta: number): boolean
	local list = state.roles
	if list == nil or #list == 0 then
		return false
	end
	local at = 0
	for i, r in list do
		if r.name == state.role then
			at = i
			break
		end
	end
	local next_at = if at == 0 then 1 else math.clamp(at + delta, 1, #list)
	local name = list[next_at].name
	if name == state.role then
		return false
	end
	state.role = name
	return true
end

local function role_items(state: State): { Node }
	local items: { Node } = {}
	for _, r in state.roles or {} do
		table.insert(items, ui.node("item", { key = r.name, label = r.name, detail = r.model, icon = "sparkle" }))
	end
	return items
end

local function roles_empty(state: State): Spans
	if state.roles_error ~= nil then
		return { ui.span(state.roles_error, "error") }
	elseif state.roles == nil and not state.fatal then
		return { ui.span("Loading roles…", "muted") }
	end
	return { ui.span("No roles available", "muted") }
end

local function keyed(node: Node, key: string): Node
	local p: { [string]: any } = node.p or {}
	p.key = key
	node.p = p
	return node
end

local function badge(label: string, tone: string, act: string, key: string): Node
	local node = keyed(ui.badge(label, tone), key)
	local p: { [string]: any } = node.p or {}
	p.actions = { click = act }
	node.p = p
	return node
end

local newTask: BlockDef<State> = {
	init = function(cx, args, saved)
		local pid = args[1] or ""
		local project = store.projects()[pid]
		local s: any = if type(saved) == "table" then saved else {}
		local state: State = {
			cx = cx,
			pid = pid,
			name = nil,
			root = nil,
			fatal = false,
			title = textfield.new(if type(s.title) == "string" then s.title else nil),
			details = textfield.new(if type(s.details) == "string" then s.details else nil),
			role = if type(s.role) == "string" and s.role ~= "" then s.role else nil,
			default_role = "default",
			primary = "Ready",
			role_note = nil,
			focus = as_focus(s.focus) or "title",
			roles = nil,
			roles_error = nil,
			error = nil,
			done = false,
		}
		if type(project) ~= "table" or type(project.root) ~= "string" then
			state.fatal = true
			state.error = UNKNOWN_PROJECT
		else
			local root: string = project.root
			state.root = root
			state.name = if type(project.name) == "string" then project.name else nil
			local cfg = config.load(root)
			state.default_role = cfg.default_role
			state.primary = cfg.new_task.lane
			roles.fetch(root, function(list, err)
				if state.done or not store.pane_alive(cx.pane) then
					return
				end
				if list == nil then
					state.roles_error = err or "Could not read omp roles"
				else
					state.roles = list
					if not has_role(list, state.role) then
						if has_role(list, state.default_role) then
							state.role = state.default_role
						else
							state.role = nil
							state.role_note = string.format('Default role "%s" is not an omp role. Pick one below.', state.default_role)
						end
					end
				end
				cx:render()
			end)
		end
		tern.timer(100, function()
			if not state.done then
				send_focus(state)
			end
		end)
		return state
	end,

	title = function(state)
		return if state.name then "New task · " .. state.name else "New Swarm task"
	end,

	view = function(state, _cx)
		local header = keyed(
			ui.text({
				ui.span("New task", "strong"),
				ui.span(" · " .. (state.name or state.pid), "muted"),
			}),
			"header"
		)

		local selected: string? = if state.role then ROLE_PREFIX .. state.role else nil
		local children: { Node } = {
			header,
			ui.node("input", {
				key = "title",
				text = state.title.text,
				cursor = textfield.utf16(state.title),
				placeholder = "Card title — what should the agent do?",
			}),
			ui.node("editor", {
				key = "details",
				text = state.details.text,
				cursor = textfield.utf16(state.details),
				maxLines = 12,
				placeholder = "Details, acceptance criteria, file pointers (optional)",
			}),
			keyed(ui.rule("omp role"), "role-rule"),
			ui.node("list", {
				key = "roles",
				selected = selected,
				empty = roles_empty(state),
			}, role_items(state)),
		}
		if state.role_note ~= nil then
			table.insert(children, keyed(ui.text({ ui.span(state.role_note, "warning") }), "role-note"))
		end
		if state.error ~= nil then
			table.insert(children, keyed(ui.text({ ui.span(state.error, "error") }), "error"))
		end

		local primary = state.primary
		local other = if primary == "Ready" then "Backlog" else "Ready"
		local function lane_badge(lane: string, tone: string): Node
			if lane == "Ready" then
				return badge("Create & start", tone, "submit_ready", "ready")
			end
			return badge("Add to backlog", tone, "submit_backlog", "backlog")
		end
		local hint_text = if primary == "Ready"
			then "Tab next field · ⌃↵ start · ⌃⇧↵ backlog · Esc cancel"
			else "Tab next field · ⌃↵ backlog · ⌃⇧↵ start · Esc cancel"
		local hint = keyed(ui.text({ ui.span(hint_text, "muted") }), "hint")

		return {
			main = ui.col(children),
			dock = ui.row({
				lane_badge(primary, "accent"),
				lane_badge(other, "neutral"),
				badge("Cancel", "neutral", "cancel", "cancel"),
				hint,
			}),
		}
	end,

	key = function(state, k, cx)
		local name = k.name
		if name == "escape" then
			state.done = true
			cx:exit(0)
			return nil
		elseif name == "tab" then
			cycle_focus(state, k.shift)
			return nil
		elseif name == "enter" and (k.ctrl or k.meta) then
			local other = if state.primary == "Ready" then "Backlog" else "Ready"
			submit(state, if k.shift then other else state.primary)
			return nil
		end

		local focus = state.focus
		if focus == "title" then
			if name == "enter" then
				set_focus(state, "details")
				return nil
			end
			if textfield.key(state.title, k, false) then
				return nil
			end
			return false
		elseif focus == "details" then
			if name == "enter" then
				textfield.insert(state.details, "\n")
				return nil
			end
			if textfield.key(state.details, k, true) then
				return nil
			end
			return false
		end

		-- Role list.
		if k.ctrl or k.meta or k.alt then
			return false
		elseif name == "up" or name == "k" then
			return if move_role(state, -1) then nil else false
		elseif name == "down" or name == "j" then
			return if move_role(state, 1) then nil else false
		elseif name == "enter" then
			submit(state, state.primary)
			return nil
		end
		return false
	end,

	event = function(state, ev, _cx)
		if ev.ev == "select" and ev.id == "main.roles" and type(ev.item) == "string" then
			local item: string = ev.item
			if string.sub(item, 1, #ROLE_PREFIX) == ROLE_PREFIX then
				local name = string.sub(item, #ROLE_PREFIX + 1)
				if state.roles ~= nil and has_role(state.roles, name) then
					state.role = name
					state.focus = "role"
					send_focus(state)
				end
			end
		elseif ev.ev == "focus" then
			if ev.id == "main.title" then
				set_focus(state, "title")
			elseif ev.id == "main.details" then
				set_focus(state, "details")
			end
		elseif ev.ev == "action" then
			if ev.act == "submit_ready" then
				submit(state, "Ready")
			elseif ev.act == "submit_backlog" then
				submit(state, "Backlog")
			elseif ev.act == "cancel" then
				state.done = true
				state.cx:exit(0)
			end
		end
	end,

	save = function(state)
		return {
			title = state.title.text,
			details = state.details.text,
			role = state.role,
			focus = state.focus,
		}
	end,
}

return newTask
