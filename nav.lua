-- nav: which way does this turtle face? Shared by oreminer, forester, travel.
--
-- Headings in world axes: 0 north(-z), 1 east(+x), 2 south(+z), 3 west(-x).
-- With a compass upgrade the answer is free. With a Geo Scanner it scans,
-- steps one block, scans again and sees which shift lines the scans up.

local link = require("link")
local tmove = require("tmove")

local N = {}

N.DIRS = { [0] = { 0, 0, -1 }, { 1, 0, 0 }, { 0, 0, 1 }, { -1, 0, 0 } }
N.NAMES = { [0] = "north", "east", "south", "west" }
local INDEX = { north = 0, east = 1, south = 2, west = 3 }
function N.index(name) return INDEX[tostring(name):lower()] end

-- Geo Scanner scan, waiting out the cooldown. AP 0.8.2a calls it
-- scanBlocks(radius) (checked in the jar, and live: it has no `scan`);
-- older APs: scan(radius).
function N.scan(radius)
  while true do
    local scanner = link.scanner()
    if not scanner then error("No Geo Scanner equipped", 0) end
    local fn = scanner.scanBlocks or scanner.scan
    if not fn then error("This Geo Scanner has no scanBlocks/scan method", 0) end
    local blocks, err = fn(radius)
    if blocks then return blocks end
    if tostring(err):lower():find("cooldown") then
      sleep(0.5)
    else
      error("scan failed: " .. tostring(err), 0)
    end
  end
end

function N.compass()
  local c = peripheral.find("compass")
  if c then return N.index(c.getFacing()) end
end

local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- Scanner method. Turns until it finds a direction it may step into (digging
-- only if `mayDig(blockName)` says so); returns the heading it ends up facing.
-- Why a turtle can't move, for a crash log nobody watches: its fuel, the
-- fuel it carries, and the block on every side.
function N.surroundings()
  local carried = 0
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and (d.name:find("coal") or d.name:find("charcoal") or d.name:find("_log$")) then carried = carried + d.count end
  end
  local around = {}
  for _ = 1, 4 do
    local ok, info = turtle.inspect()
    around[#around + 1] = ok and info.name or "nothing"
    turtle.turnRight()
  end
  local okU, up = turtle.inspectUp()
  local okD, down = turtle.inspectDown()
  return ("fuel %s, carries %d coal/logs; around: %s; up %s, down %s"):format(
    tostring(turtle.getFuelLevel()), carried, table.concat(around, ", "),
    okU and up.name or "nothing", okD and down.name or "nothing")
end

-- st, save: the caller's state, to journal the probe in (tmove.probeStart);
-- its tmove.recover settles a probe a stop interrupted.
function N.scanHeading(mayDig, st, save)
  local a = N.scan(8)
  local moved = false
  tmove.probeStart(st, save)
  for _ = 1, 4 do
    moved = turtle.forward()
    if not moved and turtle.detect() and mayDig then
      local ok, info = turtle.inspect()
      if ok and mayDig(info.name) and turtle.dig() then moved = turtle.forward() end
    end
    if moved then break end
    turtle.turnRight()
  end
  if not moved then
    tmove.probeDone(st, save)
    error("Need room to move 1 block in some direction to find my heading (" .. N.surroundings() .. ")", 0)
  end
  local b = {}
  for _, blk in ipairs(N.scan(8)) do b[key(blk.x, blk.y, blk.z)] = blk.name end
  local best, bestScore = nil, -1
  for h = 0, 3 do
    local d, score = N.DIRS[h], 0
    for _, blk in ipairs(a) do
      if blk.name ~= "minecraft:air" and b[key(blk.x - d[1], blk.y, blk.z - d[3])] == blk.name then
        score = score + 1
      end
    end
    if score > bestScore then best, bestScore = h, score end
  end
  -- step back to where we started
  if tmove.stepBack() then tmove.probeDone(st, save); return best end
  error("Could not step back after measuring my heading", 0)
end

-- Compass if equipped, else the scanner method.
function N.heading(mayDig, st, save)
  return N.compass() or N.scanHeading(mayDig, st, save)
end

return N
