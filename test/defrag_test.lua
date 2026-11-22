-- defrag planner, pure: how storage is shared out between inventories.
-- Usage: lua defrag_test.lua ..
package.path = (arg[1] or "..") .. "/?.lua;" .. package.path
local D = require("defrag")

local failures = 0
local function check(ok, what)
  print((ok and "  ok   " or "  FAIL ") .. what)
  if not ok then failures = failures + 1 end
end

local function slotsOf(share, limit, maxOf)
  local n = 0
  for _, e in ipairs(share) do n = n + math.ceil(e.n / D.cap(limit, maxOf[e.key])) end
  return n
end

print("scenario: the user's case: the upgraded barrel takes the copper, the redstone goes elsewhere")
do
  local invs = { { name = "sophisticatedstorage:iron_barrel_0", size = 3, limit = 512, slots = {} },
                 { name = "minecraft:barrel_0", size = 27, limit = 64, slots = {} } }
  local totals = { ["minecraft:copper_ingot|"] = 1280, ["minecraft:redstone|"] = 64 }
  local order, shares = D.assign(invs, totals, {})
  local big = shares["sophisticatedstorage:iron_barrel_0"]
  check(#big == 1 and big[1].key == "minecraft:copper_ingot|" and big[1].n == 1280, "1280 copper in its 3 slots of 512")
  local small = shares["minecraft:barrel_0"]
  check(#small == 1 and small[1].key == "minecraft:redstone|" and small[1].n == 64, "the redstone in the plain barrel")
end

print("scenario: fewest moves: every item stays in the barrel that holds most of it; each sorted")
do
  local invs = { { name = "b1", size = 4, limit = 64, slots = { [1] = { key = "minecraft:dirt|", count = 64 },
                                                               [3] = { key = "minecraft:apple|", count = 5 } } },
                 { name = "b2", size = 4, limit = 64, slots = { [2] = { key = "minecraft:apple|", count = 50 },
                                                               [4] = { key = "minecraft:cobblestone|", count = 64 } } } }
  local totals = { ["minecraft:dirt|"] = 64, ["minecraft:apple|"] = 55, ["minecraft:cobblestone|"] = 64 }
  local _, shares = D.assign(invs, totals, {})
  local function keys(name) local t = {} for _, e in ipairs(shares[name]) do t[#t + 1] = e.n .. e.key end return table.concat(t, ",") end
  check(keys("b1") == "64minecraft:dirt|", "dirt stays in b1: " .. keys("b1"))
  check(keys("b2") == "55minecraft:apple|,64minecraft:cobblestone|", "the apples join the 50 in b2, sorted: " .. keys("b2"))
end

print("scenario: what a slot holds: pearls 16, tools 1, upgraded x8")
do
  check(D.cap(64, 16) == 16 and D.cap(512, 16) == 128 and D.cap(512, 1) == 1 and D.cap(64, 64) == 64, "caps")
  local invs = { { name = "b", size = 3, limit = 64, slots = {} } }
  local order, shares = D.assign(invs, { ["minecraft:ender_pearl|"] = 20, ["minecraft:diamond_pickaxe|x"] = 1 },
    { ["minecraft:ender_pearl|"] = 16, ["minecraft:diamond_pickaxe|x"] = 1 })
  check(order and slotsOf(shares.b, 64, { ["minecraft:ender_pearl|"] = 16, ["minecraft:diamond_pickaxe|x"] = 1 }) == 3,
    "20 pearls take 2 slots, the pickaxe 1")
  local none, why = D.assign(invs, { ["minecraft:ender_pearl|"] = 64 }, { ["minecraft:ender_pearl|"] = 16 })
  check(none == nil and tostring(why):find("left over"), "too much for the space: says so, plans nothing: " .. tostring(why))
end

print("scenario: by item name: redstone before redstone_block (not by the key, where | sorts after _)")
do
  local _, shares = D.assign({ { name = "b", size = 9, limit = 64, slots = {} } },
    { ["minecraft:redstone_block|"] = 64, ["minecraft:redstone|"] = 64 }, {})
  check(shares.b[1].key == "minecraft:redstone|" and shares.b[2].key == "minecraft:redstone_block|",
    "redstone, then redstone_block: " .. shares.b[1].key .. ", " .. shares.b[2].key)
end

-- Replays moves as the game does (Sophisticated: onto a part stack of the
-- item, else the lowest empty slot; others: the slot asked for) and checks
-- each landed where the plan said.
local function replay(invs, moves, maxOf)
  local by = {}
  for _, v in ipairs(invs) do
    local c = { name = v.name, size = v.size, limit = v.limit, loose = v.loose, slots = {} }
    for q, st in pairs(v.slots) do c.slots[q] = { key = st.key, count = st.count } end
    by[v.name] = c
  end
  for i, m in ipairs(moves) do
    local A, B = by[m.from], by[m.to]
    local st = A.slots[m.fromSlot]
    if not st or st.key ~= m.key or st.count < m.n then return nil, "move " .. i .. ": no such stack" end
    local cap = D.cap(B.limit, maxOf[m.key])
    local land
    if B.loose then
      for q = 1, B.size do local o = B.slots[q]; if o and o.key == m.key and o.count < cap then land = q; break end end
      if not land then for q = 1, B.size do if not B.slots[q] then land = q; break end end end
    else land = m.toSlot end
    if land ~= m.landed then return nil, ("move %d landed in %s, planned %s"):format(i, tostring(land), tostring(m.landed)) end
    local o = B.slots[land]
    if o and o.key ~= m.key then return nil, "move " .. i .. ": onto another item" end
    if (o and o.count or 0) + m.n > cap then return nil, "move " .. i .. ": over the limit" end
    if o then o.count = o.count + m.n else B.slots[land] = { key = m.key, count = m.n } end
    st.count = st.count - m.n
    if st.count == 0 then A.slots[m.fromSlot] = nil end
  end
  return by
end

print("scenario: the whole run planned at once: every move lands where planned; sorted; few moves")
do
  local invs = { { name = "a", size = 9, limit = 64, loose = true, slots = {} },
                 { name = "b", size = 9, limit = 64, loose = true, slots = {} } }
  -- scattered: b holds what belongs in a and the other way round, gaps, splits
  local items = { "minecraft:apple", "minecraft:bone", "minecraft:coal", "minecraft:dirt", "minecraft:egg" }
  local maxOf = { ["minecraft:egg|"] = 16 }
  invs[1].slots = { [2] = { key = "minecraft:egg|", count = 10 }, [5] = { key = "minecraft:dirt|", count = 64 },
                    [7] = { key = "minecraft:apple|", count = 3 }, [9] = { key = "minecraft:coal|", count = 40 } }
  invs[2].slots = { [1] = { key = "minecraft:apple|", count = 30 }, [3] = { key = "minecraft:bone|", count = 64 },
                    [4] = { key = "minecraft:egg|", count = 9 }, [8] = { key = "minecraft:dirt|", count = 20 } }
  local totals = {}
  for _, v in ipairs(invs) do for _, st in pairs(v.slots) do totals[st.key] = (totals[st.key] or 0) + st.count end end
  local order, shares = D.assign(invs, totals, maxOf)
  local moves, wrong = D.moves(invs, shares, maxOf)
  local after, why = replay(invs, moves, maxOf)
  check(after ~= nil, "every move lands where it was planned: " .. tostring(why))
  check(wrong == 0, "nothing left out of place: " .. wrong)
  local ok = true
  for _, name in ipairs(order) do
    local I, last, gap = after[name], "", false
    for q = 1, I.size do
      local st = I.slots[q]
      if st then if gap or not (last == "" or not D.before(st.key, last)) then ok = false end; last = st.key else gap = true end
    end
  end
  check(ok, "both sorted from their first slot")
  local stacks = 0
  for _, v in ipairs(invs) do for _ in pairs(v.slots) do stacks = stacks + 1 end end
  check(#moves <= 3 * stacks, ("no stack moves more than 3 times on average: %d moves, %d stacks"):format(#moves, stacks))
  _ = items
end

print(failures == 0 and "ALL PASSED" or (failures .. " FAILURE(S)"))
