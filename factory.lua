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

local M = {}

M.QTY = { 8, 16, 32, 64, 128, 256, 0 } -- job sizes on the monitor; 0 = no limit

local PERSIST = { "turtles", "queue", "nextJobId", "nextSector", "totals", "counted",
                  "orders", "nextOrderId", "homesTaken", "ruleJobs", "lastFail" }

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
  job = { lanes = 3, length = 64 },
}

local function copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return c
end

function M.new(config, deps)
  local first = C.PRESETS[1]
  local F = {
    cfg = config, deps = deps,
    sel = { ore = first.name, y = first.y, onlyThis = true, qty = 3 },
    turtles = {}, queue = {}, stopFor = {}, nextJobId = 1, nextSector = {},
    totals = {}, counted = {}, orders = {}, nextOrderId = 1, homesTaken = {},
    ruleJobs = {}, selected = nil, note = "Ready",
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
local function activeOrder(F)
  for _, o in ipairs(F.orders) do
    if o.state == "queued" or o.state == "building" then return o end
  end
end

-- Items missing from storage for one turtle of `role` ({} when complete).
function M.missingParts(F, role)
  local missing = {}
  local stock = F.deps.storage.list()
  for item, n in pairs(C.parts(role, F.cfg.forester.sapling)) do
    if (stock[item] or 0) < n then missing[item] = n - (stock[item] or 0) end
  end
  return missing
end

function M.orderTurtle(F, role)
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
    local moved = S.send(supply, item, n)
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
local function handleAssembler(F, from, msg)
  local o = activeOrder(F)
  if msg.state == "failed" and o and o.state == "building" and o.assembler == from then
    failOrder(F, o, msg.reason or "assembler failed")
    return { type = "ok" }
  end
  if msg.state == "idle" then
    if not o or o.state ~= "queued" then return { type = "ok" } end
    if next(M.missingParts(F, o.role)) then return { type = "ok" } end
    -- the new turtle gets its home slot with its install data: it can fly there
    -- without talking first (there may be no modem at the build spot)
    local index, slot = claimHome(F, o.role, "order:" .. o.id)
    if not index then
      F.note = ("No free %s home slot: add one to factory.cfg"):format(o.role)
      return { type = "ok" }
    end
    o.state, o.assembler, o.step, o.home = "building", from, 1, index
    F.deps.writeInstall({ role = o.role, order = o.id, trees = F.cfg.forester.trees,
                          wait = F.cfg.forester.wait, slot = copy(slot), homeY = F.cfg.build.y })
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
    o.state = "built"
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
    if msg.state == "idle" or msg.state == "done" then
      F.stopFor[from] = nil
      if msg.state == "idle" and #F.queue > 0 then
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
     and not (t.role == "assembler" and activeOrder(F) and activeOrder(F).state == "building") then
    reply.update = { version = D.version, files = D.files }
  end
  return reply
end

-- ------------------------------------------------------------------ tick --
-- Periodic work: drain input chests, queue jobs for rules below their minimum,
-- order turtles for fleet targets that aren't met.
function M.tick(F)
  local S = F.deps.storage
  S.drainInputs()
  local stock = S.list()
  for i, rule in ipairs(F.cfg.rules) do
    if (stock[rule.item] or 0) < rule.min and not F.ruleJobs[i] then
      local job = copy(rule.job)
      job.rule = i
      M.queueJob(F, job)
      F.ruleJobs[i] = job.id
      F.note = ("Low on %s: queued %s"):format(rule.item, M.jobText(job))
    end
  end
  if not activeOrder(F) and now(F) - (F.lastFail or -math.huge) >= RETRY_AFTER then
    for role, want in pairs(F.cfg.fleet) do
      local have = 0
      for _, t in pairs(F.turtles) do if t.role == role then have = have + 1 end end
      for _, o in ipairs(F.orders) do if o.role == role and o.state == "built" and not o.arrived then have = have + 1 end end
      if have < want and not next(M.missingParts(F, role)) then
        M.orderTurtle(F, role)
        break
      end
    end
  end
  return stock
end

return M
