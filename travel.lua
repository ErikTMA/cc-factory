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

local function goTo(t)
  -- fly CLEARANCE above the build spot (and above the target) on the way
  local cruise = math.max(CLEARANCE, t.y + 1)
  while st.pos.y < cruise and (st.pos.x ~= t.x or st.pos.z ~= t.z) do step("up") end
  while st.pos.x ~= t.x do turnTo(st.pos.x < t.x and 1 or 3); step("fwd") end
  while st.pos.z ~= t.z do turnTo(st.pos.z < t.z and 2 or 0); step("fwd") end
  while st.pos.y > t.y do step("down") end
  while st.pos.y < t.y do step("up") end
end

-- Back from the home slot to the build spot (to be taken apart there).
function T.toBuildSpot()
  local cfg = link.config()
  local slot = cfg.slot
  refuel()
  st = readState() or { pos = { x = slot.x or slot.east or 0, y = slot.y or 0, z = slot.z or -(slot.north or 0) } }
  tmove.recover(st, save, apply)
  st.heading = nav.heading(nil)
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
  st.heading = nav.heading(nil) -- nil: never dig inside the base
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
