-- base: the factory's control computer (screen + wiring).
--
-- Install with the starter script (see README): it downloads this and the
-- turtle code from GitHub. Peripherals:
--   wireless modem            talks to turtles
--   advanced monitor          touch screen (else the terminal; mouse works)
--   wired modem network       barrels (storage) or an ME/RS bridge, chests
--                             (turtle home chests, drained into storage), the
--                             trapped supply chest above the assembler, and the
--                             installer disk drive under the build spot
-- Settings live in /factory.cfg (written with defaults on first start; edit it
-- with `edit factory.cfg`, then restart the base).
--
-- Decisions are in factory.lua; this file draws the screen and wires the real
-- peripherals, clock, storage and code release into it.

local C = require("oreconf")
local factory = require("factory")

local M = {}

-- ------------------------------------------------------------------ draw --
local function put(out, x, y, text, fg, bg)
  out.setCursorPos(x, y)
  out.setTextColor(fg or colors.white)
  out.setBackgroundColor(bg or colors.black)
  out.write(text)
end

local function button(UI, out, x, y, w, label, on, action)
  local text = (" " .. label .. string.rep(" ", w)):sub(1, w)
  put(out, x, y, text, on and colors.black or colors.white, on and colors.lime or colors.gray)
  UI.buttons[#UI.buttons + 1] = { x1 = x, x2 = x + w - 1, y = y, label = label, action = action }
end

local STATE_COLOR = { idle = colors.lightGray, done = colors.lightGray, resting = colors.lightGray,
                      assigned = colors.yellow, unloading = colors.cyan, new = colors.magenta }

local TABS = { "TURTLES", "JOBS", "FACTORY" }

local function drawTurtles(UI, out, w, row)
  local F = UI.F
  local ids = {}
  for id in pairs(F.turtles) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local t = F.turtles[id]
    local what = t.role == "miner" and factory.jobText(t.job)
              or t.role == "forester" and ("%d logs"):format(t.delivered or 0)
              or t.role
    local text = ("%-11s %-9s %-9s %-18s %4d f%-6s %ds"):format(
      (t.label or ("#" .. id)):sub(1, 11), t.role or "?", t.state or "?", tostring(what):sub(1, 18),
      t.mined or 0, tostring(t.fuel), math.floor(F.deps.now() - (t.seen or 0)))
    local sel = F.selected == id
    put(out, 1, row, (text .. string.rep(" ", w)):sub(1, w),
      sel and colors.black or (STATE_COLOR[t.state] or colors.white), sel and colors.white or colors.black)
    UI.buttons[#UI.buttons + 1] = { x1 = 1, x2 = w, y = row, label = "turtle " .. id,
                                    action = function() factory.selectTurtle(F, id) end }
    row = row + 1
  end
  if #ids == 0 then put(out, 1, row, "No turtles yet", colors.red); row = row + 1 end
  row = row + 1
  put(out, 1, row, "FETCHING", colors.yellow)
  row = row + 1
  local s, keys = factory.summary(F), {}
  for k in pairs(s) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local r = s[k]
    put(out, 1, row, ("%-10s %6d mined  %d turtle%s%s"):format(k, r.mined, r.turtles,
      r.turtles == 1 and "" or "s", r.queued > 0 and (", " .. r.queued .. " queued") or ""), colors.lightGray)
    row = row + 1
  end
  row = row + 1
  button(UI, out, 1, row, 16, F.selected and "STOP turtle" or "CANCEL last job", false,
    function() factory.stop(F) end)
  return row + 2
end

local function drawJobs(UI, out, w, row)
  local F = UI.F
  local cols = math.max(1, math.floor(w / 10))
  local bw = math.floor(w / cols)
  for i, p in ipairs(C.PRESETS) do
    button(UI, out, ((i - 1) % cols) * bw + 1, row + math.floor((i - 1) / cols), bw - 1,
      p.name, F.sel.ore == p.name, function() factory.selectOre(F, p.name) end)
  end
  row = row + math.floor((#C.PRESETS - 1) / cols) + 2
  put(out, 1, row, ("Y %4d "):format(F.sel.y))
  for i, d in ipairs({ -8, -1, 1, 8 }) do
    button(UI, out, 3 + i * 5, row, 4, (d > 0 and "+" or "") .. d, false, function() factory.addY(F, d) end)
  end
  row = row + 1
  local q = factory.QTY[F.sel.qty]
  put(out, 1, row, ("Qty %4s "):format(q > 0 and tostring(q) or "all"))
  button(UI, out, 10, row, 3, "<", false, function() factory.qtyStep(F, -1) end)
  button(UI, out, 14, row, 3, ">", false, function() factory.qtyStep(F, 1) end)
  button(UI, out, 18, row, 14, "only " .. F.sel.ore, F.sel.onlyThis, function() factory.toggleOnly(F) end)
  button(UI, out, 33, row, 10, "all ores", not F.sel.onlyThis, function() factory.toggleOnly(F) end)
  row = row + 2
  button(UI, out, 1, row, 16, ("START (%d queued)"):format(#F.queue), false, function() factory.start(F) end)
  return row + 2
end

local function drawFactory(UI, out, w, row)
  local F = UI.F
  local stock = UI.stock or {}
  put(out, 1, row, ("Storage: %s   code %s"):format(F.deps.storage.kind,
    F.deps.dist and F.deps.dist.version or "none"), colors.lightGray)
  row = row + 1
  button(UI, out, w - 9, row - 1, 10, "UPDATE", false, function() UI.wantUpdate = true end)
  row = row + 1
  put(out, 1, row, "STOCK RULES", colors.yellow)
  row = row + 1
  if #F.cfg.rules == 0 then put(out, 1, row, "none (factory.cfg: rules)", colors.lightGray); row = row + 1 end
  for i, r in ipairs(F.cfg.rules) do
    local have = stock[r.item] or 0
    put(out, 1, row, ("%-26s %6d / %-6d %s"):format(r.item:gsub("^minecraft:", ""):sub(1, 26), have, r.min,
      F.ruleJobs[i] and "mining" or ""), have < r.min and colors.orange or colors.lime)
    row = row + 1
  end
  row = row + 1
  put(out, 1, row, "FLEET", colors.yellow)
  row = row + 1
  for role, want in pairs(F.cfg.fleet) do
    local have = 0
    for _, t in pairs(F.turtles) do if t.role == role then have = have + 1 end end
    local missing = factory.missingParts(F, role)
    local need = ""
    for item, n in pairs(missing) do need = need .. (" %dx%s"):format(n, item:gsub("^%w+:", "")) end
    put(out, 1, row, ("%-9s %d / %d  %s"):format(role, have, want,
      have < want and (need ~= "" and ("needs" .. need) or "parts ready") or ""):sub(1, w), colors.lightGray)
    button(UI, out, w - 9, row, 10, "BUILD", false, function() factory.orderTurtle(F, role) end)
    row = row + 1
  end
  row = row + 1
  put(out, 1, row, "BUILDS", colors.yellow)
  row = row + 1
  for i = math.max(1, #F.orders - 3), #F.orders do
    local o = F.orders[i]
    put(out, 1, row, ("#%d %s: %s%s"):format(o.id, o.role, o.state,
      o.reason and (" - " .. o.reason) or ""):sub(1, w), o.state == "failed" and colors.red or colors.lightGray)
    row = row + 1
  end
  return row + 1
end

function M.draw(UI, out)
  UI.buttons = {}
  out.setBackgroundColor(colors.black)
  out.clear()
  local w, h = out.getSize()
  local x = 1
  for _, tab in ipairs(TABS) do
    button(UI, out, x, 1, #tab + 2, tab, UI.tab == tab, function() UI.tab = tab end)
    x = x + #tab + 3
  end
  local row = 3
  if UI.tab == "TURTLES" then row = drawTurtles(UI, out, w, row)
  elseif UI.tab == "JOBS" then row = drawJobs(UI, out, w, row)
  else row = drawFactory(UI, out, w, row) end
  put(out, 1, h, UI.F.note:sub(1, w), colors.orange)
end

function M.touch(UI, x, y)
  for _, b in ipairs(UI.buttons) do
    if y == b.y and x >= b.x1 and x <= b.x2 then b.action(); return b.label end
  end
end

-- ------------------------------------------------------------------ main --
local args = { ... }
if args[1] == "--lib" then return M end

local function readTable(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = textutils.unserialize(f.readAll())
  f.close()
  return t
end

local function writeTable(path, t)
  local f = fs.open(path, "w")
  f.write(textutils.serialize(t))
  f.close()
end

local storage = require("storage")
local dist = require("dist")

if args[1] == "probe" then
  -- check a storage bridge's export/import argument order on the real thing
  local S = storage.open(peripheral)
  print("storage: " .. S.kind .. ", supply chest: " .. tostring(S.supply()))
  local stock = S.list()
  local item = next(stock)
  if not item or not S.supply() then print("need one item in storage and a supply chest"); return end
  print("export 1 " .. item .. " -> supply: " .. tostring(S.send(S.supply(), item, 1)))
  print("import supply -> storage: " .. tostring(S.store(S.supply())))
  return
end

local config = readTable("/factory.cfg")
if not config then
  config = factory.DEFAULT_CONFIG
  writeTable("/factory.cfg", config)
  print("Wrote /factory.cfg with defaults; edit it to set homes, fleet and rules.")
end
for k, v in pairs(factory.DEFAULT_CONFIG) do if config[k] == nil then config[k] = v end end

local manifest = fs.exists("/manifest.lua") and dofile("/manifest.lua")
local release = manifest and dist.load(manifest, "/dist")

-- talk to turtles over every modem: wireless, and wired (turtles at home
-- slots with a wired modem next to them, cabled to this network)
local modems = 0
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" then rednet.open(name); modems = modems + 1 end
end
if modems == 0 then error("Attach a modem (wired and/or wireless)", 0) end

local F = factory.new(config, {
  storage = storage.open(peripheral),
  now = function() return os.epoch("utc") / 1000 end,
  dist = release,
  writeInstall = function(install)
    if not release then return end
    install.base = os.getComputerID()
    dist.writeDisk(peripheral, release, install)
  end,
})
factory.restore(F, readTable("/base.state"))
if release then
  dist.writeDisk(peripheral, release, { base = os.getComputerID(), role = "miner" })
end

local UI = { F = F, tab = "TURTLES", buttons = {} }
local mon = peripheral.find("monitor")
local out = mon or term
if mon then mon.setTextScale(0.5) end

local function persist() writeTable("/base.state", factory.snapshot(F)) end

local function update()
  F.note = "Updating from GitHub..."
  M.draw(UI, out)
  persist()
  shell.run("/bootstrap.lua")
  os.reboot()
end

local timer = os.startTimer(1)
local lastTick = 0
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "rednet_message" and ev[4] == C.PROTOCOL then
    local reply = factory.handle(F, ev[2], ev[3])
    if reply then rednet.send(ev[2], reply, C.PROTOCOL) end
    persist()
  elseif ev[1] == "monitor_touch" or ev[1] == "mouse_click" then
    M.touch(UI, ev[3], ev[4])
    persist()
  elseif ev[1] == "timer" and ev[2] == timer then
    timer = os.startTimer(1)
    if os.clock() - lastTick >= 10 then
      lastTick = os.clock()
      local ok, stock = pcall(factory.tick, F)
      if ok then UI.stock = stock else F.note = "tick: " .. tostring(stock) end
      persist()
    end
  end
  if UI.wantUpdate then update() end
  M.draw(UI, out)
end
