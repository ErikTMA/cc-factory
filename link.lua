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

-- Items that may sit in the upgrade slot that the modem borrows.
local SWAPPABLE = { [C.SCANNER_ITEM] = true, ["minecraft:compass"] = true }
-- Geo Scanner type is "geo_scanner" in AP 0.8 (1.21) and "geoScanner" before.
local SCANNER_TYPES = { "geo_scanner", "geoScanner" }
local SWAPPABLE_TYPE = { geo_scanner = true, geoScanner = true, compass = true }

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
function L.isKeptItem(name) return C.MODEM_ITEMS[name] or SWAPPABLE[name] or false end

-- A modem block next to the turtle (wired or wireless). Left and right are a
-- turtle's upgrade slots, so only these sides can be blocks.
local function adjacentModem()
  for _, side in ipairs({ "front", "back", "top", "bottom" }) do
    if peripheral.getType(side) == "modem" then return side end
  end
end

function L.hasModem()
  return L.equippedSide("modem") ~= nil or adjacentModem() ~= nil
      or L.findItem(function(n) return C.MODEM_ITEMS[n] end) ~= nil
end

-- Put the borrowed upgrade back if the modem is in its place (e.g. after a
-- restart in the middle of a talk). Returns true when nothing is left to fix.
function L.restoreUpgrade()
  local side = L.equippedSide("modem")
  local slot = L.findItem(function(n) return SWAPPABLE[n] end)
  if side and slot then
    turtle.select(slot); EQUIP[side](); turtle.select(1)
  end
  return not (side and slot)
end

-- Run fn() with a wireless modem equipped and rednet open; nil if no modem.
function L.withModem(fn)
  local side = L.equippedSide("modem") or adjacentModem()
  local swapped = false
  if not side then
    local slot = L.findItem(function(n) return C.MODEM_ITEMS[n] end)
    side = swappableSide()
    if not slot or not side then return nil end
    turtle.select(slot); EQUIP[side](); turtle.select(1)
    swapped = true
  end
  rednet.open(side)
  local ok, result = pcall(fn)
  rednet.close(side)
  if swapped then L.restoreUpgrade() end
  if not ok then error(result, 0) end
  return result
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
  if reply.role and reply.role ~= cfg.role then
    cfg.role = reply.role
    L.saveConfig(cfg)
    print("Role changed to " .. reply.role .. "; rebooting")
    os.reboot()
  end
  return reply
end

return L
