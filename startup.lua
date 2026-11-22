-- cc-factory turtle agent: startup.lua on every turtle.
--
-- Starts the turtle's role program after every boot (and after server
-- restarts, which resume unfinished work). The role lives in agent.cfg,
-- written by the installer disk or by the base (role change).
--   miner      oreminer serve   (jobs from the base)
--   forester   forester         (tree farm, reports each round)
--   assembler  assembler        (builds new turtles for the base)
--   surveyor   surveyor         (maps the wired network, registers homes)
--   gps        gps host x y z   (one of four GPS hosts above the base)
-- A turtle fresh from the assembler first walks to the home slot the base
-- gives it (travel.lua).

local link = require("link")
local cfg = link.config()

-- Every error a program shows (shell prints them with printError) also goes
-- to crash.log, with the time: readable on the server when nobody watches the
-- turtle's screen.
local printErrorOrig = printError
printError = function(...)
  local args = { n = select("#", ...), ... }
  pcall(function()
    local parts = {}
    for i = 1, args.n do parts[#parts + 1] = tostring(args[i]) end
    local f = fs.open("crash.log", "a")
    f.write(("[day %d %s] %s\n"):format(os.day(), textutils.formatTime(os.time(), true), table.concat(parts, " ")))
    f.close()
  end)
  return printErrorOrig(...)
end

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
elseif cfg.role == "gps" then
  -- a GPS host: its point (home frame) came with the install data
  local h = cfg.host
  if not h then print("GPS turtle without a host point"); return end
  local modem = link.equippedSide("modem")
  if modem then rednet.open(modem) end
  shell.run("gps", "host", tostring(h.x), tostring(h.y), tostring(h.z))
else
  print("cc-factory turtle without a role. Set one in agent.cfg, e.g.")
  print('  { role = "miner", base = <base computer id> }')
end
