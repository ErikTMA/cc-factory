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

local M = {}

M.QTY = { 8, 16, 32, 64, 128, 256, 0 } -- job sizes on the monitor; 0 = no limit

local PERSIST = { "turtles", "queue", "nextJobId", "nextSector", "totals", "counted",
                  "orders", "nextOrderId", "homesTaken", "ruleJobs", "lastFail", "failStreak",
                  "hammer", "craft", "nextCraftId", "crafted" }

local CRAFT_PAUSE = 60      -- seconds without craft jobs after one failed

local BUILD_TIMEOUT = 600   -- seconds of assembler silence before a build is given up
local TURTLE_GONE = 7200    -- seconds unseen before a turtle stops counting for the fleet
local MAX_FAILS = 3         -- failed builds in a row before automatic ordering pauses

-- Default config: base.lua writes it to /factory.cfg on first start; edit it there.
M.DEFAULT_CONFIG = {
  -- Y of the assembler's build spot; new turtles' home slots are at this level
  build = { y = 64 },
  -- home slots for new turtles, offsets in blocks from the build spot (east /
  -- north, negative = west / south) and the way the turtle faces at home (its
  -- chest is behind it). Build the slots (chest + room in front) yourself.
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
}

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
    totals = {}, counted = {}, orders = {}, nextOrderId = 1, homesTaken = {},
    ruleJobs = {}, selected = nil, note = "Ready",
    hammer = config.production and config.production.hammer or false,
    craft = nil, nextCraftId = 1, crafted = {}, prod = { furnaces = 0, missing = {} },
  }
  return F
end

function M.snapshot(F)
  local t = {}
  for _, k in ipairs(PERSIST) do t[k] = F[k] end
  return t
end

function M.restore(F, t)
  if type(t) ~= "table" then return end
  for _, k in ipairs(PERSIST) do if t[k] ~= nil then F[k] = t[k] end end
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

-- Storage contents, counting only usable tools.
local function usableStock(F)
  local S = F.deps.storage
  local stock = S.list()
  for item in pairs(stock) do
    if item:find("pickaxe") and S.countWhere then stock[item] = S.countWhere(item, usableTool) end
  end
  return stock
end

-- Items missing from storage for one turtle of `role` ({} when complete).
function M.missingParts(F, role)
  local missing = {}
  local stock = usableStock(F)
  for item, n in pairs(C.parts(role, F.cfg.forester.sapling)) do
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

function M.orderTurtle(F, role, manual)
  if manual then F.failStreak = 0 end
  local o = { id = F.nextOrderId, role = role, state = "queued", step = 0 }
  F.nextOrderId = F.nextOrderId + 1
  F.orders[#F.orders + 1] = o
  F.note = ("Ordered a %s turtle (#%d)"):format(role, o.id)
  return o
end

-- Empty the supply chest into storage, then deliver `items` ({[item]=n}).
local function stage(F, items)
  local S = F.deps.storage
  local supply = S.supply()
  if not supply then return false, "no supply chest (trapped chest) on the network" end
  S.store(supply)
  for item, n in pairs(items) do
    local accept = item:find("pickaxe") and usableTool or nil
    local moved = S.send(supply, item, n, accept)
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
  local taken = F.homesTaken[o.role] or {}
  for i, owner in pairs(taken) do
    if owner == "order:" .. o.id then taken[i] = nil end -- free its home slot
  end
  local supply = F.deps.storage.supply()
  if supply then F.deps.storage.store(supply) end
  F.note = ("Build #%d failed: %s"):format(o.id, why)
end

-- First free home slot for `role`, claimed for `owner` (a turtle id, or
-- "order:<n>" while the turtle is still being built). nil if none is free.
local function claimHome(F, role, owner)
  F.homesTaken[role] = F.homesTaken[role] or {}
  local taken = F.homesTaken[role]
  for i, slot in ipairs(F.cfg.homes[role] or {}) do
    if taken[i] == nil or taken[i] == owner then
      taken[i] = owner
      return i, slot
    end
  end
end

-- The assembler's side of a build: it reports, we stage and say what's next.
-- ------------------------------------------------------------- crafting --
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

-- Plan the next craft for the assembler; stage its inputs; nil if nothing to do.
local function startCraft(F, from)
  local cfgp = F.cfg.production or {}
  if cfgp.enabled == false or now(F) < (F.craftPauseUntil or 0) then return nil end
  local stock = usableStock(F)
  local wanted = production.wantedForFleet(shortRoles(F), F.cfg.forester.sapling)
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
  local ok, why = stage(F, items)
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
  local supply = F.deps.storage.supply()
  if supply then F.deps.storage.store(supply) end
  if made and c then F.crafted[c.item] = (F.crafted[c.item] or 0) + made end
  F.craft = nil
end

local handleAssemblerStep

-- Every reply in a build is remembered: if it got lost (the assembler gave up
-- waiting) and the assembler reports idle, it gets the same reply again.
local function handleAssembler(F, from, msg)
  -- a craft job in flight
  local c = F.craft
  if c and c.assembler == from then
    c.lastSeen = now(F)
    if msg.state == "crafted" and msg.craft == c.id then
      endCraft(F, msg.made or (c.sets * 1))
      return { type = "ok" }
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
    local index, slot = claimHome(F, o.role, "order:" .. o.id)
    if not index then
      F.note = ("No free %s home slot: add one to factory.cfg"):format(o.role)
      return { type = "ok" }
    end
    o.state, o.assembler, o.step, o.home, o.lastSeen = "building", from, 1, index, now(F)
    o.install = { role = o.role, order = o.id, trees = F.cfg.forester.trees,
                  wait = F.cfg.forester.wait, slot = copy(slot), homeY = F.cfg.build.y }
    F.deps.writeInstall(copy(o.install))
    local steps = C.buildSteps(o.role)
    local ok, why = stage(F, stepItems(steps[1]))
    if not ok then failOrder(F, o, why); return { type = "ok" } end
    F.note = ("Building a %s turtle (#%d)"):format(o.role, o.id)
    return stepReply(o, steps[1], 1)
  end
  if not o or o.state ~= "building" or msg.order ~= o.id then return { type = "ok" } end
  local steps = C.buildSteps(o.role)
  if msg.state == "crafted" and msg.step == o.step then
    if o.step < #steps then
      o.step = o.step + 1
      local ok, why = stage(F, stepItems(steps[o.step]))
      if not ok then failOrder(F, o, why); return { type = "abort" } end
      return stepReply(o, steps[o.step], o.step)
    end
    o.step = "place"
    return { type = "place", order = o.id }
  elseif msg.state == "placed" then
    local items, list = {}, {}
    local stock = F.deps.storage.list()
    for _, l in ipairs(C.ROLES[o.role].loadout) do
      local item = l[1] == "@sapling" and F.cfg.forester.sapling or l[1]
      if not l.optional or (stock[item] or 0) >= l[2] then
        items[item] = (items[item] or 0) + l[2]
        list[#list + 1] = { item, l[2] }
      end
    end
    local ok, why = stage(F, items)
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
  local i, slot = claimHome(F, role, from)
  if i then
    F.note = ("%s goes to %s home %d"):format(label(F, from), role, i)
    return { type = "home", home = copy(slot), y = F.cfg.build.y, index = i }
  end
  F.note = ("No free %s home slot for %s: add one to factory.cfg"):format(role, label(F, from))
  return { type = "wait" }
end

-- ------------------------------------------------------------- protocol --
-- Turtles always talk first, while at home; the reply says what to do next.
function M.handle(F, from, msg)
  if type(msg) ~= "table" or msg.type ~= "status" then return nil end
  local prev = F.turtles[from] or {}
  F.turtles[from] = { id = from, label = msg.label, role = msg.role or prev.role or "miner",
                      state = msg.state, fuel = msg.fuel, mined = msg.mined or 0,
                      job = msg.job, seen = now(F), version = msg.version,
                      delivered = msg.total or prev.delivered }
  local t = F.turtles[from]
  local reply = { type = "ok" }

  -- a built turtle reporting for the first time: its order is done, and its
  -- reserved home slot now belongs to it. (`buildOrder` is the order a turtle
  -- was built by; the assembler's `order` is the build it is working on.)
  if msg.buildOrder then
    for _, o in ipairs(F.orders) do
      if o.id == msg.buildOrder and not o.arrived then
        o.arrived = true
        local taken = F.homesTaken[o.role] or {}
        if o.home and taken[o.home] == "order:" .. o.id then taken[o.home] = from end
      end
    end
  end

  if msg.state == "new" then
    reply = assignHome(F, from, msg)
  elseif t.role == "assembler" then
    reply = handleAssembler(F, from, msg)
  elseif t.role == "forester" then
    if msg.state == "resting" and msg.delivered then
      F.totals.logs = (F.totals.logs or 0) + msg.delivered
    end
  else -- miner
    if msg.state == "done" and msg.job and msg.job.id and not F.counted[msg.job.id] then
      F.counted[msg.job.id] = true
      local k = oreKey(msg.job)
      F.totals[k] = (F.totals[k] or 0) + (msg.mined or 0)
      if msg.job.rule then F.ruleJobs[msg.job.rule] = nil end
      F.note = ("%s finished: %d %s"):format(label(F, from), msg.mined or 0, k)
    end
    if msg.state == "no fuel" and msg.job then
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
        reply = { type = "job", job = job }
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

function M.tick(F)
  local S = F.deps.storage
  S.drainInputs()
  local stock = S.list()
  local cfgp = F.cfg.production or {}
  if cfgp.enabled ~= false and S.furnaces then
    F.prod.furnaces = production.smelt(S, cfgp, F.hammer, stock)
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
