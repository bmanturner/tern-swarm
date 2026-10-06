--!strict
-- POSIX shell quoting. Both halves.

local sh = {}

-- `s` as one single-quoted shell word.
function sh.quote(s: string): string
	return "'" .. (string.gsub(s, "'", "'\\''")) .. "'"
end

return sh
