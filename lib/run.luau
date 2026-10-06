--!strict
-- tern.process.run with absolute program paths, the plugin PATH and spawn failures reported as results.
-- Both halves. Callbacks always run later (never inside the caller) and receive the window cx when
-- there is one.

local bin = require("./bin")
local paths = require("./paths")

local run = {}

export type Result = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type Options = { cwd: string?, timeout_ms: number?, stdin: string? }

local function later(cb: (Result, any) -> (), result: Result)
	tern.timer(0, function(cx: any)
		cb(result, cx)
	end)
end

-- Runs argv (argv[1] is looked up with bin.resolve) and calls cb(result, cx?) when it exits.
function run.exec(argv: { string }, opts: Options?, cb: (Result, any) -> ())
	local o = opts or {}
	local program = bin.resolve(argv[1])
	if program == nil then
		later(cb, { status = 127, stdout = "", stderr = bin.missing_message(argv[1]), timed_out = false })
		return
	end
	local full = table.clone(argv)
	full[1] = program
	local ok, err = pcall(tern.process.run, full, {
		cwd = o.cwd or paths.HOME,
		timeout_ms = o.timeout_ms or 60000,
		stdin = o.stdin,
		env = bin.env(),
	}, function(result: any, cx: any)
		cb(result, cx)
	end)
	if not ok then
		later(cb, { status = 127, stdout = "", stderr = tostring(err), timed_out = false })
	end
end

function run.trim(s: string?): string
	return (string.gsub(s or "", "^%s+", ""):gsub("%s+$", ""))
end

-- The first non-empty line of `s` (trimmed), or "".
function run.first_line(s: string?): string
	for line in string.gmatch(s or "", "[^\n]+") do
		local t = run.trim(line)
		if t ~= "" then
			return t
		end
	end
	return ""
end

-- Why a command failed, for a reason line: its first stderr line, else stdout's, else the status.
function run.why(r: Result): string
	if r.timed_out then
		return "timed out"
	end
	local line = run.first_line(r.stderr)
	if line == "" then
		line = run.first_line(r.stdout)
	end
	return if line ~= "" then line else "exit " .. tostring(r.status)
end

return run
