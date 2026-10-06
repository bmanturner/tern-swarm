--!strict
-- Short task names for tab labels: generated once per title by omp's `@tiny` role, with a
-- key-word fallback from the title until (or unless) that returns. Window half.

local const = require("./const")
local run = require("./run")
local state = require("./state")
local store = require("./store")
local text = require("./text")

local names = {}

local function set(list: { string }): { [string]: boolean }
	local s: { [string]: boolean } = {}
	for _, w in list do
		s[w] = true
	end
	return table.freeze(s)
end

-- Words that never name the thing being changed.
local STOP = set({
	"a", "an", "the", "to", "for", "of", "in", "on", "at", "by", "with", "and", "or", "that", "this", "it",
	"is", "be", "containing", "contains", "word", "words", "create", "add", "make", "implement", "write",
	"update", "please", "new", "file", "files", "so", "should", "when", "from", "into", "use", "using",
})

-- File extensions, dropped when they follow a kept word ("hello.txt" -> "hello").
local EXT = set({
	"txt", "md", "json", "ts", "tsx", "js", "jsx", "luau", "lua", "py", "rs", "go", "css", "html", "yml",
	"yaml", "toml", "sh",
})

-- Statuses whose tasks have a tab worth naming.
local NAMED = set({ "queued", "preparing", "running", "checking", "waiting", "blocked", "review", "shipping" })

-- The first three of `words` joined with "-", dropping trailing words to fit SHORT_MAX; a single
-- word longer than SHORT_MAX is cut.
local function fit(words: { string }): string
	local n = math.min(#words, 3)
	while n > 1 do
		local joined = table.concat(words, "-", 1, n)
		if #joined <= const.SHORT_MAX then
			return joined
		end
		n -= 1
	end
	return string.sub(words[1] or "", 1, const.SHORT_MAX)
end

-- A name from the title's key words, e.g. "Fix the login redirect loop" -> "fix-login".
function names.fallback(title: string): string
	local raw: { string } = {}
	for w in string.gmatch(string.lower(title), "[a-z0-9]+") do
		table.insert(raw, w)
	end
	local kept: { string } = {}
	local prev_kept = false
	for _, w in raw do
		if STOP[w] or (EXT[w] and prev_kept) then
			prev_kept = false
		else
			table.insert(kept, w)
			prev_kept = true
		end
	end
	if #kept == 0 then
		kept = { raw[1], raw[2] }
	end
	if #kept == 0 then
		return "task"
	end
	return fit(kept)
end

-- The kebab-case name in a model reply, or nil when the reply doesn't hold a usable one.
function names.sanitize(raw: string): string?
	local line = run.first_line(raw)
	if string.find(line, "^Working%.%.%.") then
		line = ""
		for l in string.gmatch(raw, "[^\n]+") do
			local t = run.trim(l)
			if t ~= "" then
				line = t
			end
		end
	end
	local lower = string.lower(line)
	for _, prefix in { "name:", "tab:", "title:" } do
		if string.sub(lower, 1, #prefix) == prefix then
			line = run.trim(string.sub(line, #prefix + 1))
			break
		end
	end
	line = string.gsub(line, "%*", "")
	line = string.gsub(line, "^[\"'`_%s]+", "")
	line = string.gsub(line, "[\"'`_%s]+$", "")
	line = string.gsub(line, "%.$", "")
	if #line > 60 then
		return nil
	end
	local slug = string.gsub(string.gsub(string.lower(line), "[^a-z0-9]+", "-"), "^%-+", "")
	slug = string.gsub(slug, "%-+$", "")
	local words: { string } = {}
	for w in string.gmatch(slug, "[^%-]+") do
		table.insert(words, w)
	end
	local name = fit(words)
	if name == "" or name == "task" or not string.find(name, "[a-z]") then
		return nil
	end
	return name
end

-- The task's short name without a status glyph. `mode` is the `tabs.names` setting (default
-- "model"): "slug" shows the slug, "keywords" the title's key words, "model" and "off" the @tiny
-- name once known (key words until then).
function names.label_plain(task: any, mode: string?): string
	local m = mode or "model"
	if m == "slug" then
		return task.slug
	elseif m == "keywords" then
		return names.fallback(task.title or task.slug)
	end
	if type(task.short_name) == "string" and task.short_name ~= "" and task.short_name_title == task.title then
		return task.short_name
	end
	return names.fallback(task.title or task.slug)
end

-- The task's tab label: status glyph plus short name.
function names.label(task: any, mode: string?): string
	return (const.GLYPH[task.status] or "") .. names.label_plain(task, mode)
end

-- `name`, suffixed -2, -3, … until no other non-terminal task of project `pid` shows it.
local function unique(pid: string, task: any, name: string): string
	local taken: { [string]: boolean } = {}
	for _, other in state.tasks[pid] or {} do
		if other ~= task and not const.TERMINAL[other.status] then
			taken[names.label_plain(other, "model")] = true
		end
	end
	local candidate = name
	local n = 1
	while taken[candidate] do
		n += 1
		local suffix = "-" .. tostring(n)
		local base = string.gsub(string.sub(name, 1, const.SHORT_MAX - #suffix), "%-+$", "")
		candidate = base .. suffix
	end
	return candidate
end

-- Naming calls in flight in this VM.
local pending = 0

-- Asks `@tiny` for a short name for the task's current title, once per title, in the background.
-- Only in `mode` "model" (the `tabs.names` setting); other modes never send titles to a model.
function names.ensure(pid: string, task: any, mode: string?)
	if mode ~= "model" then
		return
	end
	local title = task.title
	if not NAMED[task.status] or type(title) ~= "string" or title == "" then
		return
	end
	local key = pid .. "/" .. task.slug
	if task.short_name_title == title or state.naming[key] == title or pending >= const.NAME_CONCURRENCY then
		return
	end
	state.naming[key] = title
	pending += 1
	local epoch = state.epoch
	local prompt = "Task title: "
		.. string.gsub(text.clip(title, 300), "[\r\n]+", " ")
		.. "\n\nGive this coding task a very short name for a terminal tab: 1 to 3 lowercase words joined by hyphens, "
		.. "at most 16 characters, naming the thing being changed (e.g. login-redirect, dark-mode). Reply with the name only."
	run.exec({
		"omp",
		"-p",
		"--model",
		"@tiny",
		"--no-session",
		"--no-title",
		"--no-tools",
		"--no-skills",
		"--no-rules",
		"--no-extensions",
		"--no-lsp",
		"--system-prompt",
		"You name software tasks. Reply with a single short kebab-case name and nothing else.",
		prompt,
	}, { cwd = tern.plugin.data, timeout_ms = const.NAME_TIMEOUT_MS, stdin = "" }, function(r: run.Result)
		pending -= 1
		if not state.current(epoch) or (state.tasks[pid] or {})[task.slug] ~= task or task.title ~= title then
			return
		end
		local name = if r.status == 0 and not r.timed_out then names.sanitize(r.stdout) else nil
		if name then
			task.short_name = unique(pid, task, name)
			task.short_name_title = title
			store.save_task(task)
			state.poke()
		else
			tern.log.warn("swarm: tiny name failed for " .. key, run.why(r))
		end
	end)
end

return names
