--!strict
-- UTF-8-safe text clipping. Both halves.

local text = {}

-- `s` cut to at most `max` characters, ending in "…" when cut.
function text.clip(s: string, max: number): string
	local n = utf8.len(s)
	if n == nil then
		return if #s <= max then s else string.sub(s, 1, max - 1) .. "…"
	end
	if n <= max then
		return s
	end
	local cut = utf8.offset(s, max)
	return string.sub(s, 1, (cut or (max + 1)) - 1) .. "…"
end

-- The last `max` bytes of `s`, starting on a character boundary.
function text.tail(s: string, max: number): string
	if #s <= max then
		return s
	end
	local start = #s - max + 1
	while start <= #s do
		local b = string.byte(s, start)
		if b < 0x80 or b >= 0xC0 then
			break
		end
		start += 1
	end
	return string.sub(s, start)
end

-- `s` without leading and trailing whitespace.
function text.trim(s: string): string
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

return text
