-- base: the factory's control computer (screen + wiring).
--
-- Install with the starter script (see README): it downloads this and the
-- turtle code from GitHub. Peripherals:
--   wireless modem            talks to turtles
--   advanced monitor          touch screen (else the terminal; mouse works)
--   wired modem network       barrels (storage) or an ME/RS bridge, chests
--                             (turtle home chests, drained into storage),
--                             furnaces, the assembler (its modem enabled: the
--                             base fills and empties it) and the installer
--                             disk drive under the build spot
-- Settings live in /factory.cfg (written with defaults on first start; edit it
-- with `edit factory.cfg`, then restart the base).
--
-- Decisions are in factory.lua; this file draws the screen and wires the real
-- peripherals, clock, storage and code release into it.

local C = require("oreconf")
local factory = require("factory")

local M = {}

-- ------------------------------------------------------------------ draw --
local function put(out, x, y, text, fg, bg)
  out.setCursorPos(x, y)
  out.setTextColor(fg or colors.white)
  out.setBackgroundColor(bg or colors.black)
  out.write(text)
end

local function button(UI, out, x, y, w, label, on, action)
  local text = (" " .. label .. string.rep(" ", w)):sub(1, w)
  put(out, x, y, text, on and colors.black or colors.white, on and colors.lime or colors.gray)
  UI.buttons[#UI.buttons + 1] = { x1 = x, x2 = x + w - 1, y = y, label = label, action = action }
end

local STATE_COLOR = { idle = colors.lightGray, done = colors.lightGray, resting = colors.lightGray,
                      assigned = colors.yellow, unloading = colors.cyan, new = colors.magenta }

-- GATHERING has a sub-tab per way of getting raw materials (farming next)
local TABS = { "TURTLES", "GATHERING", "FACTORY" }
local GATHERING = { "MINING", "FORESTRY" }

local function drawTurtles(UI, out, w, row)
  local F = UI.F
  local ids = {}
  for id in pairs(F.turtles) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local t = F.turtles[id]
    local what = t.role == "miner" and factory.jobText(t.job)
              or t.role == "forester" and ("%d logs"):format(t.delivered or 0)
              or t.role
    local text = ("%-11s %-9s %-9s %-18s %4d f%-6s %ds"):format(
      (t.label or ("#" .. id)):sub(1, 11), t.role or "?", t.state or "?", tostring(what):sub(1, 18),
      t.mined or 0, tostring(t.fuel), math.floor(F.deps.now() - (t.seen or 0)))
    local sel = F.selected == id
    put(out, 1, row, (text .. string.rep(" ", w)):sub(1, w),
      sel and colors.black or (STATE_COLOR[t.state] or colors.white), sel and colors.white or colors.black)
    UI.buttons[#UI.buttons + 1] = { x1 = 1, x2 = w, y = row, label = "turtle " .. id,
                                    action = function() factory.selectTurtle(F, id) end }
    row = row + 1
  end
  if #ids == 0 then put(out, 1, row, "No turtles yet", colors.red); row = row + 1 end
  row = row + 1
  put(out, 1, row, "FETCHING", colors.yellow)
  row = row + 1
  local s, keys = factory.summary(F), {}
  for k in pairs(s) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local r = s[k]
    put(out, 1, row, ("%-10s %6d mined  %d turtle%s%s"):format(k, r.mined, r.turtles,
      r.turtles == 1 and "" or "s", r.queued > 0 and (", " .. r.queued .. " queued") or ""), colors.lightGray)
    row = row + 1
  end
  row = row + 1
  button(UI, out, 1, row, 16, F.selected and "STOP turtle" or "CANCEL last job", false,
    function() factory.stop(F) end)
  if F.selected then
    button(UI, out, 18, row, 12, "DISMANTLE", F.dismantle ~= nil, function() factory.dismantle(F) end)
    button(UI, out, 31, row, 9, "FORGET", false, function() factory.forget(F) end)
  end
  return row + 2
end

local function drawJobs(UI, out, w, row)
  local F = UI.F
  local cols = math.max(1, math.floor(w / 10))
  local bw = math.floor(w / cols)
  for i, p in ipairs(C.PRESETS) do
    button(UI, out, ((i - 1) % cols) * bw + 1, row + math.floor((i - 1) / cols), bw - 1,
      p.name, F.sel.ore == p.name, function() factory.selectOre(F, p.name) end)
  end
  row = row + math.floor((#C.PRESETS - 1) / cols) + 2
  put(out, 1, row, ("Y %4d "):format(F.sel.y))
  for i, d in ipairs({ -8, -1, 1, 8 }) do
    button(UI, out, 3 + i * 5, row, 4, (d > 0 and "+" or "") .. d, false, function() factory.addY(F, d) end)
  end
  row = row + 1
  local q = factory.QTY[F.sel.qty]
  put(out, 1, row, ("Qty %4s "):format(q > 0 and tostring(q) or "all"))
  button(UI, out, 10, row, 3, "<", false, function() factory.qtyStep(F, -1) end)
  button(UI, out, 14, row, 3, ">", false, function() factory.qtyStep(F, 1) end)
  button(UI, out, 18, row, 14, "only " .. F.sel.ore, F.sel.onlyThis, function() factory.toggleOnly(F) end)
  button(UI, out, 33, row, 10, "all ores", not F.sel.onlyThis, function() factory.toggleOnly(F) end)
  row = row + 2
  local startLabel = ("START (%d queued)"):format(#F.queue)
  button(UI, out, 1, row, #startLabel + 2, startLabel, false, function() factory.start(F) end)
  return row + 2
end

local function shortName(item) return (item:gsub("^[%w_]+:", ""):gsub("_sapling$", ""):gsub("_propagule$", "")) end

local function drawForestry(UI, out, w, row)
  local F = UI.F
  put(out, 1, row, "FORESTERS", colors.yellow)
  row = row + 1
  local n = 0
  local ids = {}
  for id, t in pairs(F.turtles) do if t.role == "forester" then ids[#ids + 1] = id end end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local t = F.turtles[id]
    n = n + 1
    local chest = t.chest and "" or "  (home chest not known yet: it tells the base when it unloads)"
    put(out, 1, row, ("%-10s %-8s logs %d%s"):format(t.label or ("#" .. id), t.state or "?", t.delivered or 0, chest):sub(1, w),
      t.chest and colors.lightGray or colors.orange)
    row = row + 1
  end
  if n == 0 then put(out, 1, row, "none yet", colors.lightGray); row = row + 1 end
  row = row + 1
  -- what they plant: tap kinds to select; selected kinds take turns
  local sel = {}
  for _, k in ipairs(F.saplings or {}) do sel[k] = true end
  local kinds, stock = {}, UI.stock or {}
  local seen = {}
  for item in pairs(stock) do
    if factory.isSaplingItem(item) and not C.tree(item).twoByTwo and not seen[item] then
      seen[item] = true; kinds[#kinds + 1] = item
    end
  end
  for item in pairs(sel) do if not seen[item] then seen[item] = true; kinds[#kinds + 1] = item end end
  table.sort(kinds)
  local auto = not next(sel)
  put(out, 1, row, ("SAPLINGS (tap to select; %s)"):format(auto and "none = auto" or "they take turns"):sub(1, w),
    colors.yellow)
  row = row + 1
  if auto then
    put(out, 1, row, "auto: the kind storage has most of", colors.gray)
    row = row + 1
  end
  if #kinds == 0 then put(out, 1, row, "no saplings in storage", colors.lightGray); row = row + 1 end
  local x = 1
  for _, item in ipairs(kinds) do
    local label = ("%s %d /%d"):format(shortName(item), stock[item] or 0, C.tree(item).spacing)
    local bw = #label + 2
    if x + bw - 1 > w then x = 1; row = row + 1 end
    button(UI, out, x, row, bw, label, sel[item] == true, function() factory.toggleSapling(F, item) end)
    x = x + bw + 1
  end
  row = row + 1
  put(out, 1, row, "(kind count /spacing; mixed kinds use the widest spacing)", colors.gray)
  row = row + 2
  button(UI, out, 1, row, 16, "BONE MEAL " .. (F.boneMeal and "ON" or "OFF"), F.boneMeal == true,
    function() factory.toggleBoneMeal(F) end)
  row = row + 2
  local mb = F.cfg.mailbox or {}
  put(out, 1, row, ("Home chest keeps: %d per kind, %d bone meal, %d fuel")
    :format(mb.saplings or 0, F.boneMeal and (mb.bonemeal or 0) or 0, mb.fuel or 0):sub(1, w), colors.gray)
  return row + 2
end

local function drawGathering(UI, out, w, row)
  UI.sub = UI.sub or GATHERING[1]
  local x = 1
  for _, sub in ipairs(GATHERING) do
    button(UI, out, x, row, #sub + 2, sub, UI.sub == sub, function() UI.sub = sub end)
    x = x + #sub + 3
  end
  row = row + 2
  if UI.sub == "FORESTRY" then return drawForestry(UI, out, w, row) end
  return drawJobs(UI, out, w, row)
end

local function drawFactory(UI, out, w, row)
  local F = UI.F
  local stock = UI.stock or {}
  put(out, 1, row, ("Storage: %s   code %s"):format(F.deps.storage.kind,
    F.deps.dist and F.deps.dist.version or "none"), colors.lightGray)
  row = row + 1
  button(UI, out, w - 9, row - 1, 10, "UPDATE", false, function() UI.wantUpdate = true end)
  -- what the base sees on its wired network
  local d = UI.devices
  if d then
    row = row + 1
    put(out, 1, row, "NETWORK", colors.yellow)
    row = row + 1
    local turtles = 0
    for _, n in ipairs(d.other) do if n:find("^turtle_") then turtles = turtles + 1 end end
    local summary = ("barrels %d  home chests %d  furnaces %d  disk drive %d  turtles %d")
      :format(#d.storage, #d.input, #d.furnace, #d.drive, turtles)
    put(out, 1, row, summary:sub(1, w), colors.lightGray)
    row = row + 1
    if #d.storage == 0 and #d.bridge == 0 then
      put(out, 1, row, ("No storage! Add barrels with a wired modem (chests are turtle homes)."):sub(1, w), colors.red)
      row = row + 1
    end
    local unused = {}
    for _, n in ipairs(d.other) do if not n:find("^turtle_") then unused[#unused + 1] = n end end
    if #unused > 0 then
      put(out, 1, row, ("not used: " .. table.concat(unused, ", ")):sub(1, w), colors.gray)
      row = row + 1
    end
  end
  row = row + 1
  put(out, 1, row, "PRODUCTION", colors.yellow)
  button(UI, out, w - 15, row, 16, "HAMMER " .. (F.hammer and "ON" or "OFF"), F.hammer,
    function() factory.toggleHammer(F) end)
  row = row + 1
  button(UI, out, w - 15, row, 16, "TINY FUEL " .. (F.tinyFuel and "ON" or "OFF"), F.tinyFuel,
    function() factory.toggleTinyFuel(F) end)
  put(out, 1, row, ("furnaces busy %d   crafting %s"):format(F.prod.furnaces or 0,
    F.craft and (F.craft.item:gsub("^%w+:", "") .. " x" .. F.craft.sets) or "-"):sub(1, w), colors.lightGray)
  row = row + 1
  local need = ""
  for item, n in pairs(F.prod.missing or {}) do need = need .. (" %dx%s"):format(n, item:gsub("^%w+:", "")) end
  if need ~= "" then put(out, 1, row, ("raw needed:" .. need):sub(1, w), colors.orange); row = row + 1 end
  row = row + 1
  put(out, 1, row, "STOCK RULES", colors.yellow)
  row = row + 1
  if #F.cfg.rules == 0 then put(out, 1, row, "none (factory.cfg: rules)", colors.lightGray); row = row + 1 end
  for i, r in ipairs(F.cfg.rules) do
    local have = stock[r.item] or 0
    put(out, 1, row, ("%-26s %6d / %-6d %s"):format(r.item:gsub("^minecraft:", ""):sub(1, 26), have, r.min,
      F.ruleJobs[i] and "mining" or ""), have < r.min and colors.orange or colors.lime)
    row = row + 1
  end
  row = row + 1
  put(out, 1, row, "FLEET", colors.yellow)
  row = row + 1
  -- roles the factory builds (target from factory.cfg), in a fixed order
  local built = { "miner", "forester", "surveyor" }
  if F.cfg.fleet.gps then built[#built + 1] = "gps" end
  for role in pairs(F.cfg.fleet) do
    local known = false
    for _, r in ipairs(built) do if r == role then known = true end end
    if not known then built[#built + 1] = role end
  end
  for _, role in ipairs(built) do
    local want = F.cfg.fleet[role] or 0
    local have = factory.fleetCount(F, role)
    local missing = (UI.missing or {})[role] or {}
    local need = ""
    local items = {}
    for item in pairs(missing) do items[#items + 1] = item end
    table.sort(items)
    for _, item in ipairs(items) do need = need .. (" %dx%s"):format(missing[item], item:gsub("^%w+:", "")) end
    put(out, 1, row, ("%-9s %d / %d  %s"):format(role, have, want,
      have < want and (need ~= "" and ("needs" .. need) or "parts ready") or ""):sub(1, w - 11), colors.lightGray)
    button(UI, out, w - 9, row, 10, "BUILD", false, function() factory.orderTurtle(F, role, true) end)
    row = row + 1
  end
  -- helpers the factory doesn't build: shown so you know they're there
  local asm = factory.fleetCount(F, "assembler")
  put(out, 1, row, ("%-9s %d      %s"):format("assembler", asm,
    asm == 0 and "none: nothing gets built (make the first by hand)" or ""):sub(1, w), asm == 0 and colors.red or colors.lightGray)
  row = row + 1

  row = row + 1
  put(out, 1, row, "HOMES (tap to change role)", colors.yellow)
  if not F.gpsWanted then
    button(UI, out, w - 11, row, 12, "BUILD GPS", false, function() factory.wantGps(F) end)
  end
  row = row + 1
  if #F.homes == 0 then
    put(out, 1, row, "none: run a surveyor / `home <role>` / $home", colors.lightGray); row = row + 1
  end
  for _, h in ipairs(F.homes) do
    local text = ("#%-2d %4d,%3d,%4d %-5s %-8s %-6s %s"):format(h.id, h.x, h.y, h.z, h.facing:sub(1, 5),
      h.role, h.source, h.owner and ("-> " .. tostring(h.owner)) or "")
    put(out, 1, row, (text .. string.rep(" ", w)):sub(1, w), h.role == "off" and colors.gray or colors.white)
    UI.buttons[#UI.buttons + 1] = { x1 = 1, x2 = w, y = row, label = "home " .. h.id,
                                    action = function() factory.cycleHome(F, h.id) end }
    row = row + 1
  end
  row = row + 1
  put(out, 1, row, "BUILDS", colors.yellow)
  row = row + 1
  for i = math.max(1, #F.orders - 3), #F.orders do
    local o = F.orders[i]
    local tap = (o.state == "queued" or o.state == "failed") and "  (tap: remove)" or ""
    put(out, 1, row, ("#%d %s: %s%s%s"):format(o.id, o.role, o.state,
      o.reason and (" - " .. o.reason) or "", tap):sub(1, w), o.state == "failed" and colors.red or colors.lightGray)
    if tap ~= "" then
      UI.buttons[#UI.buttons + 1] = { x1 = 1, x2 = w, y = row, label = "order " .. o.id,
                                      action = function() factory.cancelOrder(F, o.id) end }
    end
    row = row + 1
  end
  return row + 1
end

function M.draw(UI, out)
  UI.buttons = {}
  out.setBackgroundColor(colors.black)
  out.clear()
  local w, h = out.getSize()
  local x = 1
  for _, tab in ipairs(TABS) do
    button(UI, out, x, 1, #tab + 2, tab, UI.tab == tab, function() UI.tab = tab end)
    x = x + #tab + 3
  end
  local row = 3
  if UI.tab == "TURTLES" then row = drawTurtles(UI, out, w, row)
  elseif UI.tab == "GATHERING" then row = drawGathering(UI, out, w, row)
  else row = drawFactory(UI, out, w, row) end
  put(out, 1, h, UI.F.note:sub(1, w), colors.orange)
end

function M.touch(UI, x, y)
  for _, b in ipairs(UI.buttons) do
    if y == b.y and x >= b.x1 and x <= b.x2 then b.action(); return b.label end
  end
end

-- ------------------------------------------------------------------ main --
local args = { ... }
if args[1] == "--lib" then return M end

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

local storage = require("storage")
local dist = require("dist")

if args[1] == "update" then
  -- `base update`: newest code from GitHub, then restart (turtles follow)
  shell.run("/bootstrap.lua")
  os.reboot()
end

if args[1] == "probe" then
  -- check a storage bridge's export/import argument order on the real thing
  local S = storage.open(peripheral)
  local chest = S.inputs()[1]
  print("storage: " .. S.kind .. ", test chest: " .. tostring(chest))
  local stock = S.list()
  local item = next(stock)
  if not item or not chest then print("need one item in storage and a home chest (plain chest)"); return end
  print("export 1 " .. item .. " -> chest: " .. tostring(S.send(chest, item, 1)))
  print("import chest -> storage: " .. tostring(S.store(chest)))
  return
end

local config = readTable("/factory.cfg")
if not config then
  config = factory.DEFAULT_CONFIG
  writeTable("/factory.cfg", config)
  print("Wrote /factory.cfg with defaults; edit it to set homes, fleet and rules.")
end
factory.withDefaults(config)

local manifest = fs.exists("/manifest.lua") and dofile("/manifest.lua")
local release = manifest and dist.load(manifest, "/dist")

-- talk to turtles over every modem: wireless, and wired (turtles at home
-- slots with a wired modem next to them, cabled to this network)
local modems = 0
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" then rednet.open(name); modems = modems + 1 end
end
if modems == 0 then error("Attach a modem (wired and/or wireless)", 0) end

local F = factory.new(config, {
  storage = storage.open(peripheral),
  now = function() return os.epoch("utc") / 1000 end,
  dist = release,
  writeInstall = function(install)
    if not release then return end
    install.base = os.getComputerID()
    dist.writeDisk(peripheral, release, install)
  end,
})
factory.restore(F, readTable("/base.state"))
if release then
  -- the installer disk gets the active build's data again (a base restart
  -- mid-build must not turn a forester into a miner)
  local install = factory.installData(F)
  install.base = os.getComputerID()
  dist.writeDisk(peripheral, release, install)
end

local UI = { F = F, tab = "TURTLES", buttons = {} }
local mon = peripheral.find("monitor")
local out = mon or term
if mon then mon.setTextScale(0.5) end

local function persist()
  local ok, err = pcall(writeTable, "/base.state", factory.snapshot(F))
  if not ok then F.note = "could not save state: " .. tostring(err) end
end

local function update()
  F.note = "Updating from GitHub..."
  M.draw(UI, out)
  persist()
  local ok, err = pcall(shell.run, "/bootstrap.lua")
  if ok then os.reboot() end
  F.note = "Update failed: " .. tostring(err)
end

-- Auto-update: check GitHub for a newer commit now and then (one small
-- request) and update when there is one. `autoUpdate = false` in factory.cfg
-- turns it off; `base update` or the UPDATE button update by hand.
local UPDATE_EVERY = 1800

local function latestCommit()
  if not http then return nil end
  local ok, res = pcall(http.get, "https://api.github.com/repos/ErikTMA/cc-factory/commits/main",
                        { ["User-Agent"] = "cc-factory" })
  if not ok or not res then return nil end
  local body = res.readAll()
  res.close()
  return body:match('"sha"%s*:%s*"(%x+)"')
end

local function installedRelease()
  if not fs.exists("/release") then return nil end
  local f = fs.open("/release", "r")
  local r = f.readAll()
  f.close()
  return r
end

-- the release this base STARTED with: what runs in memory. The /release file
-- can be newer (files copied in while it runs); then a restart is enough.
local RUNNING = installedRelease()

local function updater()
  sleep(60)
  while true do
    if F.cfg.autoUpdate ~= false then
      local sha = latestCommit()
      -- only a real commit id counts (the API can be rate limited)
      if sha and sha ~= RUNNING then
        if sha == installedRelease() then
          persist()
          os.reboot() -- the new code is already on disk: just start it
        else
          update()
        end
      end
    end
    sleep(UPDATE_EVERY)
  end
end

-- Four coroutines. Every chest access costs the base a game tick and makes it
-- wait for its result, throwing away other events meanwhile, so:
--   receiver  only receives rednet messages into a queue (never misses one)
--   worker    answers them in order (may touch storage)
--   ticker    drains inputs, rules, fleet every 10 s (its own sleep timer)
--   screen    touches and redraws
local inbox = {}
local function receiver()
  while true do
    local from, msg = rednet.receive(C.PROTOCOL)
    inbox[#inbox + 1] = { from, msg }
    os.queueEvent("factory_inbox")
  end
end

local function worker()
  while true do
    if #inbox == 0 then os.pullEvent("factory_inbox") end
    local item = table.remove(inbox, 1)
    if item then
      local ok, reply = pcall(factory.handle, F, item[1], item[2])
      if ok and reply then rednet.send(item[1], reply, C.PROTOCOL)
      elseif not ok then F.note = "handle: " .. tostring(reply) end
      persist()
      os.queueEvent("factory_redraw")
    end
  end
end

local function ticker()
  while true do
    local okd, devices = pcall(storage.devices, peripheral)
    if okd then UI.devices = devices end
    local ok, stock = pcall(factory.tick, F)
    if ok then
      UI.stock = stock
      local missing = {}
      for role in pairs(F.cfg.fleet) do missing[role] = factory.missingParts(F, role) end
      UI.missing = missing
    else
      F.note = "tick: " .. tostring(stock)
    end
    persist()
    os.queueEvent("factory_redraw")
    sleep(10)
  end
end

-- Chat fallback for homes: a Chat Box and a Player Detector next to the base
-- (Advanced Peripherals). "$help" in chat lists the commands.
-- Chat Box and Player Detector: looked up again whenever a peripheral is
-- connected (no restart needed after placing them)
-- /chat.log: the last 30 chat events and replies, raw (to see what a Chat
-- Box really sends on a given server)
local chatLog = {}
local function logChat(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  chatLog[#chatLog + 1] = table.concat(parts, " | ")
  while #chatLog > 30 do table.remove(chatLog, 1) end
  pcall(function()
    local f = fs.open("/chat.log", "w")
    f.write(table.concat(chatLog, "\n") .. "\n")
    f.close()
  end)
end

local chatBox, detector
local function findChatPeripherals()
  chatBox = peripheral.find("chat_box") or peripheral.find("chatBox")
  detector = peripheral.find("player_detector") or peripheral.find("playerDetector")
end
findChatPeripherals()
logChat("start", "chatBox=" .. tostring(chatBox ~= nil), "detector=" .. tostring(detector ~= nil))

-- verify-live: which method/fields the Player Detector has in this AP version
local function playerPos(user)
  if not detector then return nil end
  for _, method in ipairs({ "getPlayerPos", "getPlayer", "getPlayerInfo" }) do
    if detector[method] then
      local ok, p = pcall(detector[method], user)
      if ok and type(p) == "table" then
        local pos = p.position or p.pos or p
        local x, y, z = pos.x or p.x, pos.y or p.y, pos.z or p.z
        if x and y and z then return { x = x, y = y, z = z, yaw = p.yaw or pos.yaw or 0 } end
      end
    end
  end
end

-- AP 0.8.2a: sendMessage(text, { prefix, brackets, bracketsColor, range,
-- player }) (checked in the jar; seen live: a prefix string as 2nd argument
-- -> "map expected"); older APs: sendMessageToPlayer(text, user, prefix).
local function say(user, text)
  if not chatBox or not text then return end
  local ok, err = pcall(chatBox.sendMessage, text, { prefix = "cc-factory", player = user })
  logChat("reply to", user, "sendMessage{player}", ok, err)
  if ok then return end
  if chatBox.sendMessageToPlayer then
    ok, err = pcall(chatBox.sendMessageToPlayer, text, user, "cc-factory")
    logChat("reply to", user, "sendMessageToPlayer", ok, err)
  end
end

local function chatter()
  while true do
    local ev, a, b, c, d = os.pullEvent()
    if ev == "chat" then logChat("chat event", a, b, c, d, "chatBox=" .. tostring(chatBox ~= nil)) end
    -- AP 0.8.2a: "chat", uuid, username, message, hidden (checked in the
    -- jar); a "$" message is hidden from chat and arrives WITHOUT its "$"
    -- (seen live: "help", hidden = true). Older APs: "chat", username,
    -- message, uuid, hidden, with the "$" kept.
    local user, message = a, b
    if ev == "chat" then
      if d == true and type(c) == "string" then
        user, message = b, (c:sub(1, 1) == "$") and c or ("$" .. c)
      elseif type(c) == "string" and c:sub(1, 1) == "$" then
        user, message = b, c
      end
    end
    if ev == "peripheral" or ev == "peripheral_detach" then
      local had = chatBox ~= nil
      findChatPeripherals()
      logChat(ev, a, "chatBox=" .. tostring(chatBox ~= nil), "detector=" .. tostring(detector ~= nil))
      if chatBox and not had then F.note = "Chat Box connected: $help in chat" end
    elseif ev == "chat" and chatBox and type(message) == "string" and message:sub(1, 1) == "$" then
      local pos = (message:match("^%$build") or message:match("^%$home")) and playerPos(user) or nil
      say(user, factory.chatCommand(F, user, message, pos))
      persist()
      os.queueEvent("factory_redraw")
    end
  end
end

local function screen()
  M.draw(UI, out)
  local timer = os.startTimer(1)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "monitor_touch" or ev[1] == "mouse_click" then
      M.touch(UI, ev[3], ev[4])
      persist()
    elseif ev[1] == "timer" and ev[2] == timer then
      timer = os.startTimer(1)
    end
    if UI.wantUpdate then update() end
    M.draw(UI, out)
  end
end

parallel.waitForAny(receiver, worker, ticker, screen, chatter, updater)
