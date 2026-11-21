-- assembler: builds new turtles for the base.
--
-- The turtle: an advanced turtle with a crafting table and a wireless modem.
-- Layout:
--   supply chest (TRAPPED chest, on the base's wired network) directly ABOVE it
--   build spot directly IN FRONT of it, kept empty
--   installer disk drive UNDER the build spot (not next to the assembler, or the
--   assembler would boot from the disk)
--
-- The base drives a build step by step: for each crafting step it puts exactly
-- that step's parts in the supply chest and tells the assembler which item goes
-- in which grid cell. The assembler crafts computer -> turtle -> turtle with
-- upgrades, places it on the build spot, hands it its loadout (saplings, modem,
-- coal) and switches it on; the disk installs it.

local link = require("link")
local C = require("oreconf")

local NON_GRID = { 4, 8, 12, 13, 14, 15, 16 }
local IS_GRID = {}
for _, c in ipairs(C.GRID_CELLS) do IS_GRID[c] = true end

local function log(...) print(...) end

local function suckAll()
  turtle.select(1)
  while turtle.suckUp() do end
end

-- Everything back into the supply chest (the base returns it to storage).
local function dumpAll()
  for i = 1, 16 do
    if turtle.getItemCount(i) > 0 then turtle.select(i); turtle.dropUp() end
  end
  turtle.select(1)
end

local function findIn(slots, item)
  for _, i in ipairs(slots) do
    local d = turtle.getItemDetail(i)
    if d and d.name == item then return i end
  end
end

local function emptyNonGrid()
  for _, i in ipairs(NON_GRID) do if turtle.getItemCount(i) == 0 then return i end end
end

-- Put the step's items into their grid cells. Crafting needs every slot
-- outside the grid empty, so everything must end up in a cell.
local function arrange(step)
  local keep = step.keep or {}
  for _, cell in ipairs(C.GRID_CELLS) do
    if turtle.getItemCount(cell) > 0 and not keep[cell] then
      local to = emptyNonGrid()
      if not to then return false, "inventory too full to arrange" end
      turtle.select(cell)
      turtle.transferTo(to)
    end
  end
  for cell, item in pairs(keep) do
    local d = turtle.getItemDetail(cell)
    if not d or d.name ~= item then return false, ("expected %s in slot %d"):format(item, cell) end
  end
  for cell, item in pairs(step.grid) do
    local from = findIn(NON_GRID, item)
    if not from then return false, "missing " .. item end
    turtle.select(from)
    turtle.transferTo(cell, 1)
  end
  for _, i in ipairs(NON_GRID) do
    local d = turtle.getItemDetail(i)
    if d then return false, ("%d unexpected %s"):format(d.count, d.name) end
  end
  return true
end

local function craftStep(step)
  suckAll()
  local ok, why = arrange(step)
  if not ok then return false, why end
  turtle.select(step.select)
  if not turtle.craft() then return false, "crafting failed (step " .. tostring(step.step) .. ")" end
  local d = turtle.getItemDetail(step.select)
  if not d or d.name ~= step.result then return false, "crafted the wrong thing: " .. tostring(d and d.name) end
  return true
end

local function placeTurtle()
  if turtle.detect() then
    -- a turtle left behind by an earlier failed build: pick it up (it goes back
    -- to storage with the rest)
    local ok, b = turtle.inspect()
    if not (ok and b.name:find("^computercraft:turtle") and turtle.dig()) then
      return false, "build spot in front is not empty"
    end
  end
  local slot
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == "computercraft:turtle_advanced" then slot = i end
  end
  if not slot then return false, "no finished turtle to place" end
  turtle.select(slot)
  if not turtle.place() then return false, "could not place the turtle" end
  turtle.select(1)
  return true
end

-- Hand the new turtle its loadout in order (a forester's saplings first, so
-- they land in its slot 1), then switch it on.
local function loadout(items)
  suckAll()
  for _, l in ipairs(items) do
    local left = l[2]
    while left > 0 do
      local from = findIn({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }, l[1])
      if not from then return false, "loadout missing " .. l[1] end
      turtle.select(from)
      local n = math.min(left, turtle.getItemCount(from))
      if not turtle.drop(n) then return false, "the new turtle did not take " .. l[1] end
      left = left - n
    end
  end
  turtle.select(1)
  peripheral.call("front", "turnOn")
  dumpAll() -- anything left over (e.g. a picked-up old turtle) back to storage
  return true
end

-- ------------------------------------------------------------------ main --
if not turtle.craft then error("The assembler needs a crafting table upgrade", 0) end
if not link.equippedSide("modem") then error("The assembler needs a wireless modem upgrade", 0) end

-- After a restart nothing half-built can be trusted: hand everything back.
dumpAll()
link.talk("failed", { reason = "assembler restarted" })

local state, extra = "idle", {}
while true do
  local r = link.talk(state, extra)
  if type(r) ~= "table" then
    -- no answer: say the same again (the base may be busy or restarting); a
    -- step's result must not be forgotten
    sleep(3)
  elseif r.type == "ok" or r.type == "wait" then
    state, extra = "idle", {}
    sleep(3)
  elseif r.type == "abort" then
    state, extra = "idle", {}
    dumpAll()
  else
    local ok, why
    if r.type == "step" then
      log(("Order #%d: step %d (%s)"):format(r.order, r.step, r.result))
      ok, why = craftStep(r)
      state, extra = "crafted", { order = r.order, step = r.step }
    elseif r.type == "place" then
      ok, why = placeTurtle()
      state, extra = "placed", { order = r.order }
    elseif r.type == "loadout" then
      ok, why = loadout(r.items)
      state, extra = "powered", { order = r.order }
      if ok then log(("Order #%d done: new turtle switched on"):format(r.order)) end
    end
    if ok == false then
      log("Build failed: " .. tostring(why))
      dumpAll()
      state, extra = "failed", { order = r.order, reason = why }
    end
  end
end
