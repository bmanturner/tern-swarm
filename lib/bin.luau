--!strict
-- Finds programs where package managers put them: the daemon (launchd) and the app run with a short
-- PATH, so spawn absolute paths from bin.resolve and pass bin.env(). Both halves.

local config = require("./config")

local bin = {}

local HOME = tern.getenv("HOME") or ""

bin.DIRS = table.freeze({ HOME .. "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin" })

-- The user's `bin_dirs` setting (already expanded) followed by bin.DIRS, without duplicates.
function bin.dirs(): { string }
	local ok, user = pcall(config.user)
	if not ok or type(user) ~= "table" or #user.bin_dirs == 0 then
		return bin.DIRS
	end
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, list in { user.bin_dirs, bin.DIRS } do
		for _, dir in list do
			if not seen[dir] then
				seen[dir] = true
				table.insert(out, dir)
			end
		end
	end
	return out
end

-- The absolute path of `name` in the first of bin.dirs() that has it; a `name` with a `/` is checked
-- as given. Nil when not found.
function bin.resolve(name: string): string?
	if string.find(name, "/", 1, true) then
		return if tern.fs.exists(name) then name else nil
	end
	for _, dir in bin.dirs() do
		local path = dir .. "/" .. name
		if tern.fs.exists(path) then
			return path
		end
	end
	return nil
end

function bin.missing_message(name: string): string
	return name .. " was not found in " .. table.concat(bin.dirs(), ", ")
end

-- Environment additions for every process the plugin starts.
function bin.env(): { [string]: string }
	return { PATH = table.concat(bin.dirs(), ":") .. ":/usr/sbin:/sbin" }
end

return bin
