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
-- The share (M.assign): the fewest moves. Every item stays in the
-- inventory that holds most of it; inventories with stack upgrades take the
-- items with the most stacks. Each inventory is sorted within itself.
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
-- Stable: what goes where with the fewest moves. Every item stays in the
-- inventory that already holds most of it (as much as fits there; the rest
-- where there is room); inventories with stack upgrades first take the
-- items with the most stacks (they save slots there). Each inventory is then
-- sorted within itself. Two slots are kept free in one inventory other than
-- the one with the most room: what is sorted in place moves through them.
-- `invs` entries need `slots` here (what they hold now).
local function stable(invs, totals, maxOf, withReserve)
  local cur, freeNow = {}, {}
  for _, inv in ipairs(invs) do
    cur[inv.name] = {}
    local used = 0
    for _, st in pairs(inv.slots or {}) do
      cur[inv.name][st.key] = (cur[inv.name][st.key] or 0) + st.count
      used = used + 1
    end
    freeNow[inv.name] = inv.size - used
  end
  -- two slots kept free to move through, in the plain inventory with the
  -- most room (only what it has free: never pushing its own items out)
  local roomy
  for _, inv in ipairs(invs) do
    if inv.limit <= 64 and freeNow[inv.name] > 0 and (not roomy or freeNow[inv.name] > freeNow[roomy.name]) then roomy = inv end
  end
  local reserve = {}
  if roomy and withReserve then reserve[roomy.name] = math.min(2, freeNow[roomy.name]) end
  local order = {}
  for _, inv in ipairs(invs) do order[#order + 1] = inv end
  table.sort(order, function(a, b) return a.name < b.name end)
  local left, keys = {}, {}
  for k, n in pairs(totals) do if n > 0 then left[k] = n; keys[#keys + 1] = k end end
  table.sort(keys, before)
  local free, shares = {}, {}
  for _, inv in ipairs(order) do free[inv.name] = inv.size - (reserve[inv.name] or 0); shares[inv.name] = {} end
  local function put(inv, k)
    local c = M.cap(inv.limit, maxOf[k])
    local n = math.min(left[k], free[inv.name] * c)
    if n <= 0 then return end
    table.insert(shares[inv.name], { key = k, n = n })
    free[inv.name] = free[inv.name] - math.ceil(n / c)
    left[k] = left[k] - n
  end
  -- inventories whose slots hold more than 64 (stack upgrades) take the
  -- items with more than one stack, the most stacks first: there they
  -- save slots (20 stacks of copper in one slot of 4096); an item of one
  -- stack or less saves nothing there and goes to a plain one
  local ups = {}
  for _, inv in ipairs(order) do if inv.limit > 64 then ups[#ups + 1] = inv end end
  table.sort(ups, function(a, b)
    if a.limit ~= b.limit then return a.limit > b.limit end
    return a.name < b.name
  end)
  local byStacks = {}
  for _, k in ipairs(keys) do
    if left[k] / (maxOf[k] or 64) > 1 then byStacks[#byStacks + 1] = k end
  end
  table.sort(byStacks, function(a, b)
    local sa, sb = left[a] / (maxOf[a] or 64), left[b] / (maxOf[b] or 64)
    if sa ~= sb then return sa > sb end
    return before(a, b)
  end)
  for _, up in ipairs(ups) do
    for _, k in ipairs(byStacks) do
      if free[up.name] <= 0 then break end
      if left[k] > 0 then put(up, k) end
    end
  end
  -- the rest: in a plain inventory, the one holding most of it (fewest
  -- moves); the biggest items first; what doesn't fit, wherever there is room
  local byTotal = {}
  for _, k in ipairs(keys) do byTotal[#byTotal + 1] = k end
  table.sort(byTotal, function(a, b)
    if totals[a] ~= totals[b] then return totals[a] > totals[b] end
    return before(a, b)
  end)
  for _, k in ipairs(byTotal) do
    if left[k] > 0 then
      local cands = {}
      for _, inv in ipairs(order) do cands[#cands + 1] = inv end
      table.sort(cands, function(a, b)
        local pa, pb = a.limit <= 64, b.limit <= 64
        if pa ~= pb then return pa end
        local ca, cb = cur[a.name][k] or 0, cur[b.name][k] or 0
        if ca ~= cb then return ca > cb end
        if free[a.name] ~= free[b.name] then return free[a.name] > free[b.name] end
        return a.name < b.name
      end)
      for _, inv in ipairs(cands) do
        if left[k] <= 0 then break end
        put(inv, k)
      end
    end
  end
  for _, k in ipairs(keys) do
    if left[k] > 0 then return nil, ("it doesn't all fit: %d %s left over"):format(left[k], k:match("^[^|]*")) end
  end
  local names = {}
  for _, inv in ipairs(order) do
    table.sort(shares[inv.name], function(a, b) return before(a.key, b.key) end)
    names[#names + 1] = inv.name
  end
  return names, shares
end

function M.assign(invs, totals, maxOf)
  local order, shares = stable(invs, totals, maxOf, true)
  if order then return order, shares end
  return stable(invs, totals, maxOf, false) -- (the two kept free: if that's what it takes)
end

-- ------------------------------------------------------------ the moves --
-- The whole run, planned at once by simulating how each inventory places
-- what goes in: a Sophisticated one (`loose`) onto a part stack of the item
-- first, else its lowest empty slot (the slot asked for is ignored); any
-- other the slot asked for. Then it is only carried out.
--
-- `invs` = { { name, size, limit, loose, slots = { [slot] = { key, count } } } }
-- (copied: not changed), `shares` from M.assign, `maxOf`. Returns
-- { { from, fromSlot, to, toSlot, key, n }, ... } and how many stacks are
-- left out of place (no room to move them through).
--
-- Each inventory is filled in slot order with its share (full stacks of
-- each item in name order, its part stack last). A move that puts a stack
-- straight into its final place is always taken first, from wherever it is;
-- only when none is left is something parked: what sits in a slot another
-- stack needs, or a stack wanted in its own (Sophisticated) inventory, which
-- can't be moved within it. It is parked in a finished part's free tail
-- (where nothing is wanted), and moved from there into its place later.
function M.moves(invs, shares, maxOf, maxMoves)
  maxMoves = maxMoves or 100000
  local inv, order = {}, {}
  for _, v in ipairs(invs) do
    local copy = { name = v.name, size = v.size, limit = v.limit, loose = v.loose, slots = {}, want = {} }
    for slot, st in pairs(v.slots) do copy.slots[slot] = { key = st.key, count = st.count } end
    for _, e in ipairs(shares[v.name] or {}) do
      local c = M.cap(v.limit, maxOf[e.key])
      local left = e.n
      while left > 0 do
        local n = math.min(c, left)
        copy.want[#copy.want + 1] = { key = e.key, n = n, cap = c }
        left = left - n
      end
    end
    inv[v.name] = copy
    order[#order + 1] = copy
  end
  local function capOf(I, k) return M.cap(I.limit, maxOf[k]) end
  local function right(I, p)
    local st, w = I.slots[p], I.want[p]
    if not w then return st == nil end
    return st ~= nil and st.key == w.key and st.count == w.n
  end
  -- the next slot to fill: the first wanted one not right yet (nil: done).
  -- Past what it wants is its free tail: what lies there is only taken from
  -- (to its place), never pushed out for its own sake.
  local function nextSlot(I)
    for p = 1, #I.want do if not right(I, p) then return p end end
  end
  local moves = {}
  -- move n of the stack in (A, a) to B; where it lands as B places it
  local function move(A, a, B, n, toSlot)
    local st = A.slots[a]
    local key = st.key
    local land
    if B.loose then
      for q = 1, B.size do
        local o = B.slots[q]
        if o and o.key == key and o.count < capOf(B, key) then land = q; break end
      end
      if not land then for q = 1, B.size do if not B.slots[q] then land = q; break end end end
    else
      land = toSlot
    end
    if not land then return 0 end
    local o = B.slots[land]
    n = math.min(n, st.count, capOf(B, key) - (o and o.count or 0))
    if n <= 0 then return 0 end
    if o then o.count = o.count + n else B.slots[land] = { key = key, count = n } end
    st.count = st.count - n
    if st.count == 0 then A.slots[a] = nil end
    moves[#moves + 1] = { from = A.name, fromSlot = a, to = B.name, toSlot = (not B.loose) and land or nil,
                          landed = land, key = key, n = n }
    return n
  end
  -- can stack `key` go into slot p of I next? (Sophisticated: p must be its
  -- lowest empty slot and no other part stack of the key in it)
  local function placeable(I, p, key)
    local here = I.slots[p]
    -- (the right item, too few: it is topped up)
    if here and not (here.key == key and here.count < I.want[p].n) then return false end
    if not I.loose then return true end
    for q = 1, p - 1 do if not I.slots[q] then return false end end
    for q = 1, I.size do
      local o = I.slots[q]
      if q ~= p and o and o.key == key and o.count < capOf(I, key) then return false end
    end
    return true
  end
  -- a stack that may be taken: not in its final place
  local function loose(I, q) return I.slots[q] and not right(I, q) end
  -- direct: one stack into its final place; true if it moved
  local function direct()
    for _, I in ipairs(order) do
      local p = nextSlot(I)
      local w = p and I.want[p]
      if w and placeable(I, p, w.key) then
        local need = w.n - (I.slots[p] and I.slots[p].count or 0)
        -- the source: a stack of it out of place, in another inventory (or
        -- this one, if it takes the slot asked for); exactly the size first
        local best, bestI, bestQ
        for _, A in ipairs(order) do
          if A ~= I or not I.loose then
            for q = 1, A.size do
              local o = A.slots[q]
              if o and o.key == w.key and loose(A, q) and not (A == I and q == p) then
                local score = (o.count == need) and 0 or (o.count > need and 1 or 2)
                if not best or score < best then best, bestI, bestQ = score, A, q end
              end
            end
          end
        end
        if bestI then
          local moved = move(bestI, bestQ, I, need, p)
          if moved > 0 then return true end
        end
      end
    end
    return false
  end
  -- park one stack that is in the way, in a free tail (nothing wanted there)
  local function park()
    for _, I in ipairs(order) do
      local p = nextSlot(I)
      if p then
        local w = I.want[p]
        local culprit
        if I.slots[p] and not (w and I.slots[p].key == w.key) then
          culprit = p -- (another item in the slot)
        elseif w and I.loose then
          -- a part stack of it further on, or the only stacks of it are in here
          -- (also its own last, part stack further on, though that one is
          -- in place: what comes in would land on it, never in p)
          for q = 1, I.size do
            local o = I.slots[q]
            if q ~= p and o and o.key == w.key
               and (loose(I, q) or (q > p and o.count < capOf(I, o.key))) then culprit = q; break end
          end
        end
        if culprit then
          -- where B would put it: a free tail (nothing wanted there) first;
          -- else a hole wanted for something else (it moves on from there)
          for pass = 1, 2 do
            for _, B in ipairs(order) do
              if B ~= I then
                local land
                if B.loose then
                  for q = 1, B.size do if not B.slots[q] then land = q; break end end
                else
                  for q = B.size, 1, -1 do
                    if not B.slots[q] and (pass == 2 or not B.want[q]) then land = q; break end
                  end
                end
                if land and (pass == 2 or not B.want[land]) then
                  if move(I, culprit, B, I.slots[culprit].count, land) > 0 then return true end
                end
              end
            end
          end
        end
      end
    end
    return false
  end
  -- first, merge: in an inventory that places items itself, several part
  -- stacks of one item become as few as can be: each goes out to a free
  -- slot elsewhere and straight back in, landing on the first part stack of
  -- it (one free slot outside is enough, used again and again). An upgraded
  -- barrel full of 64s becomes a few 512s this way, freeing its slots.
  local function partsOf(I)
    local by = {}
    for q = 1, I.size do
      local o = I.slots[q]
      if o and o.count < capOf(I, o.key) then
        by[o.key] = by[o.key] or {}
        table.insert(by[o.key], q)
      end
    end
    return by
  end
  local function scratchFor(I, key)
    for _, B in ipairs(order) do
      if B ~= I then
        if B.loose then
          for q = 1, B.size do if not B.slots[q] then return B, q end end
        else
          for q = B.size, 1, -1 do if not B.slots[q] then return B, q end end
        end
      end
    end
  end
  for _, I in ipairs(order) do
    if I.loose then
      for _ = 1, I.size do
        local by, q = partsOf(I), nil
        for _, list in pairs(by) do if #list >= 2 then q = list[#list]; break end end
        if not q or #moves >= maxMoves then break end
        local B, land = scratchFor(I, I.slots[q].key)
        if not B then break end
        local n = I.slots[q].count
        if move(I, q, B, n, land) < n then break end
        -- and back in: onto the first part stack of it (what doesn't fit
        -- there goes on to the next one, or the lowest empty slot)
        for _ = 1, 8 do
          if not B.slots[land] then break end
          if move(B, land, I, B.slots[land].count) == 0 then break end
        end
      end
    end
  end
  while #moves < maxMoves do
    if not direct() and not park() then break end
  end
  local wrong = 0
  for _, I in ipairs(order) do for p = 1, I.size do if not right(I, p) then wrong = wrong + 1 end end end
  return moves, wrong
end

-- Slots used: { [inventory] = { [slot] = { key, count } } } -> number.
function M.used(contents)
  local n = 0
  for _, slots in pairs(contents) do for _ in pairs(slots) do n = n + 1 end end
  return n
end

return M
