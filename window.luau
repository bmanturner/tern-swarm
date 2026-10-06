--!strict
-- Tern Swarm window half: the orchestrator (leader window only), the panel's click handling, palette
-- commands, the status segment, the swarm://wake route used by the New task form, and Carly exports.
--
-- Tern compiles every chunk to native code when it is required, and the whole window half takes
-- longer than the 50 ms load budget. So the entry loads one module per timer callback (each has its
-- own budget, and require caches the result), then registers everything.

-- iOS has no tern.process, and boards are desktop-only.
if tern.runtime.os == "ios" then
	return
end

-- Dependencies first, so each step compiles one module.
local MODULES = {
	"./lib/const",
	"./lib/text",
	"./lib/paths",
	"./lib/schema",
	"./lib/config",
	"./lib/bin",
	"./lib/sh",
	"./lib/run",
	"./lib/store",
	"./lib/roles",
	"./lib/state",
	"./lib/panel_cards",
	"./lib/panel_view",
	"./lib/panel",
	"./lib/projects",
	"./lib/git",
	"./lib/jobs",
	"./lib/prompts",
	"./lib/names",
	"./lib/actions",
	"./lib/ship",
	"./lib/cleanup",
	"./lib/prepare",
	"./lib/checking",
	"./lib/steps",
	"./lib/taskctx",
	"./lib/cardsync",
	"./lib/publish",
	"./lib/reconcile",
	"./lib/boardread",
	"./lib/intents",
	"./lib/orchestrator",
	"./lib/commands",
	"./lib/carly",
}

-- A local alias: luau-lsp strict mode rejects a computed path passed to the global `require`. The
-- caller is still this file, so the paths resolve against the package root.
local load_module: (string) -> any = require :: any

-- Startup watch: an over-budget loader step disables every timer, so register() would never run.
-- The focus handler is installed before loading starts and tells the user when startup stalled.
local started_at = os.time()
local ready = false
local stall_warned = false
local loading = MODULES[1]
local on_focus: ((cx: WindowCx) -> ())? = nil

local function register()
	ready = true
	local commands = load_module("./lib/commands")
	local orchestrator = load_module("./lib/orchestrator")
	local panel = load_module("./lib/panel")

	tern.on("canvas_action", function(ev: any, cx: WindowCx): boolean
		return panel.on_action(ev, cx)
	end)

	tern.on("command_finished", function(ev: any, cx: WindowCx)
		orchestrator.on_command_finished(ev)
		orchestrator.on_event(cx, "command")
	end)

	on_focus = function(cx: WindowCx)
		orchestrator.on_event(cx, "focus")
	end

	tern.route.link(function(link: LinkRequest, _cx: WindowCx): RouteDecision?
		if link.url == "swarm://wake" then
			orchestrator.poke()
			return { handled = true }
		end
		return nil
	end)

	commands.register()

	if tern.carly then
		-- Carly exports are optional; a failure here must not keep the orchestrator from starting.
		local ok, err = pcall(function()
			load_module("./lib/carly").register()
		end)
		if not ok then
			tern.log.warn("swarm: Carly exports not registered", err)
		end
	end

	orchestrator.start()
end

local function step(i: number)
	tern.timer(0, function()
		if i > #MODULES then
			register()
			return
		end
		loading = MODULES[i]
		local t0 = tern.now()
		load_module(MODULES[i])
		local ms = tern.now() - t0
		if ms >= 15 then
			tern.log.warn(string.format("swarm: loading %s took %.1f ms", MODULES[i], ms))
		else
			tern.log.debug(string.format("swarm: loaded %s in %.1f ms", MODULES[i], ms))
		end
		step(i + 1)
	end)
end

tern.on("focus", function(_ev: any, cx: WindowCx)
	local handler = on_focus
	if handler then
		handler(cx)
	elseif not ready and not stall_warned and os.time() - started_at >= 20 then
		stall_warned = true
		tern.log.warn("swarm: startup stalled while loading " .. loading)
		pcall(function()
			cx:toast(
				"error",
				"Swarm didn't finish starting",
				"Run Reload plugins from the palette. If it keeps happening, see Troubleshooting in the Swarm README."
			)
		end)
	end
end)

step(1)
