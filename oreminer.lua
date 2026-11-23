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
  travelSteps = 2000,  -- replans one trip may take going around what it can't dig
  orePatience = 6,     -- ... and one ore (under a bedrock layer: not worth more)
  detourMargin = 64,   -- how far around start and target a detour is searched
  turtleWait = 30,     -- s it waits for another turtle in its way before going around
  trailFile = "oreminer.trail", -- the way it came (its way out, whatever the planner finds)
  askFuelBelow = 1000, -- at home, ask the base for fuel below this
  minDepth = 16,       -- a job's level is at least this far below home (never up through the base)
  -- (no floor Y: bedrock is found on the way down, whatever the dimension: settleLevel)
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
  -- (suspicious sand/gravel: dug, its loot is gone; it is brushed by hand)
  protect = { "^computercraft:", "chest", "barrel", "shulker", "spawner", "suspicious_", "minecraft:vault" },
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
-- natural stone and ground by name (modded stones like darkstone, deepslate
-- variants), never an ore: the live scans came without usable tags
local FILLER_NAMES = { "stone$", "slate$", "deepslate", "tuff$", "basalt$", "granite$", "diorite$",
                       "andesite$", "netherrack$", "gravel$", "dirt$", "sand$", "clay$", "calcite$" }
local function filler(b)
  if FILLER[b.name] then return true end
  if not anyOre(b) and not b.name:find("_ore") then
    for _, pat in ipairs(FILLER_NAMES) do if b.name:find(pat) then return true end end
  end
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
local PEND, SEND_AT, PEND_DIRTY
local MAPPING = false -- only for the base's jobs (serve): a hand-run job keeps no map
local MAX_PENDING_SCANS = 200 -- the base out of reach for long: the oldest scans go
local function loadPend()
  PEND = readFile(CFG.mapFile) or {}
  PEND.scans, PEND.mined = PEND.scans or {}, PEND.mined or {}
end
local function savePend()
  while #PEND.scans > MAX_PENDING_SCANS do table.remove(PEND.scans, 1) end
  writeFile(CFG.mapFile, PEND)
  PEND_DIRTY = false
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
    PEND_DIRTY = true -- (saved at the next scan or talk, not on every dig)
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
-- The trail: the cells it moved through since it left home, loops cut out
-- (so it is the direct way it came). Whatever happens, that is a way out.
local TRAIL, TRAIL_AT = {}, {}
local function trailAdd()
  local k = key(S.pos.x, S.pos.y, S.pos.z)
  if S.pos.x == 0 and S.pos.y == 0 and S.pos.z == 0 then TRAIL, TRAIL_AT = {}, {}; return end
  local i = TRAIL_AT[k]
  if i then -- back on its own trail: the loop since then is cut out
    for j = #TRAIL, i + 1, -1 do TRAIL_AT[TRAIL[j]] = nil; TRAIL[j] = nil end
  else
    TRAIL[#TRAIL + 1] = k
    TRAIL_AT[k] = #TRAIL
  end
end
local function saveTrail() writeFile(CFG.trailFile, TRAIL) end
local function loadTrail()
  TRAIL, TRAIL_AT = readFile(CFG.trailFile) or {}, {}
  for i, k in ipairs(TRAIL) do TRAIL_AT[k] = i end
end

local function isTurtle(name) return name:find("^computercraft:turtle") ~= nil end

local function step(kind)
  local m = MOVES[kind]
  local waited, tries = 0, 0
  while tries < 30 do
    tries = tries + 1
    if tmove.move(S, save, kind, m.move, applyMove) then trailAdd(); return true end
    if m.detect() then
      local ok, info = m.inspect()
      -- another turtle in the way moves on: wait for it (a while), then go around
      if ok and isTurtle(info.name) and waited < CFG.turtleWait then
        sleep(1); waited = waited + 1; tries = tries - 1
      elseif ok and isProtected(info.name) then return false
      elseif not m.dig() then return false -- bedrock or unbreakable
      elseif ok then
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
-- The shortest way from `from` to `to` through cells not known to be
-- blocked (everything else is assumed diggable), inside the box around both
-- plus `margin`: a list of { kind, h } moves, or nil if there is none. A*
-- with a binary heap; ties go up first when going up, down last when going
-- down (so it mostly travels through open tunnels).
local function plan(from, to, blocked, margin)
  local lo = { x = math.min(from.x, to.x) - margin, y = math.min(from.y, to.y) - margin, z = math.min(from.z, to.z) - margin }
  local hi = { x = math.max(from.x, to.x) + margin, y = math.max(from.y, to.y) + margin, z = math.max(from.z, to.z) + margin }
  local MOVES = { { "up", nil, 0, 1, 0 }, { "fwd", 0, 0, 0, -1 }, { "fwd", 1, 1, 0, 0 },
                  { "fwd", 2, 0, 0, 1 }, { "fwd", 3, -1, 0, 0 }, { "down", nil, 0, -1, 0 } }
  local function h(p) return math.abs(p.x - to.x) + math.abs(p.y - to.y) + math.abs(p.z - to.z) end
  local heap, size = {}, 0
  local function push(n)
    size = size + 1; heap[size] = n
    local i = size
    while i > 1 do
      local pa = math.floor(i / 2)
      if heap[pa].f <= n.f then break end
      heap[i], heap[pa] = heap[pa], n; i = pa
    end
  end
  local function pop()
    local top = heap[1]
    heap[1] = heap[size]; heap[size] = nil; size = size - 1
    local i = 1
    while true do
      local l, r, m = 2 * i, 2 * i + 1, i
      if l <= size and heap[l].f < heap[m].f then m = l end
      if r <= size and heap[r].f < heap[m].f then m = r end
      if m == i then break end
      heap[i], heap[m] = heap[m], heap[i]; i = m
    end
    return top
  end
  local startK = key(from.x, from.y, from.z)
  local best, prev = { [startK] = 0 }, {}
  push({ x = from.x, y = from.y, z = from.z, g = 0, f = h(from), k = startK })
  local goal = key(to.x, to.y, to.z)
  local expanded = 0
  while size > 0 do
    local n = pop()
    if n.k == goal then
      local moves, k = {}, goal
      while prev[k] do table.insert(moves, 1, prev[k].move); k = prev[k].from end
      return moves
    end
    expanded = expanded + 1
    if expanded > 60000 then return nil end
    if n.g == best[n.k] then
      for i, m in ipairs(MOVES) do
        local p = { x = n.x + m[3], y = n.y + m[4], z = n.z + m[5] }
        if p.x >= lo.x and p.x <= hi.x and p.y >= lo.y and p.y <= hi.y and p.z >= lo.z and p.z <= hi.z then
          local k = key(p.x, p.y, p.z)
          if not blocked[k] then
            local g = n.g + 1
            if not best[k] or g < best[k] then
              best[k], prev[k] = g, { from = n.k, move = { kind = m[1], h = m[2] } }
              -- (tie-break: up first when going up, down last when going down)
              local tie = (m[1] == "up" and to.y > n.y) and 0 or (m[1] == "down" and 0.002 or 0.001)
              p.g, p.f, p.k = g, g + h(p) + tie, k
              push(p)
            end
          end
        end
      end
    end
  end
end

-- Around what it can't dig (bedrock, a chest, another turtle): it plans the
-- shortest way assuming every unknown block can be dug, follows it, and when
-- a step fails it remembers that cell and plans again from where it is. Each
-- failure rules out a cell for good, so it either gets there or finds it is
-- sealed in (or runs out of CFG.travelSteps).
-- Back the way it came: its trail, cell by cell, to home. (What blocks a
-- trail cell now was put there since: dug, or another turtle waited for.)
local function retrace()
  log("No way found around: back the way I came")
  -- (from the trail's end, one adjacent cell at a time: never by index into
  -- a trail each step shortens, never to a cell that isn't next to it)
  for _ = 1, 100000 do
    if S.pos.x == 0 and S.pos.y == 0 and S.pos.z == 0 then return true end
    local n, here = #TRAIL, key(S.pos.x, S.pos.y, S.pos.z)
    if n == 0 or TRAIL[n] ~= here then
      -- (a trail saved before its last moves: it doesn't lead from here)
      log("My trail doesn't lead from here: can't go back the way I came")
      return false
    end
    local x, y, z = 0, 0, 0
    if n > 1 then
      local a, b, c = TRAIL[n - 1]:match("^(-?%d+),(-?%d+),(-?%d+)$")
      x, y, z = tonumber(a), tonumber(b), tonumber(c)
    end
    local dx, dy, dz = x - S.pos.x, y - S.pos.y, z - S.pos.z
    if math.abs(dx) + math.abs(dy) + math.abs(dz) ~= 1 then
      log("My trail has a gap here: can't go back the way I came")
      return false
    end
    local kind
    if dy == 1 then kind = "up" elseif dy == -1 then kind = "down"
    else
      for h = 0, 3 do if DIRS[h][1] == dx and DIRS[h][3] == dz then turnTo(h); kind = "fwd" end end
    end
    if not kind or not step(kind) then return false end
    -- the trail ends where it stands now (step() may have cut it already)
    for j = #TRAIL, n, -1 do TRAIL_AT[TRAIL[j]] = nil; TRAIL[j] = nil end
    if n > 1 then TRAIL_AT[TRAIL[n - 1]] = n - 1 end
  end
  return false
end

local function goAround(t, blocked, patience)
  blocked = blocked or {}
  local margin = 8
  for _ = 1, patience or CFG.travelSteps do
    if S.pos.x == t.x and S.pos.y == t.y and S.pos.z == t.z then return true end
    local moves = plan(S.pos, t, blocked, margin)
    if not moves then
      if margin >= CFG.detourMargin then
        -- (only for the long ways: an ore isn't worth the trip back)
        if patience or #TRAIL == 0 or not retrace() then return false end
        if t.x == 0 and t.y == 0 and t.z == 0 then return true end
        blocked, margin = {}, 8 -- from home, a fresh start
      else
        margin = margin * 2 -- a wider detour
      end
    else
      for _, m in ipairs(moves) do
        if m.h then turnTo(m.h) end
        local d = m.kind == "fwd" and DIRS[S.heading] or { 0, m.kind == "up" and 1 or -1, 0 }
        local nk = key(S.pos.x + d[1], S.pos.y + d[2], S.pos.z + d[3])
        if not step(m.kind) then blocked[nk] = true; break end
      end
    end
  end
  return S.pos.x == t.x and S.pos.y == t.y and S.pos.z == t.z
end

-- Walk to target, digging a path: vertical first when going up, last when
-- going down, so the turtle mostly travels through already-open tunnels.
-- Blocked by something it can't dig: it goes around (goAround), trying
-- `patience` times (an ore: a few; the way home: CFG.travelSteps).
local function goDirect(t, patience)
  local blockedAt
  local function stepTo(kind)
    local d = kind == "fwd" and DIRS[S.heading] or { 0, kind == "up" and 1 or -1, 0 }
    local nk = key(S.pos.x + d[1], S.pos.y + d[2], S.pos.z + d[3])
    if step(kind) then return true end
    blockedAt = nk
    return false
  end
  local function vertical()
    while S.pos.y < t.y do if not stepTo("up") then return false end end
    while S.pos.y > t.y do if not stepTo("down") then return false end end
    return true
  end
  local function horizontal(axis, plus, minus)
    while S.pos[axis] ~= t[axis] do
      turnTo(S.pos[axis] < t[axis] and plus or minus)
      if not stepTo("fwd") then return false end
    end
    return true
  end
  local ok = (t.y <= S.pos.y or vertical()) and horizontal("x", 1, 3) and horizontal("z", 2, 0) and vertical()
  if ok then return true end
  log(("Blocked at %s on the way to %s: going around"):format(tostring(blockedAt), key(t.x, t.y, t.z)))
  return goAround(t, { [blockedAt or ""] = true }, patience)
end

-- Every trip that leaves or reaches the home level, or changes level a lot,
-- goes through the shaft at x=0,z=0: one hole at home instead of digging up
-- through the surface (and the base) wherever the turtle happens to be.
local SHAFT_SWITCH = 12 -- vertical distance that counts as changing level underground
local function goTo(t, patience)
  -- (mining at the home level itself, dy = 0, has no shaft: it works in its
  -- own tunnels around home)
  -- (above home there is no shaft: its column there is the modem over home)
  local viaShaft = S.dy ~= 0 and t.y ~= S.pos.y and S.pos.y <= HOME.y and t.y <= HOME.y
                   and (t.y == HOME.y or S.pos.y == HOME.y or math.abs(t.y - S.pos.y) > SHAFT_SWITCH)
  if not viaShaft then return goDirect(t, patience) end
  -- to the shaft at the job's level at least: below it (digging an ore a
  -- few blocks down) may be bedrock, which can't be dug through
  local level = math.max(S.pos.y, math.min(S.dy, 0))
  return goDirect({ x = S.pos.x, y = level, z = S.pos.z }, patience)
     and goDirect({ x = 0, y = level, z = 0 }, patience)
     and goDirect({ x = 0, y = t.y, z = 0 }, patience)
     and goDirect(t, patience)
end

-- Its position can be off from the world: a chunk saved before its last
-- moves, a server that stopped without saving the chunk, ... Then every way
-- home it plans is wrong. Home looks like nothing else nearby: an open cell
-- with the home chest behind it and the wired modem above (the base link).
-- So it asks the world: the scanner finds those cells; the one nearest where
-- it thinks home is (and only if it is the only one that near, and within a
-- few blocks) is home. Returns true if it moved its position.
local RELOCATE_RANGE = 4
local function relocate()
  if not link.scanner() then return false end
  local ok, blocks = pcall(scan)
  if not ok or type(blocks) ~= "table" then return false end
  local at = {}
  for _, b in ipairs(blocks) do at[key(b.x, b.y, b.z)] = b.name end
  local back = DIRS[(S.homeHeading + 2) % 4]
  -- where it thinks home is, from where it stands
  local tx, ty, tz = -S.pos.x, -S.pos.y, -S.pos.z
  local best, bestD, tie
  for _, b in ipairs(blocks) do
    if b.name == "computercraft:wired_modem_full" then
      local x, y, z = b.x, b.y - 1, b.z
      local here = at[key(x, y, z)]
      local chest = at[key(x + back[1], y, z + back[3])]
      if (not here or isTurtle(here)) and chest and chest:find("chest") then
        local d = math.abs(x - tx) + math.abs(y - ty) + math.abs(z - tz)
        if not bestD or d < bestD then best, bestD, tie = { x = x, y = y, z = z }, d, false
        elseif d == bestD then tie = true end
      end
    end
  end
  -- (also home itself, where it stands: nothing in the scan at 0,0,0)
  if not best or tie or bestD == 0 or bestD > RELOCATE_RANGE then return false end
  log(("I'm not where I thought: home is %d,%d,%d from here, not %d,%d,%d. Fixing my position."):format(
    best.x, best.y, best.z, tx, ty, tz))
  S.pos = { x = -best.x, y = -best.y, z = -best.z }
  TRAIL, TRAIL_AT = {}, {} -- (the old trail was from the wrong position)
  save()
  saveTrail()
  return true
end

-- Home, and if it can't get there or isn't home when it gets there, checks
-- its position against the world (relocate) and tries once more.
local function atHome()
  turnTo((S.homeHeading + 2) % 4)
  local ok, b = turtle.inspect()
  return ok and b.name:find("chest") ~= nil
end
local function goHome()
  if goTo(HOME) and atHome() then return true end
  if relocate() then return goTo(HOME) end
  return S.pos.x == 0 and S.pos.y == 0 and S.pos.z == 0
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
-- At home: face the chest (what the base sends lands there, and supplies
-- are taken from in front), run fn, face the way it did. false: no chest.
local function atChest(fn)
  local turns = 0
  while turns < 4 do
    local ok, b = turtle.inspect()
    if ok and b.name:find("chest") then break end
    turtle.turnRight(); turns = turns + 1
  end
  if turns < 4 then fn() end
  for _ = 1, (4 - turns) % 4 do turtle.turnRight() end
  return turns < 4
end

local function fuelUp(level)
  local f = turtle.getFuelLevel()
  if f == "unlimited" or f >= level then return end
  atChest(function()
    link.supply({ fuel = math.ceil((level - f) / 80) })
    refuel(level)
  end)
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

-- The tools a job brought (job.tools: an inspect job's block reader): kept
-- through its trips home, given back with the last unload (`final`).
local TOOL_TYPE = { [C.READER_ITEM] = "block_reader" }

-- final: the job's last unload: the tools it brought go back too
local function unload(final)
  if final then link.holdTools(nil) end
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
  -- (lanesDone: lanes finished; the base records what a scout job covered)
  return { job = S and S.job, mined = S and S.mined or 0, map = pending(), lanesDone = S and S.lane or nil,
           inspected = S and S.inspected or nil, floor = S and S.floor or nil }
end

-- Report to the base (only at home). Code updates wait until the job is done.
-- A reply means the base has the map report too.
talk = function(state)
  if PEND_DIRTY then savePend() end
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
  if not goHome() then error("Cannot reach home (" .. nav.surroundings() .. ")", 0) end
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
    if goTo(o, CFG.orePatience) then
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
local sampled = false
local function mineVisible()
  local seen, ores = {}, {}
  local blocks = scan()
  if not sampled and #blocks > 0 then
    -- one raw entry, as AP gave it, to check against the code's assumptions
    sampled = true
    pcall(writeFile, "scan.sample", { blocks[1], blocks[#blocks] })
  end
  for _, b in ipairs(blocks) do
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
  saveTrail() -- (its way out, kept through a restart)
  -- (a scout job maps and digs nothing: the ores stay for the miners)
  local n = S.scout and 0 or mineList(ores)
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
  -- (`along`: where its lanes start, out from home: scout areas further out)
  local along = (S.along or 0) + ((lane % 2 == 0) and progress or (S.length - progress))
  local side = (lane + (S.sector or 0)) * CFG.spacing
  return { x = f[1] * along + r[1] * side, y = S.dy, z = f[3] * along + r[3] * side }
end

-- journal: on a resume, the probe is journaled in its state (a stop in the
-- middle of it must not leave it a block off its saved position); a new job
-- has no state on disk yet to journal into.
local function detectHeading(journal)
  local mayDig = function(name) return not isProtected(name) end
  if journal then return nav.scanHeading(mayDig, S, save) end
  return nav.scanHeading(mayDig)
end

-- --------------------------------------------------------------- inspect --
-- What the block reader says about a block, cut to what the base shows:
-- a spawner's mob (and its effects), a boss spawner's boss, a chest's loot
-- table (which says what structure it is in) and whether it was opened
-- (Lootr). AP's getBlockData is the block entity's NBT as Lua (bytes as
-- numbers).
local function summarize(t, name, d)
  local out = { x = t.x, y = t.y, z = t.z, name = name or t.name }
  if type(d) ~= "table" then return out end
  local sd = type(d.SpawnData) == "table" and d.SpawnData.entity
  if type(sd) == "table" and sd.id then
    out.mob = sd.id
    local fx = {}
    for _, e in ipairs(type(sd.active_effects) == "table" and sd.active_effects or {}) do
      if e.id then fx[#fx + 1] = tostring(e.id):gsub("^minecraft:", "") .. " " .. ((tonumber(e.amplifier) or 0) + 1) end
    end
    if #fx > 0 then out.effects = table.concat(fx, ", ") end
  end
  if d.boss_item then out.boss = (d.boss_item == "empty:empty") and "random" or tostring(d.boss_item) end
  if d.LootTable then out.loot = tostring(d.LootTable) end
  if d.LootrHasBeenOpened ~= nil then out.opened = d.LootrHasBeenOpened == true or d.LootrHasBeenOpened == 1 end
  return out
end

-- Stand next to it (one of its four sides: the reader reads what is in
-- front), face it, read it with the block reader swapped in for the call.
local function inspectOne(t)
  local sides = {}
  for h = 0, 3 do
    local d = DIRS[h]
    local at = { x = t.x - d[1], y = t.y, z = t.z - d[3] }
    sides[#sides + 1] = { h = h, at = at, d = dist(S.pos, at) }
  end
  table.sort(sides, function(a, b) return a.d < b.d end)
  for _, sd in ipairs(sides) do
    if goTo(sd.at) then
      turnTo(sd.h)
      local res = link.withTool("block_reader", function(p)
        return { name = p.getBlockName and p.getBlockName() or nil, data = p.getBlockData and p.getBlockData() or nil }
      end)
      if not res then return { x = t.x, y = t.y, z = t.z, name = t.name, err = "no block reader" } end
      local info = summarize(t, res.name, res.data)
      log(("Inspected %s at %s: %s"):format(tostring(info.name), key(t.x, t.y, t.z),
        tostring(info.mob or info.loot or info.boss or "nothing to read")))
      return info
    end
  end
  return { x = t.x, y = t.y, z = t.z, name = t.name, err = "can't get next to it" }
end

local function inspectAll()
  while S.inspectAt <= #S.inspect do
    local why = needHome()
    if why then serviceTrip(why) end
    if finished() then return end
    S.inspected[#S.inspected + 1] = inspectOne(S.inspect[S.inspectAt])
    S.inspectAt = S.inspectAt + 1
    save()
  end
end

-- The world's floor, asked of the world: down its shaft to the job's level;
-- bedrock (or the bottom of the world) before it, and the level is one above
-- the HIGHEST bedrock the scanner sees around (a floor is ragged: the
-- overworld's from Y -64 to -60), so lanes run clear of it. Any dimension:
-- no floor Y is assumed. S.floor: that bedrock top, from home (reported).
local function settleLevel()
  if S.settled or S.inspect or S.dy >= 0 then return end
  goTo({ x = 0, y = math.max(S.pos.y, -1), z = 0 }) -- (into its shaft)
  while S.pos.y > S.dy do
    if not step("down") then break end
  end
  if S.pos.y > S.dy then
    local ok, below = turtle.inspectDown()
    if ok and below.name ~= "minecraft:bedrock" then
      S.settled = true -- (something else it may not dig: the way down goes round it)
      save()
      return
    end
    local top = S.pos.y - 1 -- (the bedrock below, or the bottom of the world)
    local okScan, blocks = pcall(scan)
    for _, b in ipairs(okScan and type(blocks) == "table" and blocks or {}) do
      if b.name == "minecraft:bedrock" then top = math.max(top, S.pos.y + math.floor(b.y + 0.5)) end
    end
    S.floor = top
    S.dy = math.min(top + 1, -CFG.minDepth)
    log(("Bedrock below: the floor's top is %d from home; working %d down instead"):format(top, -S.dy))
  end
  S.settled = true
  save()
end

local function run()
  link.holdTools(S.job and S.job.tools) -- (also after a restart mid-job)
  settleLevel()
  if S.inspect then
    inspectAll()
    S.lane = S.lanes -- (no lanes: done when every block is read)
  elseif not S.scout then mineKnown() end
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
  if not goHome() then error("Cannot reach home (" .. nav.surroundings() .. ")", 0) end
  unload(true) -- (the job's tools go back too)
  turnTo(S.homeHeading)
  S.done = true
  save()
  log(("Done: %d ore mined. Everything is in the chest."):format(S.mined))
end

-- A job: { only = "diamond" | nil, y = <absolute Y> | nil, quantity = n | nil,
--          lanes = n | nil, length = n | nil, sector = first lane | nil, id = n | nil }
local function newJob(job, home, known, inspect)
  TRAIL, TRAIL_AT = {}, {}
  S = { pos = { x = 0, y = 0, z = 0 }, heading = home.heading, homeHeading = home.heading,
        known = known or {},
        -- an inspect job: the blocks to read (from its home), what it read
        inspect = inspect, inspected = inspect and {} or nil, inspectAt = inspect and 1 or nil,
        lane = 0, progress = 0, lanes = job.lanes or CFG.lanes, length = job.length or CFG.length,
        dy = job.y and math.min(job.y - home.y, -CFG.minDepth) or 0,
        only = job.only, quantity = job.quantity,
        sector = job.sector or 0, along = job.along or 0, mined = 0, job = job, scout = job.scout or nil }
  save()
  if job.y and job.y - home.y > -CFG.minDepth then
    log(("Y %d is not below home (Y %d): mining at Y %d instead"):format(job.y, home.y, home.y + S.dy))
  end
  if inspect then
    log(("Job: inspect %d block(s) with the block reader."):format(#inspect))
  elseif job.scout then
    log(("Job: scout at %s, %d lane(s) of %d: scans every %d, mines nothing."):format(
      job.y and ("Y " .. job.y) or "this level", S.lanes, S.length, CFG.spacing))
  else
    log(("Job: %s%s at %s, %d lane(s) of %d."):format(
      job.quantity and (job.quantity .. " ") or "", job.only and (job.only .. " ore") or "all ores",
      job.y and ("Y " .. job.y) or "this level", S.lanes, S.length))
  end
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
      -- re-measured (a turn may not have been saved); boxed in sideways it
      -- can't be: then the saved heading (the way out may be up or down)
      local ok, h = pcall(detectHeading, true)
      if ok then S.heading = h
      else log("Keeping my saved heading: " .. tostring(h)) end
    end
    save()
    log("Resuming at " .. key(S.pos.x, S.pos.y, S.pos.z) .. " facing " .. HEADING_NAME[S.heading])
    run()
    return true
  end
  return false
end

-- ---------------------------------------------------------------- main --
-- oreminer.cfg (optional): settings over the defaults above
for k, v in pairs(readFile("oreminer.cfg") or {}) do CFG[k] = v end
if not ensureScanner() then error("No Geo Scanner equipped (or in inventory)", 0) end
loadPend()
loadTrail()

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
      local jy = j.y or home.y
      if reply.inspect then -- (an inspect job: the furthest block, there and back)
        reach, jy = 0, home.y
        for _, t in ipairs(reply.inspect) do reach = math.max(reach, math.abs(t.x) + math.abs(t.y) + math.abs(t.z) + 2) end
      end
      local needFuel = 2 * (math.abs(jy - home.y) + reach) + CFG.fuelMargin
      fuelUp(needFuel + CFG.fuelMargin)
      -- the tools the job needs (an inspect job: a block reader), from the base
      local missing = {}
      local function lacking()
        missing = {}
        for _, t in ipairs(j.tools or {}) do
          if not link.findItem(function(n) return n == t end) and not link.equippedSide(TOOL_TYPE[t] or "") then
            missing[#missing + 1] = t
          end
        end
        return #missing > 0
      end
      if lacking() then atChest(function() link.supply({ tools = missing }) end) end
      if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < needFuel then
        log(("Need about %d fuel for that job, have %d: handing it back"):format(needFuel, turtle.getFuelLevel()))
        link.talk("no fuel", { job = j, need = needFuel }, false)
        sleep(30)
      elseif lacking() then
        log("The base had no " .. table.concat(missing, ", ") .. " for that job: handing it back")
        link.talk("no tool", { job = j, need = missing }, false)
        sleep(30)
      else
        newJob(reply.job, home, reply.known, reply.inspect)
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
