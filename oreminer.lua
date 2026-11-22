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
local nav = require("nav")

local CFG = {
  radius = 8,          -- scan radius; 8 is free on this server, 9-16 costs fuel
  spacing = 16,        -- blocks between scans along a lane (2*radius covers all)
  lanes = 3,           -- parallel lanes, each `spacing` to the right of the last
  length = 64,         -- lane length in blocks
  fuelMargin = 100,    -- head home when fuel < distance home + this
  askFuelBelow = 1000, -- at home, ask the base for fuel below this
  minDepth = 16,       -- a job's level is at least this far below home (never up through the base)
  mapEvery = 3,        -- out on a job: send the base its scans every this many (wireless modem)
  stateFile = "oreminer.state",
  mapFile = "oremap.pending", -- what it saw and dug, until the base has it
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
local DIRS, HEADING_NAME = nav.DIRS, nav.NAMES

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
  return link.scanner() ~= nil
end

-- ---------------------------------------------------------------- scanner --
local function scan() return nav.scan(CFG.radius) end

-- A block's tags as a list: a scan lists them, inspect() maps tag -> true.
local function tagList(b)
  local out = {}
  for k, v in pairs(b.tags or {}) do out[#out + 1] = type(k) == "string" and k or v end
  return out
end

-- Any ore.
local function anyOre(b)
  for _, pat in ipairs(CFG.skip) do
    if b.name:find(pat) then return false end
  end
  if b.name:find("_ore$") then return true end
  for _, t in ipairs(tagList(b)) do
    if t == "c:ores" or t:find("^c:ores/") or t:find("^forge:ores") then return true end
  end
  return false
end

-- An ore's kind from its c:ores/<kind> tag (for the base's map: a job for
-- "osmium" finds a block named otherwise but tagged so), or nil.
local function oreKind(b)
  for _, t in ipairs(tagList(b)) do
    local k = t:match("^c:ores/(.+)$")
    if k then return k end
  end
end

-- Filler: the ground itself, not worth a place in the base's map. Liquids
-- too: a turtle moves through water and lava (checked in the jar).
local FILLER_TAGS = { ["minecraft:base_stone_overworld"] = true, ["minecraft:base_stone_nether"] = true,
                      ["c:stones"] = true, ["c:cobblestones"] = true, ["minecraft:dirt"] = true,
                      ["c:gravels"] = true, ["c:sands"] = true, ["minecraft:sand"] = true }
local FILLER = { ["minecraft:gravel"] = true, ["minecraft:sand"] = true, ["minecraft:red_sand"] = true,
                 ["minecraft:dirt"] = true, ["minecraft:coarse_dirt"] = true, ["minecraft:clay"] = true,
                 ["minecraft:cobblestone"] = true, ["minecraft:cobbled_deepslate"] = true,
                 ["minecraft:calcite"] = true, ["minecraft:smooth_basalt"] = true, ["minecraft:dripstone_block"] = true,
                 ["minecraft:bedrock"] = true, ["minecraft:water"] = true, ["minecraft:lava"] = true,
                 ["minecraft:stone"] = true, ["minecraft:deepslate"] = true, ["minecraft:tuff"] = true,
                 ["minecraft:granite"] = true, ["minecraft:diorite"] = true, ["minecraft:andesite"] = true,
                 ["minecraft:netherrack"] = true }
local function filler(b)
  if FILLER[b.name] then return true end
  for _, t in ipairs(tagList(b)) do if FILLER_TAGS[t] then return true end end
  return false
end

-- An ore this job digs.
local function isOre(b)
  local ore = anyOre(b)
  if not ore or not S.only then return ore end
  -- restricted to one ore kind: match the block name or its c:ores/<kind> tag
  if b.name:find(S.only, 1, true) then return true end
  for _, t in ipairs(tagList(b)) do
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

-- ------------------------------------------------------------- map report --
-- What it saw and dug since it last told the base: { scans = { { x, y, z, r,
-- ores = { { x, y, z, name } } } }, mined = { { x, y, z } } }, from its home,
-- world axes. Its own file (not the job state, which is saved every move),
-- written only when it changes; kept across jobs until the base has it.
local PEND, SEND_AT
local MAPPING = false -- only for the base's jobs (serve): a hand-run job keeps no map
local MAX_PENDING_SCANS = 200 -- the base out of reach for long: the oldest scans go
local function loadPend()
  PEND = readFile(CFG.mapFile) or {}
  PEND.scans, PEND.mined = PEND.scans or {}, PEND.mined or {}
end
local function savePend()
  while #PEND.scans > MAX_PENDING_SCANS do table.remove(PEND.scans, 1) end
  writeFile(CFG.mapFile, PEND)
end
local SEND_STEP -- (the mid-job send backoff, below)
local function clearPend()
  PEND = { scans = {}, mined = {} }
  savePend()
  SEND_STEP, SEND_AT = CFG.mapEvery, CFG.mapEvery -- the base has it all: back to normal
end
local function pending()
  return PEND and (#PEND.scans > 0 or #PEND.mined > 0) and PEND or nil
end


-- The last block `step` dug ({ key, info }): a known ore is only counted if
-- what was dug at its spot was ore (another miner, or a player, may have
-- taken it since it was scanned).
local LASTDUG
local function noteDug(x, y, z, info)
  -- (gravel or sand falling into the cell of an ore just dug, and dug too,
  -- must not hide that the ore was there)
  local k = key(x, y, z)
  if not (LASTDUG and LASTDUG.key == k and anyOre(LASTDUG.info) and not anyOre(info)) then
    LASTDUG = { key = k, info = info }
  end
  -- every block worth a place in the map that it digs (tunnels too) leaves it
  if MAPPING and not filler(info) then
    PEND.mined[#PEND.mined + 1] = { x = x, y = y, z = z }
    savePend()
  end
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
      if ok then
        local d = kind == "fwd" and DIRS[S.heading] or { 0, m.dy, 0 }
        noteDug(S.pos.x + d[1], S.pos.y + d[2], S.pos.z + d[3], info)
      end
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

-- Every trip that leaves or reaches the home level, or changes level a lot,
-- goes through the shaft at x=0,z=0: one hole at home instead of digging up
-- through the surface (and the base) wherever the turtle happens to be.
local SHAFT_SWITCH = 12 -- vertical distance that counts as changing level underground
local function goTo(t)
  -- (mining at the home level itself, dy = 0, has no shaft: it works in its
  -- own tunnels around home)
  local viaShaft = S.dy ~= 0 and t.y ~= S.pos.y
                   and (t.y == HOME.y or S.pos.y == HOME.y or math.abs(t.y - S.pos.y) > SHAFT_SWITCH)
  if not viaShaft then return goDirect(t) end
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

-- Burn fuel items up to FUEL_TARGET, one at a time, so mined coal mostly
-- reaches the chest (coal jobs!) instead of all going into the tank.
local FUEL_TARGET = 4000
local function refuel(target)
  target = target or FUEL_TARGET
  if turtle.getFuelLevel() == "unlimited" then return end
  for i = 1, 16 do
    turtle.select(i)
    while turtle.getFuelLevel() < target and turtle.getItemCount(i) > 0 and turtle.refuel(1) do end
    if turtle.getFuelLevel() >= target then break end
  end
  turtle.select(1)
end

-- At home: fuel for `level` through the home chest (the base sends it there;
-- no modem on the wired network needed), burnt. It finds the chest by
-- turning, and turns back.
local function fuelUp(level)
  local f = turtle.getFuelLevel()
  if f == "unlimited" or f >= level then return end
  local turns = 0
  while turns < 4 do
    local ok, b = turtle.inspect()
    if ok and b.name:find("chest") then break end
    turtle.turnRight(); turns = turns + 1
  end
  if turns < 4 then
    link.supply({ fuel = math.ceil((level - f) / 80) })
    refuel(level)
  end
  for _ = 1, (4 - turns) % 4 do turtle.turnRight() end
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

local talk -- defined in the base link section below

local function unload()
  turnTo((S.homeHeading + 2) % 4) -- chest is behind the start position
  -- never empty the inventory anywhere but into the home chest
  local ok, b = turtle.inspect()
  if not (ok and b.name:find("chest")) then
    error("No chest behind me: I'm not where I think home is. Not unloading.", 0)
  end
  link.claimChest() -- (once, while it has something to mark the chest with)
  -- drop everything but the kept items and one stack of fuel; if the chest is
  -- full, wait here (going back out full would just bring us straight back)
  local waited = 0
  while true do
    local keptFuel, left = false, 0
    for i = 1, 16 do
      turtle.select(i)
      local d = turtle.getItemDetail(i)
      if d and not link.isKeptItem(d.name) then
        if not keptFuel and turtle.refuel(0) then
          keptFuel = true -- keep one stack of fuel
        elseif not turtle.drop() then
          left = left + 1
        end
      end
    end
    turtle.select(1)
    if left == 0 then
      -- unloaded: the chest is a mailbox, ask the base for fuel and take it
      link.supply({ fuel = 16 })
      return
    end
    if waited % 60 == 0 then
      log("Home chest is full; waiting for the base to empty it")
      if talk then talk("chest full") end
    end
    sleep(5)
    waited = waited + 5
  end
end

-- -------------------------------------------------------------- base link --
local function status()
  return { job = S and S.job, mined = S and S.mined or 0, map = pending() }
end

-- Report to the base (only at home). Code updates wait until the job is done.
-- A reply means the base has the map report too.
talk = function(state)
  local had = pending()
  local r = link.talk(state, status(), state == "idle" or state == "done")
  if r and had then clearPend() end
  return r
end

-- Out on a job with a wireless modem: send the map report if the base is in
-- reach (nothing else; no reply needed to carry on).
-- Out of reach (deep, far): the next try waits for more scans each time
-- (3, 6, 12, 24), not every scan, as a talk that gets no answer takes ~10 s.
SEND_STEP, SEND_AT = CFG.mapEvery, CFG.mapEvery
local function sendMap()
  if not pending() or not link.hasModem() then return end
  local r = link.talk("map", { map = PEND }, false)
  link.restoreUpgrade() -- (the scanner back in)
  if r then
    clearPend()
    SEND_STEP, SEND_AT = CFG.mapEvery, CFG.mapEvery
  else
    SEND_STEP = math.min(SEND_STEP * 2, 8 * CFG.mapEvery)
    SEND_AT = math.min(#PEND.scans + SEND_STEP, MAX_PENDING_SCANS) -- (capped: it stays reachable)
  end
end

-- The base counts the job (and frees its stock rule) on "done": say it until
-- the base has heard it.
local function reportDone()
  while not talk("done") do
    log("Base didn't answer; telling it again in 30s")
    sleep(30)
  end
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
    -- not enough to go back out and return: end the job here at home
    log("Low on fuel: ending the job at home")
    S.stop, S.stopReason = true, "fuel"
    save()
    return
  end
  if not goTo(back) then log("Could not return to " .. key(back.x, back.y, back.z)) end
end

-- ---------------------------------------------------------------- mining --
-- Dig `ores` (from home, { x, y, z, name }) nearest first, which also follows
-- veins; each one dug goes into the map report. Returns how many.
local function mineList(ores)
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
    LASTDUG = nil
    if goTo(o) then
      local dug = LASTDUG and LASTDUG.key == key(o.x, o.y, o.z) and LASTDUG.info
      if dug and isOre(dug) then
        mined = mined + 1
        S.mined = S.mined + 1
      else
        log(("No %s at %s any more"):format(o.name, key(o.x, o.y, o.z)))
        if MAPPING then PEND.mined[#PEND.mined + 1] = { x = o.x, y = o.y, z = o.z }; savePend() end
      end
      save()
    else
      log("Skipped unreachable " .. o.name)
    end
  end
  return mined
end

-- Scan here: every block but filler goes into the map report (flagged if an
-- ore); the job's ores get dug.
local function mineVisible()
  local seen, ores = {}, {}
  for _, b in ipairs(scan()) do
    local ore = anyOre(b)
    if ore or not filler(b) then
      local o = { x = S.pos.x + math.floor(b.x + 0.5), y = S.pos.y + math.floor(b.y + 0.5),
                  z = S.pos.z + math.floor(b.z + 0.5), name = b.name, ore = ore or nil,
                  kind = ore and oreKind(b) or nil }
      seen[#seen + 1] = o
      if ore and isOre(b) then ores[#ores + 1] = o end
    end
  end
  if MAPPING then
    PEND.scans[#PEND.scans + 1] = { x = S.pos.x, y = S.pos.y, z = S.pos.z, r = CFG.radius, ores = seen }
    savePend()
  end
  local n = mineList(ores)
  if MAPPING and #PEND.scans >= SEND_AT then sendMap() end
  return n
end

-- The ores the base already knows of for this job (S.known): first.
local function mineKnown()
  if not S.known or #S.known == 0 then return end
  log(("Going for %d ore the base knows of"):format(#S.known))
  local list = S.known
  S.known = {}
  save()
  mineList(list)
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

local function detectHeading()
  return nav.scanHeading(function(name) return not isProtected(name) end)
end

local function run()
  mineKnown()
  while S.lane < S.lanes and not finished() do
    while S.progress <= S.length and not finished() do
      local why = needHome()
      if why then serviceTrip(why) end
      if finished() then break end
      -- enough fuel to get there AND back home? (lanes can be far out)
      local target = laneTarget(S.lane, S.progress)
      local trip = dist(S.pos, target) + dist(target, HOME) + CFG.fuelMargin
      if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < trip then
        refuel()
        if turtle.getFuelLevel() < trip then
          if S.pos.x ~= 0 or S.pos.y ~= 0 or S.pos.z ~= 0 then serviceTrip("fuel") end
          if turtle.getFuelLevel() < trip then
            log("Not enough fuel for the next lane: ending the job early")
            S.stop, S.stopReason = true, "fuel"
            save()
            break
          end
        end
      end
      if not goTo(target) then
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
  if not goTo(HOME) then error("Cannot reach home", 0) end
  unload()
  turnTo(S.homeHeading)
  S.done = true
  save()
  log(("Done: %d ore mined. Everything is in the chest."):format(S.mined))
end

-- A job: { only = "diamond" | nil, y = <absolute Y> | nil, quantity = n | nil,
--          lanes = n | nil, length = n | nil, sector = first lane | nil, id = n | nil }
local function newJob(job, home, known)
  S = { pos = { x = 0, y = 0, z = 0 }, heading = home.heading, homeHeading = home.heading,
        known = known or {},
        lane = 0, progress = 0, lanes = job.lanes or CFG.lanes, length = job.length or CFG.length,
        dy = job.y and math.min(job.y - home.y, -CFG.minDepth) or 0, only = job.only, quantity = job.quantity,
        sector = job.sector or 0, mined = 0, job = job }
  save()
  if job.y and job.y - home.y > -CFG.minDepth then
    log(("Y %d is not below home (Y %d): mining at Y %d instead"):format(job.y, home.y, home.y + S.dy))
  end
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
    if S.pos.x == 0 and S.pos.y == 0 and S.pos.z == 0 then
      -- at home: the chest is behind the home heading; find it by turning,
      -- never dig here (the walls around home may be the base)
      local found = false
      for _ = 1, 4 do
        local ok, b = turtle.inspect()
        if ok and b.name:find("chest") then found = true; break end
        turtle.turnRight()
      end
      if not found then error("At home but no chest around me", 0) end
      S.heading = (S.homeHeading + 2) % 4
    else
      S.heading = detectHeading()
    end
    save()
    log("Resuming at " .. key(S.pos.x, S.pos.y, S.pos.z) .. " facing " .. HEADING_NAME[S.heading])
    run()
    return true
  end
  return false
end

-- ---------------------------------------------------------------- main --
if not ensureScanner() then error("No Geo Scanner equipped (or in inventory)", 0) end
loadPend()

local args = { ... }
if args[1] == "resume" then
  if not resumeUnfinished() then log("Nothing to resume.") end

elseif args[1] == "serve" then
  MAPPING = true -- the base keeps the map of what it scans and digs
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
  if S and S.done then reportDone() end
  if not link.hasModem() then
    error("serve needs a wireless modem in the turtle's inventory", 0)
  end
  log("Waiting for jobs from the base...")
  local lastAsk
  while true do
    refuel() -- burn any fuel someone put in
    -- low on fuel at home: ask the base at the chest (at most once a minute)
    local f = turtle.getFuelLevel()
    if f ~= "unlimited" and f < CFG.askFuelBelow and (not lastAsk or os.clock() - lastAsk > 60) then
      lastAsk = os.clock()
      fuelUp(FUEL_TARGET)
    end
    local reply = talk("idle")
    if type(reply) == "table" and reply.type == "job" then
      local j = reply.job
      -- rough fuel for the job: shaft both ways plus the furthest lane and back
      local reach = ((j.sector or 0) + (j.lanes or CFG.lanes)) * CFG.spacing + (j.length or CFG.length)
      local needFuel = 2 * (math.abs((j.y or home.y) - home.y) + reach) + CFG.fuelMargin
      fuelUp(needFuel + CFG.fuelMargin)
      if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < needFuel then
        log(("Need about %d fuel for that job, have %d: handing it back"):format(needFuel, turtle.getFuelLevel()))
        link.talk("no fuel", { job = j, need = needFuel }, false)
        sleep(30)
      else
        newJob(j, home, reply.known)
        run()
        reportDone()
      end
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
