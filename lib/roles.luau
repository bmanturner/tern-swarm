--!strict
-- omp model roles that make sense for a coding task, from `omp config get modelRoles --json`. Both halves.

local run = require("./run")

local roles = {}

export type Role = { name: string, model: string }

-- Roles that never drive a coding agent.
local SKIP = { commit = true, memory = true, tiny = true, vision = true, advisor = true, dictation = true, speech = true }
local ORDER = { smol = 1, default = 2, task = 3, plan = 4, slow = 5 }

-- Calls cb(list) with roles ordered smol, default, task, plan, slow, then alphabetically; cb(nil, err) on failure.
function roles.fetch(root: string?, cb: (list: { Role }?, err: string?) -> ())
	run.exec({ "omp", "config", "get", "modelRoles", "--json" }, { cwd = root, timeout_ms = 10000 }, function(r)
		if r.status ~= 0 then
			cb(nil, "omp config failed: " .. run.why(r))
			return
		end
		local ok, decoded = pcall(tern.json.decode, r.stdout)
		if not ok or type(decoded) ~= "table" or type(decoded.value) ~= "table" then
			cb(nil, "omp config printed no modelRoles")
			return
		end
		local list: { Role } = {}
		for name, model in decoded.value do
			if type(name) == "string" and type(model) == "string" and not SKIP[name] then
				table.insert(list, { name = name, model = model })
			end
		end
		table.sort(list, function(a, b)
			local oa, ob = ORDER[a.name] or 99, ORDER[b.name] or 99
			if oa ~= ob then
				return oa < ob
			end
			return a.name < b.name
		end)
		cb(list, nil)
	end)
end

return roles
