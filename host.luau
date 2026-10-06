--!strict
-- Tern Swarm host half: the "New Swarm Task" form block (kind swarm.new-task) and the
-- "Swarm Settings" page (kind swarm.settings).

tern.block.define("new-task", require("./blocks/new-task"))
tern.block.define("settings", require("./blocks/settings"))
