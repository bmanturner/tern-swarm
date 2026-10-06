--!strict
-- The Swarm panel view: the canvas tree of one snapshot project.

local panel_cards = require("./panel_cards")
local state = require("./state")

local panel_view = {}

local ui = tern.ui
local with = panel_cards.with
local button = panel_cards.button
local muted = panel_cards.muted
local by_order = panel_cards.by_order
local needs_card = panel_cards.needs_card
local review_card = panel_cards.review_card
local running_card = panel_cards.running_card
local task_list = panel_cards.task_list
local section = panel_cards.section

-- Built Needs-you and Review cards, per project: memo[pid][kind|pid|slug] = { sig, node }. Every ui
-- constructor is a host call and these cards are ~30 nodes each, while redraws usually change one
-- task, so rebuilding every card would blow the 50 ms budget. A card is reused while its inputs
-- (the snapshot task, plus sp.ship for review cards) encode the same. Reuse is safe because the
-- stored node is the finished card and section() only wraps it. Running cards aren't memoized:
-- their elapsed age comes from os.time(). Each render keeps only the entries it used. A cold
-- render (a fresh VM, many changed cards) builds cards only until `deadline`; the rest become
-- placeholders and the view reports itself incomplete, so the caller redraws again later, by
-- which time the memo holds the cards built so far.
local memo: { [string]: { [string]: { sig: string, node: any } } } = {}
local deadline: number? = nil
local incomplete = false

-- The encoded snapshot task without `order` (a card's position, which shifts whenever a card is
-- added above it but isn't shown).
local function sig_of(t: any): string
	local order = t.order
	t.order = nil
	local s = tern.json.encode(t)
	t.order = order
	return s
end

local function cached(prev: { [string]: any }, used: { [string]: any }, key: string, sig: string, build: () -> any): any
	local hit = prev[key]
	if hit == nil or hit.sig ~= sig then
		if deadline and tern.now() > deadline then
			incomplete = true
			return with(ui.text({ muted("…") }), { key = string.match(key, "[^|]+$") })
		end
		hit = { sig = sig, node = build() }
	end
	used[key] = hit
	return hit.node
end

-- The panel view of snapshot project `sp` ({id, name, root, config_error, hold, trust, tasks}),
-- and whether it is complete. With `budget_ms`, cards not memoized yet are built only for that
-- long; an incomplete view must not be shown (redraw again; each call builds more).
function panel_view.view(sp: any, budget_ms: number?): (any, boolean)
	deadline = if budget_ms then tern.now() + budget_ms else nil
	incomplete = false

	local pid = sp.id
	local needs, review, running, queue, backlog, done = {}, {}, {}, {}, {}, {}
	for _, t in sp.tasks or {} do
		local st = t.status
		if st == "waiting" or st == "blocked" then
			table.insert(needs, t)
		elseif st == "review" or st == "shipping" then
			table.insert(review, t)
		elseif st == "preparing" or st == "running" or st == "checking" then
			table.insert(running, t)
		elseif st == "queued" then
			table.insert(queue, t)
		elseif st == "backlog" or st == "parked" or st == "discarding" then
			table.insert(backlog, t)
		elseif st == "shipped" or st == "closed" then
			table.insert(done, t)
		end
	end
	for _, list in { needs, review, running, queue, backlog, done } do
		by_order(list)
	end

	local global = state.snapshot.paused == true
	local mine = sp.paused == true
	local counts: { any } = {}
	local function count(n: number, label: string, tone: string, key: string)
		if n > 0 then
			table.insert(counts, with(ui.badge(n .. " " .. label, tone), { key = key }))
		end
	end
	count(#running, "running", "pending", "c-running")
	count(#needs, "need you", "warning", "c-needs")
	count(#review, "to review", "success", "c-review")
	count(#queue, "queued", "neutral", "c-queued")
	if mine then
		table.insert(counts, with(ui.badge("paused", "warning"), { key = "c-paused" }))
	elseif global then
		table.insert(counts, with(ui.badge("all paused", "warning"), { key = "c-paused" }))
	end

	local buttons: { any } = {
		button("New task", "accent", "new-task", pid, nil, "new-task"),
		button("Settings", "neutral", "settings", pid, nil, "settings"),
		if global
			then button("Resume all", "neutral", "resume-all", pid, nil, "pause")
			elseif mine then button("Resume", "neutral", "resume", pid, nil, "pause")
			else button("Pause", "neutral", "pause", pid, nil, "pause"),
	}
	if (sp.finished_count or 0) > 0 then
		table.insert(buttons, button("Clean up", "neutral", "clean", pid, nil, "clean"))
	end

	local header: { any } = {}
	local projects_error = state.snapshot.projects_error
	if type(projects_error) == "string" then
		table.insert(
			header,
			with(
				ui.text({
					ui.span(
						"Swarm's projects.json is damaged: " .. projects_error .. ". Fix or delete it; Swarm won't overwrite it.",
						"warning"
					),
				}),
				{ key = "projects-error" }
			)
		)
	end
	table.insert(header, with(ui.text({ ui.span(sp.name or pid, "strong"), muted("  " .. (sp.root or "")) }), { key = "title" }))
	if #counts > 0 then
		table.insert(header, with(ui.row(counts), { key = "counts" }))
	end
	table.insert(header, with(ui.row(buttons), { key = "buttons" }))
	if sp.config_error then
		table.insert(
			header,
			with(
				ui.row({
					ui.text({ ui.span("Settings: " .. sp.config_error, "warning") }),
					button("Open Settings", "warning", "settings", pid, nil, "config-fix"),
				}),
				{ key = "config" }
			)
		)
	end
	if sp.trust then
		local rows: { any } = {
			with(ui.text({ ui.span("Swarm runs nothing in this repository until you approve what it will run:", "warning") }), { key = "lead" }),
		}
		for i, item in sp.trust.items or {} do
			table.insert(rows, with(ui.text({ ui.span(item, "code") }), { key = "i" .. i }))
		end
		table.insert(rows, with(ui.text({ muted("Approval is saved on this machine. Swarm asks again when any of these change.") }), { key = "note" }))
		table.insert(
			rows,
			with(
				ui.row({
					button("Approve", "accent", "trust", pid, nil, "approve"),
					button("Open swarm.json", "neutral", "open-config", pid, nil, "open"),
				}),
				{ key = "actions" }
			)
		)
		table.insert(header, with(ui.col(rows), { key = "trust" }))
	end
	if sp.board_unread then
		table.insert(
			header,
			with(
				ui.text({
					ui.span(
						"The board is too large to read in full ("
							.. tostring(sp.board_unread)
							.. " cards skipped), so removed cards aren't noticed. Turn on Settings › Cleanup › Remove Done cards, then Clean up.",
						"warning"
					),
				}),
				{ key = "board-unread" }
			)
		)
	end

	local root: { any } = { with(ui.col(header), { key = "header" }) }
	local prev = memo[pid] or {}
	local used: { [string]: { sig: string, node: any } } = {}
	if #needs > 0 then
		local cards = {}
		for _, t in needs do
			table.insert(
				cards,
				cached(prev, used, "needs|" .. pid .. "|" .. t.slug, sig_of(t), function()
					return needs_card(pid, t)
				end)
			)
		end
		table.insert(root, section("needs", "Needs you", #needs, cards))
	end
	if #review > 0 then
		local cards = {}
		for _, t in review do
			table.insert(
				cards,
				cached(prev, used, "review|" .. pid .. "|" .. t.slug, sig_of(t) .. "|" .. tostring(sp.ship), function()
					return review_card(sp, pid, t)
				end)
			)
		end
		table.insert(root, section("review", "Review", #review, cards))
	end
	memo[pid] = used
	if #running > 0 then
		local cards = {}
		for _, t in running do
			table.insert(cards, running_card(pid, t))
		end
		table.insert(root, section("running", "Running", #running, cards))
	end
	local function next_role(t: any): string
		return "@" .. (t.next_role or t.role or "default")
	end
	if #queue > 0 then
		table.insert(root, section("queue", "Up next", #queue, {
			with(task_list(pid, queue, next_role, 30), { key = "list" }),
		}))
	end
	if #backlog > 0 then
		table.insert(root, section("backlog", "Backlog", #backlog, {
			with(task_list(pid, backlog, function(t)
				if t.status == "discarding" then
					return "discarding…"
				elseif t.status == "parked" then
					return "parked · " .. next_role(t)
				end
				return next_role(t)
			end, 30), { key = "list" }),
		}))
	end
	if #done > 0 then
		table.sort(done, function(a, b)
			local fa, fb = a.finished_at, b.finished_at
			if fa ~= fb then
				if fa == nil then
					return false
				elseif fb == nil then
					return true
				end
				return fa > fb
			end
			return a.slug < b.slug
		end)
		local recent: { any } = {}
		for i, t in done do
			if i > 8 then
				break
			end
			local value: any
			if t.status == "closed" then
				value = muted("closed")
			elseif t.pr_url then
				value = ui.link("PR " .. (string.match(t.pr_url, "(%d+)$") or ""), t.pr_url)
			elseif t.commit then
				value = ui.span(t.commit, "code")
			else
				value = muted(t.status)
			end
			table.insert(recent, { label = t.title, value = value, icon = if t.status == "shipped" then "success" else "x" })
		end
		local list = ui.list(recent)
		for i, child in list.c or {} do
			with(child, { key = "done-" .. i })
		end
		local children: { any } = { with(list, { key = "list" }) }
		for _, t in done do
			if t.status == "shipped" and t.kept then
				table.insert(
					children,
					with(
						ui.col({
							with(ui.text({ ui.span(t.title .. ": worktree kept because " .. t.kept, "warning") }), { key = "why" }),
							with(ui.row({ button("Discard", "error", "discard", pid, t.slug, "discard") }), { key = "actions" }),
						}),
						{ key = t.slug }
					)
				)
			end
		end
		table.insert(root, section("done", "Done", #recent, children))
	end
	if #(sp.tasks or {}) == 0 then
		table.insert(root, with(ui.md("No tasks yet. Add a card to **Ready** on the board, or run **Swarm: New task…**."), { key = "empty" }))
	end
	return ui.col(root), not incomplete
end

-- An empty snapshot project, for a panel opened before the leader published one.
function panel_view.empty(pid: string, name: string, root: string): any
	return { id = pid, name = name, root = root, tasks = {} }
end

return panel_view
