-- defrag: what goes where when storage is packed and sorted. Pure: no
-- peripherals.
--
-- How the inventories place what goes in decides the method (checked in the
-- jars): a Sophisticated Storage barrel or chest ignores the slot it is
-- given and puts an item into stacks of it first, then into its lowest empty
-- slot (Core 1.5.35 InventoryHandlerSlotTracker: emptySlots is a TreeSet);
-- CC (pushItems with no slot) puts it into the first slot that takes it.
-- Either way: an EMPTY inventory filled item by item in name order ends up
-- sorted from its first slot, every item in as few stacks as it needs. So
-- storage is rebuilt one inventory at a time: empty it into the others,
-- fill it with its share in name order. In place, that is (factory.lua):
-- slot by slot, the wrong stack out to a free slot anywhere, a part stack of
-- the wanted item further on out of the way, then the wanted stack in: it
-- lands in that slot, the lowest empty one. A slot or two free anywhere is
-- enough; no inventory has to be emptied whole.
--
-- The share: every item's total is spread over the inventories in turn. An
-- inventory whose slots hold more than 64 (stack upgrades) takes the items
-- with the most stacks first (a slot of 512 copper, not of 3 diamonds); the
-- rest take the items in name order, so storage reads A..Z across them.
-- Drawers are not in this: they hold their own item (the executor fills
-- them first, never past their room: a void upgrade deletes the rest).

local M = {}

-- What an inventory slot holds of an item: its limit is per 64-stack item;
-- pearls 16 a slot (x the upgrade), an item that doesn't stack 1.
function M.cap(limit, maxStack)
  maxStack = maxStack or 64
  if maxStack == 1 then return 1 end
  return math.max(1, math.floor(limit * maxStack / 64))
end

-- Item order: by name, then components ("redstone" before "redstone_block":
-- not by the whole key, where "|" sorts after "_").
local function before(a, b)
  local na, nb = a:match("^[^|]*"), b:match("^[^|]*")
  if na ~= nb then return na < nb end
  return a < b
end
M.before = before

-- `invs` = { { name, size, limit }, ... }, `totals` = { [key] = n },
-- `maxOf` = { [key] = max stack }. Keys sort by item name ("name|nbt").
-- Returns `order` (inventory names, the order to rebuild them in) and
-- `shares` = { [inventory] = { { key, n }, ... } in name order }; nil and
-- why if it all doesn't fit.
function M.assign(invs, totals, maxOf)
  local order = {}
  for _, inv in ipairs(invs) do order[#order + 1] = inv end
  table.sort(order, function(a, b)
    if a.limit ~= b.limit then return a.limit > b.limit end
    return a.name < b.name
  end)
  local left, keys = {}, {}
  for k, n in pairs(totals) do
    if n > 0 then left[k] = n; keys[#keys + 1] = k end
  end
  table.sort(keys, before)
  local shares, names = {}, {}
  for _, inv in ipairs(order) do
    local share, free = {}, inv.size
    local function put(k)
      local c = M.cap(inv.limit, maxOf[k])
      local n = math.min(left[k], free * c)
      if n <= 0 then return false end
      share[#share + 1] = { key = k, n = n }
      free = free - math.ceil(n / c)
      left[k] = left[k] - n
      return true
    end
    if inv.limit > 64 then
      -- upgraded: the items with the most stacks first
      while free > 0 do
        local best, bestStacks
        for _, k in ipairs(keys) do
          if left[k] > 0 then
            local stacks = left[k] / (maxOf[k] or 64)
            if not best or stacks > bestStacks then best, bestStacks = k, stacks end
          end
        end
        if not best or not put(best) then break end
      end
    else
      for _, k in ipairs(keys) do
        if free <= 0 then break end
        if left[k] > 0 then put(k) end
      end
    end
    table.sort(share, function(a, b) return before(a.key, b.key) end)
    shares[inv.name] = share
    names[#names + 1] = inv.name
  end
  for _, k in ipairs(keys) do
    if left[k] > 0 then return nil, ("it doesn't all fit: %d %s left over"):format(left[k], k:match("^[^|]*")) end
  end
  return names, shares
end

-- Slots used: { [inventory] = { [slot] = { key, count } } } -> number.
function M.used(contents)
  local n = 0
  for _, slots in pairs(contents) do for _ in pairs(slots) do n = n + 1 end end
  return n
end

return M
