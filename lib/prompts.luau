--!strict
-- Prompts sent to task agents. Window half.

local const = require("./const")
local jobs = require("./jobs")
local store = require("./store")
local text = require("./text")

local prompts = {}

function prompts.initial(task: any, cfg: any): string
	local commit_only = cfg.ship == "commit"
	local details = text.trim(store.details(task.project, task.slug))
	if details == "" then
		details = "(No further details were given. Make reasonable, minimal decisions and state them in your summary.)"
	end
	local check_lines: { string } = {}
	local agent_runs, orch_only = 0, 0
	for _, c in cfg.checks do
		if c.agent_runs == false then
			orch_only += 1
			table.insert(check_lines, "- " .. c.name .. ": `" .. c.run .. "` (the orchestrator runs this one; you don't need to)")
		else
			agent_runs += 1
			table.insert(check_lines, "- " .. c.name .. ": `" .. c.run .. "`")
		end
	end
	local run_line = "Run them yourself before you finish and fix every failure."
	if #check_lines == 0 then
		table.insert(check_lines, "- (none configured; verify your change appropriately)")
	elseif agent_runs == 0 then
		run_line = "You don't need to run them; fix whatever they report."
	elseif orch_only > 0 then
		run_line = "Run the others yourself before you finish and fix every failure."
	end
	local lines: { string } = {
		"You are an autonomous coding agent working on one card from a Kanban board.",
		"",
		"## Task",
		task.title,
		"",
		details,
		"",
		"## Workspace",
		"- You are in a dedicated git worktree: " .. task.worktree,
		"- Branch: " .. task.branch .. ", created from " .. (task.base_ref or "?") .. " at " .. string.sub(task.base_sha or "", 1, 7) .. ".",
		if commit_only
			then "- Work only inside this directory. Do not switch branches, rebase, commit, push, or open pull requests: the orchestrator commits your change after a human reviews it."
			else "- Work only inside this directory. Do not switch branches, rebase, commit, push, or open pull requests: the orchestrator commits and opens the pull request after a human reviews your change.",
		"- Do not start long-running servers or watchers.",
		"- Nobody watches this pane while you work. If you need a decision, ask it with your ask tool if you have one (Swarm then shows the task as waiting for the human); otherwise say so in your final message and stop. Never open interactive UI to collect input or show results: no Tern blocks, canvases, pickers or forms, no browser windows, no full-screen terminal programs.",
	}
	local instr = cfg.instructions or {}
	local user_text = text.trim(instr.user or "")
	local project_text = text.trim(instr.project or "")
	if user_text ~= "" then
		table.insert(lines, "")
		table.insert(lines, "## Personal instructions")
		table.insert(lines, text.clip(user_text, 8000))
	end
	if project_text ~= "" then
		table.insert(lines, "")
		table.insert(lines, "## Project instructions")
		table.insert(lines, text.clip(project_text, 8000))
	end
	if user_text ~= "" or project_text ~= "" then
		table.insert(lines, "")
		table.insert(lines, "If these instructions conflict with the Workspace rules above, follow the Workspace rules.")
	end
	for _, l in
		{
			"",
			"## Definition of done",
			"When you end your turn, the orchestrator runs these checks in this worktree:",
			table.concat(check_lines, "\n"),
			run_line,
			"",
			"## Finish",
			if commit_only
				then "End your final message with a short summary of what you changed and why; the reviewer reads it before approving. If the task is ambiguous or you are blocked, say so plainly and stop instead of guessing."
				else "End your final message with a short summary of what you changed and why; it becomes the pull request description. If the task is ambiguous or you are blocked, say so plainly and stop instead of guessing.",
		}
	do
		table.insert(lines, l)
	end
	return table.concat(lines, "\n")
end

function prompts.resume(task: any, cfg: any): string
	local head = "You are resuming a Kanban task. An earlier agent already worked on it in this worktree and its changes are still here, uncommitted. Start by reviewing `git status` and `git diff`, then continue."
	if task.reason and task.reason ~= "" then
		head ..= "\nThe earlier attempt stopped because: " .. task.reason
	end
	return head .. "\n\n" .. prompts.initial(task, cfg)
end

-- `failed` is a list of step results {name, run, status} of the task's last checks job `job`.
function prompts.feedback(task: any, job: any, failed: { any }, max_attempts: number): string
	local per = math.floor(20000 / math.max(1, #failed))
	local parts: { string } = {
		string.format("The orchestrator ran the checks in your worktree and %d failed (attempt %d of %d).", #failed, task.attempt or 1, max_attempts),
	}
	for _, f in failed do
		local tail = text.tail(jobs.tail(job, f.name), per)
		table.insert(parts, "")
		table.insert(parts, "### " .. f.name .. " — exit " .. tostring(f.status or "?"))
		table.insert(parts, "`" .. (f.run or "") .. "`")
		table.insert(parts, "```text")
		table.insert(parts, tail)
		table.insert(parts, "```")
	end
	table.insert(parts, "")
	table.insert(parts, "Fix the failures, run the failing checks again yourself, and end with an updated summary of the whole change.")
	return text.clip(table.concat(parts, "\n"), const.FEEDBACK_MAX)
end

return prompts
