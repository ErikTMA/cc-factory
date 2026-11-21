-- production: the base's furnaces and crafting planner (no peripherals of its
-- own; everything goes through the storage port).
--
-- Furnaces (vanilla furnaces and blast furnaces on the wired network): every
-- tick the base takes finished items out, tops up fuel (charcoal first, coal
-- only above a reserve the turtles need) and gives idle furnaces work:
--   ores and dusts -> ingots (raw ores are hammered first when the hammer
--   toggle is on), logs -> charcoal, cobblestone -> stone, sand -> glass,
-- each up to a target amount.
--
-- Crafting: `plan` walks the recipe tree for what the factory needs (parts of
-- a missing turtle, an ore hammer) and returns the first craft whose inputs
-- are all in storage, as a job for the assembler; or the raw items missing.

local R = require("recipes")
local C = require("oreconf")

local P = {}

P.DEFAULTS = {
  enabled = true,
  hammer = false,      -- double ores with an All The Ores ore hammer (toggle on the monitor)
  charcoal = 64,       -- keep this much charcoal (from logs)
  stone = 64,          -- keep this much stone (from cobblestone; wired modems)
  glass = 32,          -- keep this much glass (from sand; glass panes)
  coalReserve = 64,    -- coal the furnaces leave for turtles
  keepLogs = 16,       -- logs kept for planks and sticks
  keepCobble = 16,     -- cobblestone kept for observers
}

local FUELS = { "minecraft:charcoal", "minecraft:coal" }

local function hasHammer(stock)
  for item, n in pairs(stock) do if n > 0 and R.isHammer(item) then return item end end
end
P.hasHammer = hasHammer

local function sortedKeys(t)
  local k = {}
  for key in pairs(t) do k[#k + 1] = key end
  table.sort(k)
  return k
end

-- ------------------------------------------------------------- furnaces --
-- What an idle furnace should smelt next, or nil. avail(item) = stock left
-- after what this pass already handed out.
local function pickInput(cfg, hammerOn, stock, avail, blast)
  local items = sortedKeys(stock)
  local hammer = hasHammer(stock)
  for _, item in ipairs(items) do
    local s = R.smelt(item)
    if s and s.ore and avail(item) > 0 then
      local raw = R.hammerDust(item) ~= nil
      -- with the toggle on, raw ores wait for the hammer; only copper or iron
      -- for the first hammer itself may be smelted directly
      if not raw or not hammerOn
         or (not hammer and (item == "minecraft:raw_copper" or item == "minecraft:raw_iron")) then
        return item
      end
    end
  end
  if blast then return nil end -- blast furnaces only do ores
  if avail("minecraft:charcoal") < cfg.charcoal then
    for _, item in ipairs(items) do
      local s = R.smelt(item)
      if s and s.out == "minecraft:charcoal" and avail(item) > cfg.keepLogs then return item end
    end
  end
  if avail("minecraft:stone") < cfg.stone and avail("minecraft:cobblestone") > cfg.keepCobble then
    return "minecraft:cobblestone"
  end
  if avail("minecraft:glass") < cfg.glass and avail("minecraft:sand") > 0 then return "minecraft:sand" end
end

-- One pass over every furnace. Returns how many got new work.
function P.smelt(S, cfg, hammerOn, stock)
  local planned = {}
  local function avail(item) return (stock[item] or 0) - (planned[item] or 0) end
  local work = 0
  for _, f in ipairs(S.furnaces()) do
    local slots = S.slots(f.name)
    if slots[3] then S.storeSlot(f.name, 3) end
    if not slots[2] or slots[2].count < 4 then
      for _, fuel in ipairs(FUELS) do
        local reserve = fuel == "minecraft:coal" and cfg.coalReserve or 0
        local n = math.min(8, avail(fuel) - reserve)
        if n > 0 and (not slots[2] or slots[2].name == fuel) then
          planned[fuel] = (planned[fuel] or 0) + S.send(f.name, fuel, n, nil, 2)
          break
        end
      end
    end
    if not slots[1] then
      local item = pickInput(cfg, hammerOn, stock, avail, f.blast)
      if item then
        planned[item] = (planned[item] or 0) + S.send(f.name, item, math.min(16, avail(item)), nil, 1)
        work = work + 1
      end
    end
  end
  return work
end

-- ------------------------------------------------------------- planning --
local MAX_SETS = 64

-- Pick a concrete item for an ingredient (a group picks the best member).
local function pick(ing, stock, total)
  local group = R.GROUPS[ing]
  if not group then return ing end
  local best, bestN = nil, -1
  for _, m in ipairs(group) do
    if (stock[m] or 0) > bestN then best, bestN = m, stock[m] or 0 end
  end
  if bestN >= total then return best end
  -- nothing in stock: a member we can craft from what we have (planks from logs)
  for _, m in ipairs(group) do
    local rec = R.CRAFT[m]
    if rec then
      for _, src in pairs(rec.grid) do if (stock[src] or 0) > 0 then return m end end
    end
  end
  return best
end

-- Returns a craft job for the first step towards `n` of `item`, or nil plus a
-- table of raw items (not craftable here) that are missing.
local function need(item, n, stock, missing, depth)
  if depth > 12 then return nil end
  item = pick(item, stock, n)
  local have = stock[item] or 0
  if have >= n then return nil end
  local rec = R.CRAFT[item]
  if not rec then
    missing[item] = (missing[item] or 0) + (n - have)
    return nil
  end
  local sets = math.ceil((n - have) / rec.count)
  if rec.single then sets = 1 end
  sets = math.min(sets, MAX_SETS)
  -- per-set use of each concrete ingredient
  local grid, use = {}, {}
  for cell, ing in pairs(rec.grid) do
    local per = 0
    for _, i2 in pairs(rec.grid) do if i2 == ing then per = per + 1 end end
    local concrete = pick(ing, stock, per * sets)
    grid[cell] = concrete
    use[concrete] = (use[concrete] or 0) + 1
  end
  -- make what's short first (checking every input, in a fixed order, so the
  -- missing list is complete); then craft as many sets as the inputs allow
  local ready, short, firstJob = sets, false, nil
  for _, ing in ipairs(sortedKeys(use)) do
    local per, have2 = use[ing], stock[ing] or 0
    if have2 < per then
      short = true
      firstJob = firstJob or need(ing, per * sets, stock, missing, depth + 1)
    else
      ready = math.min(ready, math.floor(have2 / per))
    end
  end
  if short then return firstJob end
  return { item = item, sets = ready, grid = grid, count = rec.count }
end

-- What the factory wants made, in order: the ore hammer (toggle on, none in
-- storage), hammering raw ore, then the parts of turtles the fleet still needs.
-- `wanted` = list of { item, n }. Returns job or nil, missing raw items.
function P.plan(stock, hammerOn, wanted)
  local missing = {}
  if hammerOn then
    local hammer = hasHammer(stock)
    if not hammer then
      for _, h in ipairs(R.HAMMERS) do
        local m = {}
        local job = need(h, 1, stock, m, 0)
        if job then return job, missing end
        if not next(m) then break end
        for k, v in pairs(m) do missing[k] = math.max(missing[k] or 0, v) end
      end
    else
      for _, item in ipairs(sortedKeys(stock)) do
        local dust = R.hammerDust(item)
        if dust and stock[item] > 0 then
          return { item = dust, sets = math.min(stock[item], 32), count = 2, repeated = true,
                   grid = { [1] = hammer, [2] = item } }, missing
        end
      end
    end
  end
  -- the first thing we can make now; but walk every need so `missing` lists
  -- all raw items the factory is waiting for (shown on the monitor)
  local first
  for _, w in ipairs(wanted) do
    local job = need(w[1], w[2], stock, missing, 0)
    first = first or job
  end
  return first, missing
end

-- Items (and counts) needed for one more turtle of each role short of its
-- fleet target, in a stable order.
function P.wantedForFleet(short, sapling)
  local wanted = {}
  for _, role in ipairs(sortedKeys(short)) do
    local parts = C.parts(role, sapling)
    for _, item in ipairs(sortedKeys(parts)) do wanted[#wanted + 1] = { item, parts[item] } end
  end
  return wanted
end

return P
