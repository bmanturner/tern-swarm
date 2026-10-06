--!strict
-- Board cards as the orchestrator sees them: parsing a board read into cards by slug, lane order,
-- and applying a human's lane move to its task. Window half.

local actions = require("./actions")
local const = require("./const")
local state = require("./state")

local cardsync = {}

-- The card's text without its own `#tag` words.
local function clean_title(s: string, tags: { string }): string
	local drop: { [string]: boolean } = {}
	for _, t in tags do
		drop["#" .. t] = true
	end
	local words: { string } = {}
	for w in string.gmatch(s, "%S+") do
		if not drop[w] then
			table.insert(words, w)
		end
	end
	return table.concat(words, " ")
end

-- Cards of a board snapshot: tagged cards by slug, untagged cards in order.
function cardsync.build(snap: any): ({ [string]: any }, { any })
	local by_slug: { [string]: any } = {}
	local untagged: { any } = {}
	for _, lane in snap.lanes or {} do
		if type(lane.title) == "string" then
			for i, c in lane.cards or {} do
				local tags: { string } = {}
				local slug: string?, role: string? = nil, nil
				for _, t in c.tags or {} do
					if type(t) == "string" then
						table.insert(tags, t)
						if slug == nil and string.sub(t, 1, #const.TAG_TASK) == const.TAG_TASK then
							slug = string.sub(t, #const.TAG_TASK + 1)
						elseif role == nil and string.sub(t, 1, #const.TAG_ROLE) == const.TAG_ROLE then
							role = string.sub(t, #const.TAG_ROLE + 1)
						end
					end
				end
				local raw = if type(c.text) == "string" then c.text else ""
				local bad_role: string? = nil
				if role ~= nil and role ~= "" and not string.find(role, "^[%w_%-]+$") then
					bad_role = role
					role = nil
				end
				local card = {
					id = c.id,
					lane = lane.title,
					index = i,
					text = raw,
					tags = tags,
					slug = slug,
					role = if role ~= "" then role else nil,
					bad_role = bad_role,
					title = clean_title(raw, tags),
				}
				if slug and slug ~= "" then
					if by_slug[slug] == nil then
						by_slug[slug] = card
					end
				else
					table.insert(untagged, card)
				end
			end
		end
	end
	return by_slug, untagged
end

function cardsync.lane_order(lane: string?): number
	for i, l in const.LANES do
		if l == lane then
			return i
		end
	end
	return 99
end

-- A card a human moved: Ready = run (retry), Backlog = park, Done = per `on_move_to_done` (approve,
-- close or refuse). A rejected action leaves the status alone, and lane sync moves the card back.
function cardsync.human_move(ctx: any, task: any, card: any)
	local to, st = card.lane, task.status
	if to == "Ready" then
		if st == "backlog" then
			task.status = "queued"
		elseif st ~= "queued" then
			actions.retry(ctx, task, true)
		end
	elseif to == "Backlog" then
		if st == "queued" then
			task.status = "backlog"
		elseif st ~= "backlog" and st ~= "parked" then
			actions.park(ctx, task)
		end
	elseif to == "Done" then
		local mode = ctx.cfg.on_move_to_done
		if mode == "close" then
			actions.close(ctx, task)
		elseif mode == "revert" then
			state.notify("info", "Swarm: put " .. tostring(task.title) .. " back", "Dragging to Done is off; use Approve in the Swarm panel.")
		elseif st == "review" then
			if ctx.hold then
				state.notify("error", "Swarm: can't ship " .. tostring(task.title), ctx.hold)
			else
				actions.approve(ctx, task)
			end
		elseif mode == "approve_only" then
			state.notify("info", "Swarm: put " .. tostring(task.title) .. " back", "Only tasks in Review can be dragged to Done in this project.")
		else
			actions.close(ctx, task)
		end
	end
	task.lane = card.lane
end

return cardsync
