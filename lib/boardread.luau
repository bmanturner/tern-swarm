--!strict
-- Reads a whole board for the orchestrator, paging by lane past Tern's per-read cap. Window half.

local state = require("./state")

local boardread = {}

-- A board read pages by lane at most this many times.
local MAX_BOARD_PAGES = 8

-- Rows a board read asks for per lane (Tern's maximum).
local BOARD_ROWS = 500

-- Cards a read lane left out (its `more`). `lane.complete` marks the completion lane, not a full
-- read, so `more` is the only per-lane truncation signal.
local function lane_unread(lane: any): number
	if type(lane.more) == "number" and lane.more > 0 then
		return lane.more
	end
	return 0
end

-- Reads `board` in full, paging by lane past the per-read cap, then calls `cb(snap, nil, cx2)` with
-- {phase, lanes, more}: `more` counts cards no page returned (lanes' own `more` plus lanes a page
-- omitted) and is > 0 whenever any lane was cut off or the read stopped short, so removal
-- detection stays off. On an error calls `cb(nil, err, cx2)`. Calls nothing once leadership period
-- `epoch` is over. The first read raises synchronously when it can't start.
function boardread.read(cx: WindowCx, board: string, epoch: number, cb: (snap: any?, err: any, cx2: WindowCx?) -> ())
	local merged: any = { phase = nil, lanes = {}, more = 0 }
	local pages = 0
	local prev_first: number? = nil
	local function on_page(s: any, err: any, cx2: WindowCx?)
		state.last_await_at = os.time()
		if not state.current(epoch) then
			return
		end
		if err or type(s) ~= "table" then
			cb(nil, err, cx2)
			return
		end
		pages += 1
		local first = if type(s.first) == "number" then s.first else 1
		local more = if type(s.more) == "number" and s.more > 0 then s.more else 0
		local lanes = s.lanes or {}
		local unread: { number } = {}
		local page_unread = 0
		for i, lane in lanes do
			unread[i] = lane_unread(lane)
			page_unread += unread[i]
		end
		-- Cards the page left out beyond what its lanes account for.
		local extra = math.max(0, more - page_unread)
		if pages == 1 then
			merged.phase = s.phase
		elseif prev_first ~= nil and first <= prev_first then
			-- No progress: finish with what was merged, marked incomplete.
			merged.more += math.max(1, more, page_unread)
			cb(merged, nil, cx2)
			return
		end
		prev_first = first
		-- Appends lanes `from_i` onward of this page with their unread counts, then finishes; `short`
		-- marks a read that stopped before the last lane.
		local function finish(from_i: number, short: boolean)
			for i = from_i, #lanes do
				table.insert(merged.lanes, lanes[i])
				merged.more += unread[i]
			end
			merged.more += extra
			if short and merged.more == 0 then
				merged.more = 1
			end
			cb(merged, nil, cx2)
		end
		if more == 0 and page_unread == 0 then
			finish(1, false)
			return
		end
		-- Keep the leading fully read lanes (no `more`); a leading partial lane is kept as is and skipped past.
		local k = 0
		for i in lanes do
			if unread[i] > 0 then
				break
			end
			k += 1
		end
		local step = if k >= 1 then k else 1
		local last = if type(s.total) == "number" then s.total else first + #lanes - 1
		local from = first + step
		if #lanes == 0 then
			finish(1, true)
			return
		end
		if from > last then
			finish(1, false)
			return
		end
		if pages >= MAX_BOARD_PAGES or cx2 == nil then
			finish(1, true)
			return
		end
		for i = 1, step do
			table.insert(merged.lanes, lanes[i])
			merged.more += unread[i]
		end
		local c: WindowCx = cx2
		local ok, aw = pcall(function()
			return c.board:read(board, { rows = BOARD_ROWS, from = from, max_chars = 64000 })
		end)
		if not ok then
			cb(nil, aw, c)
			return
		end
		aw:next(on_page)
	end
	cx.board:read(board, { rows = BOARD_ROWS, max_chars = 64000 }):next(on_page)
end

return boardread
