-- Shared by the base and every turtle: protocol, ore presets, items, and how
-- turtles are built.
local C = {
  -- rednet protocol name
  PROTOCOL = "oreminer",

  -- Best Y level per vanilla ore in 1.21 world generation. Modded ores vary by
  -- mod and pack config: use a custom Y and name for those.
  PRESETS = {
    { name = "diamond", y = -58 }, { name = "redstone", y = -58 },
    { name = "lapis", y = 0 },     { name = "gold", y = -16 },
    { name = "iron", y = 16 },     { name = "copper", y = 48 },
    -- (emerald ore: Y -16 and up, mountain biomes only; its vanilla peak,
    -- 236, is above any home: miners only work below theirs)
    { name = "coal", y = 48 },     { name = "emerald", y = 48 },
  },

  -- The turtle keeps a wireless modem in its inventory and swaps it with the
  -- Geo Scanner or compass only while it is home, to talk to the base.
  MODEM_ITEMS = {
    ["computercraft:wireless_modem_normal"] = true,
    ["computercraft:wireless_modem_advanced"] = true,
  },
  SCANNER_ITEM = "advancedperipherals:geo_scanner",
  DETECTOR_ITEM = "advancedperipherals:environment_detector", -- scanEntities: items lying around
  -- tools a turtle may ask the base for (sent from storage, else crafted)
  TOOLS = { ["advancedperipherals:geo_scanner"] = true, ["advancedperipherals:environment_detector"] = true,
            ["minecraft:compass"] = true, ["computercraft:wireless_modem_normal"] = true,
            ["minecraft:shears"] = true, ["advancedperipherals:weak_automata_core"] = true,
            ["computercraft:wireless_modem_advanced"] = true },
  -- a forester that shears leaves: the Weak Automata Core digs with the item
  -- in the selected slot (AP 0.8.2a AutomataBlockHandPlugin.digBlock, 1 fuel
  -- and 1 s each), and that is the shears. The core can't be crafted by the
  -- base (its recipe takes a potion): it comes from storage.
  SHEARS_ITEM = "minecraft:shears",
  ENDER_MODEM_ITEM = "computercraft:wireless_modem_advanced",
  AUTOMATA_ITEM = "advancedperipherals:weak_automata_core",
}

-- ----------------------------------------------------------------- fuel --
-- Turtle fuel per item (CC: burn ticks * 5 / 100; checked in the 1.120.2 jar).
-- Tiny coal (Utilitarian, Actually Additions; 200 ticks) is 10: 8 of them are
-- worth one coal, so for turtles they're only less dense. Their gain is in
-- furnaces: one tiny coal smelts exactly one item (production.lua).
C.FUEL = {
  ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800,
  ["utilitarian:tiny_coal"] = 10, ["utilitarian:tiny_charcoal"] = 10,
  ["actuallyadditions:tiny_coal"] = 10, ["actuallyadditions:tiny_charcoal"] = 10,
}
-- What the base hands a turtle, first to last: charcoal (it grows back), then
-- coal, a coal block, the tiny kinds last (same fuel, 8x the slots).
C.FUEL_ORDER = { "minecraft:charcoal", "minecraft:coal", "minecraft:coal_block",
  "utilitarian:tiny_charcoal", "utilitarian:tiny_coal",
  "actuallyadditions:tiny_charcoal", "actuallyadditions:tiny_coal" }
C.TINY = { "utilitarian:tiny_charcoal", "utilitarian:tiny_coal",
  "actuallyadditions:tiny_charcoal", "actuallyadditions:tiny_coal" }
function C.isFuel(name) return C.FUEL[name] ~= nil end

-- ---------------------------------------------------------------- trees --
-- Per sapling kind: `spacing` between tree spots, from how far the tree's
-- LOGS reach sideways (worldgen data in the 1.21.1 jars; leaves don't stop a
-- tree from growing, so crowns may overlap):
--   straight 1x1 trunks (oak, birch, spruce, small jungle): 3
--   menril (Integrated Dynamics TrunkPlacerMenril): its first 3 blocks are
--     plus-shaped (a log on each side), and it only grows when the ground
--     under its 4 side cells is grass or dirt (`soilAround`): 4, so a free
--     cell stays between two trees' bases
--   acacia (forking trunk), cherry (branches 2-4 sideways), mangrove
--     (branches and roots): 5
--   dark oak only grows from 4 saplings in a square (`twoByTwo`): not planted
-- Unknown (modded) kinds: 4.
-- `reach`: how far its canopy reaches from the trunk; a spot keeps that many
-- open cells to the fence, so the leaves (and the saplings they drop) stay in.
C.TREES = {
  ["minecraft:oak_sapling"] = { spacing = 3, reach = 2 }, ["minecraft:birch_sapling"] = { spacing = 3, reach = 2 },
  ["minecraft:spruce_sapling"] = { spacing = 3, reach = 2 }, ["minecraft:jungle_sapling"] = { spacing = 3, reach = 2 },
  ["integrateddynamics:menril_sapling"] = { spacing = 4, reach = 3, soilAround = true },
  ["minecraft:acacia_sapling"] = { spacing = 5, reach = 4 }, ["minecraft:cherry_sapling"] = { spacing = 5, reach = 4 },
  ["minecraft:mangrove_propagule"] = { spacing = 5, reach = 4 },
  ["minecraft:dark_oak_sapling"] = { twoByTwo = true },
}
local UNKNOWN_TREE = { spacing = 4, reach = 3 }
function C.tree(name) return C.TREES[name] or UNKNOWN_TREE end

-- ------------------------------------------------------------- building --
-- Crafting grid cells in a turtle's inventory (slots 1-3, 5-7, 9-11).
C.GRID_CELLS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }

local GOLD, REDSTONE, PANE = "minecraft:gold_ingot", "minecraft:redstone", "minecraft:glass_pane"
local IRON, STONE = "minecraft:iron_ingot", "minecraft:stone"
-- advanced turtles (gold) for working turtles, normal ones (iron) for GPS hosts
local TIERS = {
  advanced = { body = GOLD, computerBody = GOLD,
               computer = "computercraft:computer_advanced", turtle = "computercraft:turtle_advanced" },
  normal = { body = IRON, computerBody = STONE,
             computer = "computercraft:computer_normal", turtle = "computercraft:turtle_normal" },
}

-- What each kind of turtle is made of. "@sapling" is replaced by the base's
-- configured sapling. Loadout is handed to the new turtle in this order, so a
-- forester's saplings land in slot 1. `optional` items are handed over only if
-- storage has them: without a wireless modem the turtle talks through a wired
-- modem at its home slot instead.
local WIRELESS = { "computercraft:wireless_modem_normal", 1, optional = true }
C.ROLES = {
  miner = {
    upgrades = { "minecraft:diamond_pickaxe", C.SCANNER_ITEM },
    loadout = { WIRELESS, { "minecraft:coal", 32 } },
  },
  forester = {
    upgrades = { "minecraft:diamond_pickaxe", "minecraft:compass" },
    loadout = { { "@sapling", 16 }, WIRELESS, { "minecraft:coal", 16 } },
  },
  -- surveyor: maps the network from the build spot (where it is built), then
  -- parks next to a modem. No home slot; cobblestone = markers for home chests.
  surveyor = {
    upgrades = { "minecraft:compass" },
    loadout = { { "minecraft:coal", 16 }, { "minecraft:cobblestone", 8 } },
    noHome = true,
  },
  -- GPS host: flies to a point high above the base and runs `gps host`. The
  -- compass tells it its heading on the way (there is no GPS yet).
  gps = {
    tier = "normal",
    upgrades = { "minecraft:compass", "computercraft:wireless_modem_normal" },
    loadout = { { "minecraft:coal", 8 } },
  },
}

-- GPS host points, from the build spot. Not all at one height: four points in
-- one plane can't tell above it from below it.
C.GPS_POINTS = {
  { x = -4, y = 20, z = -4 }, { x = 4, y = 20, z = -4 }, { x = -4, y = 20, z = 4 }, { x = 4, y = 26, z = 4 },
}

-- Accessories: what the player picks per turtle (TURTLES tab). The turtle
-- asks the base for the ones it lacks at its next stop home (sent from
-- storage, else crafted), keeps them, and puts back into its chest any it is
-- no longer meant to carry. `roles`: who may have it.
C.ACCESSORIES = {
  { name = "MODEM", items = { "computercraft:wireless_modem_normal" }, roles = { miner = true, forester = true },
    what = "wireless modem: talks to the base within 64 blocks, GPS" },
  { name = "ENDER", items = { "computercraft:wireless_modem_advanced" }, roles = { miner = true, forester = true },
    what = "ender modem: talks to the base from anywhere (same dimension)" },
  { name = "SHEAR", items = { "minecraft:shears", "advancedperipherals:weak_automata_core" }, roles = { forester = true },
    what = "shears + Weak Automata Core: shears leaves before felling" },
  -- (the base crafts it: casing, observer (nether quartz), wired modem, redstone blocks)
  { name = "READER", items = { "advancedperipherals:block_reader" }, roles = { miner = true },
    what = "block reader: INSPECT on FINDS reads spawners (the mob) and chests (loot, opened)" },
}
C.READER_ITEM = "advancedperipherals:block_reader"
C.ACCESSORY_ITEMS = {}
-- (an accessory's items are tools too: asked for, sent, crafted when there is a recipe)
for _, a in ipairs(C.ACCESSORIES) do
  for _, item in ipairs(a.items) do C.ACCESSORY_ITEMS[item] = true; C.TOOLS[item] = true end
end

-- The assembler's crafting steps for a role. Each step: `grid` = items the base
-- delivers, by cell; `keep` = the previous result already in its cell;
-- `select` = the cell the result lands in. `from` (AE2-style): start at that
-- step because its input is already in storage (a computer: 2, a plain
-- turtle: 3); that first step's `keep` item is then delivered like the rest.
function C.buildSteps(role, from)
  local all = C.allBuildSteps(role)
  from = from or 1
  local out = {}
  for i = from, #all do
    local s = all[i]
    if i == from and s.keep then
      local grid = {}
      for c, it in pairs(s.grid) do grid[c] = it end
      for c, it in pairs(s.keep) do grid[c] = it end
      s = { grid = grid, select = s.select, result = s.result }
    end
    out[#out + 1] = s
  end
  return out
end

function C.allBuildSteps(role)
  local up = C.ROLES[role].upgrades
  local t = TIERS[C.ROLES[role].tier or "advanced"]
  local cb, b = t.computerBody, t.body
  return {
    { grid = { [1] = cb, [2] = cb, [3] = cb, [5] = cb, [6] = REDSTONE, [7] = cb,
               [9] = cb, [10] = PANE, [11] = cb },
      select = 6, result = t.computer },
    { grid = { [1] = b, [2] = b, [3] = b, [5] = b, [7] = b,
               [9] = b, [10] = "minecraft:chest", [11] = b },
      keep = { [6] = t.computer }, select = 2, result = t.turtle },
    { grid = { [1] = up[1], [3] = up[2] }, keep = { [2] = t.turtle }, select = 2, result = t.turtle },
  }
end

-- Every item (and count) the base needs in storage to build one turtle
-- (starting at step `from`, see buildSteps).
function C.parts(role, sapling, from)
  local need = {}
  for _, step in ipairs(C.buildSteps(role, from)) do
    for _, item in pairs(step.grid) do need[item] = (need[item] or 0) + 1 end
  end
  for _, l in ipairs(C.ROLES[role].loadout) do
    if not l.optional then
      local item = l[1] == "@sapling" and sapling or l[1]
      need[item] = (need[item] or 0) + l[2]
    end
  end
  return need
end

return C
