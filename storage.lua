-- storage: one interface over the base's items, whatever holds them.
--
-- The base sees everything on its wired modem network and sorts inventories by
-- block type, so no configuration is needed:
--   barrels        storage (any mod's barrel)
--   chests         input (turtle home chests); drained into storage. Only the
--                  plain vanilla chest, so players' modded chests on the same
--                  network are left alone.
--   trapped chest  the assembler's supply chest (vanilla trapped chest)
--   furnaces       vanilla furnaces and blast furnaces, run by production.lua
-- If an AE2 ME Bridge or Refined Storage RS Bridge is on the network it becomes
-- the storage instead of the barrels.
--
-- Interface (both backends):
--   list()                        -> { [item] = count }
--   count(item)                   -> number
--   send(toName, item, count[, accept[, toSlot]]) -> moved  (storage -> an
--                                 inventory; accept(itemDetail) picks stacks)
--   countWhere(item, accept)      -> number of `item` whose details pass accept
--   furnaces()                    -> { { name, blast } }
--   slots(name)                   -> { [slot] = { name, count } }
--   storeSlot(name, slot)         -> moved   (one slot of an inventory -> storage)
--   store(fromName)               -> moved   (everything in an inventory -> storage)
--   drainInputs()                 -> moved   (all input chests -> storage)
--   supply()                      -> name of the supply chest, or nil
--   inputs()                      -> names of the input (home) chests
--   kind                          "barrels" | "me_bridge" | "rs_bridge"

local M = {}

function M.classify(name)
  if name:find("^minecraft:furnace_%d+$") or name:find("^minecraft:blast_furnace_%d+$") then return "furnace" end
  if name:find("^minecraft:trapped_chest_%d+$") then return "supply" end
  if name:find("^minecraft:chest_%d+$") then return "input" end
  if name:find("barrel") then return "storage" end
  return nil
end

local function inventories(api, role)
  local out = {}
  for _, n in ipairs(api.getNames()) do
    if M.classify(n) == role and api.hasType(n, "inventory") then out[#out + 1] = n end
  end
  table.sort(out)
  return out
end

local function base(api)
  local S = {}
  function S.supply() return inventories(api, "supply")[1] end
  function S.inputs() return inventories(api, "input") end
  function S.furnaces()
    local out = {}
    for _, n in ipairs(inventories(api, "furnace")) do
      out[#out + 1] = { name = n, blast = n:find("blast_furnace") ~= nil }
    end
    return out
  end
  function S.slots(name) return api.call(name, "list") or {} end
  -- A turtle on the wired network (a modem touching it, enabled) by its
  -- computer ID: its network name, or nil. Its inventory takes pushItems.
  function S.findTurtle(id)
    for _, n in ipairs(api.getNames()) do
      if api.hasType(n, "turtle") then
        local ok, tid = pcall(api.call, n, "getID")
        if ok and tid == id then return n end
      end
    end
  end
  function S.count(item) return S.list()[item] or 0 end
  function S.drainInputs()
    local moved = 0
    for _, n in ipairs(inventories(api, "input")) do moved = moved + S.store(n) end
    return moved
  end
  return S
end

-- ---------------------------------------------------------------- chests --
local function chests(api)
  local S = base(api)
  S.kind = "barrels"

  function S.list()
    local total = {}
    for _, n in ipairs(inventories(api, "storage")) do
      for _, it in pairs(api.call(n, "list")) do
        total[it.name] = (total[it.name] or 0) + it.count
      end
    end
    return total
  end

  function S.send(toName, item, count, accept, toSlot)
    local moved = 0
    for _, n in ipairs(inventories(api, "storage")) do
      for slot, it in pairs(api.call(n, "list")) do
        if it.name == item and moved < count
           and (not accept or accept(api.call(n, "getItemDetail", slot) or {})) then
          moved = moved + api.call(n, "pushItems", toName, slot, count - moved, toSlot)
        end
      end
      if moved >= count then break end
    end
    return moved
  end

  local function storeOne(fromName, slot, count, targets)
    local moved, left = 0, count
    for _, t in ipairs(targets) do
      local n = api.call(fromName, "pushItems", t, slot, left)
      left, moved = left - n, moved + n
      if left <= 0 then break end
    end
    return moved
  end

  function S.store(fromName)
    local moved = 0
    local targets = inventories(api, "storage")
    for slot, it in pairs(api.call(fromName, "list")) do
      moved = moved + storeOne(fromName, slot, it.count, targets)
    end
    return moved
  end

  function S.storeSlot(fromName, slot)
    local it = api.call(fromName, "list")[slot]
    if not it then return 0 end
    return storeOne(fromName, slot, it.count, inventories(api, "storage"))
  end

  function S.countWhere(item, accept)
    local n = 0
    for _, inv in ipairs(inventories(api, "storage")) do
      for slot, it in pairs(api.call(inv, "list")) do
        if it.name == item and accept(api.call(inv, "getItemDetail", slot) or {}) then n = n + it.count end
      end
    end
    return n
  end

  return S
end

-- ---------------------------------------------------------------- bridges --
-- verify-live: argument order of exportItem/importItem comes from the AP jar
-- (exportItem(filter, toName), importItem(filter, fromName)); `base probe`
-- checks it on a real bridge before trusting this backend.
local function bridge(api, name, kind)
  local S = base(api)
  S.kind = kind

  function S.list()
    local total = {}
    for _, it in ipairs(api.call(name, "getItems") or {}) do
      total[it.name] = (total[it.name] or 0) + (it.count or it.amount or 0)
    end
    return total
  end

  -- (bridges can't check damage or pick a slot: best effort; furnaces need
  -- barrel storage for exact slots -- verify-live)
  function S.send(toName, item, count)
    local moved = api.call(name, "exportItem", { name = item, count = count }, toName)
    return tonumber(moved) or 0
  end

  function S.storeSlot(fromName, slot)
    local it = api.call(fromName, "list")[slot]
    if not it then return 0 end
    return tonumber(api.call(name, "importItem", { name = it.name, count = it.count }, fromName)) or 0
  end

  function S.store(fromName)
    local moved = 0
    for _, it in pairs(api.call(fromName, "list")) do
      moved = moved + (tonumber(api.call(name, "importItem", { name = it.name, count = it.count }, fromName)) or 0)
    end
    return moved
  end

  function S.countWhere(item) return S.count(item) end -- bridges: no item details

  function S.craft(item, count)
    return api.call(name, "craftItem", { name = item, count = count })
  end

  return S
end

-- What the base sees on its wired network, grouped by what it uses it for:
-- { storage = {...}, input = {...}, supply = {...}, furnace = {...},
--   drive = {...}, bridge = {...}, other = {...} } (peripheral names).
-- The computer's own sides (left, top...) are not network devices.
local SIDES = { left = true, right = true, top = true, bottom = true, front = true, back = true }
function M.devices(api)
  local d = { storage = {}, input = {}, supply = {}, furnace = {}, drive = {}, bridge = {}, other = {} }
  for _, n in ipairs(api.getNames()) do
    if not SIDES[n] then
      local class = M.classify(n)
      if class and not api.hasType(n, "inventory") then class = nil end
      if not class then
        if api.hasType(n, "drive") then class = "drive"
        elseif api.hasType(n, "me_bridge") or api.hasType(n, "rs_bridge") then class = "bridge"
        else class = "other" end
      end
      table.insert(d[class], n)
    end
  end
  for _, list in pairs(d) do table.sort(list) end
  return d
end

-- Pick the backend from what is on the network. `api` is CC's peripheral API
-- (injected so the harness can fake it).
function M.open(api)
  for _, n in ipairs(api.getNames()) do
    if api.hasType(n, "me_bridge") then return bridge(api, n, "me_bridge") end
    if api.hasType(n, "rs_bridge") then return bridge(api, n, "rs_bridge") end
  end
  return chests(api)
end

return M
