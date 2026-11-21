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
    { name = "coal", y = 96 },     { name = "emerald", y = 236 },
  },

  -- The turtle keeps a wireless modem in its inventory and swaps it with the
  -- Geo Scanner or compass only while it is home, to talk to the base.
  MODEM_ITEMS = {
    ["computercraft:wireless_modem_normal"] = true,
    ["computercraft:wireless_modem_advanced"] = true,
  },
  SCANNER_ITEM = "advancedperipherals:geo_scanner",
}

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

-- The assembler's crafting steps for a role. Each step: `grid` = items the base
-- delivers, by cell; `keep` = the previous result already in its cell;
-- `select` = the cell the result lands in.
function C.buildSteps(role)
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

-- Every item (and count) the base needs in storage to build one turtle.
function C.parts(role, sapling)
  local need = {}
  for _, step in ipairs(C.buildSteps(role)) do
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
