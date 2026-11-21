-- Which files go where. Read by bootstrap.lua (base) and by base.lua when it
-- hands code to turtles. Paths are relative to the repository root.
return {
  -- installed on the base computer
  base = { "base.lua", "factory.lua", "production.lua", "recipes.lua", "homes.lua", "storage.lua", "dist.lua",
           "oreconf.lua", "manifest.lua", "bootstrap.lua" },
  -- handed to every turtle (the base keeps a copy in /dist); startup.lua is the agent
  turtle = { "startup.lua", "link.lua", "tmove.lua", "oreconf.lua", "oreminer.lua",
             "forester.lua", "assembler.lua", "travel.lua", "nav.lua", "surveyor.lua" },
  -- written to the installer disk as its startup.lua
  installer = "install.lua",
}
