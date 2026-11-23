-- travel: a turtle fresh from the assembler walks to its home slot.
--
-- It asks the base for a home slot (an offset from the build spot, and the way
-- to face there), rises CLEARANCE blocks above the build spot, flies across,
-- comes down and turns to face the right way. It never digs (it is inside the
-- base): if something is in the way it waits and tries again. Moves are
-- journaled (tmove), so a restart on the way just continues.

local tmove = require("tmove")
local link = require("link")
local nav = require("nav")

local T = {}

local STATE = "travel.state"
local CLEARANCE = 3     -- blocks above the build spot it travels at
local MIN_FUEL = 200

local function readState()
  if not fs.exists(STATE) then return nil end
  local f = fs.open(STATE, "r")
  local s = textutils.unserialize(f.readAll())
  f.close()
  return s
end

local st
local function save()
  local f = fs.open(STATE, "w")
  f.write(textutils.serialize(st))
  f.close()
end

local function apply(s, kind)
  if kind == "up" then s.pos.y = s.pos.y + 1
  elseif kind == "down" then s.pos.y = s.pos.y - 1
  else
    local d = nav.DIRS[s.heading]
    s.pos.x, s.pos.z = s.pos.x + d[1], s.pos.z + d[3]
  end
end

local function turnTo(h)
  local d = (h - st.heading) % 4
  if d == 1 then turtle.turnRight() elseif d == 2 then turtle.turnRight(); turtle.turnRight()
  elseif d == 3 then turtle.turnLeft() end
  st.heading = h
  save()
end

-- One step without digging: wait for whatever is in the way to move.
local function step(kind)
  local move = ({ fwd = turtle.forward, up = turtle.up, down = turtle.down })[kind]
  local attack = ({ fwd = turtle.attack, up = turtle.attackUp, down = turtle.attackDown })[kind]
  for tries = 1, 60 do
    if tmove.move(st, save, kind, move, apply) then return end
    attack() -- a mob
    if tries % 10 == 0 then print("Waiting: something is in the way") end
    sleep(1)
  end
  error("Blocked on the way home at " .. textutils.serialize(st.pos) .. "; clear the path and reboot me", 0)
end

local function refuel()
  if turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() >= MIN_FUEL then return end
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and (d.name == "minecraft:coal" or d.name == "minecraft:charcoal") then
      turtle.select(i)
      turtle.refuel(math.min(d.count, 8))
    end
  end
  turtle.select(1)
end

-- One move that may simply not be possible (something solid): a few tries
-- (a mob may be in the way), then false. Never digs.
local function tryStep(kind)
  local move = ({ fwd = turtle.forward, up = turtle.up, down = turtle.down })[kind]
  local attack = ({ fwd = turtle.attack, up = turtle.attackUp, down = turtle.attackDown })[kind]
  for _ = 1, 3 do
    if tmove.move(st, save, kind, move, apply) then return true end
    attack()
    sleep(0.5)
  end
  return false
end

-- Flat walk to (x, z) at the current height, x first or z first; on a block
-- in the way it walks back the way it came and returns false.
local function walkFlat(x, z, xFirst)
  local done = {}
  local function leg(axis)
    while (axis == "x" and st.pos.x ~= x) or (axis == "z" and st.pos.z ~= z) do
      local h
      if axis == "x" then h = st.pos.x < x and 1 or 3 else h = st.pos.z < z and 2 or 0 end
      turnTo(h)
      if not tryStep("fwd") then return false end
      done[#done + 1] = h
    end
    return true
  end
  local ok = leg(xFirst and "x" or "z") and leg(xFirst and "z" or "x")
  if ok then return true end
  for i = #done, 1, -1 do turnTo((done[i] + 2) % 4); step("fwd") end
  return false
end

local function columnTo(x, z, cruise)
  while st.pos.y < cruise do step("up") end
  while st.pos.x ~= x do turnTo(st.pos.x < x and 1 or 3); step("fwd") end
  while st.pos.z ~= z do turnTo(st.pos.z < z and 2 or 0); step("fwd") end
end

local function downTo(y)
  while st.pos.y > y do if not tryStep("down") then return false end end
  return true
end

-- Fly CLEARANCE above the build spot (and above the target), then down into
-- the target. When it is roofed over (a home in a pocket, under a cable...):
-- down a neighbouring column (nearest first, up to 3 away) and walk in
-- sideways. Never digs.
local function goTo(t)
  local cruise = math.max(CLEARANCE, t.y + 1)
  if st.pos.x ~= t.x or st.pos.z ~= t.z then columnTo(t.x, t.z, cruise) end
  if downTo(t.y) then
    while st.pos.y < t.y do step("up") end
    return
  end
  local around = {}
  for dx = -3, 3 do for dz = -3, 3 do
    if dx ~= 0 or dz ~= 0 then around[#around + 1] = { dx, dz } end
  end end
  table.sort(around, function(a, b)
    local da, db = math.abs(a[1]) + math.abs(a[2]), math.abs(b[1]) + math.abs(b[2])
    if da ~= db then return da < db end
    return a[1] * 10 + a[2] < b[1] * 10 + b[2]
  end)
  for _, d in ipairs(around) do
    columnTo(t.x + d[1], t.z + d[2], cruise)
    if downTo(t.y) and (walkFlat(t.x, t.z, true) or walkFlat(t.x, t.z, false)) then return end
  end
  error(("No way into my home slot %d,%d,%d from above or the side (it is roofed over); clear a way and reboot me")
    :format(t.x, t.y, t.z), 0)
end

-- Back from the home slot to the build spot (to be taken apart there).
function T.toBuildSpot()
  local cfg = link.config()
  local slot = cfg.slot
  refuel()
  st = readState() or { pos = { x = slot.x or slot.east or 0, y = slot.y or 0, z = slot.z or -(slot.north or 0) } }
  tmove.recover(st, save, apply)
  st.heading = nav.heading(nil, st, save)
  save()
  goTo({ x = 0, y = 0, z = 0 })
  fs.delete(STATE)
end

-- Ask for a home slot, walk there, record it in agent.cfg.
function T.toHomeSlot()
  local cfg = link.config()
  refuel()
  while not cfg.slot do
    local r = link.talk("new")
    if r and r.type == "home" then
      cfg.slot, cfg.homeY = r.home, r.y
      link.saveConfig(cfg)
    else
      print("Waiting for the base to give me a home slot...")
      sleep(10)
    end
  end

  st = readState() or { pos = { x = 0, y = 0, z = 0 } }
  tmove.recover(st, save, apply)
  -- turns are not journaled: measure the heading on every start
  st.heading = nav.heading(nil, st, save) -- nil: never dig inside the base
  save()

  -- slot: { x, y, z } from the build spot (older bases sent { east, north })
  local slot = cfg.slot
  local target = { x = slot.x or slot.east or 0, y = slot.y or 0, z = slot.z or -(slot.north or 0) }
  goTo(target)
  turnTo(nav.index(slot.facing or "north"))

  cfg.home = { y = (cfg.homeY or 0) + target.y, heading = st.heading }
  cfg.needsHome = nil
  link.saveConfig(cfg)
  fs.delete(STATE)
  print(("Home: %s, facing %s"):format(textutils.serialize(cfg.slot), nav.NAMES[st.heading]))
end

return T
