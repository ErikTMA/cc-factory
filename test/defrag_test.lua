-- defrag planner, pure: every plan is replayed against a model with the
-- game's rules (a slot takes an item only if empty or the same item, never
-- above what it holds; nothing is made or lost), then the layout is checked.
-- Usage: lua defrag_test.lua ..
package.path = (arg[1] or "..") .. "/?.lua;" .. package.path
local D = require("defrag")

local failures = 0
local function check(ok, what)
  print((ok and "  ok   " or "  FAIL ") .. what)
  if not ok then failures = failures + 1 end
end

-- storage: { inv = { cap = n (per 64-stack), lock = { [slot] = key }, size = n, items = { [slot] = { key, n } } } }
local STACK = { ["minecraft:ender_pearl"] = 16 }
local function maxOf(key) return STACK[(key or ""):match("^[^|]+") or ""] or 64 end
local function build(invs)
  local slots, caps = {}, {}
  for inv, I in pairs(invs) do
    for slot = 1, I.size do
      local it = I.items[slot]
      local s = { id = inv .. "#" .. slot, inv = inv, slot = slot,
                  key = it and it[1], count = it and it[2] or 0, lock = I.lock and I.lock[slot] }
      caps[s.id] = I.cap
      slots[#slots + 1] = s
    end
  end
  local function cap(s, key) return math.floor(caps[s.id] * maxOf(key) / 64) end
  return slots, cap
end

local function replay(slots, cap, moves)
  local state, byId, before = {}, {}, {}
  for _, s in ipairs(slots) do
    byId[s.id] = s
    state[s.id] = { key = s.key, n = s.count }
    if s.key then before[s.key] = (before[s.key] or 0) + s.count end
  end
  for i, m in ipairs(moves) do
    local a, b = state[m.from], state[m.to]
    if not a or a.key ~= m.key or a.n < m.n or m.n <= 0 then return false, "move " .. i .. ": source" end
    if b.key and b.key ~= m.key then return false, "move " .. i .. ": into another item" end
    if byId[m.to].lock and byId[m.to].lock ~= m.key then return false, "move " .. i .. ": into a locked slot" end
    if b.n + m.n > cap(byId[m.to], m.key) then return false, "move " .. i .. ": over the slot's limit" end
    a.n = a.n - m.n; if a.n == 0 then a.key = nil end
    b.key, b.n = m.key, b.n + m.n
  end
  local after, used = {}, 0
  for _, st in pairs(state) do
    if st.key then after[st.key] = (after[st.key] or 0) + st.n; used = used + 1 end
  end
  for k, n in pairs(before) do if after[k] ~= n then return false, "lost " .. k end end
  for k in pairs(after) do if not before[k] then return false, "made " .. k end end
  return true, used, state
end

local function run(invs)
  local slots, cap = build(invs)
  local moves, used = D.plan(slots, cap)
  local ok, real, state = replay(slots, cap, moves)
  return ok, real, used, moves, state, D.usedSlots(slots)
end

print("scenario: the user's case: a stack of redstone sits in the big barrel the copper needs")
do
  local small = { size = 27, cap = 64, items = {} }
  for i = 1, 20 do small.items[i] = { "minecraft:copper_ingot", 64 } end
  local big = { size = 3, cap = 512, items = { [1] = { "minecraft:redstone", 64 } } }
  local ok, used, planned, moves, state, before = run({ ["sophisticatedstorage:barrel_0"] = big, ["minecraft:barrel_0"] = small })
  check(ok, "every move is valid: " .. tostring(used))
  check(before == 21 and used == 4 and planned == 4, ("21 slots -> 4 (3 big for 1280 copper, 1 for redstone): %s -> %s"):format(before, tostring(used)))
  local inBig = 0
  for slot = 1, 3 do
    local st = state["sophisticatedstorage:barrel_0#" .. slot]
    if st.key == "minecraft:copper_ingot" then inBig = inBig + st.n end
  end
  check(inBig == 1280, "all copper in the big barrel: " .. inBig)
end

print("scenario: partial stacks merge; a tie moves nothing")
do
  local b = { size = 9, cap = 64, items = {} }
  for i = 1, 5 do b.items[i * 2 - 1] = { "minecraft:cobblestone", 10 } end
  local ok, used = run({ ["minecraft:barrel_0"] = b })
  check(ok and used == 1, "5 slots of 10 cobblestone -> 1: " .. tostring(used))
  local tie = { size = 2, cap = 64, items = { [1] = { "minecraft:dirt", 64 }, [2] = { "minecraft:sand", 64 } } }
  local _, _, _, moves = run({ ["minecraft:barrel_0"] = tie })
  check(#moves == 0, "two full stacks: no moves: " .. #moves)
end

print("scenario: different components never merge; items that stack to 16")
do
  local b = { size = 4, cap = 64, items = {
    [1] = { "minecraft:diamond_pickaxe|a1", 1 }, [2] = { "minecraft:diamond_pickaxe|b2", 1 },
    [3] = { "minecraft:ender_pearl", 10 }, [4] = { "minecraft:ender_pearl", 10 } } }
  local ok, used, _, _, state = run({ ["minecraft:barrel_0"] = b })
  check(ok, "valid (no stack over 16 pearls, no mixed pickaxes)")
  check(used == 4, "pickaxes stay apart, 20 pearls need 2 slots: " .. tostring(used))
end

print("scenario: a drawer locked to copper is filled first; the barrel copper moves in")
do
  local drawer = { size = 1, cap = 2048, lock = { [1] = "minecraft:copper_ingot" }, items = { [1] = { "minecraft:copper_ingot", 100 } } }
  local barrel = { size = 27, cap = 64, items = {} }
  for i = 1, 10 do barrel.items[i] = { "minecraft:copper_ingot", 64 } end
  barrel.items[11] = { "minecraft:iron_ingot", 64 }
  local ok, used, _, _, state = run({ ["functionalstorage:oak_1_0"] = drawer, ["minecraft:barrel_0"] = barrel })
  check(ok and used == 2, "copper all in the drawer, iron in the barrel: " .. tostring(used))
  check(state["functionalstorage:oak_1_0#1"].n == 740, "drawer holds 740 copper")
  -- a locked drawer never takes another item
  local d2 = { size = 1, cap = 2048, lock = { [1] = "minecraft:gold_ingot" }, items = {} }
  local b2 = { size = 3, cap = 64, items = { [1] = { "minecraft:iron_ingot", 30 }, [3] = { "minecraft:iron_ingot", 30 } } }
  local ok2, used2 = run({ ["functionalstorage:oak_1_1"] = d2, ["minecraft:barrel_1"] = b2 })
  check(ok2 and used2 == 1, "iron merges in the barrel, not into the gold drawer: " .. tostring(used2))
end

print("scenario: full storage, a pointless swap is never planned; a needed one waits for room")
do
  local big = { size = 1, cap = 512, items = { [1] = { "minecraft:redstone", 64 } } }
  local small = { size = 2, cap = 64, items = { [1] = { "minecraft:copper_ingot", 64 }, [2] = { "minecraft:copper_ingot", 64 } } }
  local ok, used = run({ ["a"] = big, ["b"] = small })
  check(ok, "valid with no free slot: " .. tostring(used))
  check(used <= 3, "never more slots than before: " .. tostring(used))
end

print("scenario: moves that share no slot go in the same round, in order")
do
  local b = { size = 27, cap = 64, items = {} }
  for i = 1, 8 do b.items[i * 3] = { "minecraft:stone", 8 } end
  local slots, cap = build({ ["minecraft:barrel_0"] = b })
  local moves = D.plan(slots, cap)
  local rounds = D.rounds(moves)
  local flat, okRounds = {}, true
  for _, r in ipairs(rounds) do
    local seen = {}
    for _, m in ipairs(r) do
      if seen[m.from] or seen[m.to] then okRounds = false end
      seen[m.from], seen[m.to] = true, true
      flat[#flat + 1] = m
    end
  end
  local ok = replay(slots, cap, flat)
  check(okRounds and ok, ("rounds touch each slot once and replay valid (%d moves, %d rounds)"):format(#moves, #rounds))
end

print(failures == 0 and "ALL PASSED" or (failures .. " FAILURE(S)"))
