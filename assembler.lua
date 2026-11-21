-- assembler: builds new turtles for the base.
--
-- The turtle: an advanced turtle with a crafting table, touching a wired
-- modem on the base's network that is ENABLED (right-click it with the
-- assembler in place: the base then reaches the assembler's inventory). A
-- wireless modem upgrade is optional.
-- Layout:
--   the wired modem behind it, under it or on top of it
--   build spot directly IN FRONT of it, kept empty
--   installer disk drive UNDER the build spot (not next to the assembler, or the
--   assembler would boot from the disk)
--
-- The base drives a build step by step: for each crafting step it pushes
-- exactly that step's parts into the assembler and says which item goes in
-- which grid cell; the assembler sorts them into its grid and crafts computer
-- -> turtle -> turtle with upgrades, places it on the build spot, hands it its
-- loadout (saplings, modem, coal) and switches it on; the disk installs it.
-- Whatever it should not keep, the base pulls back out: every status carries
-- the assembler's slots, since a turtle's inventory can't be listed remotely.

local link = require("link")
local C = require("oreconf")

local NON_GRID = { 4, 8, 12, 13, 14, 15, 16 }
local IS_GRID = {}
for _, c in ipairs(C.GRID_CELLS) do IS_GRID[c] = true end

local function log(...) print(...) end

-- {[slot] = item name}: sent with every status so the base can pull slots out
local function inventory()
  local inv = {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then inv[i] = d.name end
  end
  return inv
end

local function talk(state, extra)
  extra = extra or {}
  extra.inv = inventory()
  return link.talk(state, extra)
end

local function nonGridEmpty()
  for _, i in ipairs(NON_GRID) do if turtle.getItemCount(i) > 0 then return false end end
  return true
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

-- Put the step's items into their grid cells (`sets` of each). Crafting needs
-- every slot outside the grid empty: leftovers fail the step.
local function arrange(step, sets)
  sets = sets or 1
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
    local left = sets
    while left > 0 do
      local from = findIn(NON_GRID, item)
      if not from then return false, "missing " .. item end
      turtle.select(from)
      local n = math.min(left, turtle.getItemCount(from))
      turtle.transferTo(cell, n)
      left = left - n
    end
  end
  for _, i in ipairs(NON_GRID) do
    local d = turtle.getItemDetail(i)
    if d then return false, ("%d unexpected %s"):format(d.count, d.name) end
  end
  return true
end

-- A hammer round: the hammer (back damaged after each craft) into its cell,
-- ALL the ore into its cell, everything else (the dust) outside the grid.
-- Returns false when the hammer or the ore is gone.
local function arrangeRepeated(job)
  local want = {}
  for cell, item in pairs(job.grid) do want[cell] = item end
  for _, cell in ipairs(C.GRID_CELLS) do
    local d = turtle.getItemDetail(cell)
    if d and d.name ~= want[cell] then
      local to = emptyNonGrid()
      if not to then return false end
      turtle.select(cell)
      turtle.transferTo(to)
    end
  end
  for cell, item in pairs(want) do
    for _, i in ipairs(NON_GRID) do
      local d = turtle.getItemDetail(i)
      if d and d.name == item then turtle.select(i); turtle.transferTo(cell) end
    end
    if turtle.getItemCount(cell) == 0 then return false end
  end
  return true
end

local function count(item)
  local n = 0
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == item then n = n + d.count end
  end
  return n
end

-- A craft job from the base: `sets` crafts of one recipe; the base takes the
-- results. `repeated` (ore hammer): one craft at a time, because the hammer
-- comes back damaged and must go into its cell again, until the ore runs out
-- or the hammer breaks; after each round the base takes the dust out (crafting
-- needs the slots outside the grid empty). Returns ok, and how many results
-- are still in the turtle (not yet reported).
local function craftJob(job)
  if job.repeated then
    local round, any = 0, false
    while round < job.sets do
      local ready = arrangeRepeated(job)
      if not nonGridEmpty() then
        -- the last round's dust: the base takes it, then says continue
        local taken = false
        for _ = 1, 20 do
          local r = talk("crafting", { craft = job.craft, round = round, made = count(job.result) })
          if r and r.type == "continue" and nonGridEmpty() then taken = true; break end
          if r and r.type ~= "continue" then return false, "the base stopped the craft" end
          sleep(1)
        end
        if not taken then return false, "the base did not take the results" end
      end
      if not ready then break end
      turtle.select(job.select)
      if not turtle.craft(1) then break end
      round, any = round + 1, true
    end
    arrangeRepeated(job)
    if not any then return false, "nothing hammered (no hammer or ore?)" end
    return true, count(job.result)
  end
  local ok, why = arrange(job, job.sets)
  if not ok then return false, why end
  turtle.select(job.select)
  if not turtle.craft(job.sets) then return false, "crafting " .. job.result .. " failed" end
  local made = count(job.result)
  if made == 0 then return false, "crafted the wrong thing for " .. job.result end
  return true, made
end

local function craftStep(step)
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
    if d and d.name:find("^computercraft:turtle_") then slot = i end
  end
  if not slot then return false, "no finished turtle to place" end
  turtle.select(slot)
  if not turtle.place() then return false, "could not place the turtle" end
  turtle.select(1)
  return true
end

-- Hand the new turtle its loadout in order (a forester's saplings first, so
-- they land in its slot 1), then switch it on. (The base delivered it.)
local function loadout(items)
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
  return true -- (anything left over, e.g. a picked-up old turtle: the base takes it)
end

-- ------------------------------------------------------------------ main --
if not turtle.craft then error("The assembler needs a crafting table upgrade", 0) end
if not link.hasModem() then
  error("The assembler needs a wired modem touching it (enabled), or a wireless modem", 0)
end

-- After a restart nothing half-built can be trusted: the base takes it all back.
talk("failed", { reason = "assembler restarted" })

local state, extra = "idle", {}
while true do
  local r = talk(state, extra)
  if type(r) ~= "table" then
    -- no answer: say the same again (the base may be busy or restarting); a
    -- step's result must not be forgotten
    sleep(3)
  elseif r.type == "ok" or r.type == "wait" then
    state, extra = "idle", {}
    sleep(3)
  elseif r.type == "abort" then
    state, extra = "idle", {} -- (the base takes the parts back)
  else
    local ok, why
    if r.type == "craft" then
      local made
      ok, made = craftJob(r)
      if ok then why = nil else why = made end
      state, extra = "crafted", { craft = r.craft, made = ok and made or 0 }
      if ok then log(("Crafted %d %s"):format(made, r.result)) end
    elseif r.type == "step" then
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
      log("Failed: " .. tostring(why))
      state, extra = "failed", { order = r.order, craft = r.craft, reason = why }
    end
  end
end
