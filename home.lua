-- home: register the spot this turtle stands on as its home (needs GPS).
--
--   home miner|forester [north|east|south|west]
--
-- Stand the turtle where it should live, facing the way it should face (its
-- chest behind it). It asks the GPS where it is (wireless modem: equipped, or
-- swapped in from its inventory), reads its facing from its compass or Geo
-- Scanner (or the argument), tells the base, and from then on lives here in
-- that role.

local link = require("link")
local nav = require("nav")

local args = { ... }
local role = args[1]
if role ~= "miner" and role ~= "forester" then
  error("Usage: home miner|forester [facing]", 0)
end

-- position from GPS (through the modem)
local pos = link.withModem(function()
  local x, y, z = gps.locate(3)
  if x then return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) } end
end)
if not pos then error("No GPS here: build the GPS (monitor: BUILD GPS) or use $home in chat", 0) end

-- facing: argument, compass, or the Geo Scanner method (no digging)
local h = args[2] and nav.index(args[2]) or nav.compass()
if not h and link.scanner() then h = nav.scanHeading(nil) end
if not h then error("Which way do I face? home " .. role .. " north|east|south|west", 0) end

local reply = link.talk("registerHome", { home = { x = pos.x, y = pos.y, z = pos.z, facing = nav.NAMES[h] },
                                          homeRole = role }, false)
if not (reply and reply.type == "registered") then
  error("The base did not register the home: " .. tostring(reply and (reply.reason or reply.type) or "no answer"), 0)
end

local cfg = link.config()
cfg.role, cfg.needsHome, cfg.slot = role, nil, nil
cfg.home = { y = reply.y, heading = h }
link.saveConfig(cfg)
print(("Home %d: %s at %d %d %d facing %s. Starting."):format(reply.home, role, pos.x, pos.y, pos.z, nav.NAMES[h]))
os.reboot()
