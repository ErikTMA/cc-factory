-- factory: the base's decisions, with no peripheral access of its own.
--
-- Everything the base decides lives here: mining jobs (queue, sectors, stop),
-- stock rules that queue jobs, fleet targets that order new turtles, the
-- assembler's build steps, home slots for new turtles and code updates.
-- Storage, the clock, the code release and the installer disk are injected
-- (base.lua wires the real ones; the test harness wires fakes).
--
--   local F = factory.new(config, { storage = S, now = fn, dist = D,
--                                   writeInstall = fn(installCfg) })
--   reply = factory.handle(F, fromId, statusMessage)
--   factory.tick(F)            -- drain inputs, apply stock rules and fleet targets

local C = require("oreconf")
local production = require("production")
local recipes = require("recipes")
local homes = require("homes")
local oremap = require("oremap")
local defrag = require("defrag")

local M = {}

M.QTY = { 8, 16, 32, 64, 128, 256, 0 } -- job sizes on the monitor; 0 = no limit

local PERSIST = { "turtles", "queue", "nextJobId", "nextSector", "totals", "counted", "toolWants",
                  "orders", "nextOrderId", "homes", "nextHomeId", "buildSpot", "gpsWanted", "anchor", "ruleJobs", "lastFail", "failStreak",
                  "hammer", "tinyFuel", "craft", "nextCraftId", "crafted",
                  "saplings", "boneMeal", "dismantle" }

local CRAFT_PAUSE = 60      -- seconds without craft jobs after one failed

local BUILD_TIMEOUT = 600   -- seconds of assembler silence before a build is given up
local TURTLE_GONE = 7200    -- seconds unseen before a turtle stops counting for the fleet
local MAX_FAILS = 3         -- failed builds in a row before automatic ordering pauses

-- Default config: base.lua writes it to /factory.cfg on first start; edit it there.
M.DEFAULT_CONFIG = {
  -- Y of the assembler's build spot; new turtles' home slots are at this level
  build = { y = 64 },
  -- optional home slots, offsets from the build spot (east / north / up,
  -- negative = west / south / down) and the way the turtle faces at home (its
  -- chest is behind it). Usually not needed: homes come from `home <role>` on
  -- a turtle (GPS), the surveyor or `$home` in chat, and the monitor sets
  -- their role.
  homes = {
    miner = {},
    forester = {},
  },
  -- how many turtles of each kind to keep; missing ones get built when the
  -- parts are in storage
  fleet = { miner = 0, forester = 0 },
  -- keep at least `min` of an item in storage: queue a mining job when below
  rules = {
    -- { item = "minecraft:raw_iron", min = 256, job = { only = "iron", y = 16, quantity = 64 } },
  },
  forester = { sapling = "minecraft:oak_sapling", trees = 6, wait = 300 },
  -- furnaces, crafting turtle parts, ore doubling (see production.lua)
  production = production.DEFAULTS,
  -- lanes per job; sectors reuse lanes from 0 after maxLanes (bounds how far
  -- out miners go: maxLanes x 16 blocks to the right of their home)
  job = { lanes = 3, length = 64, maxLanes = 24 },
  -- check GitHub every 30 minutes and update the base (and so all turtles)
  autoUpdate = true,
}

-- The sapling a new forester gets: the first kind selected on the monitor,
-- else factory.cfg's forester.sapling.
local function buildSapling(F)
  return (F.saplings and F.saplings[1]) or F.cfg.forester.sapling
end

local function copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return c
end

-- Fill in settings missing from factory.cfg (older files, or sections with
-- only some keys) from the defaults, one level deep.
function M.withDefaults(config)
  for k, v in pairs(M.DEFAULT_CONFIG) do
    if config[k] == nil then
      config[k] = copy(v)
    elseif type(v) == "table" and type(config[k]) == "table" and #v == 0 then
      for k2, v2 in pairs(v) do if config[k][k2] == nil then config[k][k2] = copy(v2) end end
    end
  end
  return config
end

function M.new(config, deps)
  config = M.withDefaults(config)
  local first = C.PRESETS[1]
  local F = {
    cfg = config, deps = deps,
    sel = { ore = first.name, y = first.y, onlyThis = true, qty = 3 },
    turtles = {}, queue = {}, stopFor = {}, nextJobId = 1, nextSector = {},
    totals = {}, counted = {}, orders = {}, nextOrderId = 1, homes = {}, nextHomeId = 1,
    ruleJobs = {}, selected = nil, note = "Ready",
    hammer = config.production and config.production.hammer or false,
    craft = nil, nextCraftId = 1, crafted = {}, prod = { furnaces = 0, missing = {} },
    map = oremap.new(), -- (its own file: base.lua loads and saves it)
  }
  homes.import(F, F.cfg.homes)
  return F
end

function M.snapshot(F)
  local t = {}
  for _, k in ipairs(PERSIST) do t[k] = F[k] end
  return t
end

function M.restore(F, t)
  if type(t) == "table" then
    for _, k in ipairs(PERSIST) do if t[k] ~= nil then F[k] = t[k] end end
  end
  homes.import(F, F.cfg.homes, F.buildSpot) -- (no duplicates: same position = same home)
  if F.gpsWanted then F.cfg.fleet.gps = #C.GPS_POINTS end
  if F.anchor then -- $build in chat set the build spot's world Y
    local b = F.buildSpot or { x = 0, y = 0, z = 0 }
    F.cfg.build.y = F.anchor.wy + b.y
  end
end

-- Homes are stored relative to the survey's start (next to the base
-- computer); turtles get them relative to the build spot. Before a survey the
-- two are the same. When the build spot becomes known, homes registered in
-- the old frame (factory.cfg, by hand) move along.
function M.setBuildSpot(F, p)
  local old = F.buildSpot or { x = 0, y = 0, z = 0 }
  for _, h in ipairs(F.homes) do
    if h.source ~= "survey" then h.x, h.y, h.z = h.x + p.x - old.x, h.y + p.y - old.y, h.z + p.z - old.z end
  end
  -- the ore map was placed from homes in the old frame, some of which just
  -- moved and some (surveyed) didn't: no single shift is right, start over
  if p.x ~= old.x or p.y ~= old.y or p.z ~= old.z then
    F.map = oremap.new()
    F.mapDirty = true
  end
  F.buildSpot = { x = p.x, y = p.y, z = p.z }
end

-- A home as a turtle flying from the build spot needs it.
local function slotFor(F, h)
  local b = F.buildSpot or { x = 0, y = 0, z = 0 }
  local s = homes.slot(h)
  s.x, s.y, s.z = s.x - b.x, s.y - b.y, s.z - b.z
  return s
end

-- -------------------------------------------------------------------- GPS --
-- Four GPS host turtles at C.GPS_POINTS above the build spot, hosting in the
-- home frame. Asked for once (monitor), then kept like any fleet target.
function M.wantGps(F)
  F.gpsWanted = true
  local b = F.buildSpot or { x = 0, y = 0, z = 0 }
  for _, p in ipairs(C.GPS_POINTS) do
    homes.add(F, { x = b.x + p.x, y = b.y + p.y, z = b.z + p.z, facing = "north", role = "gps", source = "gps-point" })
  end
  F.cfg.fleet.gps = #C.GPS_POINTS
  F.note = "GPS: 4 host turtles ordered (iron turtle + compass + wireless modem each)"
end

-- Absolute Y of a home-frame y (factory.cfg build.y is the build spot's Y).
local function absY(F, y)
  local b = F.buildSpot or { x = 0, y = 0, z = 0 }
  return F.cfg.build.y + (y - b.y)
end

-- A turtle that knows its position (GPS) registers the spot it stands on as
-- a home for `role` and moves in.
local function registerHome(F, from, msg)
  local p = msg.home
  if type(p) ~= "table" or not p.x then return { type = "nohome" } end
  local h = homes.add(F, { x = p.x, y = p.y, z = p.z, facing = p.facing, source = "gps" })
  if h.owner and h.owner ~= from then
    return { type = "nohome", reason = "home lived in by " .. tostring(h.owner) }
  end
  homes.release(F, from)
  h.role, h.owner = msg.homeRole or h.role, from
  local who = F.turtles[from] and F.turtles[from].label or ("#" .. from)
  F.note = ("%s registered home %d (%s) at %d,%d,%d"):format(who, h.id, h.role, h.x, h.y, h.z)
  return { type = "registered", home = h.id, y = absY(F, h.y) }
end

-- ------------------------------------------------------------------ chat --
-- `$build` on the build spot ties the world to the home frame; `$home [role]`
-- registers the block at the player's HEAD (a player is 2 high: standing
-- next to a home's chest and modem, the head is where the turtle goes),
-- facing the way they look.
-- `pos` = { x, y, z, yaw } of the player in world coordinates (or nil).
local function facingOf(yaw)
  -- Minecraft yaw: 0 = south, 90 = west, 180 = north, 270 = east
  local i = math.floor(((yaw % 360) + 45) / 90) % 4
  return ({ [0] = "south", "west", "north", "east" })[i]
end

function M.chatCommand(F, user, text, pos)
  local cmd, arg = tostring(text):match("^%$(%a+)%s*(%S*)")
  if not cmd then return nil end
  cmd = cmd:lower()
  if cmd == "help" then
    return "$build (stand on the build spot), $home [miner|forester] (head where the turtle goes, look the way it should face), $homes, $removehome <id>"
  elseif cmd == "homes" then
    local parts = {}
    for _, h in ipairs(F.homes) do parts[#parts + 1] = ("#%d %s %d,%d,%d"):format(h.id, h.role, h.x, h.y, h.z) end
    return #parts > 0 and table.concat(parts, "; ") or "no homes yet"
  elseif cmd == "removehome" then
    local ok, why = homes.remove(F, tonumber(arg) or -1)
    return ok and ("home " .. arg .. " removed") or ("can't: " .. tostring(why))
  end
  if not pos then return "I can't see where you are (Player Detector missing or out of range)" end
  local wx, wy, wz = math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)
  if cmd == "build" then
    local b = F.buildSpot or { x = 0, y = 0, z = 0 }
    F.anchor = { wx = wx - b.x, wy = wy - b.y, wz = wz - b.z } -- world position of home-frame (0,0,0)
    F.cfg.build.y = wy
    return ("build spot set at %d %d %d"):format(wx, wy, wz)
  elseif cmd == "home" then
    if not F.anchor then return "stand on the build spot and type $build first" end
    local role = arg ~= "" and arg or nil
    if role and role ~= "miner" and role ~= "forester" and role ~= "off" then return "role must be miner, forester or off" end
    local hy = wy + 1 -- the head block
    local h = homes.add(F, { x = wx - F.anchor.wx, y = hy - F.anchor.wy, z = wz - F.anchor.wz,
                             facing = facingOf(pos.yaw or 0), role = role, source = "chat" })
    F.note = ("%s added home %d via chat"):format(user, h.id)
    return ("home %d at %d %d %d (your head) facing %s: %s"):format(h.id, wx, hy, wz, h.facing, h.role)
  end
  return "unknown command; $help"
end

-- Home list actions for the monitor.
function M.cycleHome(F, id)
  local h, why = homes.cycle(F, id)
  F.note = h and ("Home %d: %s"):format(id, h.role) or why
end

function M.addHome(F, home)
  local h = homes.add(F, home)
  F.note = ("Home %d at %d,%d,%d facing %s: %s"):format(h.id, h.x, h.y, h.z, h.facing, h.role)
  return h
end

function M.removeHome(F, id)
  local ok, why = homes.remove(F, id)
  F.note = ok and ("Home %d removed"):format(id) or why
end

local function now(F) return F.deps.now() end
local function label(F, id) local t = F.turtles[id]; return (t and t.label) or ("#" .. id) end

local function presetY(name)
  for _, p in ipairs(C.PRESETS) do if p.name == name then return p.y end end
end

local function oreKey(job) return job and (job.only or "all") or "-" end

function M.jobText(job)
  if not job then return "-" end
  return ("%s%s @Y%s"):format(job.quantity and (job.quantity .. "x ") or "",
    job.only or "all ores", tostring(job.y))
end

-- ------------------------------------------------------------------ jobs --
-- Queue a mining job. Each job gets its own lanes (sector) at its Y level.
function M.queueJob(F, job)
  local sector = F.nextSector[job.y] or 0
  local lanes = job.lanes or F.cfg.job.lanes
  if sector + lanes > (F.cfg.job.maxLanes or 24) then sector = 0 end
  F.nextSector[job.y] = sector + lanes
  job.id, job.sector = F.nextJobId, sector
  job.lanes, job.length = lanes, job.length or F.cfg.job.length
  F.nextJobId = F.nextJobId + 1
  F.queue[#F.queue + 1] = job
  return job
end

function M.selectOre(F, name) F.sel.ore, F.sel.y = name, presetY(name) end
function M.toggleOnly(F) F.sel.onlyThis = not F.sel.onlyThis end
function M.addY(F, d) F.sel.y = math.max(-64, math.min(319, F.sel.y + d)) end
function M.qtyStep(F, d) F.sel.qty = math.max(1, math.min(#M.QTY, F.sel.qty + d)) end
function M.selectTurtle(F, id) F.selected = (F.selected ~= id) and id or nil end

-- TURTLES tab: take the selected turtle apart. At its next safe stop at home
-- it is told to (see handle); one at a time; builds wait meanwhile.
function M.dismantle(F)
  local t = F.selected and F.turtles[F.selected]
  if not t then F.note = "Select a turtle first"; return end
  if t.role == "assembler" then F.note = "The assembler can't take itself apart"; return end
  if F.dismantle then F.note = ("Already taking %s apart"):format(label(F, F.dismantle.id)); return end
  F.dismantle = { id = t.id, state = "asked", since = now(F) }
  F.note = ("%s will be taken apart at its next stop at home"):format(label(F, t.id))
end

-- TURTLES tab: forget the selected turtle (one that will never report again:
-- picked up, broken, reused elsewhere). Its home is free again, a job it had
-- goes back to the front of the queue. A turtle that is still around simply
-- shows up again the next time it reports.
function M.forget(F)
  local id = F.selected
  local t = id and F.turtles[id]
  if not t then F.note = "Select a turtle first"; return end
  if t.job and t.job.id and t.state ~= "idle" and t.state ~= "done" then
    oremap.release(F.map, t.job.id)
    table.insert(F.queue, 1, t.job)
  end
  F.turtles[id] = nil
  homes.release(F, id)
  F.stopFor[id] = nil
  if F.dismantle and F.dismantle.id == id then F.dismantle = nil end
  F.selected = nil
  F.note = ("Forgot %s"):format(t.label or ("#" .. id))
end

-- The dismantled turtle is gone: out of the fleet, its home free again.
local function dismantled(F, id, how)
  F.note = ("%s %s"):format(label(F, id), how)
  F.turtles[id] = nil
  homes.release(F, id)
  F.dismantle = nil
end

function M.start(F)
  local q = M.QTY[F.sel.qty]
  local job = M.queueJob(F, { only = F.sel.onlyThis and F.sel.ore or nil, y = F.sel.y,
                              quantity = q > 0 and q or nil })
  F.note = ("Queued #%d: %s (%d in queue)"):format(job.id, M.jobText(job), #F.queue)
end

function M.stop(F)
  local t = F.selected and F.turtles[F.selected]
  if t then
    if t.state == "idle" or t.state == "done" or t.role ~= "miner" then
      F.note = label(F, t.id) .. " has no job to stop"
    else
      F.stopFor[t.id] = true
      F.note = "Stop for " .. label(F, t.id) .. ": delivered next time it is home"
    end
  elseif #F.queue > 0 then
    local j = table.remove(F.queue)
    if j.rule then F.ruleJobs[j.rule] = nil end
    F.note = ("Cancelled queued #%d: %s"):format(j.id, M.jobText(j))
  else
    F.note = "Select a turtle to stop it"
  end
end

-- [ore] = { turtles = busy on it, mined = finished + in progress, queued = n }
function M.summary(F)
  local s = {}
  local function row(k)
    s[k] = s[k] or { turtles = 0, mined = F.totals[k] or 0, queued = 0 }
    return s[k]
  end
  for k in pairs(F.totals) do row(k) end
  for _, t in pairs(F.turtles) do
    if t.role == "miner" and t.job and t.state ~= "idle" and t.state ~= "done" then
      local r = row(oreKey(t.job))
      r.turtles = r.turtles + 1
      r.mined = r.mined + (t.mined or 0)
    end
  end
  for _, j in ipairs(F.queue) do local r = row(oreKey(j)); r.queued = r.queued + 1 end
  return s
end

-- -------------------------------------------------------------- building --
-- The order being built (at most one), if any.
local function buildingOrder(F)
  for _, o in ipairs(F.orders) do if o.state == "building" then return o end end
end

-- The order the assembler should work on: the one being built, else the first
-- queued order whose parts are all in storage, else the first queued one. An
-- order still waiting for parts never blocks one that is ready.
local function activeOrder(F)
  local b = buildingOrder(F)
  if b then return b end
  local first
  for _, o in ipairs(F.orders) do
    if o.state == "queued" then
      if not next(M.missingParts(F, o.role)) then return o end
      first = first or o
    end
  end
  return first
end

-- Turtle upgrades must be undamaged and unenchanted, or crafting them on fails.
local function usableTool(d) return (d.damage or 0) == 0 and not (d.enchantments and next(d.enchantments)) end

-- A computer or turtle item that is PLAIN: its name is the plain name (CC
-- en_us: "Advanced Turtle", "Advanced Computer"...). Upgrades change the name
-- ("Advanced Mining Turtle") and a label replaces it, so an upgraded or
-- labelled turtle is never taken; a stripped, unlabelled one is (its old
-- computer ID doesn't matter: the installer disk overwrites files and role).
-- The untranslated key counts too, in case the server doesn't translate.
local PLAIN = {
  ["computercraft:turtle_advanced"] = "Advanced Turtle", ["computercraft:turtle_normal"] = "Turtle",
  ["computercraft:computer_advanced"] = "Advanced Computer", ["computercraft:computer_normal"] = "Computer",
}
local function plain(item)
  return function(d)
    return d.displayName == PLAIN[item] or d.displayName == "block." .. item:gsub(":", ".")
  end
end

-- How the base picks stacks it hands over: usable tools, plain computers.
local function acceptFor(item)
  if item:find("pickaxe") then return usableTool end
  if PLAIN[item] then return plain(item) end
end

-- Storage contents, counting only usable tools and plain computers/turtles
-- (with a bridge, fresh computers/turtles aren't counted yet: see
-- storage.lua's bridge countWhere).
local function usableStock(F)
  local S = F.deps.storage
  local stock = S.list()
  local checks = {}
  for item in pairs(stock) do
    local accept = acceptFor(item)
    if accept then checks[item] = accept; stock[item] = 0 end
  end
  if next(checks) and S.kind == "barrels" and S.countWhereMany then
    for item, n in pairs(S.countWhereMany(checks)) do stock[item] = n end -- (one batch of reads)
  end
  return stock
end

-- AE2-style: the build step to start at for `role`, by what is in storage: a
-- plain turtle of its tier skips to the upgrades (3), a plain computer to the
-- body (2), else from the start (1).
local function startFor(F, role, stock)
  stock = stock or usableStock(F)
  local all = C.allBuildSteps(role)
  if (stock[all[2].result] or 0) >= 1 then return 3 end
  if (stock[all[1].result] or 0) >= 1 then return 2 end
  return 1
end
M.startFor = startFor

-- Items missing from storage for one turtle of `role` ({} when complete).
function M.missingParts(F, role)
  local missing = {}
  local stock = usableStock(F)
  for item, n in pairs(C.parts(role, buildSapling(F), startFor(F, role, stock))) do
    if (stock[item] or 0) < n then missing[item] = n - (stock[item] or 0) end
  end
  return missing
end

-- The install data a new turtle should get: the active build's, or a plain
-- miner's (for a turtle someone places on the build spot by hand).
function M.installData(F)
  local o = buildingOrder(F)
  if o and o.install then return copy(o.install) end
  return { role = "miner" }
end

-- Cancel a queued order, or clear a failed one from the list (monitor tap).
function M.cancelOrder(F, id)
  for i, o in ipairs(F.orders) do
    if o.id == id then
      if o.state == "building" then F.note = ("Build #%d is in progress"):format(id); return end
      if o.state == "queued" or o.state == "failed" then
        table.remove(F.orders, i)
        homes.release(F, "order:" .. id)
        F.note = ("Build #%d removed"):format(id)
      end
      return
    end
  end
end

function M.orderTurtle(F, role, manual)
  if manual then F.failStreak = 0 end
  local o = { id = F.nextOrderId, role = role, state = "queued", step = 0 }
  F.nextOrderId = F.nextOrderId + 1
  F.orders[#F.orders + 1] = o
  F.note = ("Ordered a %s turtle (#%d)"):format(role, o.id)
  return o
end

-- The assembler's inventory. The base fills it and empties it over the wired
-- network (the assembler must touch an enabled wired modem): items go straight
-- in, the assembler sorts them into its crafting grid, and whatever it should
-- not keep is pulled back into storage by slot. It reports its slots
-- ({[slot] = item}) with every status (a turtle can't be listed remotely).
local NOT_ON_NET = "the assembler isn't on the network: right-click the wired modem it touches"

-- Pull every reported slot of the assembler back into storage, except `keep`
-- ({[slot] = true}).
local function clearAssembler(F, from, keep)
  local S = F.deps.storage
  local name = S.findTurtle and S.findTurtle(from)
  if not name then return false, NOT_ON_NET end
  local t = F.turtles[from] or {}
  local left = {}
  for slot, item in pairs(t.inv or {}) do
    if keep and keep[slot] then left[slot] = item else S.takeFrom(name, slot, item) end
  end
  t.inv = left -- until its next report
  return true
end

-- Deliver `items` ({[item]=n}) into the assembler, after pulling out what it
-- holds except the `keep` cells.
local function stage(F, from, items, keep)
  local ok, why = clearAssembler(F, from, keep)
  if not ok then return false, why end
  local S = F.deps.storage
  local name = S.findTurtle(from)
  local names = {}
  for item in pairs(items) do names[#names + 1] = item end
  table.sort(names)
  for _, item in ipairs(names) do
    local n = items[item]
    local moved = S.send(name, item, n, acceptFor(item))
    if moved < n then return false, ("only %d of %d %s in storage"):format(moved, n, item) end
  end
  return true
end

local function stepItems(step)
  local items = {}
  for _, item in pairs(step.grid) do items[item] = (items[item] or 0) + 1 end
  return items
end

local function stepReply(o, step, n)
  return { type = "step", order = o.id, step = n, grid = step.grid, keep = step.keep,
           select = step.select, result = step.result }
end

local RETRY_AFTER = 300 -- seconds before ordering again after a failed build

local function failOrder(F, o, why)
  o.state, o.reason, F.lastFail = "failed", why, now(F)
  F.failStreak = (F.failStreak or 0) + 1
  homes.release(F, "order:" .. o.id) -- free its home slot
  if o.assembler then clearAssembler(F, o.assembler) end
  F.note = ("Build #%d failed: %s"):format(o.id, why)
end

-- The assembler's side of a build: it reports, we stage and say what's next.
-- ------------------------------------------------------------- crafting --
-- ------------------------------------------------------------ mailbox --
local function isSaplingItem(name) return name:find("sapling") ~= nil or name:find("propagule") ~= nil end
M.isSaplingItem = isSaplingItem

-- GATHERING > FORESTRY: select/deselect a sapling kind; none selected = auto.
function M.toggleSapling(F, item)
  F.saplings = F.saplings or {}
  for i, n in ipairs(F.saplings) do
    if n == item then table.remove(F.saplings, i); return end
  end
  F.saplings[#F.saplings + 1] = item
  table.sort(F.saplings)
end

function M.toggleBoneMeal(F)
  F.boneMeal = not F.boneMeal
  F.note = "Bone meal for foresters: " .. (F.boneMeal and "ON" or "OFF")
end

-- The sapling kinds foresters plant: the ones selected on the monitor, else
-- (auto) the kind storage has most of. { item, ... }, maybe empty.
local function plantKinds(F, stock)
  if F.saplings and #F.saplings > 0 then return F.saplings end
  local best
  for item, n in pairs(stock) do
    if isSaplingItem(item) and not C.tree(item).twoByTwo and n > 0
       and (not best or n > stock[best] or (n == stock[best] and item < best)) then
      best = item
    end
  end
  return { best }
end

-- The home chest of turtle `id`: its home's (surveyed, or claimed with the
-- marker trick), else, for a turtle without a home, the one it claimed.
local function chestOf(F, id)
  for _, h in ipairs(F.homes) do if h.owner == id and h.chest then return h.chest end end
  return F.turtles[id] and F.turtles[id].chest
end
M.chestOf = chestOf

-- A chest with a delivery in it is not emptied until the turtle that asked
-- talks again (it has taken it by then), or HOLD s at most.
local HOLD = 30

-- Supplies on request. A turtle at home, facing its chest, asks for what it
-- wants to carry: `req` = { fuel = items, saplings = per kind, bonemeal = n,
-- dirt = n } and says what it carries (`have` = { [item] = count }). The base
-- sends the difference into its chest and says what it could not get.
function M.supply(F, from, req, have)
  local chest = chestOf(F, from)
  if not chest then return { type = "nochest" } end
  local S = F.deps.storage
  -- it is this turtle's turn at the chest: empty it first (it takes all it
  -- finds), unless another turtle's delivery is waiting there
  local held = F.held and F.held[chest]
  if not (held and held.by ~= from and now(F) < held.untilTime) then S.store(chest) end
  local stock = S.list()
  have = have or {}
  local sent, short = {}, {}
  local function give(item, n)
    if n <= 0 or (stock[item] or 0) <= 0 then return 0 end
    local m = S.send(chest, item, math.min(n, stock[item]))
    stock[item] = stock[item] - m
    if m > 0 then sent[item] = (sent[item] or 0) + m end
    return m
  end
  local function want(key, item, n)
    local left = n - (have[item] or 0)
    left = left - give(item, left)
    if left > 0 then short[key] = (short[key] or 0) + left end
  end
  if (req.fuel or 0) > 0 then
    local left = req.fuel
    for _, f in ipairs(C.FUEL_ORDER) do left = left - (have[f] or 0) end
    for _, f in ipairs(C.FUEL_ORDER) do
      if left <= 0 then break end
      left = left - give(f, left)
    end
    if left > 0 then short.fuel = left end
  end
  if (req.saplings or 0) > 0 then
    local kinds = plantKinds(F, stock)
    if #kinds == 0 then short.saplings = req.saplings end
    for _, k in ipairs(kinds) do want("saplings", k, req.saplings) end
  end
  if F.boneMeal and (req.bonemeal or 0) > 0 then want("bonemeal", "minecraft:bone_meal", req.bonemeal) end
  if (req.dirt or 0) > 0 then want("dirt", "minecraft:dirt", req.dirt) end
  -- tools for its toolbelt: one each it lacks; none in storage: the base
  -- crafts one if it can (M.toolsToCraft), the next ask takes it. A
  -- forester set to shear gets the shears and the Weak Automata Core too.
  local tools = {}
  for _, item in ipairs(req.tools or {}) do tools[#tools + 1] = item end
  local t = F.turtles[from]
  if t and t.role == "forester" and t.shear then
    tools[#tools + 1] = C.SHEARS_ITEM
    tools[#tools + 1] = C.AUTOMATA_ITEM
  end
  local asked = {}
  for _, item in ipairs(tools) do
    if not asked[item] and C.TOOLS[item] and (have[item] or 0) == 0 and give(item, 1) == 0 then
      short[item] = 1
      -- the base crafts the ones it has a recipe for (the core: storage only)
      if recipes.CRAFT[item] then
        F.toolWants = F.toolWants or {}
        F.toolWants[item] = true
      end
    end
    asked[item] = true
  end
  if next(sent) then
    F.held = F.held or {}
    F.held[chest] = { untilTime = now(F) + HOLD, by = from }
  end
  local reply = { type = "supplied", chest = chest, sent = sent, short = short }
  if t and t.role == "forester" then
    reply.plant = (F.saplings and #F.saplings > 0) and F.saplings or false
    reply.shear = t.shear == true
  end
  return reply
end

-- Every 10 s: empty the home chests into storage, except one a turtle is
-- taking a delivery from.
function M.serviceChests(F)
  local S = F.deps.storage
  for _, name in ipairs(S.inputs and S.inputs() or {}) do
    local held = F.held and F.held[name]
    if held and now(F) >= held.untilTime then F.held[name] = nil; held = nil end
    if not held then S.store(name) end
  end
end

function M.toggleTinyFuel(F)
  F.tinyFuel = not F.tinyFuel
  F.note = "Furnaces on tiny coal (crafted from charcoal/coal): " .. (F.tinyFuel and "ON" or "OFF")
end

-- FACTORY tab: DEFRAG packs storage into as few slots as possible (see
-- defrag.lua). It runs a few rounds of moves per tick, planned each time
-- from storage as it is then, so turtles and players change it meanwhile
-- without harm; it stops when a plan has no moves left or stops gaining.
local DEFRAG_ROUNDS = 8 -- rounds of side-by-side moves per tick
function M.toggleDefrag(F)
  local S = F.deps.storage
  if not (S.layout and S.move) then
    F.note = "Defrag needs barrel storage (an ME/RS bridge packs itself)"
    return
  end
  if F.defrag then
    F.defrag = nil
    F.note = "Defrag stopped"
  else
    F.defrag = { idle = 0 }
    F.note = "Defrag: packing storage..."
  end
end

local function defragStep(F)
  local d = F.defrag
  if not d then return end
  local S = F.deps.storage
  local slots, cap = S.layout()
  local before = defrag.usedSlots(slots)
  d.from = d.from or before
  local moves, after = defrag.plan(slots, cap)
  if #moves == 0 or after >= before then
    F.defrag = nil
    F.note = ("Defrag done: storage uses %d slots (was %d)"):format(before, d.from)
    return
  end
  local short = false
  for i, round in ipairs(defrag.rounds(moves)) do
    if i > DEFRAG_ROUNDS or short then break end
    for _, ok in ipairs(S.move(round)) do if not ok then short = true end end
  end
  S.forget() -- (moved: the journal no longer says where things are)
  -- a short move: storage changed under us; the next tick plans again
  if short then
    d.idle = d.idle + 1
    if d.idle >= 5 then
      F.defrag = nil
      F.note = "Defrag stopped: storage keeps changing under it"
      return
    end
  end
  F.note = ("Defrag: %d -> %d slots..."):format(d.from, after)
end
M.defragStep = defragStep

-- TURTLES tab: the selected forester shears its trees' leaves before
-- felling them (the leaves as blocks), or not.
function M.toggleShear(F)
  local t = F.selected and F.turtles[F.selected]
  if not (t and t.role == "forester") then F.note = "Select a forester to shear with"; return end
  t.shear = not t.shear
  F.note = ("%s shears leaves: %s%s"):format(label(F, F.selected), t.shear and "ON" or "OFF",
    t.shear and " (it gets shears and a Weak Automata Core at home; the core comes from storage)" or "")
end

function M.toggleHammer(F)
  F.hammer = not F.hammer
  F.note = "Ore doubling with hammers: " .. (F.hammer and "ON" or "OFF")
end

-- Turtles short of each role's fleet target (and the queued order's role).
local function shortRoles(F)
  local short = {}
  for role, want in pairs(F.cfg.fleet) do
    if M.fleetCount(F, role) < want then short[role] = true end
  end
  for _, o in ipairs(F.orders) do
    if o.state == "queued" then short[o.role] = true end
  end
  return short
end

-- Tools turtles asked for that storage didn't have: { { item, 1 }, ... } to
-- craft (a want is dropped once storage has one).
function M.toolsToCraft(F, stock)
  local list = {}
  for item in pairs(F.toolWants or {}) do
    if (stock[item] or 0) > 0 then F.toolWants[item] = nil else list[#list + 1] = { item, 1 } end
  end
  table.sort(list, function(a, b) return a[1] < b[1] end)
  return list
end

-- Plan the next craft for the assembler; stage its inputs; nil if nothing to do.
local function startCraft(F, from)
  local cfgp = F.cfg.production or {}
  if cfgp.enabled == false or now(F) < (F.craftPauseUntil or 0) then return nil end
  local stock = usableStock(F)
  local wanted = production.wantedForFleet(shortRoles(F), buildSapling(F),
    function(role) return startFor(F, role, stock) end)
  for _, w in ipairs(M.toolsToCraft(F, stock)) do wanted[#wanted + 1] = w end
  if F.tinyFuel then -- after the turtle parts: they matter more
    for _, w in ipairs(production.wantedTiny(stock, cfgp)) do wanted[#wanted + 1] = w end
  end
  local job, missing = production.plan(stock, F.hammer, wanted)
  F.prod.missing = missing
  if not job then return nil end
  local items, select = {}, nil
  for cell, item in pairs(job.grid) do
    -- a repeated (hammer) job uses one hammer for all its sets
    local n = (job.repeated and recipes.isHammer(item)) and 1 or job.sets
    items[item] = (items[item] or 0) + n
    if not select or cell < select then select = cell end
  end
  local ok, why = stage(F, from, items)
  if not ok then
    F.note = "Craft " .. job.item .. ": " .. why
    F.craftPauseUntil = now(F) + CRAFT_PAUSE
    return nil
  end
  F.craft = { id = F.nextCraftId, item = job.item, sets = job.sets, assembler = from, lastSeen = now(F) }
  F.nextCraftId = F.nextCraftId + 1
  F.craft.reply = { type = "craft", craft = F.craft.id, grid = job.grid, select = select,
                    result = job.item, sets = job.sets, repeated = job.repeated }
  F.note = ("Crafting %s x%d"):format(job.item:gsub("^%w+:", ""), job.sets * (job.count or 1))
  return F.craft.reply
end

local function endCraft(F, made)
  local c = F.craft
  if c and c.assembler then clearAssembler(F, c.assembler) end
  if made and c then F.crafted[c.item] = (F.crafted[c.item] or 0) + made end
  F.craft = nil
end

local handleAssemblerStep

-- Every reply in a build is remembered: if it got lost (the assembler gave up
-- waiting) and the assembler reports idle, it gets the same reply again.
local function handleAssembler(F, from, msg)
  -- a turtle being taken apart on the build spot
  local dm = F.dismantle
  if dm and msg.state == "collecting" then
    clearAssembler(F, from) -- what it handed over goes to storage
    return { type = "ok" }
  elseif dm and msg.state == "collected" and msg.dismantle == dm.id then
    clearAssembler(F, from)
    dismantled(F, dm.id, "taken apart: its parts and the plain turtle are in storage")
    return { type = "ok" }
  elseif dm and msg.state == "failed" and msg.dismantle == dm.id then
    F.note = ("Taking %s apart: %s"):format(label(F, dm.id), tostring(msg.reason))
    F.dismantle = nil
    clearAssembler(F, from)
    return { type = "ok" }
  elseif dm and msg.state == "idle" then
    if dm.state == "coming" then return { type = "collect", id = dm.id } end
    return { type = "ok" } -- (no new builds while one is being taken apart)
  end
  -- it fits a pickaxe itself (to pick up dismantled turtles): deliver one
  -- when it has none and a free side, and isn't busy
  if msg.state == "equipped" then
    clearAssembler(F, from) -- (anything left over)
    return { type = "ok" }
  end
  -- (builds first: only while no order waits, which may need that pickaxe)
  if msg.state == "idle" and msg.pickaxe == false and not F.craft and not activeOrder(F) then
    if msg.freeSide then
      if (usableStock(F)["minecraft:diamond_pickaxe"] or 0) > 0 then
        local ok = stage(F, from, { ["minecraft:diamond_pickaxe"] = 1 })
        if ok then
          F.note = "The assembler fits a diamond pickaxe (to pick up dismantled turtles)"
          return { type = "equip" }
        end
      end
    elseif not F.warnedPickaxe then
      F.warnedPickaxe = true
      F.note = "Assembler: no free upgrade side for a pickaxe (DISMANTLE needs one)"
    end
  end
  -- a craft job in flight
  local c = F.craft
  if c and c.assembler == from then
    c.lastSeen = now(F)
    if msg.state == "crafting" and msg.craft == c.id then
      -- a hammer round done: take its dust out (crafting needs every slot
      -- outside the grid empty), keep the hammer and ore in their cells
      if msg.round and msg.round ~= c.round then
        c.round, c.made = msg.round, (c.made or 0) + (msg.made or 0)
      end
      local keep = {}
      for cell in pairs(c.reply.grid) do keep[cell] = true end
      local ok, why = clearAssembler(F, from, keep)
      if not ok then F.note = "Craft " .. c.item .. ": " .. why end
      return { type = "continue", craft = c.id }
    elseif msg.state == "crafted" and msg.craft == c.id then
      endCraft(F, (c.made or 0) + (msg.made or 0))
      -- the next craft right away (not after its idle round trip)
      return startCraft(F, from) or { type = "ok" }
    elseif msg.state == "failed" then
      F.note = "Craft " .. c.item .. " failed: " .. tostring(msg.reason)
      endCraft(F, nil)
      F.craftPauseUntil = now(F) + CRAFT_PAUSE
      return { type = "ok" }
    elseif msg.state == "idle" then
      return c.reply -- lost on the way: say it again
    end
    return { type = "ok" }
  end
  local o = activeOrder(F)
  if o and o.state == "building" and o.assembler == from then o.lastSeen = now(F) end
  if msg.state == "failed" and o and o.state == "building" and o.assembler == from then
    failOrder(F, o, msg.reason or "assembler failed")
    return { type = "ok" }
  end
  if msg.state == "failed" then -- (a restart, nothing running): empty it
    clearAssembler(F, from)
    return { type = "ok" }
  end
  if msg.state == "idle" and o and o.state == "building" and o.assembler == from and o.lastReply then
    return o.lastReply
  end
  local reply = handleAssemblerStep(F, from, msg, o)
  if o and o.state == "building" and reply.type ~= "ok" then o.lastReply = reply end
  return reply
end

handleAssemblerStep = function(F, from, msg, o)
  if msg.state == "idle" then
    -- a build when its parts are all there, else make parts
    if not o or o.state ~= "queued" or next(M.missingParts(F, o.role)) then
      return startCraft(F, from) or { type = "ok" }
    end
    -- the new turtle gets its home slot with its install data: it can fly there
    -- without talking first (there may be no modem at the build spot)
    -- (a role without homes, e.g. the surveyor, starts right on the build spot)
    local noHome = C.ROLES[o.role].noHome
    local home = nil
    if not noHome then home = homes.claim(F, o.role, "order:" .. o.id) end
    if not noHome and not home then
      F.note = ("No free %s home: add one (monitor HOMES, `home %s` or $home)"):format(o.role, o.role)
      return { type = "ok" }
    end
    o.state, o.assembler, o.step, o.home, o.lastSeen = "building", from, 1, home and home.id, now(F)
    o.install = { role = o.role, order = o.id, trees = F.cfg.forester.trees,
                  wait = F.cfg.forester.wait, slot = home and slotFor(F, home) or nil, homeY = F.cfg.build.y,
                  host = o.role == "gps" and { x = home.x, y = home.y, z = home.z } or nil }
    F.deps.writeInstall(copy(o.install))
    o.from = startFor(F, o.role) -- AE2-style: skip what storage already has
    local steps = C.buildSteps(o.role, o.from)
    local ok, why = stage(F, from, stepItems(steps[1]))
    if not ok then failOrder(F, o, why); return { type = "ok" } end
    F.note = ("Building a %s turtle (#%d)%s"):format(o.role, o.id,
      o.from == 3 and ": a plain turtle from storage" or o.from == 2 and ": a computer from storage" or "")
    return stepReply(o, steps[1], 1)
  end
  if not o or o.state ~= "building" or msg.order ~= o.id then return { type = "ok" } end
  local steps = C.buildSteps(o.role, o.from)
  if msg.state == "crafted" and msg.step == o.step then
    if o.step < #steps then
      o.step = o.step + 1
      local keep = {}
      for cell in pairs(steps[o.step].keep or {}) do keep[cell] = true end
      local ok, why = stage(F, from, stepItems(steps[o.step]), keep)
      if not ok then failOrder(F, o, why); return { type = "abort" } end
      return stepReply(o, steps[o.step], o.step)
    end
    o.step = "place"
    return { type = "place", order = o.id }
  elseif msg.state == "placed" then
    local items, list = {}, {}
    local stock = F.deps.storage.list()
    for _, l in ipairs(C.ROLES[o.role].loadout) do
      local item = l[1] == "@sapling" and buildSapling(F) or l[1]
      if not l.optional or (stock[item] or 0) >= l[2] then
        items[item] = (items[item] or 0) + l[2]
        list[#list + 1] = { item, l[2] }
      end
    end
    local ok, why = stage(F, from, items)
    if not ok then failOrder(F, o, why); return { type = "abort" } end
    o.step = "loadout"
    return { type = "loadout", order = o.id, items = list }
  elseif msg.state == "powered" then
    o.state, o.lastReply, F.failStreak = "built", nil, 0
    F.note = ("Built a %s turtle (#%d); it is installing"):format(o.role, o.id)
    return { type = "ok" }
  end
  return { type = "ok" }
end

-- A new turtle asks where it lives: the first free home slot for its role.
local function assignHome(F, from, msg)
  local role = msg.role
  local h = homes.claim(F, role, from)
  if h then
    F.note = ("%s goes to %s home %d"):format(label(F, from), role, h.id)
    return { type = "home", home = slotFor(F, h), y = F.cfg.build.y, index = h.id }
  end
  F.note = ("No free %s home for %s: add one"):format(role, label(F, from))
  return { type = "wait" }
end

-- -------------------------------------------------------------- surveyor --
-- The surveyor drops a marker into a home chest; the base sees which input
-- chest it landed in. Draining is paused meanwhile, or the marker would move.
local MARK_TIMEOUT = 60

local function inputCounts(F)
  local S, counts = F.deps.storage, {}
  for _, name in ipairs(S.inputs and S.inputs() or {}) do
    local c = {}
    for _, it in pairs(S.slots(name)) do c[it.name] = (c[it.name] or 0) + it.count end
    counts[name] = c
  end
  return counts
end

function M.marking(F) return F.mark and now(F) < F.mark.untilTime end

-- The marker trick: on mark1 the base snapshots its home chests (and stops
-- emptying them); the turtle drops one item into the chest in front of it;
-- on mark2 the chest that gained something is the one. Returns its name.
local function markStart(F, from)
  F.mark = { from = from, untilTime = now(F) + MARK_TIMEOUT, snap = inputCounts(F) }
end
-- `marker`: the item it dropped. Only the chest that gained exactly one of
-- it counts; when another turtle unloads at the same moment (or two chests
-- match) it doesn't guess: nil, and the turtle tries again later.
local function markFind(F, from, marker)
  local mark = F.mark
  F.mark = nil
  if not mark or mark.from ~= from then return nil end
  local found, n = nil, 0
  for name, c in pairs(inputCounts(F)) do
    local before = mark.snap[name] or {}
    local gained = {}
    for item, k in pairs(c) do
      if k > (before[item] or 0) then gained[item] = k - (before[item] or 0) end
    end
    if marker then
      if gained[marker] == 1 then found, n = name, n + 1 end
    elseif next(gained) then
      found, n = name, n + 1
    end
  end
  if n ~= 1 then return nil end
  return found
end

local function handleSurveyor(F, from, msg)
  if msg.state == "mark1" then
    markStart(F, from)
    return { type = "ok" }
  elseif msg.state == "mark2" then
    local found = markFind(F, from, msg.marker)
    if not found or not msg.home then
      F.note = "Survey: marker not found in any home chest"
      return { type = "nomark" }
    end
    local h = homes.add(F, { x = msg.home.x, y = msg.home.y, z = msg.home.z, facing = msg.home.facing,
                             source = "survey", chest = found })
    F.note = ("Survey: home %d at %d,%d,%d (%s)"):format(h.id, h.x, h.y, h.z, found)
    return { type = "marked", chest = found, home = h.id }
  elseif msg.state == "surveyed" then
    local n = 0
    for _ in pairs(msg.homes or {}) do n = n + 1 end
    -- the installer drive is under the build spot
    local d = msg.drives and #msg.drives == 1 and msg.drives[1]
    if d then M.setBuildSpot(F, { x = d.x, y = d.y + 1, z = d.z }) end
    F.note = ("Survey done: %d homes%s; pick their roles under HOMES"):format(n,
      d and "" or (msg.drives and #msg.drives > 1 and ", several disk drives: build spot unknown"
                   or ", no disk drive found: build spot unknown"))
  end
  return { type = "ok" }
end

-- ------------------------------------------------------------- ore map --
-- Where turtle `id` lives, in the home frame: its home record, or nil (a
-- miner set up by hand: its reports can't be placed in the map).
local function homeOf(F, id)
  for _, h in ipairs(F.homes) do if h.owner == id then return h end end
end

-- A miner's map report, in its own frame (from its home, world axes):
-- { scans = { { x, y, z, r, ores = { { x, y, z, name }, ... } }, ... },
--   mined = { { x, y, z }, ... } }. Moved into the home frame and applied.
function M.applyMap(F, from, rep)
  local h = homeOf(F, from)
  if not h or type(rep) ~= "table" then return false end
  local function at(p) return { x = h.x + p.x, y = h.y + p.y, z = h.z + p.z, name = p.name, ore = p.ore, kind = p.kind } end
  for _, sc in ipairs(rep.scans or {}) do
    local ores = {}
    for _, o in ipairs(sc.ores or {}) do ores[#ores + 1] = at(o) end
    oremap.scan(F.map, at(sc), sc.r or 8, ores)
  end
  local mined = {}
  for _, p in ipairs(rep.mined or {}) do mined[#mined + 1] = at(p) end
  oremap.mined(F.map, mined)
  F.mapDirty = true
  return true
end

-- The known ores a job of turtle `id` should go for first, nearest its home,
-- held for the job; in the turtle's own frame. (A job wanting `quantity`
-- gets a few more than that: some may be gone.)
local KNOWN_MAX = 64
local KNOWN_BELOW = 8 -- known ores this far below the home at least (never up through the base)
local function knownFor(F, id, job)
  local h = homeOf(F, id)
  if not h then return nil end
  local max = job.quantity and math.min(KNOWN_MAX, job.quantity * 2) or KNOWN_MAX
  oremap.release(F.map, job.id) -- (a job handed out again: its own holds are its again)
  local list = oremap.find(F.map, h, job.only, max, { y = h.y - KNOWN_BELOW })
  if #list == 0 then return nil end
  oremap.hold(F.map, list, job.id)
  F.mapDirty = true
  local out = {}
  for i, o in ipairs(list) do out[i] = { x = o.x - h.x, y = o.y - h.y, z = o.z - h.z, name = o.name } end
  return out
end

-- ------------------------------------------------------------- protocol --
-- Turtles always talk first, while at home; the reply says what to do next.
-- Every decision starts from what storage holds now (see storage.lua).
local function freshStorage(F)
  local S = F.deps.storage
  if S and S.forget then S.forget() end
end

function M.handle(F, from, msg)
  if type(msg) ~= "table" or msg.type ~= "status" then return nil end
  freshStorage(F)
  -- what a miner saw and dug (with any status; "map" is a miner out on a job,
  -- in wireless reach: only that, its record stays as it was)
  if msg.map then M.applyMap(F, from, msg.map) end
  if msg.state == "map" then
    if F.turtles[from] then F.turtles[from].seen = now(F) end
    return { type = "ok" }
  end
  local prev = F.turtles[from] or {}
  F.turtles[from] = { id = from, label = msg.label, role = msg.role or prev.role or "miner",
                      state = msg.state, fuel = msg.fuel, mined = msg.mined or 0,
                      job = msg.job, seen = now(F), version = msg.version,
                      delivered = msg.total or prev.delivered,
                      inv = msg.inv or prev.inv, -- (the assembler's slots)
                      chest = msg.chest or prev.chest } -- the chest it claimed itself
  local t = F.turtles[from]
  local reply = { type = "ok" }
  if msg.state ~= "supply" then -- it has taken its delivery: its chest may be emptied
    for chest, h in pairs(F.held or {}) do if h.by == from then F.held[chest] = nil end end
  end

  -- a built turtle reporting for the first time: its order is done, and its
  -- reserved home slot now belongs to it. (`buildOrder` is the order a turtle
  -- was built by; the assembler's `order` is the build it is working on.)
  if msg.buildOrder then
    for _, o in ipairs(F.orders) do
      if o.id == msg.buildOrder and not o.arrived then
        o.arrived = true
        homes.handOver(F, "order:" .. o.id, from)
      end
    end
  end

  local dm = F.dismantle
  local safe = msg.state == "idle" or msg.state == "done" or msg.state == "resting"
  if dm and dm.id == from and dm.state == "asked" and safe and t.role ~= "assembler"
     and not buildingOrder(F) and not F.craft then
    dm.state = "told"
    local asm
    for id, tt in pairs(F.turtles) do if tt.role == "assembler" then asm = id end end
    return { type = "dismantle", assembler = asm }
  elseif dm and dm.id == from and msg.state == "dismantling" then
    if msg.toBuildSpot then
      dm.state, dm.since = "coming", now(F)
      F.note = ("%s is flying to the build spot to be taken apart"):format(label(F, from))
    else
      dismantled(F, from, "switched off where it is (its things in the chest next to it, or in itself): pick it up")
    end
    return { type = "ok" }
  end
  if msg.wantFuel then
    reply = M.deliverFuel(F, from, msg.wantFuel)
  elseif msg.state == "supply" then
    reply = M.supply(F, from, msg.supply or {}, msg.have)
  elseif (msg.state == "mark1" or msg.state == "mark2") and t.role ~= "surveyor" then
    -- a turtle tells which chest is its home's (the mailbox)
    if msg.state == "mark1" then
      markStart(F, from)
    else
      local found = markFind(F, from, msg.marker)
      if found then
        -- the chest belongs to its home (one chest per home, shared by every
        -- turtle there); the turtle's own record only for one without a home
        local home
        for _, h in ipairs(F.homes) do if h.owner == from then home = h end end
        if home then home.chest = found else t.chest = found end
        F.note = ("%s's home chest: %s"):format(label(F, from), found)
        reply = { type = "marked", chest = found }
      else
        reply = { type = "nomark" }
      end
    end
  elseif msg.state == "new" then
    reply = assignHome(F, from, msg)
  elseif msg.state == "registerHome" then
    reply = registerHome(F, from, msg)
  elseif t.role == "assembler" then
    reply = handleAssembler(F, from, msg)
  elseif t.role == "surveyor" then
    reply = handleSurveyor(F, from, msg)
  elseif t.role == "forester" then
    if msg.state == "resting" and msg.delivered then
      F.totals.logs = (F.totals.logs or 0) + msg.delivered
    end
    if msg.state == "resting" then
      reply.plant = (F.saplings and #F.saplings > 0) and F.saplings or false
    end
  else -- miner
    if msg.state == "done" and msg.job and msg.job.id and not F.counted[msg.job.id] then
      F.counted[msg.job.id] = true
      oremap.release(F.map, msg.job.id)
      local k = oreKey(msg.job)
      F.totals[k] = (F.totals[k] or 0) + (msg.mined or 0)
      if msg.job.rule then F.ruleJobs[msg.job.rule] = nil end
      F.note = ("%s finished: %d %s"):format(label(F, from), msg.mined or 0, k)
    end
    if msg.state == "no fuel" and msg.job then
      oremap.release(F.map, msg.job.id)
      table.insert(F.queue, 1, msg.job) -- back to the front for someone else
      t.noFuel, t.job = msg.fuel or 0, nil
      F.note = ("%s needs fuel (~%d) for jobs"):format(label(F, from), msg.need or 0)
    elseif msg.state == "idle" or msg.state == "done" then
      F.stopFor[from] = nil
      local prevNoFuel = prev.noFuel
      if prevNoFuel and (msg.fuel or 0) <= prevNoFuel then
        t.noFuel = prevNoFuel -- still too little fuel: no job for it
      elseif msg.state == "idle" and #F.queue > 0 then
        local job = table.remove(F.queue, 1)
        t.job, t.mined, t.state = job, 0, "assigned"
        F.note = ("%s took job: %s"):format(label(F, from), M.jobText(job))
        reply = { type = "job", job = job, known = knownFor(F, from, job) }
      end
    elseif F.stopFor[from] then
      F.stopFor[from] = nil
      F.note = "Stop delivered to " .. label(F, from)
      reply = { type = "stop" }
    end
  end

  -- code updates, only at safe points (between jobs / rounds / builds)
  local D = F.deps.dist
  local safe = msg.state == "idle" or msg.state == "done" or msg.state == "resting"
  if D and D.version and msg.version ~= D.version and safe and reply.type ~= "job"
     and not (t.role == "assembler" and buildingOrder(F)) then
    reply.update = { version = D.version, files = D.files }
  end
  return reply
end

-- Fuel on request: push `need` fuel worth of charcoal, then coal (see
-- oreconf.FUEL_ORDER) from storage straight into the turtle, if it is on the
-- wired network. Coal below the furnaces' reserve is the turtles' anyway.
-- Returns the reply for the turtle.
function M.deliverFuel(F, from, need)
  local S = F.deps.storage
  local name = S.findTurtle and S.findTurtle(from)
  if not name then
    F.note = ("%s wants fuel but isn't on the network: its modem is off"):format(label(F, from))
    return { type = "nofuel", reason = "my modem is off: right-click it; if only I touch it, it switches "
      .. "off whenever I leave, so put a barrel or chest against it too" }
  end
  local stock = S.list()
  local given = 0
  for _, item in ipairs(C.FUEL_ORDER) do
    if given >= need then break end
    local per = C.FUEL[item]
    local n = math.min(stock[item] or 0, math.ceil((need - given) / per), 64)
    if n > 0 then given = given + per * S.send(name, item, n) end
  end
  if given == 0 then
    F.note = ("%s wants fuel; storage has none"):format(label(F, from))
    return { type = "nofuel", reason = "no coal or charcoal in storage" }
  end
  F.note = ("Gave %s %d fuel"):format(label(F, from), given)
  return { type = "fuel", fuel = given }
end

-- How much of `item` the factory has, counting what the furnaces and hammers
-- turn it into: a rule for raw iron also counts iron dust and iron ingots
-- (they get smelted as soon as they arrive).
function M.stockOf(stock, item)
  local seen, n = {}, 0
  local function add(i) if i and not seen[i] then seen[i] = true; n = n + (stock[i] or 0) end end
  add(item)
  local dust = recipes.hammerDust(item)
  add(dust)
  local s = recipes.smelt(item)
  add(s and s.out)
  local ds = dust and recipes.smelt(dust)
  add(ds and ds.out)
  return n
end

-- Turtles of `role` that count for the fleet: seen recently, or built and on
-- their way.
function M.fleetCount(F, role)
  local have = 0
  for _, t in pairs(F.turtles) do
    if t.role == role and now(F) - (t.seen or 0) < TURTLE_GONE then have = have + 1 end
  end
  for _, o in ipairs(F.orders) do
    if o.role == role and o.state == "built" and not o.arrived then have = have + 1 end
  end
  return have
end

-- ------------------------------------------------------------------ tick --
-- Periodic work: drain input chests, queue jobs for rules below their minimum,
-- order turtles for fleet targets that aren't met.
local function jobActive(F, id)
  for _, j in ipairs(F.queue) do if j.id == id then return true end end
  for _, t in pairs(F.turtles) do
    if t.job and t.job.id == id and t.state ~= "idle" and t.state ~= "done" then return true end
  end
  return false
end

local DISMANTLE_TIMEOUT = 3600 -- seconds before giving up on a turtle to take apart

function M.tick(F)
  freshStorage(F)
  local S = F.deps.storage
  defragStep(F)
  if F.dismantle and now(F) - (F.dismantle.since or 0) > DISMANTLE_TIMEOUT then
    F.note = ("Gave up taking %s apart (it didn't come)"):format(label(F, F.dismantle.id))
    F.dismantle = nil
  end
  if not M.marking(F) then M.serviceChests(F) end -- (a marker must stay put)
  local stock = S.list()
  local cfgp = F.cfg.production or {}
  if cfgp.enabled ~= false and S.furnaces then
    F.prod.report = {}
    F.prod.furnaces = production.smelt(S, cfgp, F.hammer, stock, F.tinyFuel, F.prod.report)
    stock = S.list()
  end
  -- a craft job whose assembler went silent
  if F.craft and now(F) - (F.craft.lastSeen or 0) > BUILD_TIMEOUT then
    F.note = "Craft " .. F.craft.item .. ": assembler silent"
    endCraft(F, nil)
  end
  -- a rule's job that nobody has any more (its "done" got lost, the turtle is
  -- gone) must not block the rule forever
  for i, id in pairs(F.ruleJobs) do
    if not jobActive(F, id) then F.ruleJobs[i] = nil end
  end
  -- ores held for a job nobody has any more (its turtle gone, its "done" lost)
  for id in pairs(oremap.holders(F.map)) do
    if not jobActive(F, id) then oremap.release(F.map, id); F.mapDirty = true end
  end
  -- a build whose assembler went silent
  local o = buildingOrder(F)
  if o and now(F) - (o.lastSeen or 0) > BUILD_TIMEOUT then
    failOrder(F, o, "assembler silent for " .. BUILD_TIMEOUT .. "s")
  end
  for i, rule in ipairs(F.cfg.rules) do
    if M.stockOf(stock, rule.item) < rule.min and not F.ruleJobs[i] then
      local job = copy(rule.job)
      job.rule = i
      M.queueJob(F, job)
      F.ruleJobs[i] = job.id
      F.note = ("Low on %s: queued %s"):format(rule.item, M.jobText(job))
    end
  end
  if now(F) - (F.lastFail or -math.huge) >= RETRY_AFTER and (F.failStreak or 0) < MAX_FAILS then
    local open = {}
    for _, ord in ipairs(F.orders) do
      if ord.state == "queued" or ord.state == "building" then open[ord.role] = true end
    end
    for role, want in pairs(F.cfg.fleet) do
      local have = M.fleetCount(F, role)
      if have < want and not open[role] and not next(M.missingParts(F, role)) then
        M.orderTurtle(F, role)
        break
      end
    end
  end
  return stock
end

return M
