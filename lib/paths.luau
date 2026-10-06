--!strict
-- The plugin's data layout under tern.plugin.data, project ids and task slugs. Both halves.

local paths = {}

paths.HOME = tern.getenv("HOME") or ""

function paths.data(): string
	return tern.plugin.data
end

function paths.projects_file(): string
	return tern.plugin.data .. "/projects.json"
end

function paths.snapshot_file(): string
	return tern.plugin.data .. "/snapshot.json"
end

function paths.intents_dir(): string
	return tern.plugin.data .. "/intents"
end

function paths.project_dir(pid: string): string
	return tern.plugin.data .. "/projects/" .. pid
end

function paths.board(pid: string): string
	return paths.project_dir(pid) .. "/board.md"
end

function paths.tasks_dir(pid: string): string
	return paths.project_dir(pid) .. "/tasks"
end

function paths.task_dir(pid: string, slug: string): string
	return paths.tasks_dir(pid) .. "/" .. slug
end

function paths.archive_dir(pid: string): string
	return paths.project_dir(pid) .. "/archive"
end

-- The last component of `p`, ignoring trailing slashes.
function paths.basename(p: string): string
	local trimmed = string.gsub(p, "/+$", "")
	return string.match(trimmed, "([^/]+)$") or trimmed
end

-- `p` without its last component ("/" for a top-level path).
function paths.dirname(p: string): string
	local trimmed = string.gsub(p, "/+$", "")
	local dir = string.match(trimmed, "^(.*)/[^/]*$")
	if dir == nil then
		return "."
	end
	return if dir == "" then "/" else dir
end

-- `rel` resolved against directory `base` (`~/` expands to HOME), with `.` and `..` collapsed.
function paths.abs(base: string, rel: string): string
	local full: string
	if string.sub(rel, 1, 1) == "/" then
		full = rel
	elseif rel == "~" or string.sub(rel, 1, 2) == "~/" then
		full = paths.HOME .. string.sub(rel, 2)
	else
		full = base .. "/" .. rel
	end
	local parts: { string } = {}
	for part in string.gmatch(full, "[^/]+") do
		if part == ".." then
			if #parts > 0 then
				table.remove(parts)
			end
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

-- 32-bit djb2 hash of `s`.
function paths.djb2(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 4294967296
	end
	return h
end

local function sanitize(s: string): string
	local out = string.lower(s)
	out = string.gsub(out, "[^a-z0-9]+", "-")
	out = string.gsub(out, "^%-+", "")
	out = string.gsub(out, "%-+$", "")
	return out
end

-- Stable project id for repository root `root`: `<basename>-<8 hex of djb2(root)>`.
function paths.project_id(root: string): string
	local name = sanitize(paths.basename(root))
	if name == "" then
		name = "repo"
	end
	return name .. "-" .. string.format("%08x", paths.djb2(root))
end

-- A task slug from a card title: lowercase, runs outside [a-z0-9] become `-`, at most 40 bytes.
function paths.slugify(title: string): string
	local slug = sanitize(title)
	if #slug > 40 then
		slug = string.sub(slug, 1, 40)
		slug = string.gsub(slug, "%-+$", "")
	end
	return if slug == "" then "task" else slug
end

-- A slug for `title` not yet used by a task or archived task of project `pid`.
function paths.unique_slug(pid: string, title: string): string
	local base = paths.slugify(title)
	local function taken(slug: string): boolean
		return tern.fs.exists(paths.task_dir(pid, slug)) or tern.fs.exists(paths.archive_dir(pid) .. "/" .. slug)
	end
	if not taken(base) then
		return base
	end
	local n = 2
	while taken(base .. "-" .. n) do
		n += 1
	end
	return base .. "-" .. n
end

return paths
