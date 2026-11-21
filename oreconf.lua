-- Shared by the turtle (oreminer.lua) and the base computer (base.lua).
-- Copy this file onto both.
return {
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
  -- Geo Scanner only while it is home, to talk to the base.
  MODEM_ITEMS = {
    ["computercraft:wireless_modem_normal"] = true,
    ["computercraft:wireless_modem_advanced"] = true,
  },
  SCANNER_ITEM = "advancedperipherals:geo_scanner",
}
