-- forester: tree farm turtle (CC: Tweaked + Advanced Peripherals).
--
-- The turtle: an advanced turtle with a diamond pickaxe (it breaks wood fine)
-- and a compass (craft the turtle with a plain Compass). The compass lets it
-- know which way it faces after a server restart. Needs tmove.lua next to it.
--
-- Layout (seen from above, turtle T facing up, chest C behind it):
--
--     S . S        S = sapling spot (dirt or grass underneath), every 3 blocks
--     . . .        . = air; the middle column is the lane the turtle walks
--     . . .
--     S . S
--     . T .
--       C
--
-- Slot 1 (top left): the saplings to plant. Only that kind is planted; saplings
-- picked up from fallen leaves go back into slot 1.
-- Slot 2: optional bone meal, used on fresh saplings.
--
-- Run: forester [trees] [wait]
--   trees  spots per side of the lane (default 6, i.e. 12 trees)
--   wait   seconds between rounds (default 300)
-- Each round it walks the lane, plants empty spots, fells grown trees and
-- replants, then empties wood and drops into the chest, keeping saplings, bone
-- meal and a few logs for fuel. startup.lua resumes it after a restart.

local tmove = require("tmove")
local link = require("link")

local CFG = {
  trees = 6,
  spacing = 3,         -- blocks between spots along the lane
  wait = 300,
  maxHeight = 40,      -- never climb higher than this when felling
  fuelLow = 300,       -- refuel from logs below this ...
  fuelTarget = 600,    -- ... up to this
  keepLogs = 16,       -- logs it keeps for fuel when unloading
  boneMealTries = 8,   -- bone meal uses per sapling before giving up
  stateFile = "forester.state",
}

-- CC puts dug items into the selected slot first, so the turtle works with slot
-- 3 selected and only selects slot 1 or 2 to place from them.
local SAPLING_SLOT, BONEMEAL_SLOT, WORK_SLOT = 1, 2, 3
local HEADINGS = { north = 0, east = 1, south = 2, west = 3 }

-- Persisted: { sapling, trees, wait, lane (absolute heading of the lane),
--   face (0 out along the lane, 1 right, 2 back home, 3 left),
--   pos (blocks out along the lane), up (blocks up a trunk),
--   inTree (face we entered a tree spot with, or nil), pending (tmove) }
local S

local function log(...) print(...) end

local function save()
  local f = fs.open(CFG.stateFile, "w")
  f.write(textutils.serialize(S))
  f.close()
end

local function load()
  if not fs.exists(CFG.stateFile) then return nil end
  local f = fs.open(CFG.stateFile, "r")
  local s = textutils.unserialize(f.readAll())
  f.close()
  return s
end

-- Absolute heading from the compass upgrade, or nil without one.
local function compassHeading()
  local c = peripheral.find("compass")
  if not c then return nil end
  return HEADINGS[tostring(c.getFacing()):lower()]
end

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

local function isSaplingBlock(b) return b and b.name == S.sapling end

-- ------------------------------------------------------------- movement --
local function turnTo(f)
  local d = (f - S.face) % 4
  if d == 1 then turtle.turnRight() elseif d == 2 then turtle.turnRight(); turtle.turnRight()
  elseif d == 3 then turtle.turnLeft() end
  S.face = f
  save()
end

-- Position update for a completed move (also replayed by tmove.recover).
local function applyMove(st, kind)
  if kind == "up" then st.up = st.up + 1
  elseif kind == "down" then st.up = st.up - 1
  elseif kind == "back" then st.inTree = nil -- only used to back out of a tree spot
  elseif st.face == 0 then st.pos = st.pos + 1
  elseif st.face == 2 then st.pos = st.pos - 1
  elseif st.inTree == nil then st.inTree = st.face -- stepped sideways into a spot
  else st.inTree = nil end                          -- stepped back out to the lane
end

local function move(kind, fn) return tmove.move(S, save, kind, fn, applyMove) end

local function force(kind, fn, detect, dig, attack)
  for _ = 1, 20 do
    if move(kind, fn) then return true end
    if detect() then dig() else attack() end
  end
  return false
end

local function forceForward() return force("fwd", turtle.forward, turtle.detect, turtle.dig, turtle.attack) end
local function forceUp() return force("up", turtle.up, turtle.detectUp, turtle.digUp, turtle.attackUp) end
local function forceDown() return force("down", turtle.down, turtle.detectDown, turtle.digDown, turtle.attackDown) end

-- Move along the lane (face 0 = outwards, 2 = home) one block.
local function laneStep(dir)
  turnTo(dir)
  if not forceForward() then error("Lane is blocked", 0) end
  turtle.suckDown() -- pick up saplings and apples lying on the lane
end

-- Leave a tree spot back to the lane, facing the spot again.
local function leaveSpot()
  local side = S.inTree
  turnTo(side)
  if not move("back", turtle.back) then
    turnTo((side + 2) % 4)
    forceForward()
    turnTo(side)
  end
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
    if d and isLog(d) and not reserved(i, d) then
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

local fell -- forward declaration

-- Use bone meal on the sapling in front until it grows; fell it if it did.
local function boneMeal()
  for _ = 1, CFG.boneMealTries do
    if not haveBoneMeal() then break end
    select(BONEMEAL_SLOT); turtle.place(); select(WORK_SLOT)
    local ok, b = turtle.inspect()
    if ok and isLog(b) then fell(); return end
    if not (ok and isSaplingBlock(b)) then return end
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

-- --------------------------------------------------------------- felling --
local function digLogsAround()
  -- branches (acacia, cherry, ...) that grow out sideways next to the trunk
  for _ = 1, 4 do
    local ok, b = turtle.inspect()
    if ok and isLog(b) then turtle.dig() end
    turtle.turnRight()
  end
end

-- Facing a log: fell the tree, come back to the lane, replant.
fell = function()
  turtle.dig()
  if not forceForward() then return end
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
  leaveSpot()
  turtle.suck()
  plant(false)
end

-- Look after the spot in front of us.
local function tend()
  local ok, b = turtle.inspect()
  if not ok then
    plant(true)
  elseif isLog(b) then
    fell()
  elseif isLeaves(b) then
    turtle.dig()
    turtle.suck()
    plant(true)
  elseif isSaplingBlock(b) then
    boneMeal()
  end
end

-- -------------------------------------------------------------- the round --
local function unload()
  turnTo(2) -- chest is behind the home spot
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
  turnTo(0)
  return delivered
end

local function goHome()
  while S.up > 0 do
    if not forceDown() then error("Cannot get back down", 0) end
  end
  if S.inTree then leaveSpot() end
  while S.pos > 0 do laneStep(2) end
end

local function round()
  select(WORK_SLOT)
  refuel()
  for _ = 1, S.trees do
    for _ = 1, CFG.spacing do laneStep(0) end
    turnTo(3); tend()
    turnTo(1); tend()
  end
  goHome()
  refuel()
  local delivered = unload()
  S.delivered = (S.delivered or 0) + delivered
  save()
  -- tell the base (if it has a wireless modem); code updates apply here
  link.talk("resting", { delivered = delivered, total = S.delivered, sapling = S.sapling })
end

-- ------------------------------------------------------------------- main --
local args = { ... }
link.restoreUpgrade() -- compass back in, if a restart caught it mid-talk
S = load()
if S then
  -- settle a move that was in flight when it stopped, and re-read the facing:
  -- a turn may have happened without being saved
  tmove.recover(S, save, applyMove)
  local h = compassHeading()
  if h then S.face = (h - S.lane) % 4; save() end
  log(("Resuming: %s, %d spots per side"):format(S.sapling, S.trees))
  goHome()
  turnTo(0)
else
  local d = turtle.getItemDetail(SAPLING_SLOT)
  if not d then error("Put the saplings to plant in slot 1 (top left)", 0) end
  local h = compassHeading()
  if not h then log("No compass upgrade: it cannot re-check its facing after a restart.") end
  S = { sapling = d.name, trees = tonumber(args[1]) or CFG.trees,
        wait = tonumber(args[2]) or CFG.wait, lane = h or 0, pos = 0, face = 0, up = 0 }
  save()
  log(("Planting %s, %d spots per side, a round every %ds"):format(S.sapling, S.trees, S.wait))
end
if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() == 0 then
  error("No fuel: put coal or logs in it", 0)
end

local rounds = 0
while true do
  round()
  rounds = rounds + 1
  log(("Round %d done. Fuel %s. Next in %ds."):format(rounds, tostring(turtle.getFuelLevel()), S.wait))
  sleep(S.wait)
end
