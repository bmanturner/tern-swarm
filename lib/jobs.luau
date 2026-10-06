--!strict
-- Jobs: a generated sh script typed into the task's shell pane (the user's interactive shell, so the
-- project's PATH and node version apply), reporting per-step status files the leader polls. Window half.

local const = require("./const")
local paths = require("./paths")
local sh = require("./sh")
local store = require("./store")
local text = require("./text")

local jobs = {}

export type Step = { name: string, run: string }
export type RunOpts = { timeout_s: number, env: { [string]: string } }

local function read_small(path: string, max: number): string?
	local ok, s = pcall(tern.fs.read, path, max)
	return if ok then s else nil
end

-- Whether the task's shell can take a job now: "ready" at an idle prompt; "noshell" when it is gone;
-- "wait" while it is busy (at most SHELL_BUSY_BLOCK_S, then "busy") or its prompt state is unknown (at
-- most SHELL_READY_WAIT_S, then "ready").
function jobs.ready(cx: WindowCx, task: any): string
	local shell = task.shell_pane
	local info = if type(shell) == "number" then cx.session:pane(shell) else nil
	if info == nil then
		return "noshell"
	end
	if info.at_prompt == true and info.busy ~= true then
		task.job_wait_since = nil
		return "ready"
	end
	task.job_wait_since = task.job_wait_since or os.time()
	local waited = os.time() - task.job_wait_since
	if info.busy == true or info.at_prompt == false then
		return if waited >= const.SHELL_BUSY_BLOCK_S then "busy" else "wait"
	end
	return if waited >= const.SHELL_READY_WAIT_S then "ready" else "wait"
end

-- Allocates the next job directory of `task` for `kind`: (seq, dir).
function jobs.alloc(task: any, kind: string): (number, string)
	local seq = (task.job_seq or 0) + 1
	local dir = paths.task_dir(task.project, task.slug) .. "/jobs/" .. seq .. "-" .. kind
	tern.fs.mkdir(dir)
	return seq, dir
end

local function script(task: any, kind: string, dir: string, steps: { Step }, stop_on_fail: boolean, env: { [string]: string }): string
	local lines = {
		"#!/bin/sh",
		"# Tern Swarm " .. kind .. " job for " .. task.slug,
		"J=" .. sh.quote(dir),
		"cd " .. sh.quote(task.worktree) .. ' || { echo 1 > "$J/done"; exit 1; }',
		"overall=0",
		"step() {",
		"  name=$1; cmd=$2",
		"  printf '\\n\\033[1m▸ %s\\033[0m %s\\n' \"$name\" \"$cmd\"",
		"  t0=$(date +%s)",
		'  { sh -c "$cmd"; echo $? > "$J/$name.status"; } 2>&1 | tee "$J/$name.log"',
		'  echo $(( $(date +%s) - t0 )) > "$J/$name.secs"',
		'  tail -c ' .. const.TAIL_BYTES .. ' "$J/$name.log" > "$J/$name.tail"',
		'  st=$(cat "$J/$name.status" 2>/dev/null || echo 1)',
		"  if [ \"$st\" != 0 ]; then overall=1; printf '\\033[31m✗ %s (exit %s)\\033[0m\\n' \"$name\" \"$st\"; else printf '\\033[32m✓ %s\\033[0m\\n' \"$name\"; fi",
		'  return "$st"',
		"}",
	}
	-- Exports go right after the `cd` line, sorted by name.
	local env_names: { string } = {}
	for name in env do
		table.insert(env_names, name)
	end
	table.sort(env_names)
	for i, name in env_names do
		table.insert(lines, 4 + i, "export " .. name .. "=" .. sh.quote(env[name]))
	end
	local on_fail = if stop_on_fail then '{ echo 1 > "$J/done"; exit 1; }' else "true"
	for _, s in steps do
		table.insert(lines, "step " .. sh.quote(s.name) .. " " .. sh.quote(s.run) .. " || " .. on_fail)
	end
	table.insert(lines, 'echo "$overall" > "$J/done"')
	return table.concat(lines, "\n") .. "\n"
end

-- Writes the job script into `dir` (from jobs.alloc) and types it into the shell. False when typing failed.
function jobs.launch(cx: WindowCx, task: any, kind: string, steps: { Step }, stop_on_fail: boolean, seq: number, dir: string, run: RunOpts): boolean
	store.write_text(dir .. "/run.sh", script(task, kind, dir, steps, stop_on_fail, run.env))
	local ok, err = pcall(function()
		cx:run(task.shell_pane, " sh " .. sh.quote(dir .. "/run.sh") .. "\r")
	end)
	if not ok then
		tern.log.warn("swarm: could not type the job into the shell", err)
		return false
	end
	task.job_seq = seq
	task.job = { kind = kind, seq = seq, dir = dir, started = os.time(), steps = steps, timeout_s = run.timeout_s }
	task.job_wait_since = nil
	return true
end

-- Starts a job when the shell is ready: "started", "error", or jobs.ready's "wait", "noshell" or "busy".
function jobs.start(cx: WindowCx, task: any, kind: string, steps: { Step }, stop_on_fail: boolean, run: RunOpts): string
	local ready = jobs.ready(cx, task)
	if ready ~= "ready" then
		return ready
	end
	local seq, dir = jobs.alloc(task, kind)
	return if jobs.launch(cx, task, kind, steps, stop_on_fail, seq, dir, run) then "started" else "error"
end

local function results(job: any): { any }
	local out: { any } = {}
	for _, s in job.steps or {} do
		local status = read_small(job.dir .. "/" .. s.name .. ".status", 64)
		local secs = read_small(job.dir .. "/" .. s.name .. ".secs", 64)
		table.insert(out, {
			name = s.name,
			run = s.run,
			status = if status then tonumber(text.trim(status)) else nil,
			secs = if secs then tonumber(text.trim(secs)) else nil,
		})
	end
	return out
end

-- The finished job's outcome {status = "passed"|"failed"|"aborted"|"timeout", steps}, or nil while it runs.
function jobs.poll(cx: WindowCx, task: any): any
	local job = task.job
	if job == nil then
		return nil
	end
	local done = read_small(job.dir .. "/done", 64)
	if done then
		return { status = if text.trim(done) == "0" then "passed" else "failed", steps = results(job) }
	end
	local shell = task.shell_pane
	local info = if type(shell) == "number" then cx.session:pane(shell) else nil
	if info == nil then
		return { status = "aborted", steps = results(job) }
	end
	local age = os.time() - (job.started or os.time())
	if age > 5 and info.busy == false and info.at_prompt == true then
		return { status = "aborted", steps = results(job) }
	end
	if age > (job.timeout_s or 1800) then
		pcall(function()
			cx:run(shell, "\3")
		end)
		return { status = "timeout", steps = results(job) }
	end
	return nil
end

-- The captured output tail of step `name` of the task's last job.
function jobs.tail(job: any, name: string): string
	return read_small(job.dir .. "/" .. name .. ".tail", 16384) or ""
end

return jobs
