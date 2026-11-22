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
-- (sideways branches too) and replants, then goes home. The home chest is a
-- mailbox: it asks the base for what it wants to carry (saplings, bone meal,
-- fuel, dirt for the floor) and takes what the base sends there, then empties
-- wood and drops into it (keeping saplings, bone
-- meal, fuel and a few logs) and reports to the base.
--
-- Saplings: it plants every kind it carries, taking turns (round-robin), so a
-- mix of trees grows; the base says which kinds are selected on the monitor
-- (others go back into the chest). Slot 2: bone meal.
--
-- Run: forester [wait] | forester rescan     (wait: seconds between rounds)

local tmove = require("tmove")
local link = require("link")
local C = require("oreconf")
local nav = require("nav")

local CFG = {
  spacing = 3,         -- tree spots when it has no saplings yet (else oreconf.TREES)
  wait = 300,
  maxHeight = 40,      -- never climb higher than this when felling
  maxArea = 1024,      -- more open cells than this: the pen is not closed
  fuelLow = 300,       -- refuel from logs below this ...
  fuelTarget = 600,    -- ... up to this
  keepLogs = 16,       -- logs it keeps for fuel when unloading
  keepSaplings = 64,   -- saplings it keeps of each kind when unloading
  keepFuel = 64,       -- fuel items (charcoal...) it keeps when unloading
  supply = { fuel = 16, saplings = 16, bonemeal = 32 }, -- what it asks the base for at home
  treeFuel = 2 * 40 + 10, -- fuel one tree may take (climb up and down, maxHeight)
  minRoundFuel = 60,   -- below this (after filling up at home) it waits at home
  boneMealTries = 8,   -- bone meal uses per sapling before giving up
  stateFile = "forester.state",
  areaFile = "forester.area",
}

-- CC puts dug items into the selected slot first, so the turtle works with slot
-- 3 selected and only selects a sapling's slot or slot 2 (bone meal) to place.
local BONEMEAL_SLOT, WORK_SLOT = 2, 3
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
      or n:find("bush") or n:find("tulip") or n:find("poppy") or n:find("dandelion")
      or n:find("mushroom") and not n:find("block") or n:find("vine") or n:find("sugar_cane")
      or n:find("berry") or false
end

local DIRT = "minecraft:dirt"

local function isFluid(name) return name and (name:find("water") or name:find("lava")) and true or false end

-- never dig these out of the floor (its modem, chests, other machines)
local function isMachine(name)
  return name:find("computercraft") or name:find("chest") or name:find("barrel") or name:find("modem")
end

-- may be removed when it is in a path or a spot (everything else is a border)
local function isClearable(b) return isLeaves(b) or isPlant(b) or isSapling(b) end

-- the pen's floor: dirt or grass (not a dirt path); anything else under a
-- cell is dug out and replaced with dirt
local function isSoil(name)
  return name and ((name:find("dirt") and not name:find("path")) or name:find("grass_block")) and true or false
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

local refuel -- (below)

-- Every move goes through here: below the low mark it first burns logs or
-- fuel it carries (measuring a big pen takes 1000+ moves), and with nothing
-- left it says so instead of failing as if the way were blocked.
local function move(kind, fn)
  local f = turtle.getFuelLevel()
  if f ~= "unlimited" and f < CFG.fuelLow then
    refuel()
    if turtle.getFuelLevel() == 0 then error("Out of fuel: put coal, charcoal or logs in me", 0) end
  end
  return tmove.move(S, save, kind, fn, applyMove)
end

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
local placeSpots -- (below)
local function indexSpots()
  isSpot = {}
  for _, k in ipairs(AREA.spots or {}) do isSpot[k] = true end
end

-- The sapling kinds it plants now: the ones the base selected, else the ones
-- it carries (never a 2x2-only kind).
local function isSaplingName(name) return name:find("sapling") ~= nil or name:find("propagule") ~= nil end
local function kindsInPlay()
  local kinds = {}
  if S.allowed then
    for k in pairs(S.allowed) do kinds[k] = true end
  else
    for i = 1, 16 do
      local d = turtle.getItemDetail(i)
      if d and isSaplingName(d.name) then kinds[d.name] = true end
    end
  end
  for k in pairs(kinds) do if C.tree(k).twoByTwo then kinds[k] = nil end end
  return kinds
end

-- Spacing for the kinds in play: the widest one decides (mixed kinds share
-- one grid). And whether any needs grass/dirt under its 4 side cells.
local function treeNeeds()
  local spacing, around = nil, false
  for k in pairs(kindsInPlay()) do
    local t = C.tree(k)
    spacing = math.max(spacing or 0, t.spacing)
    around = around or t.soilAround == true
  end
  return spacing or CFG.spacing, around
end

-- Tree spots: every `spacing` cells, counted from the pen's corner (its
-- lowest x and z), starting one cell in so a path runs along the fence.
-- Spots still without soil get dirt in the rounds.
placeSpots = function()
  local spacing = treeNeeds()
  local minX, minZ
  for k in pairs(AREA.cells) do
    local x, z = unkey(k)
    minX, minZ = math.min(minX or x, x), math.min(minZ or z, z)
  end
  local ax, az = minX + 1, minZ + 1
  local spots = {}
  for k in pairs(AREA.cells) do
    local x, z = unkey(k)
    if (x ~= 0 or z ~= 0) and (x - ax) % spacing == 0 and (z - az) % spacing == 0 then spots[#spots + 1] = k end
  end
  table.sort(spots)
  AREA.spots, AREA.spacing = spots, spacing
  saveArea()
  indexSpots()
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

local isSaplingItem = isSaplingName

-- the kinds the base selected (nil: any kind it carries)
local function allowed(name) return not S.allowed or S.allowed[name] == true end

-- Saplings it may plant (any slot) and bone meal in slot 2 are ours;
-- everything else is loot, except the wireless modem and compass the base
-- link swaps (link.lua).
local function reserved(i, d)
  return (i ~= BONEMEAL_SLOT and isSaplingItem(d.name) and allowed(d.name))
      or (i == BONEMEAL_SLOT and d.name == "minecraft:bone_meal")
end

-- the kinds selected on the monitor (false: any)
local function setAllowed(plant)
  local set
  if plant then set = {}; for _, n in ipairs(plant) do set[n] = true end end
  S.allowed = set
  save()
end

-- dirt stays too: it lays the pen's floor with it
local function keep(i, d) return reserved(i, d) or link.isKeptItem(d.name) or d.name == DIRT end

local function dirtSlot()
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == DIRT then return i end
  end
end

-- Make the block under us dirt, unless it is dirt or grass already: fill a
-- hole (air, water, lava, a plant), dig out anything else (stone, sand...)
-- and put dirt there. Machines (its modem, chests) are never touched.
-- Returns the ground block's name, or nil if it needed dirt and had none.
local function fixGround()
  local ok, b = turtle.inspectDown()
  if ok and (isSoil(b.name) or isMachine(b.name)) then return b.name end
  if ok and not isFluid(b.name) then
    if not isClearable(b) and not dirtSlot() then return b.name end -- keep the floor until we have dirt
    turtle.digDown()
  end
  local slot = dirtSlot()
  if not slot then return nil end
  turtle.select(slot)
  local placed = turtle.placeDown()
  turtle.select(WORK_SLOT)
  if not placed then return nil end
  return DIRT
end

-- a floor cell that still needs dirt (measured without dirt for it)
local function needsDirt(name) return not isSoil(name) and not (name and isMachine(name)) end

local function dirtCount()
  local n = 0
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == DIRT then n = n + d.count end
  end
  return n
end

-- Cells whose floor still needs dirt. { key = true }
local function cellsNeedingDirt()
  local need = {}
  for k, g in pairs(AREA.cells) do if needsDirt(g) then need[k] = true end end
  return need
end


-- Move anything that is not bone meal out of slot 2, into a free loot slot.
local function clearReservedSlots()
  for _, i in ipairs({ BONEMEAL_SLOT }) do
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

-- Bone meal from anywhere into slot 2.
local function restock()
  clearReservedSlots()
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if i ~= BONEMEAL_SLOT and d and d.name == "minecraft:bone_meal" then
      select(i); turtle.transferTo(BONEMEAL_SLOT)
    end
  end
  select(WORK_SLOT)
end

-- The slot of the next kind of sapling to plant: the kinds it carries take
-- turns (round-robin), so no kind is planted only ever.
local function nextSapling()
  local kinds, slotOf = {}, {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and reserved(i, d) and isSaplingItem(d.name) and not slotOf[d.name] then
      kinds[#kinds + 1] = d.name
      slotOf[d.name] = i
    end
  end
  if #kinds == 0 then return nil end
  table.sort(kinds)
  S.turn = (S.turn or 0) + 1
  return slotOf[kinds[(S.turn - 1) % #kinds + 1]]
end

refuel = function()
  if turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() >= CFG.fuelLow then return end
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and (isLog(d) or C.isFuel(d.name)) and not reserved(i, d) then
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
    if not (ok and isSapling(b)) then return end
  end
end

-- Plant a sapling in front. Bone meal only on spots that were empty, not right
-- after felling: otherwise one spot would grow, fell and replant in a loop
-- until all the bone meal is gone.
local function plant(withBoneMeal)
  restock()
  local slot = nextSapling()
  if not slot then return false end
  select(slot)
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
  elseif isSapling(b) then
    boneMeal()
  end
end

-- ----------------------------------------------------------- exploration --
-- Measure the pen: every open cell (and the block under it) is cached in
-- forester.area, every fence/wall cell next to it in AREA.border. It works
-- from the frontier: walk to the nearest known cell next to one not looked at
-- yet and look. So it can stop any time and carry on later from the map
-- (after a restart, or a trip home for fuel). Trees inside are felled,
-- plants cleared.
local fuelTrip -- (below: home, mailbox, fuel from the base)

local function frontier()
  -- nearest known cell (walking) that has a neighbour not looked at yet
  local start = key(S.pos.x, S.pos.z)
  local seen, queue, head = { [start] = 0 }, { start }, 1
  while queue[head] do
    local cur = queue[head]
    head = head + 1
    local cx, cz = unkey(cur)
    for h = 0, 3 do
      local nk = key(cx + DIRS[h][1], cz + DIRS[h][3])
      if not AREA.cells[nk] and not AREA.border[nk] then return { x = cx, z = cz, h = h }, seen[cur] end
    end
    for h = 0, 3 do
      local nk = key(cx + DIRS[h][1], cz + DIRS[h][3])
      if AREA.cells[nk] and seen[nk] == nil then
        seen[nk] = seen[cur] + 1
        queue[#queue + 1] = nk
      end
    end
  end
end

local function cellCount()
  local n = 0
  for _ in pairs(AREA.cells) do n = n + 1 end
  return n
end

local function explore()
  if not AREA or AREA.done then
    log("Measuring the pen...")
    local ok0, ground0 = turtle.inspectDown()
    AREA = { done = false, cells = { [key(0, 0)] = ok0 and ground0.name or "air" }, border = {}, spots = {} }
    saveArea()
  else
    log(("Measuring the pen, carrying on (%d cells so far)..."):format(cellCount()))
  end
  AREA.border = AREA.border or {}
  while true do
    local f, dist = frontier()
    if not f then break end
    -- fuel for the way there, one step, and the way home from there
    local back = path({ x = f.x, z = f.z }, { x = 0, z = 0 })
    local need = dist + 1 + (back and #back or dist) + 20
    if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < need then
      refuel()
      if turtle.getFuelLevel() < need then fuelTrip(need) end
    end
    if not walkTo({ x = f.x, z = f.z }) then error("Cannot reach a cell of the pen I have seen", 0) end
    local nx, nz = f.x + DIRS[f.h][1], f.z + DIRS[f.h][3]
    local nk = key(nx, nz)
    turnTo(f.h)
    local ok, b = turtle.inspect()
    if ok and isLog(b) then fell(false); ok, b = turtle.inspect() end
    if ok and isClearable(b) then turtle.dig(); ok, b = turtle.inspect() end
    if ok or not move("fwd", turtle.forward) then
      AREA.border[nk] = true
    else
      AREA.cells[nk] = fixGround() or "air" -- (no dirt yet: later, in the rounds)
      if cellCount() > CFG.maxArea then
        error(("The pen is not closed: more than %d open cells. Close the fence and run 'forester rescan'.")
          :format(CFG.maxArea), 0)
      end
    end
    saveArea() -- every cell at once: a restart carries on from the map
  end
  AREA.done = true
  placeSpots()
  log(("Pen: %d cells, %d tree spots %d apart."):format(cellCount(), #AREA.spots, AREA.spacing))
end

-- ------------------------------------------------------------- the round --
-- Drop what it doesn't keep into the chest in front; returns the logs dropped.
local function dropHaul()
  -- keep: saplings it may plant (CFG.keepSaplings of each), bone meal in
  -- slot 2, fuel, a few logs, dirt; the rest goes into the chest
  local kept, delivered = {}, 0
  local function keepUpTo(i, d, n)
    local k = math.min(d.count, math.max(0, n - (kept[d.name] or 0)))
    kept[d.name] = (kept[d.name] or 0) + k
    if d.count > k then select(i); turtle.drop(d.count - k) end
    return d.count - k
  end
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and not (link.isKeptItem(d.name) or d.name == DIRT or (i == BONEMEAL_SLOT and d.name == "minecraft:bone_meal")) then
      if isSaplingItem(d.name) and allowed(d.name) then keepUpTo(i, d, CFG.keepSaplings)
      elseif isLog(d) then delivered = delivered + keepUpTo(i, d, CFG.keepLogs)
      elseif C.isFuel(d.name) then keepUpTo(i, d, CFG.keepFuel)
      else select(i); turtle.drop() end
    end
  end
  return delivered
end

-- At home, facing the chest: unload the haul FIRST (room to take supplies;
-- the base empties the chest before it sends), ask the base for what we want
-- to carry, take it all, and put back what we don't keep.
local function unload()
  turnTo((S.homeHeading + 2) % 4) -- chest is behind the home spot
  local ok, b = turtle.inspect()
  if not (ok and b.name:find("chest")) then
    error("No chest behind me: I'm not where I think home is. Not unloading.", 0)
  end
  link.claimChest() -- (once, while it has something to mark the chest with)
  local delivered = dropHaul()
  local dirt = 0
  if AREA and AREA.cells then for _ in pairs(cellsNeedingDirt()) do dirt = dirt + 1 end end
  local r = link.supply({ fuel = CFG.supply.fuel, saplings = CFG.supply.saplings,
                          bonemeal = CFG.supply.bonemeal, dirt = dirt })
  if r and r.plant ~= nil then setAllowed(r.plant) end
  restock()
  dropHaul() -- (what it took but doesn't keep)
  select(WORK_SLOT)
  turnTo(S.homeHeading)
  return delivered
end

-- Measuring ran low on fuel: home, take the mailbox (the base keeps fuel in
-- the chest), drop the clutter, burn what it has, and ask the base for more.
-- At home: take the mailbox (the base keeps fuel in the chest), drop the
-- clutter, burn what it has, ask the base for more. True when it has `need`.
local function fillUp(need)
  unload()
  refuel()
  local f = turtle.getFuelLevel()
  if f ~= "unlimited" and f < need then
    local got, why = link.requestFuel(math.max(need, CFG.fuelTarget) - f)
    log(got and ("The base gave me %d fuel"):format(got) or ("No fuel from the base: " .. tostring(why)))
  end
  return turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() >= need
end

fuelTrip = function(need)
  log("Low on fuel: going home to fill up")
  while S.up > 0 do forceDown() end
  if not walkTo({ x = 0, z = 0 }) then error("Cannot find my way home through the pen", 0) end
  if not fillUp(need) then
    error(("Out of fuel while measuring the pen (%s, need %d): put coal or logs in me (I'm home)")
      :format(tostring(turtle.getFuelLevel()), need), 0)
  end
end

local function goHome()
  while S.up > 0 do
    if not forceDown() then error("Cannot get back down", 0) end
  end
  if not walkTo({ x = 0, z = 0 }) then error("Cannot find my way home through the pen", 0) end
end

local function dist(a, x, z) return math.abs(a.x - x) + math.abs(a.z - z) end

-- A path cell whose floor isn't dirt or grass yet: stand on it and fix it.
local function fillHole(k)
  local x, z = unkey(k)
  if needsDirt(AREA.cells[k]) and dirtSlot() and walkTo({ x = x, z = z }) then
    AREA.cells[k] = fixGround() or AREA.cells[k]
    saveArea()
  end
end

-- A tree spot: lay soil (and under its side cells for menril) if it has
-- dirt, then tend it from the nearest path cell next to it.
local function visitSpot(sk, soilAround)
  local sx, sz = unkey(sk)
  if not isSoil(AREA.cells[sk]) and dirtSlot() and walkTo({ x = sx, z = sz }) then
    AREA.cells[sk] = fixGround() or AREA.cells[sk]
    saveArea()
  end
  if soilAround and isSoil(AREA.cells[sk]) then
    for h = 0, 3 do
      local nk = key(sx + DIRS[h][1], sz + DIRS[h][3])
      local nx, nz = unkey(nk)
      if AREA.cells[nk] and not isSoil(AREA.cells[nk]) and dirtSlot() and walkTo({ x = nx, z = nz }) then
        AREA.cells[nk] = fixGround() or AREA.cells[nk]
        saveArea()
      end
    end
  end
  local best, bestLen
  for h = 0, 3 do
    local ax, az = sx - DIRS[h][1], sz - DIRS[h][3]
    local ak = key(ax, az)
    if AREA.cells[ak] and not isSpot[ak] then
      local p = path(S.pos, { x = ax, z = az })
      if p and (not bestLen or #p < bestLen) then best, bestLen = { x = ax, z = az, h = h }, #p end
    end
  end
  if best and isSoil(AREA.cells[sk]) and walkTo(best) then
    turnTo(best.h)
    tend()
  end
end

local function round()
  select(WORK_SLOT)
  refuel()
  -- (at home) too little fuel to go out at all: fill up, else wait here
  local f0 = turtle.getFuelLevel()
  if f0 ~= "unlimited" and f0 < CFG.fuelLow and not fillUp(CFG.fuelLow) and turtle.getFuelLevel() < CFG.minRoundFuel then
    log(("Fuel %d: waiting at home for fuel (put coal or logs in me, or in my chest)"):format(turtle.getFuelLevel()))
    return false
  end
  -- the kinds changed (the base's selection, what it carries): new grid
  local spacing, soilAround = treeNeeds()
  if spacing ~= AREA.spacing then
    placeSpots()
    log(("Tree spots now %d apart: %d spots"):format(spacing, #AREA.spots))
  end
  -- visit the spots nearest first, and the holes in the path while it has
  -- dirt for them
  local todo = {}
  for _, k in ipairs(AREA.spots) do todo[#todo + 1] = k end
  if dirtSlot() then
    local holes = {}
    for k, g in pairs(AREA.cells) do
      if not isSpot[k] and needsDirt(g) then holes[#holes + 1] = k end
    end
    table.sort(holes)
    for _, k in ipairs(holes) do todo[#todo + 1] = k end
  end
  while #todo > 0 do
    local bi, bd = 1, math.huge
    for i, k in ipairs(todo) do
      local x, z = unkey(k)
      local d = dist(S.pos, x, z)
      if d < bd then bi, bd = i, d end
    end
    local sk = table.remove(todo, bi)
    -- enough fuel to get there, fell a tree and walk home? else home now
    local sx0, sz0 = unkey(sk)
    local there = path(S.pos, { x = sx0, z = sz0 }) or {}
    local back = path({ x = sx0, z = sz0 }, { x = 0, z = 0 }) or there
    local need = #there + #back + (isSpot[sk] and CFG.treeFuel or 1)
    if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < need then
      refuel()
      if turtle.getFuelLevel() < need then
        log(("Fuel %d: not enough for the next tree and the way home, going home early"):format(turtle.getFuelLevel()))
        break
      end
    end
    if isSpot[sk] then visitSpot(sk, soilAround) else fillHole(sk) end
  end
  goHome()
  refuel()
  local delivered = unload()
  S.delivered = (S.delivered or 0) + delivered
  save()
  -- tell the base (if it can); code updates apply here
  local cells = 0
  for _ in pairs(cellsNeedingDirt()) do cells = cells + 1 end
  if cells > dirtCount() then log(("%d cells of the pen need dirt, I carry %d"):format(cells, dirtCount())) end
  refuel()
  local f = turtle.getFuelLevel()
  if f ~= "unlimited" and f < CFG.fuelLow then
    local got, why = link.requestFuel(CFG.fuelTarget - f)
    log(got and ("The base gave me %d fuel"):format(got) or ("Low on fuel, none from the base: " .. tostring(why)))
  end
  local r = link.talk("resting", { delivered = delivered, total = S.delivered })
  if type(r) == "table" and r.plant ~= nil then setAllowed(r.plant) end
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
  log("Resuming")
  if AREA then indexSpots() end
  -- a measurement that was cut short carries on from its map (explore);
  -- a finished pen: back home first (a round restarts from home)
  if AREA and AREA.cells then
    while S.up > 0 do forceDown() end
    if AREA.done and not walkTo({ x = 0, z = 0 }) then error("Cannot find my way home", 0) end
  end
else
  local h = nav.compass()
  if not h then log("No compass upgrade: it cannot re-check its facing after a restart.") end
  S = { homeHeading = h or 0, heading = h or 0, pos = { x = 0, z = 0 }, up = 0 }
  local any = false
  for i = 1, 16 do local d = turtle.getItemDetail(i); if d and isSaplingItem(d.name) then any = true end end
  if not any then log("No saplings yet: the base puts them in the home chest (or give me some)") end
end
-- forester [wait] ; the agent passes "<trees> <wait>" (trees is not used any more)
local nums = {}
for _, a in ipairs(args) do if tonumber(a) then nums[#nums + 1] = tonumber(a) end end
S.wait = nums[#nums] or S.wait or CFG.wait
save()

if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() == 0 then
  refuel() -- (what it carries first)
  if turtle.getFuelLevel() == 0 then error("No fuel: put coal or logs in it", 0) end
end

if args[1] == "rescan" then AREA = nil end
if not AREA or not AREA.done then
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
