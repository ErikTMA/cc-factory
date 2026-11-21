-- cc-factory installer: the startup.lua of the installer disk.
--
-- The disk drive sits under the assembler's build spot. A computer boots from
-- an attached disk *instead of* its own startup, so this runs on every boot of
-- anything attached to the drive:
--   * a new turtle on the build spot  -> install it (once), then reboot
--   * an installed turtle             -> just run its own startup
--   * the base (sees the drive over wired modems) or any other computer
--                                     -> run its own startup, touch nothing

local function runOwnStartup()
  if fs.exists("/startup.lua") then shell.run("/startup.lua") end
end

if not turtle or fs.exists("/agent.cfg") then
  runOwnStartup()
  return
end

local mount = fs.getDir(shell.getRunningProgram())
local cfgFile = fs.combine(mount, "install.cfg")
if not fs.exists(cfgFile) then
  print("Installer disk has no install.cfg yet; the base writes it.")
  return
end
local f = fs.open(cfgFile, "r")
local inst = textutils.unserialize(f.readAll())
f.close()

-- copy the turtle files
local dist = fs.combine(mount, "dist")
for _, name in ipairs(fs.list(dist)) do
  local to = "/" .. name
  if fs.exists(to) then fs.delete(to) end
  fs.copy(fs.combine(dist, name), to)
end

local function writeTable(path, t)
  local h = fs.open(path, "w")
  h.write(textutils.serialize(t))
  h.close()
end

writeTable("/agent.cfg", { base = inst.base, role = inst.role, order = inst.order,
                           trees = inst.trees, wait = inst.wait, needsHome = true,
                           slot = inst.slot, homeY = inst.homeY })
local v = fs.open("/version", "w")
v.write(inst.version)
v.close()
os.setComputerLabel(("%s-%d"):format(inst.role, os.getComputerID()))
print(("Installed as %s (order %s). Rebooting."):format(inst.role, tostring(inst.order)))
os.reboot()
