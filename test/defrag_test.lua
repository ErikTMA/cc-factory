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
  local invs = { { name = "sophisticatedstorage:iron_barrel_0", size = 3, limit = 512 },
                 { name = "minecraft:barrel_0", size = 27, limit = 64 } }
  local totals = { ["minecraft:copper_ingot|"] = 1280, ["minecraft:redstone|"] = 64 }
  local order, shares = D.assign(invs, totals, {})
  check(order and order[1] == "sophisticatedstorage:iron_barrel_0", "the upgraded barrel first")
  local big = shares["sophisticatedstorage:iron_barrel_0"]
  check(#big == 1 and big[1].key == "minecraft:copper_ingot|" and big[1].n == 1280, "1280 copper in its 3 slots of 512")
  local small = shares["minecraft:barrel_0"]
  check(#small == 1 and small[1].key == "minecraft:redstone|" and small[1].n == 64, "the redstone in the plain barrel")
end

print("scenario: plain barrels read A..Z: items in name order across them; each share sorted")
do
  local invs = { { name = "b1", size = 2, limit = 64 }, { name = "b2", size = 2, limit = 64 } }
  local totals = { ["minecraft:dirt|"] = 64, ["minecraft:apple|"] = 10, ["minecraft:cobblestone|"] = 100 }
  local order, shares = D.assign(invs, totals, {})
  local keys = {}
  for _, name in ipairs(order) do for _, e in ipairs(shares[name]) do keys[#keys + 1] = e.key end end
  check(table.concat(keys, ",") == "minecraft:apple|,minecraft:cobblestone|,minecraft:cobblestone|,minecraft:dirt|",
    "apple, cobblestone (split over the two), dirt: " .. table.concat(keys, ","))
  check(slotsOf(shares.b1, 64, {}) <= 2 and slotsOf(shares.b2, 64, {}) <= 2, "no barrel over its slots")
end

print("scenario: what a slot holds: pearls 16, tools 1, upgraded x8")
do
  check(D.cap(64, 16) == 16 and D.cap(512, 16) == 128 and D.cap(512, 1) == 1 and D.cap(64, 64) == 64, "caps")
  local invs = { { name = "b", size = 3, limit = 64 } }
  local order, shares = D.assign(invs, { ["minecraft:ender_pearl|"] = 20, ["minecraft:diamond_pickaxe|x"] = 1 },
    { ["minecraft:ender_pearl|"] = 16, ["minecraft:diamond_pickaxe|x"] = 1 })
  check(order and slotsOf(shares.b, 64, { ["minecraft:ender_pearl|"] = 16, ["minecraft:diamond_pickaxe|x"] = 1 }) == 3,
    "20 pearls take 2 slots, the pickaxe 1")
  local none, why = D.assign(invs, { ["minecraft:ender_pearl|"] = 64 }, { ["minecraft:ender_pearl|"] = 16 })
  check(none == nil and tostring(why):find("left over"), "too much for the space: says so, plans nothing: " .. tostring(why))
end

print("scenario: by item name: redstone before redstone_block (not by the key, where | sorts after _)")
do
  local _, shares = D.assign({ { name = "b", size = 9, limit = 64 } },
    { ["minecraft:redstone_block|"] = 64, ["minecraft:redstone|"] = 64 }, {})
  check(shares.b[1].key == "minecraft:redstone|" and shares.b[2].key == "minecraft:redstone_block|",
    "redstone, then redstone_block: " .. shares.b[1].key .. ", " .. shares.b[2].key)
end

print(failures == 0 and "ALL PASSED" or (failures .. " FAILURE(S)"))
