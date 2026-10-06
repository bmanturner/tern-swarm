--!strict
-- Shared constants and the task status / board lane vocabulary. Both halves.

local const = {}

const.TICK_MS = 3000
-- Delay before a follow-up timer call (a reconcile slice, a publish, a panel redraw step), so
-- heavy calls don't run back to back on the window's UI thread and the window renders between
-- them.
const.YIELD_MS = 60
-- How long a reconcile slice starts new per-task work. One task's step can take another 15-25 ms
-- (a ship job, a board move, a first save), so this leaves room under the 50 ms budget.
const.SLICE_MS = 10
const.LEASE_TTL_S = 10
const.ADOPT_STABLE_TICKS = 2
const.MISSING_CARD_TICKS = 2
const.PROMPT_STALL_S = 180
const.SHELL_READY_WAIT_S = 15
const.CONFIG_CACHE_S = 30
const.ROLE_CACHE_S = 1800
const.TAIL_BYTES = 12000
const.FEEDBACK_MAX = 24000
const.WATCHDOG_S = 60
const.WATCHDOG_RELOAD_GAP_S = 600
const.SHELL_BUSY_BLOCK_S = 120
const.SHORT_MAX = 16
const.NAME_CONCURRENCY = 2
const.NAME_TIMEOUT_MS = 20000
const.BUSY_REASON = "The task's shell is busy; finish or interrupt what's running in it, then Retry"

-- Board lanes, in board order.
const.LANES = table.freeze({ "Backlog", "Ready", "Doing", "Blocked", "Review", "Done" })

-- The lane each task status lives in; `cancelled` has none.
local LANE: { [string]: string } = {
	backlog = "Backlog",
	queued = "Ready",
	preparing = "Doing",
	running = "Doing",
	checking = "Doing",
	waiting = "Blocked",
	blocked = "Blocked",
	review = "Review",
	shipping = "Review",
	shipped = "Done",
	closed = "Done",
	parked = "Backlog",
	discarding = "Backlog",
}
const.LANE = table.freeze(LANE)

local TERMINAL: { [string]: boolean } = { shipped = true, closed = true, cancelled = true }
const.TERMINAL = table.freeze(TERMINAL)

-- Statuses that count against max_concurrent.
local ACTIVE: { [string]: boolean } = { preparing = true, running = true, checking = true }
const.ACTIVE = table.freeze(ACTIVE)

local COLOR: { [string]: string } = {
	preparing = "blue",
	running = "teal",
	checking = "purple",
	waiting = "yellow",
	blocked = "red",
	review = "green",
	shipping = "green",
}
const.COLOR = table.freeze(COLOR)

-- Tab label prefix per task status (statuses without one show the bare name).
local GLYPH: { [string]: string } = {
	waiting = "? ",
	blocked = "! ",
	checking = "⋯ ",
	review = "✓ ",
	shipping = "✓ ",
}
const.GLYPH = table.freeze(GLYPH)

-- The statuses each user action accepts (one rule for actions, intents and Carly).
local CAN: { [string]: { [string]: boolean } } = {
	approve = table.freeze({ review = true }),
	retry = table.freeze({ waiting = true, blocked = true, review = true, parked = true }),
	park = table.freeze({ preparing = true, running = true, checking = true, waiting = true, blocked = true, review = true }),
	discard = table.freeze({ backlog = true, queued = true, preparing = true, running = true, checking = true, waiting = true, blocked = true, review = true, parked = true }),
}
const.CAN = table.freeze(CAN)

-- Card tags (written without `#`).
const.TAG_TASK = "swarm-"
const.TAG_ROLE = "role-"
const.TAG_NO_CHANGE_OK = "no-change-ok"
const.TAG_AUTO_SHIP = "auto-ship"
const.TAG_DRAFT = "draft"

return const
