-- cc-factory turtle agent: startup.lua on every turtle.
--
-- Starts the turtle's role program after every boot (and after server
-- restarts, which resume unfinished work). The role lives in agent.cfg,
-- written by the installer disk or by the base (role change).
--   miner      oreminer serve   (jobs from the base)
--   forester   forester         (tree farm, reports each round)
--   assembler  assembler        (builds new turtles for the base)
--   surveyor   surveyor         (maps the wired network, registers homes)
-- A turtle fresh from the assembler first walks to the home slot the base
-- gives it (travel.lua).

local link = require("link")
local cfg = link.config()

-- installs from before agent.cfg existed: work the role out from the files
if not cfg.role then
  if fs.exists("forester.state") then cfg.role = "forester"
  elseif fs.exists("oreminer.home") or fs.exists("oreminer.state") then cfg.role = "miner" end
  if cfg.role then link.saveConfig(cfg) end
end

if cfg.role and cfg.needsHome then
  require("travel").toHomeSlot()
  cfg = link.config()
end

if cfg.role == "miner" then
  if fs.exists("oreminer.home") then
    shell.run("oreminer", "serve")
  elseif cfg.home then
    shell.run("oreminer", "serve", "at=" .. cfg.home.y, "heading=" .. cfg.home.heading)
  elseif fs.exists("oreminer.state") then
    shell.run("oreminer", "resume")
  else
    print("Miner without a home: run 'oreminer serve' once here.")
  end
elseif cfg.role == "forester" then
  shell.run("forester", tostring(cfg.trees or ""), tostring(cfg.wait or ""))
elseif cfg.role == "assembler" then
  shell.run("assembler")
elseif cfg.role == "surveyor" then
  shell.run("surveyor", "resume")
else
  print("cc-factory turtle without a role. Set one in agent.cfg, e.g.")
  print('  { role = "miner", base = <base computer id> }')
end
