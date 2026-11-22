-- storage: one interface over the base's items, whatever holds them.
--
-- The base sees everything on its wired modem network and sorts inventories by
-- block type, so no configuration is needed:
--   barrels        storage (any mod's barrel)
--   chests         input (turtle home chests); drained into storage. Only the
--                  plain vanilla chest, so players' modded chests on the same
--                  network are left alone.
--   furnaces       vanilla furnaces and blast furnaces, and Iron Furnaces (all
--                  kinds), run by production.lua
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
--   takeFrom(name, slot, item)    -> moved   (one slot of a turtle -> storage)
--   findTurtle(id)                -> network name of the turtle with that ID, or nil
--   inputs()                      -> names of the input (home) chests
--   kind                          "barrels" | "me_bridge" | "rs_bridge"

local M = {}

-- Iron Furnaces (iron, copper, gold, silver, diamond, emerald, crystal,
-- obsidian, netherite, allthemodium, vibranium, unobtainium, million) burn
-- fuel and look like vanilla to CC: it asks for the item capability without
-- a side first, and the mod answers with its whole inventory (InvWrapper):
-- input 1, fuel 2, output 3, its augments after (checked in both jars).
--
-- Storage: barrels, Functional Storage drawers, Sophisticated Storage
-- barrels and chests (checked in the jars, FS 1.5.8 / SS 1.6.18):
-- * a plain drawer (<wood>_1/_2/_4) holds 1, 2 or 4 items; CC's size counts
--   one more slot with a void upgrade, a slot that deletes what goes in:
--   only the drawers' own slots are used (M.drawerSlots).
-- * never a controller, controller extension, storage_io/input/output (they
--   show every connected storage's slots again: counted twice), nor a
--   compacting drawer (its slots are one amount shown three ways), an ender
--   drawer (shared with other places) or an armory cabinet.
-- * a Sophisticated double chest shows the same contents on both halves:
--   storage.lua keeps one of two chests that list exactly alike.
function M.drawerSlots(name)
  local wood, n = name:match("^functionalstorage:([%l_]+)_([124])_%d+$")
  if wood and wood ~= "fluid" and wood ~= "framed_fluid" then return tonumber(n) end
end
function M.classify(name)
  if name:find("^minecraft:furnace_%d+$") or name:find("^minecraft:blast_furnace_%d+$")
     or name:find("^ironfurnaces:%w+_furnace_%d+$") then return "furnace" end
  if name:find("^minecraft:chest_%d+$") then return "input" end
  if name:find("^functionalstorage:") then return M.drawerSlots(name) and "storage" or nil end
  if name:find("^sophisticatedstorage:") then
    if name:find("^sophisticatedstorage:[%l_]*barrel_%d+$") or name:find("^sophisticatedstorage:[%l_]*chest_%d+$")
       or name:find("^sophisticatedstorage:limited_[%l_]*barrel_[1-4]_%d+$") then return "storage" end
    return nil
  end
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
  -- a new decision: what was read before may have changed (the barrel
  -- backend also drops its journal)
  function S.forget() if S.forgetTurtles then S.forgetTurtles() end end
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
  -- (remembered per ID, and checked once per decision: a name is one call, a
  -- search one per turtle)
  local turtleName, checked = {}, {}
  S.forgetTurtles = function() checked = {} end
  function S.findTurtle(id)
    local known = turtleName[id]
    if known and checked[id] then return known end
    if known then
      local ok, tid = pcall(api.call, known, "getID")
      if ok and tid == id then checked[id] = true; return known end
      turtleName[id] = nil
    end
    for _, n in ipairs(api.getNames()) do
      if api.hasType(n, "turtle") then
        local ok, tid = pcall(api.call, n, "getID")
        if ok and tid == id then turtleName[id] = n; checked[id] = true; return n end
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
-- Run peripheral calls side by side: CC (parallel API, coroutines) lets
-- calls from several coroutines complete in the same tick, where one after
-- the other each waits for its own (every call over a wired network does).
local function runAll(fns)
  if #fns == 0 then return end
  if parallel and parallel.waitForAll and #fns > 1 then
    parallel.waitForAll(table.unpack(fns))
  else
    for _, f in ipairs(fns) do f() end
  end
end
M.runAll = runAll

local function chests(api)
  local S = base(api)
  S.kind = "barrels"

  -- The journal: what sits where in storage. CC has no event for an
  -- inventory changing (players and hoppers change barrels too), so the only
  -- truth is a read, and every read waits for a tick. So: one listing of all
  -- inventories side by side (one tick, however many barrels), kept for one
  -- decision (S.forget() at each message and tick), with every move the base
  -- makes in that decision written into it (what it stores goes into a slot
  -- it picks). A send that finds less than the journal said lists again.
  --   slots[inv][slot] = { name, count }
  local slots, sizes
  local function forget() slots = nil; S.forgetTurtles() end
  S.forget = forget

  local function refresh()
    local invs = inventories(api, "storage")
    local lists, fns = {}, {}
    sizes = sizes or {}
    for i, n in ipairs(invs) do
      fns[#fns + 1] = function() lists[i] = api.call(n, "list") or {} end
      if not sizes[n] then
        sizes[n] = M.drawerSlots(n)
        if not sizes[n] then fns[#fns + 1] = function() sizes[n] = api.call(n, "size") or 27 end end
      end
    end
    runAll(fns)
    slots = {}
    local seen = {}
    for i, n in ipairs(invs) do
      local list = lists[i] or {}
      -- the other half of a Sophisticated double chest: the same contents
      -- again (two chests that list exactly alike count once; while empty,
      -- that leaves one out until it holds something)
      local twin = false
      if n:find("^sophisticatedstorage:[%l_]*chest_%d+$") then
        local parts = { tostring(sizes[n]) }
        for slot = 1, sizes[n] or 0 do
          local it = list[slot]
          if it then parts[#parts + 1] = slot .. "=" .. it.name .. "x" .. it.count .. "/" .. tostring(it.nbt) end
        end
        local sig = table.concat(parts, ";")
        twin = seen[sig] ~= nil
        seen[sig] = true
      end
      if not twin then
        slots[n] = {}
        for slot, it in pairs(list) do
          if slot <= (sizes[n] or slot) then slots[n][slot] = { name = it.name, count = it.count, nbt = it.nbt } end
        end
      end
    end
  end
  local function fresh()
    if not slots then refresh() end
    return slots
  end
  local function entries(item)
    local out = {}
    for inv, ss in pairs(fresh()) do
      for slot, it in pairs(ss) do if it.name == item and it.count > 0 then out[#out + 1] = { inv = inv, slot = slot } end end
    end
    table.sort(out, function(a, b) if a.inv ~= b.inv then return a.inv < b.inv end return a.slot < b.slot end)
    return out
  end

  function S.list()
    local total = {}
    for _, ss in pairs(fresh()) do
      for _, it in pairs(ss) do total[it.name] = (total[it.name] or 0) + it.count end
    end
    return total
  end

  local function sendFrom(list, toName, count, accept, toSlot)
    local moved = 0
    local details = {}
    if accept then -- (the details to check, all read side by side first)
      local fns = {}
      for i, e in ipairs(list) do fns[#fns + 1] = function() details[i] = api.call(e.inv, "getItemDetail", e.slot) or {} end end
      runAll(fns)
    end
    for i, e in ipairs(list) do
      if moved >= count then break end
      local it = slots[e.inv] and slots[e.inv][e.slot]
      if it and it.count > 0 and (not accept or accept(details[i] or {})) then
        local n = api.call(e.inv, "pushItems", toName, e.slot, count - moved, toSlot)
        it.count = it.count - n
        if it.count <= 0 then slots[e.inv][e.slot] = nil end
        moved = moved + n
      end
    end
    return moved
  end

  function S.send(toName, item, count, accept, toSlot)
    local moved = sendFrom(entries(item), toName, count, accept, toSlot)
    if moved < count then -- (the journal was out of date: list again, once)
      refresh()
      moved = moved + sendFrom(entries(item), toName, count - moved, accept, toSlot)
    end
    return moved
  end

  -- Where `count` of `item` should go: stacks of it first, then free slots.
  -- (How much a slot holds isn't assumed: a drawer or an upgraded barrel
  -- holds far more than 64. A stack that took nothing is full for the rest
  -- of the decision.)
  local function targetsFor(item)
    local list = {}
    for inv, ss in pairs(fresh()) do
      for slot, it in pairs(ss) do
        if it.name == item and not it.full then list[#list + 1] = { inv = inv, slot = slot, rank = 0 } end
      end
    end
    for inv, ss in pairs(slots) do
      for slot = 1, sizes[inv] or 27 do
        if not ss[slot] then list[#list + 1] = { inv = inv, slot = slot, rank = 1 } end
      end
    end
    table.sort(list, function(a, b)
      if a.rank ~= b.rank then return a.rank < b.rank end
      if a.inv ~= b.inv then return a.inv < b.inv end
      return a.slot < b.slot
    end)
    return list
  end

  local function note(inv, slot, item, n)
    local it = slots[inv][slot]
    if it then it.count = it.count + n else slots[inv][slot] = { name = item, count = n } end
  end

  -- One slot of `fromName` (holding `count` of `item`) into storage, into
  -- slots it picks (written into the journal). No room in the journal: the
  -- old way, into any inventory, and the journal is dropped.
  local function storeOne(fromName, slot, count, item)
    local moved, left = 0, count
    for _, t in ipairs(targetsFor(item)) do
      if left <= 0 then break end
      local n = api.call(fromName, "pushItems", t.inv, slot, left, t.slot)
      if n > 0 then note(t.inv, t.slot, item, n) end
      if n < left and t.rank == 0 then slots[t.inv][t.slot].full = true end
      left, moved = left - n, moved + n
    end
    if left > 0 then
      for _, t in ipairs(inventories(api, "storage")) do
        local n = api.call(fromName, "pushItems", t, slot, left)
        left, moved = left - n, moved + n
        if left <= 0 then break end
      end
      forget()
    end
    return moved
  end

  function S.store(fromName)
    local moved = 0
    for slot, it in pairs(api.call(fromName, "list") or {}) do
      moved = moved + storeOne(fromName, slot, it.count, it.name)
    end
    return moved
  end

  function S.storeSlot(fromName, slot)
    local it = (api.call(fromName, "list") or {})[slot]
    if not it then return 0 end
    return storeOne(fromName, slot, it.count, it.name)
  end

  -- Pull one slot of an inventory that can't be listed (a turtle) back into
  -- storage. With `item` known it goes into slots the journal picks; without,
  -- anywhere, and the journal is dropped.
  function S.takeFrom(fromName, slot, item)
    local moved = 0
    if item then
      for _, t in ipairs(targetsFor(item)) do
        local n = api.call(t.inv, "pullItems", fromName, slot, 64, t.slot)
        if n > 0 then note(t.inv, t.slot, item, n); moved = moved + n
        elseif t.rank == 0 then slots[t.inv][t.slot].full = true end
        if moved > 0 and n == 0 then return moved end -- (moved some, then nothing: empty)
      end
      return moved
    end
    forget()
    for _, t in ipairs(inventories(api, "storage")) do
      local got = 0
      repeat
        local n = api.call(t, "pullItems", fromName, slot)
        got = got + n
      until n == 0
      moved = moved + got
      if got > 0 and api.call(t, "pullItems", fromName, slot) == 0 then break end
    end
    return moved
  end

  -- How many of each item pass its check: `checks` = { [item] = accept };
  -- every slot's details read side by side, in one go.
  function S.countWhereMany(checks)
    local jobs, details, fns = {}, {}, {}
    for item, accept in pairs(checks) do
      for _, e in ipairs(entries(item)) do
        local i = #jobs + 1
        jobs[i] = { item = item, accept = accept, e = e }
        fns[#fns + 1] = function() details[i] = api.call(e.inv, "getItemDetail", e.slot) or {} end
      end
    end
    runAll(fns)
    local out = {}
    for item in pairs(checks) do out[item] = 0 end
    for i, j in ipairs(jobs) do
      if j.accept(details[i] or {}) then out[j.item] = out[j.item] + slots[j.e.inv][j.e.slot].count end
    end
    return out
  end
  function S.countWhere(item, accept) return S.countWhereMany({ [item] = accept })[item] end

  -- ------------------------------------------------------------ defrag --
  -- Every storage slot for defrag.lua, and what each holds of an item.
  -- A slot's limit (CC getItemLimit = the handler's slot limit) is per
  -- 64-stack item: a drawer's limit for its stored item is its stacks x that
  -- item's max stack, so it is scaled back. What an item holds: limit x its
  -- max stack / 64 (pearls 16 in a plain barrel, 16 x n in an upgraded one),
  -- an item that doesn't stack 1 (a drawer stores those by its stacks).
  -- Never too much: a drawer or barrel with a void upgrade deletes what
  -- doesn't fit. An empty drawer slot isn't planned into (one the player
  -- locked to an item takes nothing else, and CC can't tell).
  local function key(it) return it.name .. "|" .. tostring(it.nbt or "") end
  function S.layout()
    fresh()
    local list, fns, limits, maxOf, probe = {}, {}, {}, {}, {}
    local invs = {}
    for inv in pairs(slots) do invs[#invs + 1] = inv end
    table.sort(invs)
    for _, inv in ipairs(invs) do
      for slot = 1, sizes[inv] or 0 do
        local it = slots[inv][slot]
        local s = { id = inv .. "#" .. slot, inv = inv, slot = slot, drawer = M.drawerSlots(inv) ~= nil }
        if it and it.count > 0 then
          s.key, s.name, s.count = key(it), it.name, it.count
          if s.drawer then s.lock = s.key end
          if not probe[s.key] then probe[s.key] = s end
        elseif s.drawer then
          s.lock = "?" -- (nothing goes in)
        end
        list[#list + 1] = s
        fns[#fns + 1] = function() limits[s.id] = api.call(inv, "getItemLimit", slot) or 64 end
      end
    end
    for k, s in pairs(probe) do
      fns[#fns + 1] = function()
        local d = api.call(s.inv, "getItemDetail", s.slot)
        maxOf[k] = d and d.maxCount or 64
      end
    end
    runAll(fns)
    for _, s in ipairs(list) do
      local limit = limits[s.id] or 64
      if s.drawer and s.key then limit = math.floor(limit * 64 / (maxOf[s.key] or 64)) end
      s.limit = limit
    end
    local function cap(s, k)
      local m = k and (maxOf[k] or 64) or 64
      if m == 1 and not s.drawer then return 1 end
      return math.floor(s.limit * m / 64)
    end
    return list, cap
  end

  -- One round of moves side by side ({ from, to, n }, slot ids "inv#slot"):
  -- { true/false per move: all of it moved }.
  function S.move(round)
    local results, fns = {}, {}
    for i, m in ipairs(round) do
      local fromInv, fromSlot = m.from:match("^(.*)#(%d+)$")
      local toInv, toSlot = m.to:match("^(.*)#(%d+)$")
      fns[#fns + 1] = function()
        local ok, n = pcall(api.call, fromInv, "pushItems", toInv, tonumber(fromSlot), m.n, tonumber(toSlot))
        results[i] = ok and n == m.n
      end
    end
    runAll(fns)
    forget()
    return results
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

  -- (a bridge imports by item, not by slot)
  function S.takeFrom(fromName, slot, item)
    return tonumber(api.call(name, "importItem", { name = item }, fromName)) or 0
  end

  -- (AP 0.8.2a's item entries DO carry `components`/`nbt`, but what a fresh
  -- item's entry looks like and whether exportItem can pick that exact stack
  -- is unverified: until checked live, callers treat a bridge as "no details")
  function S.countWhere(item) return S.count(item) end

  function S.craft(item, count)
    return api.call(name, "craftItem", { name = item, count = count })
  end

  return S
end

-- What the base sees on its wired network, grouped by what it uses it for:
-- { storage = {...}, input = {...}, furnace = {...},
--   drive = {...}, bridge = {...}, other = {...} } (peripheral names).
-- The computer's own sides (left, top...) are not network devices.
local SIDES = { left = true, right = true, top = true, bottom = true, front = true, back = true }
function M.devices(api)
  local d = { storage = {}, input = {}, furnace = {}, drive = {}, bridge = {}, other = {} }
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
