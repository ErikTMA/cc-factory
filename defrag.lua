-- defrag: pack storage into as few slots as possible. Pure: no peripherals.
--
-- In: every storage slot, as { id = "inv#slot", inv, slot, key (item+nbt,
-- nil: empty), name, count, lock = key or nil (a drawer slot that only
-- takes its item) }, and cap(slot, key) = how many of that item the slot
-- holds (drawers and upgraded barrels hold far more than 64; and less for
-- items that stack to 16).
--
-- The target: every slot locked to an item is filled with it first (it is
-- taken either way). The rest go to the open slots biggest first, each to
-- the item that puts the most into it: a big slot holds 512 of the copper
-- with 20 stacks, not the one stack of redstone, which moves to a small
-- slot (the other half of "move others": what sits in a big slot moves out
-- if something bigger belongs there). On a tie what is there stays.
--
-- Out: the moves that get there, in order, each { from, to, key, n }
-- (slot ids), simulated as they go, so every move is valid when the one
-- before it went through: what goes into a slot only goes where it fits
-- and is the same item or the slot is empty. A slot whose content has to
-- leave before its new item comes in is emptied first into its item's own
-- target slots, or a free slot. With no free slot at all a cycle can't be
-- broken: those slots stay as they are (the plan says so).

local M = {}

local function sortedSlots(slots)
  local list = {}
  for _, s in ipairs(slots) do list[#list + 1] = s end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

-- The target layout: { [slot id] = { key, n } } (no entry: empty), and how
-- many slots it uses.
function M.target(slots, cap)
  local total = {}
  for _, s in ipairs(slots) do
    if s.key then total[s.key] = (total[s.key] or 0) + s.count end
  end
  local left, want, used = {}, {}, 0
  for k, n in pairs(total) do left[k] = n end
  local open = {}
  for _, s in ipairs(sortedSlots(slots)) do
    if s.lock then
      local n = math.min(left[s.lock] or 0, cap(s, s.lock))
      if n > 0 then
        want[s.id] = { key = s.lock, n = n }
        left[s.lock] = left[s.lock] - n
        used = used + 1
      end
    else
      open[#open + 1] = s
    end
  end
  -- open slots, biggest first (by what they hold of a 64-stack item)
  table.sort(open, function(a, b)
    local ca, cb = cap(a, nil), cap(b, nil)
    if ca ~= cb then return ca > cb end
    return a.id < b.id
  end)
  for _, s in ipairs(open) do
    -- the item that puts the most into this slot; a tie leaves what is
    -- there (a swap that saves no slot is only work), then by name
    local best, bestPut
    for k, n in pairs(left) do
      local put = math.min(n, cap(s, k))
      if put > 0 then
        local better = not best or put > bestPut
          or (put == bestPut and (k == s.key) and best ~= s.key)
          or (put == bestPut and best ~= s.key and k ~= s.key and k < best)
        if better then best, bestPut = k, put end
      end
    end
    if not best then break end
    local n = bestPut
    want[s.id] = { key = best, n = n }
    left[best] = left[best] - n
    used = used + 1
  end
  local stuck = 0
  for _, n in pairs(left) do stuck = stuck + n end -- (doesn't fit anywhere: stays where it is)
  return want, used, stuck
end

function M.usedSlots(slots)
  local n = 0
  for _, s in ipairs(slots) do if s.key and s.count > 0 then n = n + 1 end end
  return n
end

-- The moves from what is there to the target. Returns moves, and how many
-- slots are used after them.
function M.plan(slots, cap, maxMoves)
  maxMoves = maxMoves or 10000
  local want, _, stuck = M.target(slots, cap)
  if stuck > 0 then want = {} end -- (a target that can't hold everything: don't move anything)
  local state, byId, order = {}, {}, sortedSlots(slots)
  for _, s in ipairs(order) do
    byId[s.id] = s
    state[s.id] = { key = s.key, n = s.key and s.count or 0 }
  end
  local moves = {}
  local function move(from, to, n)
    local a, b = state[from], state[to]
    assert(a.key and a.n >= n and n > 0)
    assert(not b.key or b.key == a.key)
    assert(b.n + n <= cap(byId[to], a.key))
    moves[#moves + 1] = { from = from, to = to, key = a.key, n = n }
    b.key, b.n = a.key, b.n + n
    a.n = a.n - n
    if a.n == 0 then a.key = nil end
  end
  -- how many of its own item slot `id` should still lose
  local function excess(id)
    local st, w = state[id], want[id]
    if not st.key then return 0 end
    if not w or w.key ~= st.key then return st.n end
    return math.max(0, st.n - w.n)
  end
  local function room(id, key) -- into a slot that wants `key`
    local st, w = state[id], want[id]
    if not w or w.key ~= key or (st.key and st.key ~= key) then return 0 end
    return w.n - st.n
  end
  -- a free slot to park in: empty, not locked to another item, wanted by
  -- nothing (or by this item)
  local function parking(key, notId)
    for _, s in ipairs(order) do
      local st, w = state[s.id], want[s.id]
      if s.id ~= notId and not st.key and (not s.lock or s.lock == key)
         and (not w or w.key == key) and cap(s, key) > 0 then
        return s.id
      end
    end
  end
  for _ = 1, 64 do
    local progress = false
    for _, s in ipairs(order) do
      local x = excess(s.id)
      if x > 0 then
        local key = state[s.id].key
        -- into slots that want this item
        for _, d in ipairs(order) do
          if x <= 0 or #moves >= maxMoves then break end
          if d.id ~= s.id then
            local r = room(d.id, key)
            if r > 0 then
              local n = math.min(r, x)
              move(s.id, d.id, n); x = x - n; progress = true
            end
          end
        end
        -- the slot wants another item: park what's left
        local w = want[s.id]
        if x > 0 and (not w or w.key ~= key) and #moves < maxMoves then
          local p = parking(key, s.id)
          if p then
            local n = math.min(x, cap(byId[p], key))
            move(s.id, p, n); progress = true
          end
        end
      end
    end
    if not progress or #moves >= maxMoves then break end
  end
  local used = 0
  for _, st in pairs(state) do if st.key then used = used + 1 end end
  return moves, used
end

-- Moves that touch no slot twice can run side by side: rounds of them, in
-- order (a move never runs before one it depends on).
function M.rounds(moves)
  local rounds, busyUntil = {}, {}
  for _, m in ipairs(moves) do
    local r = math.max(busyUntil[m.from] or 0, busyUntil[m.to] or 0) + 1
    rounds[r] = rounds[r] or {}
    table.insert(rounds[r], m)
    busyUntil[m.from], busyUntil[m.to] = r, r
  end
  return rounds
end

return M
