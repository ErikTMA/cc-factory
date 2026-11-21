-- recipes: what the base can make, for the crafting planner and the furnaces.
--
-- Every grid here is checked by the test harness against the real recipe JSON
-- from the game/mod jars (test/fixtures/recipes.json), so a wrong cell fails
-- the tests. Cells are turtle slots: 1 2 3 / 5 6 7 / 9 10 11.
--
-- An ingredient is an item id or a group ("#planks"): the planner picks the
-- member with the most in stock, or one it can make.

local R = {}

local WOODS = { "oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry" }

R.GROUPS = { ["#planks"] = {}, ["#logs"] = {}, ["#glass_panes"] = { "minecraft:glass_pane" } }
for _, w in ipairs(WOODS) do
  table.insert(R.GROUPS["#planks"], "minecraft:" .. w .. "_planks")
  table.insert(R.GROUPS["#logs"], "minecraft:" .. w .. "_log")
end

-- output item -> { count = made per craft, grid = {[cell] = ingredient},
--                  single = true if the result does not stack (craft one at a time) }
R.CRAFT = {
  ["computercraft:computer_advanced"] = { count = 1, grid = {
    [1] = "minecraft:gold_ingot", [2] = "minecraft:gold_ingot", [3] = "minecraft:gold_ingot",
    [5] = "minecraft:gold_ingot", [6] = "minecraft:redstone", [7] = "minecraft:gold_ingot",
    [9] = "minecraft:gold_ingot", [10] = "#glass_panes", [11] = "minecraft:gold_ingot" } },
  ["computercraft:wired_modem"] = { count = 1, grid = {
    [1] = "minecraft:stone", [2] = "minecraft:stone", [3] = "minecraft:stone",
    [5] = "minecraft:stone", [6] = "minecraft:redstone", [7] = "minecraft:stone",
    [9] = "minecraft:stone", [10] = "minecraft:stone", [11] = "minecraft:stone" } },
  ["computercraft:wired_modem_full"] = { count = 1, grid = { [1] = "computercraft:wired_modem" } },
  ["advancedperipherals:peripheral_casing"] = { count = 1, grid = {
    [1] = "minecraft:iron_ingot", [2] = "minecraft:iron_bars", [3] = "minecraft:iron_ingot",
    [5] = "minecraft:iron_bars", [6] = "minecraft:redstone_block", [7] = "minecraft:iron_bars",
    [9] = "minecraft:iron_ingot", [10] = "minecraft:iron_bars", [11] = "minecraft:iron_ingot" } },
  ["advancedperipherals:geo_scanner"] = { count = 1, grid = {
    [1] = "minecraft:diamond", [2] = "computercraft:wired_modem_full", [3] = "minecraft:diamond",
    [5] = "minecraft:diamond", [6] = "advancedperipherals:peripheral_casing", [7] = "minecraft:diamond",
    [9] = "minecraft:redstone_block", [10] = "minecraft:observer", [11] = "minecraft:redstone_block" } },
  ["computercraft:wireless_modem_normal"] = { count = 1, grid = {
    [1] = "minecraft:stone", [2] = "minecraft:stone", [3] = "minecraft:stone",
    [5] = "minecraft:stone", [6] = "minecraft:ender_pearl", [7] = "minecraft:stone",
    [9] = "minecraft:stone", [10] = "minecraft:stone", [11] = "minecraft:stone" } },
  ["minecraft:observer"] = { count = 1, grid = {
    [1] = "minecraft:cobblestone", [2] = "minecraft:cobblestone", [3] = "minecraft:cobblestone",
    [5] = "minecraft:redstone", [6] = "minecraft:redstone", [7] = "minecraft:quartz",
    [9] = "minecraft:cobblestone", [10] = "minecraft:cobblestone", [11] = "minecraft:cobblestone" } },
  ["minecraft:iron_bars"] = { count = 16, grid = {
    [1] = "minecraft:iron_ingot", [2] = "minecraft:iron_ingot", [3] = "minecraft:iron_ingot",
    [5] = "minecraft:iron_ingot", [6] = "minecraft:iron_ingot", [7] = "minecraft:iron_ingot" } },
  ["minecraft:redstone_block"] = { count = 1, grid = {
    [1] = "minecraft:redstone", [2] = "minecraft:redstone", [3] = "minecraft:redstone",
    [5] = "minecraft:redstone", [6] = "minecraft:redstone", [7] = "minecraft:redstone",
    [9] = "minecraft:redstone", [10] = "minecraft:redstone", [11] = "minecraft:redstone" } },
  ["minecraft:copper_block"] = { count = 1, grid = {
    [1] = "minecraft:copper_ingot", [2] = "minecraft:copper_ingot", [3] = "minecraft:copper_ingot",
    [5] = "minecraft:copper_ingot", [6] = "minecraft:copper_ingot", [7] = "minecraft:copper_ingot",
    [9] = "minecraft:copper_ingot", [10] = "minecraft:copper_ingot", [11] = "minecraft:copper_ingot" } },
  ["minecraft:iron_block"] = { count = 1, grid = {
    [1] = "minecraft:iron_ingot", [2] = "minecraft:iron_ingot", [3] = "minecraft:iron_ingot",
    [5] = "minecraft:iron_ingot", [6] = "minecraft:iron_ingot", [7] = "minecraft:iron_ingot",
    [9] = "minecraft:iron_ingot", [10] = "minecraft:iron_ingot", [11] = "minecraft:iron_ingot" } },
  ["minecraft:diamond_pickaxe"] = { count = 1, single = true, grid = {
    [1] = "minecraft:diamond", [2] = "minecraft:diamond", [3] = "minecraft:diamond",
    [6] = "minecraft:stick", [10] = "minecraft:stick" } },
  ["minecraft:compass"] = { count = 1, grid = {
    [2] = "minecraft:iron_ingot", [5] = "minecraft:iron_ingot", [6] = "minecraft:redstone",
    [7] = "minecraft:iron_ingot", [10] = "minecraft:iron_ingot" } },
  ["minecraft:chest"] = { count = 1, grid = {
    [1] = "#planks", [2] = "#planks", [3] = "#planks", [5] = "#planks", [7] = "#planks",
    [9] = "#planks", [10] = "#planks", [11] = "#planks" } },
  ["minecraft:stick"] = { count = 4, grid = { [1] = "#planks", [5] = "#planks" } },
  ["minecraft:glass_pane"] = { count = 16, grid = {
    [1] = "minecraft:glass", [2] = "minecraft:glass", [3] = "minecraft:glass",
    [5] = "minecraft:glass", [6] = "minecraft:glass", [7] = "minecraft:glass" } },
  -- Utilitarian (Almost Unified's choice in ATM10): 1 -> 8, each smelts one item
  ["utilitarian:tiny_charcoal"] = { count = 8, grid = { [1] = "minecraft:charcoal" } },
  ["utilitarian:tiny_coal"] = { count = 8, grid = { [1] = "minecraft:coal" } },
  ["alltheores:copper_ore_hammer"] = { count = 1, single = true, grid = {
    [2] = "minecraft:copper_block", [3] = "minecraft:stick", [6] = "minecraft:stick",
    [7] = "minecraft:copper_block", [9] = "minecraft:stick" } },
  ["alltheores:iron_ore_hammer"] = { count = 1, single = true, grid = {
    [2] = "minecraft:iron_block", [3] = "minecraft:stick", [6] = "minecraft:stick",
    [7] = "minecraft:iron_block", [9] = "minecraft:stick" } },
}
for _, w in ipairs(WOODS) do
  R.CRAFT["minecraft:" .. w .. "_planks"] = { count = 4, grid = { [1] = "minecraft:" .. w .. "_log" } }
end

-- ------------------------------------------------------------- smelting --
-- input -> output for the furnaces. `ore` inputs go to blast furnaces too.
R.SMELT = {
  ["minecraft:raw_iron"] = { out = "minecraft:iron_ingot", ore = true },
  ["minecraft:raw_gold"] = { out = "minecraft:gold_ingot", ore = true },
  ["minecraft:raw_copper"] = { out = "minecraft:copper_ingot", ore = true },
  ["minecraft:cobblestone"] = { out = "minecraft:stone" },
  ["minecraft:sand"] = { out = "minecraft:glass" },
}
for _, w in ipairs(WOODS) do R.SMELT["minecraft:" .. w .. "_log"] = { out = "minecraft:charcoal" } end

local VANILLA_METAL = { iron = true, gold = true, copper = true, netherite = true }
local function ingotOf(metal)
  return (VANILLA_METAL[metal] and "minecraft:" or "alltheores:") .. metal .. "_ingot"
end

-- Smelting for items not listed above: All The Ores dusts and raw materials.
function R.smelt(item)
  if R.SMELT[item] then return R.SMELT[item] end
  local metal = item:match("^alltheores:(%w+)_dust$") or item:match("^alltheores:raw_(%w+)$")
  if metal then return { out = ingotOf(metal), ore = true } end
end

-- ------------------------------------------------------------- hammering --
-- All The Ores: hammer + raw ore -> 2 dust (the hammer comes back damaged).
R.HAMMERS = { "alltheores:copper_ore_hammer", "alltheores:iron_ore_hammer" }

function R.hammerDust(item)
  local metal = item:match("^minecraft:raw_(%w+)$") or item:match("^alltheores:raw_(%w+)$")
  if metal and metal ~= "" then return "alltheores:" .. metal .. "_dust" end
end

function R.isHammer(item)
  return item:find("^alltheores:%w+_ore_hammer$") ~= nil
end

return R
