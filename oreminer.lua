-- oreminer: Geo Scanner mining turtle (CC: Tweaked + Advanced Peripherals)
--
-- Setup: an advanced mining turtle with a diamond pickaxe on one side and a
-- Geo Scanner on the other. Place it at the surface with a chest directly
-- BEHIND it. Put coal in it. Needs oreconf.lua next to it.
--
-- Run by hand:
--   oreminer diamond            go down to the best diamond level, mine only diamonds
--   oreminer diamond all        same level, but mine every ore found there
--   oreminer diamond qty=32     stop after 32 diamond ore
--   oreminer y=-30              go to Y -30 and mine every ore
--   oreminer y=-30 only=osmium  go to Y -30, mine only ores matching "osmium"
--   oreminer                    mine every ore at the turtle's own level
--   options: at=<Y> (turtle's current Y, asked if missing), lanes=<n>, length=<n>
--
-- Or controlled from the base computer (base.lua):
--   oreminer serve              wait at home for jobs from the base
--   With a wireless modem in its inventory, it swaps the modem in for the Geo
--   Scanner while at home, reports to the base and picks up jobs or a stop.
--
-- It digs a shaft down from home, mines lanes ahead of (and to the right of)
-- the shaft, scanning every 16 blocks and digging only matching ore, nearest
-- first. When full or low on fuel it goes back up the shaft, empties into the
-- chest and continues. Progress is saved after every move, so startup.lua
-- carries on after a server restart or chunk unload.

local C = require("oreconf")
local tmove = require("tmove")
local link = require("link")

local CFG = {
  radius = 8,          -- scan radius; 8 is free on this server, 9-16 costs fuel
  spacing = 16,        -- blocks between scans along a lane (2*radius covers all)
  lanes = 3,           -- parallel lanes, each `spacing` to the right of the last
  length = 64,         -- lane length in blocks
  fuelMargin = 100,    -- head home when fuel < distance home + this
  stateFile = "oreminer.state",
  homeFile = "oreminer.home",
  -- ores whose name matches any of these are left alone
  skip = { },
  -- dropped while mining to save space (only when inventory gets tight)
  junk = {
    ["minecraft:cobblestone"] = true, ["minecraft:cobbled_deepslate"] = true,
    ["minecraft:dirt"] = true, ["minecraft:gravel"] = true,
    ["minecraft:andesite"] = true, ["minecraft:diorite"] = true,
    ["minecraft:granite"] = true, ["minecraft:tuff"] = true,
    ["minecraft:netherrack"] = true, ["minecraft:calcite"] = true,
    ["minecraft:sand"] = true, ["minecraft:flint"] = true,
  },
  -- never dig these (other turtles, computers, storage)
  protect = { "^computercraft:", "chest", "barrel", "shulker", "spawner" },
}

local PRESET_Y = {}
for _, p in ipairs(C.PRESETS) do PRESET_Y[p.name] = p.y end

-- Headings in world axes: 0 north(-z), 1 east(+x), 2 south(+z), 3 west(-x)
local DIRS = { [0] = { 0, 0, -1 }, { 1, 0, 0 }, { 0, 0, 1 }, { -1, 0, 0 } }
local HEADING_NAME = { [0] = "north", "east", "south", "west" }

-- Persisted job state: pos{x,y,z}, heading, homeHeading, lane, progress,
-- lanes, length, dy, only, quantity, mined, stop, done, job
local S
local HOME = { x = 0, y = 0, z = 0 }

local function log(...) print(...) end

local function writeFile(path, value)
  local f = fs.open(path, "w")
  f.write(textutils.serialize(value))
  f.close()
end

local function readFile(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local v = textutils.unserialize(f.readAll())
  f.close()
  return v
end

local function save() writeFile(CFG.stateFile, S) end

local function key(x, y, z) return x .. "," .. y .. "," .. z end

local function dist(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

-- -------------------------------------------------------------- equipment --
-- The Geo Scanner shares its upgrade slot with the wireless modem (link.lua).
local function ensureScanner()
  link.restoreUpgrade()
  return link.equippedSide("geoScanner") ~= nil
end

-- ---------------------------------------------------------------- scanner --
local function scan()
  while true do
    local scanner = peripheral.find("geoScanner")
    if not scanner then error("No Geo Scanner equipped", 0) end
    local blocks, err = scanner.scan(CFG.radius)
    if blocks then return blocks end
    if tostring(err):lower():find("cooldown") then
      sleep(0.5)
    else
      error("scan failed: " .. tostring(err), 0)
    end
  end
end

local function isOre(b)
  for _, pat in ipairs(CFG.skip) do
    if b.name:find(pat) then return false end
  end
  local ore = b.name:find("_ore$") ~= nil
  if not ore and b.tags then
    for _, t in ipairs(b.tags) do
      if t == "c:ores" or t:find("^c:ores/") or t:find("^forge:ores") then ore = true; break end
    end
  end
  if not ore or not S.only then return ore end
  -- restricted to one ore kind: match the block name or its c:ores/<kind> tag
  if b.name:find(S.only, 1, true) then return true end
  for _, t in ipairs(b.tags or {}) do
    if t == "c:ores/" .. S.only then return true end
  end
  return false
end

local function isProtected(name)
  for _, pat in ipairs(CFG.protect) do
    if name:find(pat) then return true end
  end
  return false
end

-- ---------------------------------------------------------------- movement --
local function turnTo(h)
  local diff = (h - S.heading) % 4
  if diff == 1 then turtle.turnRight()
  elseif diff == 2 then turtle.turnRight(); turtle.turnRight()
  elseif diff == 3 then turtle.turnLeft() end
  S.heading = h
  save()
end

local MOVES = {
  fwd = { move = turtle.forward, dig = turtle.dig, detect = turtle.detect,
          inspect = turtle.inspect, attack = turtle.attack },
  up = { move = turtle.up, dig = turtle.digUp, detect = turtle.detectUp,
         inspect = turtle.inspectUp, attack = turtle.attackUp, dy = 1 },
  down = { move = turtle.down, dig = turtle.digDown, detect = turtle.detectDown,
           inspect = turtle.inspectDown, attack = turtle.attackDown, dy = -1 },
}

-- Position update for a completed move (also replayed by tmove.recover).
local function applyMove(st, kind)
  if kind == "fwd" then
    local d = DIRS[st.heading]
    st.pos.x, st.pos.z = st.pos.x + d[1], st.pos.z + d[3]
  else
    st.pos.y = st.pos.y + MOVES[kind].dy
  end
end

-- One step, digging through whatever is in the way. Returns false if blocked
-- by something we may not or cannot break.
local function step(kind)
  local m = MOVES[kind]
  for _ = 1, 30 do
    if tmove.move(S, save, kind, m.move, applyMove) then return true end
    if m.detect() then
      local ok, info = m.inspect()
      if ok and isProtected(info.name) then return false end
      if not m.dig() then return false end -- bedrock or unbreakable
    else
      m.attack() -- a mob, or a falling block mid-air
      sleep(0.2)
    end
  end
  return false
end

-- Walk to target, digging a path: vertical first when going up, last when going
-- down, so the turtle mostly travels through already-open tunnels.
local function goDirect(t)
  local function vertical()
    while S.pos.y < t.y do if not step("up") then return false end end
    while S.pos.y > t.y do if not step("down") then return false end end
    return true
  end
  local function horizontal(axis, plus, minus)
    while S.pos[axis] ~= t[axis] do
      turnTo(S.pos[axis] < t[axis] and plus or minus)
      if not step("fwd") then return false end
    end
    return true
  end
  if t.y > S.pos.y and not vertical() then return false end
  if not horizontal("x", 1, 3) then return false end
  if not horizontal("z", 2, 0) then return false end
  return vertical()
end

-- Travel between the surface and the mining level always goes through the
-- shaft at x=0,z=0, so every trip reuses one hole instead of digging new ones.
local SHAFT_SWITCH = 12 -- vertical distance that counts as changing level
local function goTo(t)
  if math.abs(t.y - S.pos.y) <= SHAFT_SWITCH then return goDirect(t) end
  return goDirect({ x = 0, y = S.pos.y, z = 0 })
     and goDirect({ x = 0, y = t.y, z = 0 })
     and goDirect(t)
end

-- -------------------------------------------------------------- inventory --
local function emptySlots()
  local n = 0
  for i = 1, 16 do if turtle.getItemCount(i) == 0 then n = n + 1 end end
  return n
end

local function dropJunk()
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and CFG.junk[d.name] then turtle.select(i); turtle.dropUp() end
  end
  turtle.select(1)
end

local function refuel()
  if turtle.getFuelLevel() == "unlimited" then return end
  for i = 1, 16 do
    turtle.select(i)
    if turtle.getFuelLevel() >= turtle.getFuelLimit() - 1000 then break end
    if turtle.refuel(0) then turtle.refuel() end
  end
  turtle.select(1)
end

local function needHome()
  if emptySlots() < 2 then dropJunk() end
  if emptySlots() < 2 then return "full" end
  local f = turtle.getFuelLevel()
  if f ~= "unlimited" and f < dist(S.pos, HOME) + CFG.fuelMargin then
    refuel()
    f = turtle.getFuelLevel()
    if f < dist(S.pos, HOME) + CFG.fuelMargin then return "fuel" end
  end
  return nil
end

local function unload()
  turnTo((S.homeHeading + 2) % 4) -- chest is behind the start position
  local keptFuel = false
  for i = 1, 16 do
    turtle.select(i)
    local d = turtle.getItemDetail(i)
    if d and not link.isKeptItem(d.name) then
      if not keptFuel and turtle.refuel(0) then
        keptFuel = true -- keep one stack of fuel
      else
        turtle.drop()
      end
    end
  end
  turtle.select(1)
end

-- -------------------------------------------------------------- base link --
local function status()
  return { job = S and S.job, mined = S and S.mined or 0 }
end

-- Report to the base (only at home). Code updates wait until the job is done.
local function talk(state)
  return link.talk(state, status(), state == "idle" or state == "done")
end

local function finished()
  return S.stop or (S.quantity and S.mined >= S.quantity)
end

-- Go home, unload, report, and come back to where we were (unless stopped).
local function serviceTrip(reason)
  log("Returning home: " .. reason)
  local back = { x = S.pos.x, y = S.pos.y, z = S.pos.z }
  if not goTo(HOME) then error("Cannot reach home", 0) end
  unload()
  refuel()
  local reply = talk("unloading")
  if reply and reply.type == "stop" then
    log("Stop requested by base")
    S.stop = true
    save()
    return
  end
  if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 2 * dist(back, HOME) + CFG.fuelMargin then
    error("Out of fuel. Put fuel in it and restart (startup resumes).", 0)
  end
  if not goTo(back) then log("Could not return to " .. key(back.x, back.y, back.z)) end
end

-- ---------------------------------------------------------------- mining --
local function mineVisible()
  local ores = {}
  for _, b in ipairs(scan()) do
    if isOre(b) then
      ores[#ores + 1] = { x = S.pos.x + b.x, y = S.pos.y + b.y, z = S.pos.z + b.z, name = b.name }
    end
  end
  local mined = 0
  while #ores > 0 and not finished() do
    -- nearest first, which also follows veins naturally
    local bi, bd = 1, math.huge
    for i, o in ipairs(ores) do
      local d = dist(S.pos, o)
      if d < bd then bi, bd = i, d end
    end
    local o = table.remove(ores, bi)
    local why = needHome()
    if why then serviceTrip(why) end
    if finished() then break end
    if goTo(o) then
      mined = mined + 1
      S.mined = S.mined + 1
      save()
    else
      log("Skipped unreachable " .. o.name)
    end
  end
  return mined
end

-- Lane target: lanes go out along homeHeading, each shifted right by `spacing`.
-- The base gives every job its own `sector` (first lane index) so jobs at the
-- same level never overlap.
local function laneTarget(lane, progress)
  local f, r = DIRS[S.homeHeading], DIRS[(S.homeHeading + 1) % 4]
  local along = (lane % 2 == 0) and progress or (S.length - progress)
  local side = (lane + (S.sector or 0)) * CFG.spacing
  return { x = f[1] * along + r[1] * side, y = S.dy, z = f[3] * along + r[3] * side }
end

-- Detect which way we face by scanning, moving forward one block, scanning
-- again and seeing which shift lines the two scans up. Turns until it finds a
-- direction it may move into; returns the heading it ends up facing.
local function detectHeading()
  local a = scan()
  local moved = false
  for _ = 1, 4 do
    moved = turtle.forward()
    if not moved and turtle.detect() then
      local ok, info = turtle.inspect()
      if not (ok and isProtected(info.name)) and turtle.dig() then moved = turtle.forward() end
    end
    if moved then break end
    turtle.turnRight()
  end
  if not moved then error("Need room to move 1 block in some direction to detect heading", 0) end
  local b = {}
  for _, blk in ipairs(scan()) do b[key(blk.x, blk.y, blk.z)] = blk.name end
  local best, bestScore = nil, -1
  for h = 0, 3 do
    local d, score = DIRS[h], 0
    for _, blk in ipairs(a) do
      if blk.name ~= "minecraft:air" and b[key(blk.x - d[1], blk.y, blk.z - d[3])] == blk.name then
        score = score + 1
      end
    end
    if score > bestScore then best, bestScore = h, score end
  end
  turtle.back()
  return best
end

local function run()
  while S.lane < S.lanes and not finished() do
    while S.progress <= S.length and not finished() do
      local why = needHome()
      if why then serviceTrip(why) end
      if finished() then break end
      if not goTo(laneTarget(S.lane, S.progress)) then
        log("Lane blocked; skipping ahead")
      end
      local n = mineVisible()
      log(("lane %d/%d  %d/%d  mined %d (total %d)  fuel %s"):format(
        S.lane + 1, S.lanes, S.progress, S.length, n, S.mined, tostring(turtle.getFuelLevel())))
      S.progress = S.progress + CFG.spacing
      save()
    end
    if not finished() then S.lane, S.progress = S.lane + 1, 0 end
    save()
  end
  goTo(HOME)
  unload()
  turnTo(S.homeHeading)
  S.done = true
  save()
  log(("Done: %d ore mined. Everything is in the chest."):format(S.mined))
end

-- A job: { only = "diamond" | nil, y = <absolute Y> | nil, quantity = n | nil,
--          lanes = n | nil, length = n | nil, sector = first lane | nil, id = n | nil }
local function newJob(job, home)
  S = { pos = { x = 0, y = 0, z = 0 }, heading = home.heading, homeHeading = home.heading,
        lane = 0, progress = 0, lanes = job.lanes or CFG.lanes, length = job.length or CFG.length,
        dy = job.y and (job.y - home.y) or 0, only = job.only, quantity = job.quantity,
        sector = job.sector or 0, mined = 0, job = job }
  save()
  log(("Job: %s%s at %s, %d lane(s) of %d."):format(
    job.quantity and (job.quantity .. " ") or "", job.only and (job.only .. " ore") or "all ores",
    job.y and ("Y " .. job.y) or "this level", S.lanes, S.length))
end

local function askY()
  local at
  while not at do
    write("Turtle's current Y (F3)? ")
    at = tonumber(read())
  end
  return at
end

local function resumeUnfinished()
  local s = readFile(CFG.stateFile)
  if s and not s.done then
    S = s
    S.dy, S.mined, S.lanes, S.length = S.dy or 0, S.mined or 0, S.lanes or CFG.lanes, S.length or CFG.length
    -- settle a move that was in flight when it stopped, and re-measure the
    -- heading: a turn may have happened without being saved
    tmove.recover(S, save, applyMove)
    S.heading = detectHeading()
    save()
    log("Resuming at " .. key(S.pos.x, S.pos.y, S.pos.z) .. " facing " .. HEADING_NAME[S.heading])
    run()
    return true
  end
  return false
end

-- ---------------------------------------------------------------- main --
if not ensureScanner() then error("No Geo Scanner equipped (or in inventory)", 0) end

local args = { ... }
if args[1] == "resume" then
  if not resumeUnfinished() then log("Nothing to resume.") end

elseif args[1] == "serve" then
  -- serve [at=<Y>] [heading=<0-3>]: the agent passes both for a new turtle
  local opt = {}
  for _, a in ipairs(args) do
    local k, v = a:match("^(%w+)=(.+)$")
    if k then opt[k] = tonumber(v) end
  end
  local home = readFile(CFG.homeFile)
  if not home then
    log("First start: telling the turtle where home is.")
    home = { y = opt.at or askY() }
    refuel()
    S = { pos = { x = 0, y = 0, z = 0 }, heading = 0, homeHeading = 0 }
    home.heading = opt.heading or detectHeading()
    writeFile(CFG.homeFile, home)
    log(("Home is Y %d facing %s."):format(home.y, HEADING_NAME[home.heading]))
  end
  resumeUnfinished()
  if S and S.done then talk("done") end
  if not link.hasModem() then
    error("serve needs a wireless modem in the turtle's inventory", 0)
  end
  log("Waiting for jobs from the base...")
  while true do
    local reply = talk("idle")
    if type(reply) == "table" and reply.type == "job" then
      newJob(reply.job, home)
      run()
      talk("done")
    else
      sleep(3)
    end
  end

else
  local job, opt, all = {}, {}, false
  for _, a in ipairs(args) do
    local k, v = a:match("^(%w+)=(.+)$")
    if k then opt[k] = v
    elseif a == "all" then all = true
    elseif PRESET_Y[a] then job.only, job.y = a, PRESET_Y[a]
    else error("Unknown argument '" .. a .. "'. Presets: diamond redstone lapis gold iron copper coal emerald", 0) end
  end
  if all then job.only = nil end
  if opt.only then job.only = opt.only end
  if opt.y then job.y = tonumber(opt.y) or error("y= must be a number", 0) end
  job.lanes, job.length, job.quantity = tonumber(opt.lanes), tonumber(opt.length), tonumber(opt.qty)

  local home = { y = 0 }
  if job.y then home.y = tonumber(opt.at) or askY() end
  refuel()
  S = { pos = { x = 0, y = 0, z = 0 }, heading = 0, homeHeading = 0 }
  home.heading = detectHeading()
  log("Facing " .. HEADING_NAME[home.heading] .. ".")
  newJob(job, home)
  run()
end
