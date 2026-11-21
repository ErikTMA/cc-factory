-- forester: tree farm turtle inside a fence (CC: Tweaked + Advanced Peripherals).
--
-- The turtle: an advanced turtle with a diamond pickaxe (it breaks wood fine)
-- and a compass (craft the turtle with a plain Compass), so it always knows
-- which way it faces, even after a server restart. Needs tmove.lua, nav.lua,
-- link.lua next to it.
--
-- Layout: a fenced pen (fence, wall, gate or any solid block as the border)
-- with dirt or grass as the floor. The turtle stands inside it, on its home
-- spot, with its chest directly BEHIND it (the chest can sit in the fence line).
--
--   F F F F F F F F
--   F S . . S . . F       S = tree spot (every 3rd cell, measured from home)
--   F . . . . . . F       . = path the turtle walks on
--   F . . . . . . F
--   F S . . S . . F
--   F . . . . . . F
--   F T . . . . . F       T = turtle at home, facing into the pen
--   F C F F F F F F       C = its chest
--
-- First start: it walks every open cell of the pen once (never crossing the
-- border; grass and flowers get cleared, trees already in there felled) and
-- caches the pen in forester.area. After that it only uses the cache;
-- `forester rescan` measures the pen again (e.g. after moving the fence). If
-- the pen is not closed it stops exploring and says so.
--
-- Each round it walks to every tree spot: plants empty ones, fells grown trees
-- (sideways branches too) and replants, then goes home, empties wood and drops
-- into the chest (keeping saplings, bone meal and a few logs for fuel) and
-- reports to the base.
--
-- Slot 1 (top left): the saplings to plant; only that kind is planted, and
-- saplings it picks up go back to slot 1. Slot 2: optional bone meal.
--
-- Run: forester [wait] | forester rescan     (wait: seconds between rounds)

local tmove = require("tmove")
local link = require("link")
local nav = require("nav")

local CFG = {
  spacing = 3,         -- tree spots every `spacing` cells, counted from home
  wait = 300,
  maxHeight = 40,      -- never climb higher than this when felling
  maxArea = 1024,      -- more open cells than this: the pen is not closed
  fuelLow = 300,       -- refuel from logs below this ...
  fuelTarget = 600,    -- ... up to this
  keepLogs = 16,       -- logs it keeps for fuel when unloading
  boneMealTries = 8,   -- bone meal uses per sapling before giving up
  stateFile = "forester.state",
  areaFile = "forester.area",
}

-- CC puts dug items into the selected slot first, so the turtle works with slot
-- 3 selected and only selects slot 1 or 2 to place from them.
local SAPLING_SLOT, BONEMEAL_SLOT, WORK_SLOT = 1, 2, 3
local DIRS = nav.DIRS -- [heading] = { dx, dy, dz }; 0 north, 1 east, 2 south, 3 west

-- Persisted state: { sapling, wait, homeHeading, heading, pos = {x, z} (from
-- home, world axes), up (blocks up a trunk), delivered, pending (tmove) }
local S
-- The pen: { done, cells = { ["x,z"] = groundBlockName }, spots = { "x,z", ... } }
local AREA

local function log(...) print(...) end

local function writeTable(path, t)
  local f = fs.open(path, "w")
  f.write(textutils.serialize(t))
  f.close()
end

local function readTable(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = textutils.unserialize(f.readAll())
  f.close()
  return t
end

local function save() writeTable(CFG.stateFile, S) end
local function saveArea() writeTable(CFG.areaFile, AREA) end

local function key(x, z) return x .. "," .. z end
local function unkey(k) local x, z = k:match("^(-?%d+),(-?%d+)$"); return tonumber(x), tonumber(z) end

-- ------------------------------------------------------------- blocks --
local function hasTag(b, tag)
  if type(b.tags) ~= "table" then return false end
  if b.tags[tag] then return true end -- CC returns tags as a set
  for _, t in ipairs(b.tags) do if t == tag then return true end end
  return false
end

local function isLog(b)
  return b and (hasTag(b, "minecraft:logs") or b.name:find("_log$") or b.name:find("_stem$")
    or b.name:find("_wood$")) and true or false
end

local function isLeaves(b)
  return b and (hasTag(b, "minecraft:leaves") or b.name:find("leaves")) and true or false
end

local function isSapling(b)
  return b and (hasTag(b, "minecraft:saplings") or b.name:find("sapling")) and true or false
end

-- grass, ferns, flowers, snow layers...: in the way, harmless to remove
local function isPlant(b)
  if not b then return false end
  if hasTag(b, "minecraft:replaceable") or hasTag(b, "minecraft:flowers")
     or hasTag(b, "minecraft:small_flowers") then return true end
  local n = b.name
  return (n:find("grass") and not n:find("grass_block")) or n:find("fern") or n:find("flower")
      or n:find("bush") or n:find("tulip") or n:find("poppy") or n:find("dandelion") or false
end

-- may be removed when it is in a path or a spot (everything else is a border)
local function isClearable(b) return isLeaves(b) or isPlant(b) or isSapling(b) end

-- trees grow on these
local function isSoil(name)
  return name and (name:find("dirt") or name:find("grass_block") or name:find("podzol")
    or name:find("mycelium") or name:find("moss_block") or name:find("mud")) and true or false
end

-- ------------------------------------------------------------- movement --
local function turnTo(h)
  local d = (h - S.heading) % 4
  if d == 1 then turtle.turnRight() elseif d == 2 then turtle.turnRight(); turtle.turnRight()
  elseif d == 3 then turtle.turnLeft() end
  S.heading = h
  save()
end

-- Position update for a completed move (also replayed by tmove.recover).
local function applyMove(st, kind)
  if kind == "up" then st.up = st.up + 1
  elseif kind == "down" then st.up = st.up - 1
  else
    local d = DIRS[st.heading]
    local sign = kind == "back" and -1 or 1
    st.pos.x, st.pos.z = st.pos.x + sign * d[1], st.pos.z + sign * d[3]
  end
end

local function move(kind, fn) return tmove.move(S, save, kind, fn, applyMove) end

-- Forward one cell, clearing plants/leaves/logs in the way; false at a border.
local function step()
  for _ = 1, 20 do
    if move("fwd", turtle.forward) then
      turtle.suckDown() -- saplings and apples lying around
      return true
    end
    local ok, b = turtle.inspect()
    if ok then
      if not (isClearable(b) or isLog(b)) then return false end
      turtle.dig()
    else
      turtle.attack() -- a mob
      sleep(0.2)
    end
  end
  return false
end

local function forceUp()
  for _ = 1, 20 do
    if move("up", turtle.up) then return true end
    if turtle.detectUp() then turtle.digUp() else turtle.attackUp() end
  end
  return false
end

local function forceDown()
  for _ = 1, 20 do
    if move("down", turtle.down) then return true end
    if turtle.detectDown() then turtle.digDown() else turtle.attackDown() end
  end
  return false
end

-- ---------------------------------------------------------------- paths --
local isSpot = {}
local function indexSpots()
  isSpot = {}
  for _, k in ipairs(AREA.spots or {}) do isSpot[k] = true end
end

-- Directions from `from` to `to` over the pen's path cells (not tree spots),
-- breadth first; `from` and `to` themselves may be spots.
local function path(from, to)
  local start, goal = key(from.x, from.z), key(to.x, to.z)
  if start == goal then return {} end
  local prev, queue, head = { [start] = false }, { start }, 1
  while queue[head] do
    local cur = queue[head]
    head = head + 1
    local cx, cz = unkey(cur)
    for h = 0, 3 do
      local nk = key(cx + DIRS[h][1], cz + DIRS[h][3])
      if prev[nk] == nil and AREA.cells[nk] and (not isSpot[nk] or nk == goal) then
        prev[nk] = { cur, h }
        if nk == goal then
          local dirs, k = {}, nk
          while prev[k] do table.insert(dirs, 1, prev[k][2]); k = prev[k][1] end
          return dirs
        end
        queue[#queue + 1] = nk
      end
    end
  end
end

local function walkTo(target)
  local dirs = path(S.pos, target)
  if not dirs then return false end
  for _, h in ipairs(dirs) do
    turnTo(h)
    if not step() then return false end
  end
  return true
end

-- ------------------------------------------------------------ inventory --
local function select(slot) turtle.select(slot) end

-- Slot 1 holds our saplings and slot 2 bone meal; everything else is loot,
-- except the wireless modem and compass the base link swaps (link.lua).
local function reserved(i, d)
  return (i == SAPLING_SLOT and d.name == S.sapling)
      or (i == BONEMEAL_SLOT and d.name == "minecraft:bone_meal")
end

local function keep(i, d) return reserved(i, d) or link.isKeptItem(d.name) end

-- Move anything that is not ours out of slots 1 and 2 (e.g. logs that landed
-- there while slot 1 was empty), into the first free loot slot.
local function clearReservedSlots()
  for _, i in ipairs({ SAPLING_SLOT, BONEMEAL_SLOT }) do
    local d = turtle.getItemDetail(i)
    if d and not reserved(i, d) then
      select(i)
      for j = WORK_SLOT, 16 do
        if turtle.getItemCount(i) == 0 then break end
        local dj = turtle.getItemDetail(j)
        if not dj or dj.name == d.name then turtle.transferTo(j) end
      end
    end
  end
  select(WORK_SLOT)
end

-- Keep slot 1 stocked with our saplings from anywhere in the inventory.
local function restockSaplings()
  clearReservedSlots()
  for i = WORK_SLOT, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == S.sapling then
      select(i); turtle.transferTo(SAPLING_SLOT)
    end
  end
  select(WORK_SLOT)
end

local function refuel()
  if turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() >= CFG.fuelLow then return end
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and (isLog(d) or d.name == "minecraft:coal" or d.name == "minecraft:charcoal") and not reserved(i, d) then
      select(i)
      while turtle.getFuelLevel() < CFG.fuelTarget and turtle.getItemCount(i) > 0 do
        if not turtle.refuel(1) then break end
      end
    end
  end
  select(WORK_SLOT)
end

local function haveBoneMeal()
  local bm = turtle.getItemDetail(BONEMEAL_SLOT)
  return bm and bm.name == "minecraft:bone_meal"
end

-- ------------------------------------------------------ planting/felling --
local fell -- forward declaration

-- Use bone meal on the sapling in front until it grows; fell it if it did.
local function boneMeal()
  for _ = 1, CFG.boneMealTries do
    if not haveBoneMeal() then break end
    select(BONEMEAL_SLOT); turtle.place(); select(WORK_SLOT)
    local ok, b = turtle.inspect()
    if ok and isLog(b) then fell(true); return end
    if not (ok and b.name == S.sapling) then return end
  end
end

-- Plant a sapling in front. Bone meal only on spots that were empty, not right
-- after felling: otherwise one spot would grow, fell and replant in a loop
-- until all the bone meal is gone.
local function plant(withBoneMeal)
  restockSaplings()
  if turtle.getItemCount(SAPLING_SLOT) == 0 then return false end
  select(SAPLING_SLOT)
  local ok = turtle.place()
  select(WORK_SLOT)
  if ok and withBoneMeal then boneMeal() end
  return ok
end

local function digLogsAround()
  -- branches (acacia, cherry, ...) that grow out sideways next to the trunk
  for _ = 1, 4 do
    local ok, b = turtle.inspect()
    if ok and isLog(b) then turtle.dig() end
    turtle.turnRight()
  end
end

-- Facing a log from a path cell: step into the trunk, fell it upwards, come
-- back down and out, facing the cell again; replant if asked.
fell = function(replant)
  local facing = S.heading
  turtle.dig()
  if not move("fwd", turtle.forward) then return end
  while S.up < CFG.maxHeight do
    local ok, b = turtle.inspectUp()
    if not (ok and isLog(b)) then break end
    turtle.digUp()
    if not forceUp() then break end
    digLogsAround()
  end
  while S.up > 0 do
    if not forceDown() then error("Cannot get back down", 0) end
  end
  turtle.suck(); turtle.suckDown()
  turnTo(facing)
  if not move("back", turtle.back) then
    turnTo((facing + 2) % 4); step(); turnTo(facing)
  end
  turtle.suck()
  if replant then plant(false) end
end

-- Look after the tree spot in front of us.
local function tend()
  local ok, b = turtle.inspect()
  if not ok then
    plant(true)
  elseif isLog(b) then
    fell(true)
  elseif isLeaves(b) or isPlant(b) then
    turtle.dig()
    turtle.suck()
    plant(true)
  elseif b.name == S.sapling then
    boneMeal()
  end
end

-- ----------------------------------------------------------- exploration --
-- Walk every open cell of the pen once (depth first, back-tracking), caching
-- each cell and the block under it. Trees inside are felled, plants cleared.
local function explore()
  log("Measuring the pen...")
  local ok0, ground0 = turtle.inspectDown()
  AREA = { done = false, cells = { [key(0, 0)] = ok0 and ground0.name or "air" }, spots = {} }
  saveArea()
  local border = {}
  local count = 1
  local stack = { { x = 0, z = 0, next = 0 } }
  while #stack > 0 do
    local top = stack[#stack]
    if top.next < 4 then
      local h = top.next
      top.next = h + 1
      local nx, nz = top.x + DIRS[h][1], top.z + DIRS[h][3]
      local nk = key(nx, nz)
      if not AREA.cells[nk] and not border[nk] then
        turnTo(h)
        local ok, b = turtle.inspect()
        if ok and isLog(b) then fell(false); ok, b = turtle.inspect() end
        if ok and isClearable(b) then turtle.dig(); ok, b = turtle.inspect() end
        if ok then
          border[nk] = true
        elseif move("fwd", turtle.forward) then
          local okd, ground = turtle.inspectDown()
          AREA.cells[nk] = okd and ground.name or "air"
          count = count + 1
          if count > CFG.maxArea then
            error(("The pen is not closed: more than %d open cells. Close the fence and run 'forester rescan'.")
              :format(CFG.maxArea), 0)
          end
          saveArea() -- every cell at once: a restart must find its way back home
          stack[#stack + 1] = { x = nx, z = nz, next = 0, back = (h + 2) % 4 }
        else
          border[nk] = true
        end
      end
    else
      stack[#stack] = nil
      if top.back then
        turnTo(top.back)
        if not move("fwd", turtle.forward) then error("Could not step back while measuring the pen", 0) end
      end
    end
  end
  -- tree spots: every `spacing` cells from home, on soil, next to a path cell
  local spots = {}
  for k, ground in pairs(AREA.cells) do
    local x, z = unkey(k)
    if (x ~= 0 or z ~= 0) and x % CFG.spacing == 0 and z % CFG.spacing == 0 and isSoil(ground) then
      spots[#spots + 1] = k
    end
  end
  table.sort(spots)
  AREA.spots = spots
  AREA.done = true
  saveArea()
  indexSpots()
  log(("Pen: %d cells, %d tree spots."):format(count, #spots))
end

-- ------------------------------------------------------------- the round --
local function unload()
  turnTo((S.homeHeading + 2) % 4) -- chest is behind the home spot
  local ok, b = turtle.inspect()
  if not (ok and b.name:find("chest")) then
    error("No chest behind me: I'm not where I think home is. Not unloading.", 0)
  end
  clearReservedSlots()
  local logsKept, delivered = 0, 0
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and not keep(i, d) then
      select(i)
      if d.name == S.sapling then
        turtle.transferTo(SAPLING_SLOT)
        if turtle.getItemCount(i) > 0 then turtle.drop() end
      elseif isLog(d) and logsKept < CFG.keepLogs then
        local keepN = math.min(d.count, CFG.keepLogs - logsKept)
        logsKept = logsKept + keepN
        if d.count > keepN then
          turtle.drop(d.count - keepN)
          delivered = delivered + d.count - keepN
        end
      else
        if isLog(d) then delivered = delivered + d.count end
        turtle.drop()
      end
    end
  end
  select(WORK_SLOT)
  turnTo(S.homeHeading)
  return delivered
end

local function goHome()
  while S.up > 0 do
    if not forceDown() then error("Cannot get back down", 0) end
  end
  if not walkTo({ x = 0, z = 0 }) then error("Cannot find my way home through the pen", 0) end
end

local function dist(a, x, z) return math.abs(a.x - x) + math.abs(a.z - z) end

local function round()
  select(WORK_SLOT)
  refuel()
  -- visit the spots nearest first
  local todo = {}
  for _, k in ipairs(AREA.spots) do todo[#todo + 1] = k end
  while #todo > 0 do
    local bi, bd = 1, math.huge
    for i, k in ipairs(todo) do
      local x, z = unkey(k)
      local d = dist(S.pos, x, z)
      if d < bd then bi, bd = i, d end
    end
    local sx, sz = unkey(table.remove(todo, bi))
    -- the nearest path cell next to the spot we can reach
    local best, bestLen
    for h = 0, 3 do
      local ax, az = sx - DIRS[h][1], sz - DIRS[h][3]
      local ak = key(ax, az)
      if AREA.cells[ak] and not isSpot[ak] then
        local p = path(S.pos, { x = ax, z = az })
        if p and (not bestLen or #p < bestLen) then best, bestLen = { x = ax, z = az, h = h }, #p end
      end
    end
    if best and walkTo(best) then
      turnTo(best.h)
      tend()
    end
  end
  goHome()
  refuel()
  local delivered = unload()
  S.delivered = (S.delivered or 0) + delivered
  save()
  -- tell the base (if it can); code updates apply here
  link.talk("resting", { delivered = delivered, total = S.delivered, sapling = S.sapling })
end

-- ------------------------------------------------------------------- main --
local args = { ... }
link.restoreUpgrade() -- compass back in, if a restart caught it mid-talk
S = readTable(CFG.stateFile)
AREA = readTable(CFG.areaFile)

-- older installs ran in lane mode: start over in the pen
if S and not S.pos.x then S = nil end

if S then
  -- settle a move that was in flight when it stopped, and re-read the facing:
  -- a turn may have happened without being saved
  tmove.recover(S, save, applyMove)
  S.heading = nav.compass() or S.heading
  save()
  log(("Resuming: %s"):format(S.sapling))
  if AREA then indexSpots() end
  -- an unfinished measurement: back home over the cells known so far, measure again
  if AREA and AREA.cells then
    while S.up > 0 do forceDown() end
    if not walkTo({ x = 0, z = 0 }) then error("Cannot find my way home", 0) end
  end
  if not AREA or not AREA.done then AREA = nil end
else
  local d = turtle.getItemDetail(SAPLING_SLOT)
  if not d then error("Put the saplings to plant in slot 1 (top left)", 0) end
  local h = nav.compass()
  if not h then log("No compass upgrade: it cannot re-check its facing after a restart.") end
  S = { sapling = d.name, homeHeading = h or 0, heading = h or 0, pos = { x = 0, z = 0 }, up = 0 }
end
-- forester [wait] ; the agent passes "<trees> <wait>" (trees is not used any more)
local nums = {}
for _, a in ipairs(args) do if tonumber(a) then nums[#nums + 1] = tonumber(a) end end
S.wait = nums[#nums] or S.wait or CFG.wait
save()

if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() == 0 then
  error("No fuel: put coal or logs in it", 0)
end

if args[1] == "rescan" or not AREA then
  refuel()
  explore()
  turnTo(S.homeHeading)
end

local rounds = 0
while true do
  round()
  rounds = rounds + 1
  log(("Round %d done. Fuel %s. Next in %ds."):format(rounds, tostring(turtle.getFuelLevel()), S.wait))
  sleep(S.wait)
end
