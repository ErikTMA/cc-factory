-- link: every turtle's connection to the base computer.
--
-- Turtles only talk to the base while at home, through the first of:
--   1. a modem equipped as an upgrade (e.g. the assembler's wireless modem)
--   2. a modem block next to it at home (top, bottom, front or back), e.g. a
--      wired modem cabled to the base: no ender pearls needed
--   3. a wireless modem from its inventory, swapped in for the Geo Scanner or
--      compass just for the talk
--
-- talk(state, extra) sends a status and returns the base's reply. Replies may
-- carry a code update (the turtle writes the files and reboots) or a new role.
-- Only replies from the pinned base computer (agent.cfg `base`) are accepted.

local C = require("oreconf")

local L = {}

-- Seconds to wait for the base's reply. Every chest the base touches costs it
-- a game tick, so a build step can take a few seconds to answer.
L.REPLY_TIMEOUT = 10

local CFG_FILE, VERSION_FILE = "agent.cfg", "version"

-- The toolbelt. A turtle has one upgrade slot besides its pickaxe; it keeps
-- its tools in its inventory (never unloaded) and swaps the one it needs in:
-- HOME tools live in that slot (the compass, the Geo Scanner), VISITING ones
-- are swapped in for a moment (the wireless modem to talk, the Environment
-- Detector to look for items) and the home tool goes back.
local HOME_ITEMS = { [C.SCANNER_ITEM] = true, ["minecraft:compass"] = true }
local VISITING_ITEMS = { [C.DETECTOR_ITEM] = true, [C.AUTOMATA_ITEM] = true }
for name in pairs(C.MODEM_ITEMS) do VISITING_ITEMS[name] = true end
-- (kept, never unloaded: every tool but the modems, kept as MODEM_ITEMS)
local SWAPPABLE = { [C.SCANNER_ITEM] = true, ["minecraft:compass"] = true, [C.DETECTOR_ITEM] = true }
-- Geo Scanner type is "geo_scanner" in AP 0.8 (1.21) and "geoScanner" before.
local SCANNER_TYPES = { "geo_scanner", "geoScanner" }
-- what may be in the swap slot (everything but the pickaxe side)
local SWAPPABLE_TYPE = { geo_scanner = true, geoScanner = true, compass = true,
                         environment_detector = true, modem = true, weak_automata = true }
-- a tool's item, by the peripheral type it gives
local TOOL_ITEM = { geo_scanner = { [C.SCANNER_ITEM] = true }, compass = { ["minecraft:compass"] = true },
                    environment_detector = { [C.DETECTOR_ITEM] = true }, modem = C.MODEM_ITEMS,
                    weak_automata = { [C.AUTOMATA_ITEM] = true },
                    block_reader = { [C.READER_ITEM] = true } }

local EQUIP = { left = turtle.equipLeft, right = turtle.equipRight }

local function readTable(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = textutils.unserialize(f.readAll())
  f.close()
  return t
end

local function writeTable(path, t)
  local f = fs.open(path, "w")
  f.write(textutils.serialize(t))
  f.close()
end

function L.config() return readTable(CFG_FILE) or {} end
function L.saveConfig(cfg) writeTable(CFG_FILE, cfg) end

function L.version()
  if not fs.exists(VERSION_FILE) then return nil end
  local f = fs.open(VERSION_FILE, "r")
  local v = f.readAll()
  f.close()
  return v
end

-- ------------------------------------------------------------- equipment --
function L.equippedSide(ptype)
  for _, side in ipairs({ "left", "right" }) do
    if peripheral.getType(side) == ptype then return side end
  end
end

local function swappableSide()
  for _, side in ipairs({ "left", "right" }) do
    if SWAPPABLE_TYPE[peripheral.getType(side) or ""] then return side end
  end
end

-- The equipped Geo Scanner peripheral (any AP version), or nil.
function L.scanner()
  for _, t in ipairs(SCANNER_TYPES) do
    local p = peripheral.find(t)
    if p then return p end
  end
end

function L.findItem(pred)
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and pred(d.name) then return i end
  end
end

-- Items a turtle must never unload: its modem and the upgrade it swaps.
local adjacentModem -- (below)

-- Kept (never unloaded): its tools, and the accessories the base says it is
-- to carry (agent.cfg `accessories`, from the last supply answer). One it is
-- no longer meant to carry goes into the chest with the rest. Never told
-- (an older turtle): everything as before.
-- The tools a job brought (an inspect job's block reader): kept while the
-- job runs, whatever drops items (unload, the chest marker, a supply);
-- L.holdTools(nil) gives them up (its last unload).
local HELD = {}
function L.holdTools(list)
  HELD = {}
  for _, t in ipairs(list or {}) do HELD[t] = true end
end

function L.isKeptItem(name)
  if HELD[name] then return true end
  if C.ACCESSORY_ITEMS[name] then
    -- (a modem it talks through: no wired modem at its home: always kept,
    -- or it couldn't even ask for it back)
    if C.MODEM_ITEMS[name] and not adjacentModem() then return true end
    local wanted = L.config().accessories
    if wanted then
      for _, item in ipairs(wanted) do if item == name then return true end end
      return false
    end
  end
  return C.MODEM_ITEMS[name] or SWAPPABLE[name] or false
end

-- A modem block next to the turtle (wired or wireless). Left and right are a
-- turtle's upgrade slots, so only these sides can be blocks.
adjacentModem = function()
  for _, side in ipairs({ "front", "back", "top", "bottom" }) do
    if peripheral.getType(side) == "modem" then return side end
  end
end

function L.hasModem()
  return L.equippedSide("modem") ~= nil or adjacentModem() ~= nil
      or L.findItem(function(n) return C.MODEM_ITEMS[n] end) ~= nil
end

-- Put the home tool back if a visiting one is in its place (e.g. after a
-- restart in the middle of a talk or a look around). Returns true when
-- nothing is left to fix.
function L.restoreUpgrade()
  local side
  for _, s in ipairs({ "left", "right" }) do
    local t = peripheral.getType(s)
    if t == "modem" or t == "environment_detector" or t == "weak_automata" or t == "block_reader" then side = s end
  end
  local slot = L.findItem(function(n) return HOME_ITEMS[n] end)
  if side and slot then
    turtle.select(slot); EQUIP[side](); turtle.select(1)
  end
  return not (side and slot)
end

-- Run fn(peripheral, side) with the tool of peripheral type `ptype` equipped:
-- the one already on, or swapped in from the inventory for the call (the
-- tool that was there goes back after, also when fn fails). nil if the
-- turtle has no such tool.
function L.withTool(ptype, fn)
  local side = L.equippedSide(ptype)
  if side then return fn(peripheral.wrap(side), side) end
  local items = TOOL_ITEM[ptype] or {}
  local slot = L.findItem(function(n) return items[n] end)
  side = swappableSide()
  if not slot or not side then return nil end
  turtle.select(slot); EQUIP[side](); turtle.select(1) -- (what was there is in `slot` now)
  local ok, result = pcall(fn, peripheral.wrap(side), side)
  turtle.select(slot); EQUIP[side](); turtle.select(1)
  if not ok then error(result, 0) end
  return result
end

-- Run fn() with a wireless modem equipped and rednet open; nil if no modem.
-- (A modem block next to the turtle does as well: its home's.)
function L.withModem(fn)
  local function talking(side)
    rednet.open(side)
    local ok, result = pcall(fn)
    rednet.close(side)
    if not ok then error(result, 0) end
    return result
  end
  local adjacent = adjacentModem()
  if adjacent and not L.equippedSide("modem") then return talking(adjacent) end
  return L.withTool("modem", function(_, side) return talking(side) end)
end

-- --------------------------------------------------------------- updates --
-- Apply a code update from the base: write every file, then the version, then
-- reboot into the new code. A crash half-way leaves the old version number, so
-- the base simply sends the update again.
-- Only plain program names are accepted: no paths. (Rednet sender ids can be
-- spoofed, and a home turtle can see the installer disk at /disk.)
local function safeName(name)
  return type(name) == "string" and name:match("^[%w_%-]+%.lua$") ~= nil
end

function L.applyUpdate(update)
  for name in pairs(update.files) do
    if not safeName(name) then
      print("Rejected update: bad file name " .. tostring(name))
      return
    end
  end
  for name, content in pairs(update.files) do
    local tmp = name .. ".new"
    local f = fs.open(tmp, "w")
    f.write(content)
    f.close()
    if fs.exists(name) then fs.delete(name) end
    fs.move(tmp, name)
  end
  local f = fs.open(VERSION_FILE, "w")
  f.write(update.version)
  f.close()
  print("Updated to version " .. update.version .. "; rebooting")
  os.reboot()
end

-- ------------------------------------------------------------------ talk --
local function equipment()
  local t = {}
  for _, side in ipairs({ "left", "right" }) do t[side] = peripheral.getType(side) end
  return t
end

-- Send a status to the base and return its reply (nil without modem or base).
-- `updates` false defers code updates (e.g. while a job is half done).
function L.talk(state, extra, updates)
  local cfg = L.config()
  local reply = L.withModem(function()
    local msg = { type = "status", state = state, label = os.getComputerLabel(),
                  role = cfg.role, buildOrder = cfg.order, version = L.version(),
                  chest = cfg.chest, -- its home chest (mailbox), once known
                  fuel = turtle.getFuelLevel(),
                  equipment = equipment() }
    for k, v in pairs(extra or {}) do msg[k] = v end
    if cfg.base then rednet.send(cfg.base, msg, C.PROTOCOL) else rednet.broadcast(msg, C.PROTOCOL) end
    local deadline = os.clock() + L.REPLY_TIMEOUT
    while true do
      local left = deadline - os.clock()
      if left <= 0 then return nil end
      local from, r = rednet.receive(C.PROTOCOL, left)
      if not from then return nil end
      if cfg.base == nil or from == cfg.base then
        if cfg.base == nil and type(r) == "table" then
          cfg.base = from -- pin the first base that answers
          L.saveConfig(cfg)
        end
        return r
      end
    end
  end)
  if type(reply) ~= "table" then return nil end
  if reply.update and updates ~= false then L.applyUpdate(reply.update) end
  if reply.type == "dismantle" then L.dismantle(reply.assembler) end
  if reply.role and reply.role ~= cfg.role then
    cfg.role = reply.role
    L.saveConfig(cfg)
    print("Role changed to " .. reply.role .. "; rebooting")
    os.reboot()
  end
  return reply
end

-- ------------------------------------------------------------ mailbox --
-- The home chest is a mailbox: at home the turtle asks the base for what it
-- wants to carry (L.supply), the base sends it into the chest, the turtle
-- takes it; the base empties everything else. One turtle, one home, one
-- chest. These functions expect the turtle to FACE its home chest.

-- Take what is in the chest, until it is empty or nothing more fits (CC's
-- suck takes the chest's first stack and stacks it into the turtle; false
-- when none of it fits). The caller drops back what it doesn't keep.
function L.takeSupplies()
  for _ = 1, 64 do
    if not turtle.suck() then break end
  end
end

local function carried()
  local have = {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then have[d.name] = (have[d.name] or 0) + d.count end
  end
  return have
end

-- Ask the base for supplies: `want` = { fuel = items, saplings = per kind,
-- bonemeal = n, dirt = n } (what it wants to carry), then take what is in the
-- chest (the caller drops back what it doesn't keep). The base emptied the
-- chest before it sent, so all of it is ours: without its answer nothing is
-- taken (it would be our own haul). Returns the reply ({ sent, short,
-- plant }) or nil.
function L.supply(want)
  local r = L.talk("supply", { supply = want, have = carried() }, false)
  if r and r.type == "nochest" and L.claimChest() then
    r = L.talk("supply", { supply = want, have = carried() }, false)
  end
  if r and r.type == "supplied" then
    -- which accessories it is to carry (the base sends the missing ones)
    if r.accessories then
      local cfg = L.config()
      cfg.accessories = r.accessories
      L.saveConfig(cfg)
    end
    L.takeSupplies()
    local miss = {}
    for k, n in pairs(r.short or {}) do miss[#miss + 1] = ("%d %s"):format(n, k) end
    table.sort(miss)
    if #miss > 0 then print("The base could not send: " .. table.concat(miss, ", ")) end
    return r
  end
end

-- Once: tell the base which of its network chests is this home's, so it knows
-- where to put the supplies. It watches its chests while one item is dropped
-- in, and sees where it landed (the base empties that item again).
function L.claimChest()
  local cfg = L.config()
  if cfg.chest then return true end
  local slot
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and not L.isKeptItem(d.name) then slot = i end
  end
  if not slot then return false end -- nothing to drop yet: next time
  local r1 = L.talk("mark1", {}, false)
  if not (r1 and r1.type == "ok") then return false end
  local marker = turtle.getItemDetail(slot).name
  turtle.select(slot)
  turtle.drop(1)
  turtle.select(1)
  local r2 = L.talk("mark2", { marker = marker }, false)
  if r2 and r2.type == "marked" and r2.chest then
    cfg = L.config()
    cfg.chest = r2.chest
    L.saveConfig(cfg)
    return true
  end
  return false
end

-- ---------------------------------------------------------- dismantle --
-- The base asked to take this turtle apart (TURTLES tab: DISMANTLE). Built by
-- the factory (it knows its way, cfg.slot): it flies to the build spot, hands
-- everything to the assembler in front of it there, takes its upgrades off
-- and hands those over too, clears its label and switches off; the assembler
-- picks it up and the base stores the plain turtle. Otherwise it empties
-- itself into the chest next to it and switches off, to be picked up.
function L.dismantle(assembler)
  local cfg = L.config()
  local toSpot = type(cfg.slot) == "table" and assembler ~= nil
  L.talk("dismantling", { toBuildSpot = toSpot }, false)
  if toSpot then require("travel").toBuildSpot() end
  -- face the assembler (by its computer ID: other turtles may stand next to
  -- the build spot too), or else a chest
  local function isTarget()
    local ok, b = turtle.inspect()
    if not ok then return false end
    if toSpot then
      if not b.name:find("^computercraft:turtle") then return false end
      local okId, id = pcall(peripheral.call, "front", "getID")
      return okId and id == assembler
    end
    return b.name:find("chest") ~= nil
  end
  local facing = false
  for _ = 1, 4 do
    if isTarget() then facing = true; break end
    turtle.turnRight()
  end
  local function handOver()
    if not facing then return end
    for i = 1, 16 do
      if turtle.getItemCount(i) > 0 then turtle.select(i); turtle.drop() end
    end
  end
  handOver()
  -- the upgrades off, each into an EMPTY slot (equipping from a full one
  -- would swap that item in), then over as well
  for _, equip in ipairs({ turtle.equipLeft, turtle.equipRight }) do
    for i = 1, 16 do
      if turtle.getItemCount(i) == 0 then turtle.select(i); equip(); break end
    end
  end
  handOver()
  turtle.select(1)
  cfg.role, cfg.slot, cfg.home, cfg.chest = nil, nil, nil, nil
  L.saveConfig(cfg)
  os.setComputerLabel(nil)
  print(toSpot and "Dismantled: the assembler picks me up." or "Dismantled: pick me up.")
  os.shutdown()
end

-- Burn fuel items (oreconf.FUEL) from the inventory up to `target`.
function L.burnFuel(target)
  if turtle.getFuelLevel() == "unlimited" then return end
  for i = 1, 16 do
    if turtle.getFuelLevel() >= target then break end
    local d = turtle.getItemDetail(i)
    if d and C.isFuel(d.name) then
      turtle.select(i)
      while turtle.getFuelLevel() < target and turtle.getItemCount(i) > 0 and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
end

-- Ask the base for `need` fuel. It pushes coal straight into this turtle when
-- the turtle is on the wired network (a modem touching it, enabled); then it
-- is burnt. Returns the fuel gained, or nil and why not.
function L.requestFuel(need)
  local before = turtle.getFuelLevel()
  if before == "unlimited" then return 0 end
  local reply = L.talk("fuel", { wantFuel = need }, false)
  if not reply then return nil, "no answer from the base (no modem here?)" end
  if reply.type ~= "fuel" then return nil, reply.reason or "the base has no fuel for me" end
  L.burnFuel(before + need)
  return turtle.getFuelLevel() - before
end

return L
