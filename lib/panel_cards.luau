--!strict
-- Card and list builders for the Swarm panel view: one function per kind of node.

local text = require("./text")

local panel_cards = {}

local ui = tern.ui

function panel_cards.with(node: any, props: { [string]: any }): any
	local p = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

function panel_cards.button(label: string, tone: string, act: string, pid: string, slug: string?, key: string): any
	return panel_cards.with(ui.badge(label, tone), { key = key, actions = { click = act .. "|" .. pid .. "|" .. (slug or "") } })
end

function panel_cards.muted(s: string): any
	return ui.span(s, "muted")
end

function panel_cards.by_order(list: { any })
	table.sort(list, function(a, b)
		local oa, ob = a.order or 1e9, b.order or 1e9
		if oa ~= ob then
			return oa < ob
		end
		return a.slug < b.slug
	end)
end

function panel_cards.role_badge(t: any): any
	return panel_cards.with(ui.badge("@" .. (t.role or "default"), "accent"), { key = "role" })
end

function panel_cards.check_badges(t: any): { any }
	local out: { any } = {}
	for i, c in t.checks or {} do
		local node
		if c.status == 0 then
			node = ui.badge("✓ " .. c.name, "success")
		elseif c.status == nil then
			node = ui.badge("· " .. c.name, "muted")
		else
			node = ui.badge("✗ " .. c.name, "error")
		end
		table.insert(out, panel_cards.with(node, { key = "check-" .. i }))
	end
	return out
end

function panel_cards.needs_card(pid: string, t: any): any
	local children: { any } = {
		panel_cards.with(ui.text({ ui.span(t.reason or "Needs attention", if t.status == "waiting" then "warning" else "error") }), { key = "reason" }),
	}
	if t.last_message and t.last_message ~= "" then
		table.insert(children, panel_cards.with(ui.md(t.last_message), { key = "msg" }))
	end
	table.insert(
		children,
		panel_cards.with(
			ui.row({
				panel_cards.button("Focus", "neutral", "focus", pid, t.slug, "focus"),
				panel_cards.button("Log", "neutral", "log", pid, t.slug, "log"),
				panel_cards.button("Details", "neutral", "details", pid, t.slug, "details"),
				panel_cards.button("Retry", "accent", "retry", pid, t.slug, "retry"),
				panel_cards.button("Discard", "error", "discard", pid, t.slug, "discard"),
			}),
			{ key = "actions" }
		)
	)
	local head: { any } = { ui.span(t.title, "strong") }
	if t.short then
		table.insert(head, panel_cards.muted("  " .. t.short))
	end
	table.insert(head, panel_cards.muted("  @" .. (t.role or "default")))
	return panel_cards.with(ui.card(head, children), {
		key = t.slug,
		tone = if t.status == "waiting" then "warning" else "error",
	})
end

function panel_cards.context_card(sp: any, t: any): any
	local names: { string } = {}
	for _, c in t.checks or {} do
		table.insert(names, c.name)
	end
	local body: { any } = {
		panel_cards.with(
			ui.kv({
				{ "branch", t.branch or "—" },
				{ "base", t.base_ref or "—" },
				{ "ship", if sp.ship == "pr" then "pull request" elseif sp.ship == "commit" then "commit only" else "—" },
				{ "checks", if #names == 0 then "none configured" else table.concat(names, ", ") },
			}),
			{ key = "kv" }
		),
	}
	if t.details and t.details ~= "" then
		table.insert(body, panel_cards.with(ui.md(t.details), { key = "details" }))
	end
	return panel_cards.with(ui.card({ panel_cards.muted("Context") }, body), { key = "context", collapsible = true, collapsed = true })
end

function panel_cards.review_card(sp: any, pid: string, t: any): any
	local r = t.review or {}
	local head: { any } = { ui.span(t.title, "strong") }
	if t.short then
		table.insert(head, panel_cards.muted("  " .. t.short))
	end
	if r.count then
		table.insert(head, panel_cards.muted(string.format("  +%d −%d · %d files", r.add or 0, r.del or 0, r.count)))
	end
	local meta: { any } = { panel_cards.role_badge(t) }
	if t.agent_model then
		table.insert(meta, panel_cards.with(ui.text({ panel_cards.muted(t.agent_model) }), { key = "model" }))
	end
	for _, b in panel_cards.check_badges(t) do
		table.insert(meta, b)
	end
	local children: { any } = { panel_cards.with(ui.row(meta), { key = "meta" }) }
	if t.ship_error then
		table.insert(children, panel_cards.with(ui.text({ ui.span(t.ship_error, "error") }), { key = "ship-error" }))
	end
	if r.files and #r.files > 0 then
		local rows: { any } = {}
		for i, f in r.files do
			if i > 10 then
				break
			end
			table.insert(rows, {
				f.path,
				if f.add == -1 then "new" else tostring(f.add or 0),
				if f.add == -1 then "" else tostring(f.del or 0),
			})
		end
		table.insert(
			children,
			panel_cards.with(
				ui.table({
					{ id = "path", head = "File", grow = 1, truncate = "middle" },
					{ id = "add", head = "+", align = "end" },
					{ id = "del", head = "−", align = "end" },
				}, rows),
				{ key = "files" }
			)
		)
	end
	table.insert(children, panel_cards.context_card(sp, t))
	if t.summary and t.summary ~= "" then
		table.insert(
			children,
			panel_cards.with(ui.card({ panel_cards.muted("Agent summary") }, { ui.md(t.summary) }), { key = "summary", collapsible = true, collapsed = true })
		)
	end
	local actions: { any }
	if t.status == "shipping" then
		actions = {
			ui.node("spinner", { key = "approve", style = "dots", label = { panel_cards.muted("Shipping…") } }),
			panel_cards.button("Diff", "neutral", "diff", pid, t.slug, "diff"),
			panel_cards.button("Focus", "neutral", "focus", pid, t.slug, "focus"),
		}
	else
		actions = {
			panel_cards.button("Approve", "accent", "approve", pid, t.slug, "approve"),
			panel_cards.button("Diff", "neutral", "diff", pid, t.slug, "diff"),
			panel_cards.button("Log", "neutral", "log", pid, t.slug, "log"),
			panel_cards.button("Details", "neutral", "details", pid, t.slug, "details"),
			panel_cards.button("Focus", "neutral", "focus", pid, t.slug, "focus"),
			panel_cards.button("Retry", "neutral", "retry", pid, t.slug, "retry"),
			panel_cards.button("Discard", "error", "discard", pid, t.slug, "discard"),
		}
	end
	table.insert(children, panel_cards.with(ui.row(actions), { key = "actions" }))
	return panel_cards.with(ui.card(head, children), { key = t.slug, tone = "success" })
end

function panel_cards.running_card(pid: string, t: any): any
	local label = if t.status == "running" then "working" else t.status
	local row: { any } = {
		panel_cards.role_badge(t),
		panel_cards.with(ui.badge(label, if t.status == "checking" then "info" else "pending"), { key = "status" }),
		panel_cards.with(ui.text({ panel_cards.muted(string.format("attempt %d/%d", t.attempt or 0, t.max_attempts or 0)) }), { key = "attempt" }),
	}
	if t.started_at then
		table.insert(row, ui.node("elapsed", { key = "elapsed", age = math.max(0, os.time() - t.started_at) * 1000 }))
	end
	local children: { any } = { panel_cards.with(ui.row(row), { key = "meta" }) }
	if t.last_message and t.last_message ~= "" then
		table.insert(children, panel_cards.with(ui.text({ panel_cards.muted(text.tail(t.last_message, 200)) }), { key = "msg" }))
	end
	table.insert(
		children,
		panel_cards.with(
			ui.row({
				panel_cards.button("Focus", "neutral", "focus", pid, t.slug, "focus"),
				panel_cards.button("Park", "neutral", "park", pid, t.slug, "park"),
			}),
			{ key = "actions" }
		)
	)
	local head: { any } = { ui.span(t.title, "strong") }
	if t.short then
		table.insert(head, panel_cards.muted("  " .. t.short))
	end
	return panel_cards.with(ui.card(head, children), { key = t.slug, tone = "pending" })
end

function panel_cards.task_list(pid: string, list: { any }, detail: (any) -> string, max: number): any
	local items: { any } = {}
	for i, t in list do
		if i > max then
			break
		end
		table.insert(items, { label = t.title, detail = detail(t) })
	end
	local node = ui.list(items)
	for i, child in node.c or {} do
		panel_cards.with(child, { key = list[i].slug, actions = { click = "details|" .. pid .. "|" .. list[i].slug } })
	end
	return node
end

function panel_cards.section(key: string, head: string, n: number, children: { any }): any
	return panel_cards.with(ui.section({ ui.span(head, "strong"), panel_cards.muted(" (" .. n .. ")") }, children), { key = key })
end

return panel_cards
