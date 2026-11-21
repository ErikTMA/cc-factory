-- base: touch-monitor dispatcher for any number of oreminer turtles.
--
-- Setup: an advanced computer with an advanced monitor (4 wide x 3 high is
-- comfortable) and a wireless modem, within modem range of the turtles' homes.
-- Needs oreconf.lua next to it. Run: base   (add to startup to auto-start)
--
-- Pick an ore (or "all ores"), the Y level and how many, then press START to
-- queue a job. Every turtle running `oreminer serve` takes the next queued job
-- when it is home. Each job gets its own mining sector at its Y level, so
-- turtles never mine the same area twice. Tap a turtle to select it; STOP stops
-- the selected turtle (delivered next time it is home) or, with no turtle
-- selected, cancels the last queued job.

local C = require("oreconf")

local QTY = { 8, 16, 32, 64, 128, 256, 0 } -- 0 = no limit (mine all lanes)
local STATE_FILE = "base.state"

local M = {}

local function now() return os.epoch("utc") / 1000 end

function M.new()
  local first = C.PRESETS[1]
  return {
    sel = { ore = first.name, y = first.y, onlyThis = true, qty = 3, lanes = 3, length = 64 },
    turtles = {},     -- [id] = { id, label, state, fuel, mined, job, seen }
    queue = {},       -- jobs waiting for an idle turtle
    stopFor = {},     -- [id] = true: stop delivered next time that turtle is home
    nextJobId = 1,
    nextSector = {},  -- [y] = next free lane index at that Y level
    totals = {},      -- [ore or "all"] = ore mined by finished jobs
    counted = {},     -- [job id] = true once its result is in totals
    selected = nil,   -- selected turtle id
    note = "Pick an ore and press START",
    buttons = {},
  }
end

-- ---------------------------------------------------------- persistence --
local PERSIST = { "turtles", "queue", "nextJobId", "nextSector", "totals", "counted" }

function M.save(B)
  local t = {}
  for _, k in ipairs(PERSIST) do t[k] = B[k] end
  local f = fs.open(STATE_FILE, "w")
  f.write(textutils.serialize(t))
  f.close()
end

function M.load(B)
  if not fs.exists(STATE_FILE) then return end
  local f = fs.open(STATE_FILE, "r")
  local t = textutils.unserialize(f.readAll())
  f.close()
  if type(t) == "table" then
    for _, k in ipairs(PERSIST) do if t[k] ~= nil then B[k] = t[k] end end
  end
end

-- --------------------------------------------------------------- helpers --
local function presetY(name)
  for _, p in ipairs(C.PRESETS) do if p.name == name then return p.y end end
end

local function oreKey(job) return job and (job.only or "all") or "-" end

local function jobText(job)
  if not job then return "-" end
  return ("%s%s @Y%s"):format(job.quantity and (job.quantity .. "x ") or "",
    job.only or "all ores", tostring(job.y))
end

-- [ore] = { turtles = n busy on it, mined = finished + in progress, queued = n }
function M.summary(B)
  local s = {}
  local function row(k)
    s[k] = s[k] or { turtles = 0, mined = B.totals[k] or 0, queued = 0 }
    return s[k]
  end
  for k in pairs(B.totals) do row(k) end
  for _, t in pairs(B.turtles) do
    if t.job and t.state ~= "idle" and t.state ~= "done" then
      local r = row(oreKey(t.job))
      r.turtles = r.turtles + 1
      r.mined = r.mined + (t.mined or 0)
    end
  end
  for _, j in ipairs(B.queue) do local r = row(oreKey(j)); r.queued = r.queued + 1 end
  return s
end

-- ------------------------------------------------------------- protocol --
-- Turtles always talk first (a status while home); we answer with a job, a
-- stop or a plain ok.
function M.handleMessage(B, from, msg)
  if type(msg) ~= "table" or msg.type ~= "status" then return nil end
  B.turtles[from] = { id = from, label = msg.label, state = msg.state, fuel = msg.fuel,
                      mined = msg.mined or 0, job = msg.job, seen = now() }
  local reply = { type = "ok" }

  if msg.state == "done" and msg.job and msg.job.id and not B.counted[msg.job.id] then
    B.counted[msg.job.id] = true
    local k = oreKey(msg.job)
    B.totals[k] = (B.totals[k] or 0) + (msg.mined or 0)
    B.note = ("%s finished: %d %s"):format(msg.label or ("#" .. from), msg.mined or 0, k)
  end

  if msg.state == "idle" or msg.state == "done" then
    B.stopFor[from] = nil
    if msg.state == "idle" and #B.queue > 0 then
      local job = table.remove(B.queue, 1)
      B.turtles[from].job, B.turtles[from].mined, B.turtles[from].state = job, 0, "assigned"
      B.note = ("%s took job: %s"):format(msg.label or ("#" .. from), jobText(job))
      reply = { type = "job", job = job }
    end
  elseif B.stopFor[from] then
    B.stopFor[from] = nil
    B.note = ("Stop delivered to %s"):format(msg.label or ("#" .. from))
    reply = { type = "stop" }
  end
  M.save(B)
  return reply
end

-- --------------------------------------------------------------- actions --
function M.selectOre(B, name) B.sel.ore, B.sel.y = name, presetY(name) end
function M.toggleOnly(B) B.sel.onlyThis = not B.sel.onlyThis end
function M.addY(B, d) B.sel.y = math.max(-64, math.min(319, B.sel.y + d)) end
function M.qtyStep(B, d) B.sel.qty = math.max(1, math.min(#QTY, B.sel.qty + d)) end

function M.selectTurtle(B, id)
  B.selected = (B.selected ~= id) and id or nil
end

function M.start(B)
  local q = QTY[B.sel.qty]
  local y = B.sel.y
  -- each job gets fresh lanes at its level, so no two jobs mine the same area
  local sector = B.nextSector[y] or 0
  B.nextSector[y] = sector + B.sel.lanes
  local job = {
    id = B.nextJobId,
    only = B.sel.onlyThis and B.sel.ore or nil,
    y = y,
    quantity = q > 0 and q or nil,
    lanes = B.sel.lanes, length = B.sel.length,
    sector = sector,
  }
  B.nextJobId = B.nextJobId + 1
  B.queue[#B.queue + 1] = job
  B.note = ("Queued #%d: %s (%d in queue)"):format(job.id, jobText(job), #B.queue)
  M.save(B)
end

function M.stop(B)
  local t = B.selected and B.turtles[B.selected]
  if t then
    if t.state == "idle" or t.state == "done" then
      B.note = (t.label or ("#" .. t.id)) .. " is not working"
    else
      B.stopFor[t.id] = true
      B.note = "Stop for " .. (t.label or ("#" .. t.id)) .. ": delivered next time it is home"
    end
  elseif #B.queue > 0 then
    local j = table.remove(B.queue)
    B.note = ("Cancelled queued #%d: %s"):format(j.id, jobText(j))
  else
    B.note = "Select a turtle to stop it"
  end
  M.save(B)
end

-- ------------------------------------------------------------------ draw --
local function put(out, x, y, text, fg, bg)
  out.setCursorPos(x, y)
  out.setTextColor(fg or colors.white)
  out.setBackgroundColor(bg or colors.black)
  out.write(text)
end

local function button(B, out, x, y, w, label, on, action)
  local text = (" " .. label .. string.rep(" ", w)):sub(1, w)
  put(out, x, y, text, on and colors.black or colors.white, on and colors.lime or colors.gray)
  B.buttons[#B.buttons + 1] = { x1 = x, x2 = x + w - 1, y = y, label = label, action = action }
end

local STATE_COLOR = { idle = colors.lightGray, done = colors.lightGray, assigned = colors.yellow,
                      unloading = colors.cyan }

function M.draw(B, out)
  B.buttons = {}
  out.setBackgroundColor(colors.black)
  out.clear()
  local w, h = out.getSize()

  -- turtles
  put(out, 1, 1, "TURTLES", colors.yellow)
  local ids = {}
  for id in pairs(B.turtles) do ids[#ids + 1] = id end
  table.sort(ids)
  local row = 2
  for _, id in ipairs(ids) do
    local t = B.turtles[id]
    local age = math.floor(now() - (t.seen or 0))
    local text = ("%-9s %-9s %-20s %4d  f%-6s %ds"):format(
      (t.label or ("#" .. id)):sub(1, 9), t.state, jobText(t.job):sub(1, 20),
      t.mined or 0, tostring(t.fuel), age)
    local sel = B.selected == id
    put(out, 1, row, (text .. string.rep(" ", w)):sub(1, w),
      sel and colors.black or (STATE_COLOR[t.state] or colors.white),
      sel and colors.white or colors.black)
    B.buttons[#B.buttons + 1] = { x1 = 1, x2 = w, y = row, label = "turtle " .. id,
                                  action = function() M.selectTurtle(B, id) end }
    row = row + 1
  end
  if #ids == 0 then put(out, 1, row, "none yet (run: oreminer serve)", colors.red); row = row + 1 end

  -- summary per ore
  row = row + 1
  put(out, 1, row, "FETCHING", colors.yellow)
  row = row + 1
  local s, keys = M.summary(B), {}
  for k in pairs(s) do keys[#keys + 1] = k end
  table.sort(keys)
  local line = ""
  for _, k in ipairs(keys) do
    local r = s[k]
    line = line .. ("%s: %d mined, %d turtle%s%s   "):format(k, r.mined, r.turtles,
      r.turtles == 1 and "" or "s", r.queued > 0 and (", " .. r.queued .. " queued") or "")
  end
  for i = 1, #line, w do
    put(out, 1, row, line:sub(i, i + w - 1), colors.lightGray); row = row + 1
  end
  if #keys == 0 then put(out, 1, row, "-", colors.lightGray); row = row + 1 end

  -- new job
  row = row + 1
  put(out, 1, row, "NEW JOB", colors.yellow)
  row = row + 1
  local cols = math.max(1, math.floor(w / 10))
  local bw = math.floor(w / cols)
  for i, p in ipairs(C.PRESETS) do
    button(B, out, ((i - 1) % cols) * bw + 1, row + math.floor((i - 1) / cols), bw - 1,
      p.name, B.sel.ore == p.name, function() M.selectOre(B, p.name) end)
  end
  row = row + math.floor((#C.PRESETS - 1) / cols) + 1

  put(out, 1, row, ("Y %4d "):format(B.sel.y))
  button(B, out, 8, row, 4, "-8", false, function() M.addY(B, -8) end)
  button(B, out, 13, row, 4, "-1", false, function() M.addY(B, -1) end)
  button(B, out, 18, row, 4, "+1", false, function() M.addY(B, 1) end)
  button(B, out, 23, row, 4, "+8", false, function() M.addY(B, 8) end)
  row = row + 1

  local q = QTY[B.sel.qty]
  put(out, 1, row, ("Qty %4s "):format(q > 0 and tostring(q) or "all"))
  button(B, out, 10, row, 3, "<", false, function() M.qtyStep(B, -1) end)
  button(B, out, 14, row, 3, ">", false, function() M.qtyStep(B, 1) end)
  button(B, out, 18, row, 14, "only " .. B.sel.ore, B.sel.onlyThis, function() M.toggleOnly(B) end)
  button(B, out, 33, row, 10, "all ores", not B.sel.onlyThis, function() M.toggleOnly(B) end)
  row = row + 2

  button(B, out, 1, row, 14, ("START (%d)"):format(#B.queue), false, function() M.start(B) end)
  button(B, out, 16, row, 14, B.selected and "STOP turtle" or "CANCEL last", false,
    function() M.stop(B) end)
  row = row + 2

  if row <= h then put(out, 1, row, B.note:sub(1, w), colors.orange) end
end

function M.touch(B, x, y)
  for _, b in ipairs(B.buttons) do
    if y == b.y and x >= b.x1 and x <= b.x2 then b.action(); return b.label end
  end
end

-- ------------------------------------------------------------------ main --
local args = { ... }
if args[1] == "--lib" then return M end

local mon = peripheral.find("monitor")
local out = mon or term
if mon then mon.setTextScale(0.5) end
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Attach a wireless modem", 0) end
rednet.open(peripheral.getName(modem))

local B = M.new()
M.load(B)
M.draw(B, out)
local timer = os.startTimer(1)
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "rednet_message" and ev[4] == C.PROTOCOL then
    local reply = M.handleMessage(B, ev[2], ev[3])
    if reply then rednet.send(ev[2], reply, C.PROTOCOL) end
  elseif ev[1] == "monitor_touch" or ev[1] == "mouse_click" then
    M.touch(B, ev[3], ev[4])
  elseif ev[1] == "timer" and ev[2] == timer then
    timer = os.startTimer(1)
  end
  M.draw(B, out)
end
