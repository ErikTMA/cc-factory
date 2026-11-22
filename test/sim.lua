-- Offline harness: runs oreminer.lua unmodified against a simulated world,
-- turtle, Geo Scanner, fs and textutils. Usage: lua sim.lua <path/to/oreminer.lua>
local PROGRAM = arg[1] or "../oreminer.lua"
local DIR = PROGRAM:match("^(.*)/[^/]*$") or "."
local function readAll(path) return assert(io.open(path)):read("*a") end
local BASE_SRC = readAll(DIR .. "/base.lua")
local FACTORY_SRC = readAll(os.getenv("FACTORY") or (DIR .. "/factory.lua"))
MODULES_EXTRA = { factory = FACTORY_SRC, production = readAll(DIR .. "/production.lua"),
                  recipes = readAll(DIR .. "/recipes.lua"), homes = readAll(DIR .. "/homes.lua"),
                  oremap = readAll(DIR .. "/oremap.lua") }
local MODULES = { oreconf = readAll(DIR .. "/oreconf.lua"), tmove = readAll(DIR .. "/tmove.lua"),
                  link = readAll(DIR .. "/link.lua"), nav = readAll(DIR .. "/nav.lua") }

-- yield to the scheduler when running as one of several coroutines
local function yieldIfCo()
  local _, main = coroutine.running()
  if not main and coroutine.running() then coroutine.yield() end
end

local failures = 0
local function check(cond, msg)
  if cond then print("  ok   " .. msg) else print("  FAIL " .. msg); failures = failures + 1 end
end

local DIRS = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } } -- dx, dz per heading

local function newWorld(seed, startHeading, opts)
  opts = opts or {}
  math.randomseed(seed)
  local W = { blocks = {}, chest = {}, ores = 0 }
  local function k(x, y, z) return x .. "," .. y .. "," .. z end
  function W.get(x, y, z) return W.blocks[k(x, y, z)] end
  function W.set(x, y, z, v) W.blocks[k(x, y, z)] = v end
  local SPAN = opts.span or 90
  local YMIN, YMAX = opts.ymin or -10, opts.ymax or 10
  for x = -SPAN, SPAN do for y = YMIN, YMAX do for z = -SPAN, SPAN do
    local r = math.random()
    local name = "minecraft:stone"
    if r < 0.004 then name = "minecraft:diamond_ore"
    elseif r < 0.012 then name = "minecraft:iron_ore"
    elseif r < 0.02 then name = "minecraft:coal_ore"
    elseif r < 0.05 then name = "minecraft:cobblestone" end
    if y == YMIN then name = "minecraft:bedrock" end
    W.set(x, y, z, name)
  end end end
  -- start cell open, chest behind the turtle
  local d = DIRS[startHeading]
  W.set(0, 0, 0, nil)
  W.set(0 - d[1], 0, 0 - d[2], "minecraft:chest") -- 0 - x avoids Lua "-0" keys
  if opts.protectedTurtle then W.set(5, 0, 0, "computercraft:turtle_advanced") end
  W.chests = {}
  -- extra homes: open cell + chest behind
  function W.addHome(x, z, h)
    local dd = DIRS[h]
    W.set(x, 0, z, nil)
    W.set(x - dd[1], 0, z - dd[2], "minecraft:chest")
  end
  return W
end

local function oreName(n) return n and n:find("_ore$") ~= nil end
local oremap = assert(load(MODULES_EXTRA.oremap, "oremap"))()

local function newTurtle(W, startHeading, fuel, start)
  start = start or { x = 0, y = 0, z = 0 }
  local T = { x = start.x, y = start.y, z = start.z, start = start, h = startHeading, fuel = fuel,
              sel = 1, inv = {}, moves = 0,
              left = "advancedperipherals:geo_scanner", right = "minecraft:diamond_pickaxe" }
  local function front() local d = DIRS[T.h]; return T.x + d[1], T.y, T.z + d[2] end
  local function addItem(name)
    for i = 1, 16 do local s = T.inv[i]; if s and s.name == name and s.count < 64 then s.count = s.count + 1; return true end end
    for i = 1, 16 do if not T.inv[i] then T.inv[i] = { name = name, count = 1 }; return true end end
    return true -- full: item dropped on floor (like CC)
  end
  local function drops(name)
    if name == "minecraft:coal_ore" then return "minecraft:coal" end
    if name == "minecraft:stone" then return "minecraft:cobblestone" end
    return name
  end
  local function dig(x, y, z)
    local b = W.get(x, y, z)
    if not b then return false end
    if b == "minecraft:bedrock" or b:find("^computercraft:") or b == "minecraft:chest" then return false end
    W.set(x, y, z, nil); addItem(drops(b))
    if W.onDig then W.onDig(x, y, z, b) end
    if oreName(b) then W.mined = (W.mined or 0) + 1 end
    W.dug = W.dug or {}
    W.dug[b] = (W.dug[b] or 0) + 1
    return true
  end
  local function move(nx, ny, nz)
    if W.get(nx, ny, nz) then return false end
    if T.fuel < 1 then return false end
    T.fuel = T.fuel - 1; T.x, T.y, T.z = nx, ny, nz; T.moves = T.moves + 1
    if T.onMove then T.onMove() end -- may throw: stopped after the move, before the save
    yieldIfCo()
    return true
  end
  local api = {}
  function api.forward() return move(front()) end
  function api.back() local d = DIRS[T.h]; return move(T.x - d[1], T.y, T.z - d[2]) end
  function api.up() return move(T.x, T.y + 1, T.z) end
  function api.down() return move(T.x, T.y - 1, T.z) end
  function api.turnLeft() T.h = (T.h + 3) % 4; if T.onTurn then T.onTurn() end; return true end
  function api.turnRight() T.h = (T.h + 1) % 4; if T.onTurn then T.onTurn() end; return true end
  function api.dig() return dig(front()) end
  function api.digUp() return dig(T.x, T.y + 1, T.z) end
  function api.digDown() return dig(T.x, T.y - 1, T.z) end
  function api.detect() return W.get(front()) ~= nil end
  function api.detectUp() return W.get(T.x, T.y + 1, T.z) ~= nil end
  function api.detectDown() return W.get(T.x, T.y - 1, T.z) ~= nil end
  local function insp(b) if b then return true, { name = b } end return false, "No block to inspect" end
  function api.inspect() return insp(W.get(front())) end
  function api.inspectUp() return insp(W.get(T.x, T.y + 1, T.z)) end
  function api.inspectDown() return insp(W.get(T.x, T.y - 1, T.z)) end
  function api.attack() return false end
  api.attackUp, api.attackDown = api.attack, api.attack
  function api.getFuelLevel() return T.fuel end
  function api.getFuelLimit() return 20000 end
  function api.select(i) T.sel = i; return true end
  function api.getItemCount(i) return T.inv[i] and T.inv[i].count or 0 end
  function api.getItemDetail(i) local s = T.inv[i]; return s and { name = s.name, count = s.count } or nil end
  function api.refuel(n)
    local s = T.inv[T.sel]
    if not s or s.name ~= "minecraft:coal" then return false end
    if n == 0 then return true end
    n = n or s.count
    T.fuel = T.fuel + 80 * n; s.count = s.count - n
    if s.count <= 0 then T.inv[T.sel] = nil end
    return true
  end
  function api.drop(n)
    local s = T.inv[T.sel]; if not s then return false end
    n = math.min(n or s.count, s.count)
    local fx, fy, fz = front()
    if W.get(fx, fy, fz) == "minecraft:chest" then
      W.chest[s.name] = (W.chest[s.name] or 0) + n
      local ck = fx .. "," .. fz
      W.chests[ck] = W.chests[ck] or {}
      W.chests[ck][s.name] = (W.chests[ck][s.name] or 0) + n
    end
    s.count = s.count - n
    if s.count <= 0 then T.inv[T.sel] = nil end
    return true
  end
  -- take one stack from the chest in front (first item by name), into the
  -- selected slot or the next free one
  function api.suck()
    local fx, fy, fz = front()
    if W.get(fx, fy, fz) ~= "minecraft:chest" then return false end
    local c = W.chests[fx .. "," .. fz] or {}
    local names = {}
    for name, n in pairs(c) do if n > 0 then names[#names + 1] = name end end
    if #names == 0 then return false end
    table.sort(names)
    local item = names[1]
    local slot
    for k = 0, 15 do local i = (T.sel - 1 + k) % 16 + 1; if not T.inv[i] then slot = i; break end end
    if not slot then return false end
    local n = math.min(64, c[item])
    c[item] = c[item] - n
    W.chest[item] = (W.chest[item] or 0) - n
    T.inv[slot] = { name = item, count = n }
    return true
  end
  function api.dropUp() T.inv[T.sel] = nil; return true end
  local function equip(side)
    local cur, new = T[side], T.inv[T.sel]
    T[side] = new and new.name or nil
    T.inv[T.sel] = cur and { name = cur, count = 1 } or nil
    T.swaps = (T.swaps or 0) + 1
    return true
  end
  function api.equipLeft() return equip("left") end
  function api.equipRight() return equip("right") end
  local scanner = {}
  local lastScan = -1
  -- AP 0.8.2a: scanBlocks(radius); there is no `scan` (seen live)
  function scanner.scanBlocks(r)
    local out = {}
    for x = -r, r do for y = -r, r do for z = -r, r do
      local b = W.get(T.x + x, T.y + y, T.z + z)
      if b then
        local tags = {}
        if oreName(b) then tags = { "c:ores", "c:ores/" .. b:match(":(.-)_ore") } end
        out[#out + 1] = { name = b, tags = (not W.untagged) and tags or nil, x = x, y = y, z = z }
      end
    end end end
    W.scans = (W.scans or 0) + 1
    return out
  end
  return T, api, scanner
end

local PTYPE = { ["advancedperipherals:geo_scanner"] = "geo_scanner", -- AP 0.8.2a type name
                ["computercraft:wireless_modem_normal"] = "modem",
                ["computercraft:wireless_modem_advanced"] = "modem" }

-- Shared rednet bus: turtles broadcast, the base (a lib instance) answers.
local function newBus(base, B)
  return { base = base, B = B, inbox = {}, log = {} }
end

local function makeEnv(T, api, scanner, files, bus, id)
  local env = setmetatable({}, { __index = _G })
  env.turtle = api
  env.peripheral = {
    getType = function(side) return PTYPE[T and T[side] or ""] end,
    find = function(t)
      if t == "geo_scanner" and T and (PTYPE[T.left or ""] == t or PTYPE[T.right or ""] == t) then return scanner end
    end,
    -- what is equipped on that side, as CC wraps it
    wrap = function(side)
      local t = PTYPE[T and T[side] or ""]
      if t == "geo_scanner" then return scanner end
      if t then return {} end
    end,
  }
  env.os = setmetatable({ getComputerLabel = function() return T and T.label end,
                          epoch = function() return (bus and bus.clock or 0) * 1000 end },
                        { __index = os })
  env.require = function(name)
    local src = MODULES[name] or MODULES_EXTRA[name]
    return assert(load(assert(src, name), name, "t", env))()
  end
  env.colors = setmetatable({}, { __index = function(_, k) return k end })
  env.rednet = {
    open = function(side) assert(PTYPE[T[side] or ""] == "modem", "rednet.open on " .. tostring(side)); T.rednetOpen = true end,
    close = function() T.rednetOpen = false end,
    send = function(to, msg) return env.rednet.broadcast(msg) end,
    broadcast = function(msg)
      assert(T.rednetOpen, "broadcast without open modem")
      -- like rednet: each side gets its own copy (messages are serialized)
      local function copy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, x in pairs(v) do c[copy(k)] = copy(x) end
        return c
      end
      msg = copy(msg)
      -- out of wireless reach: the base never hears it
      if bus.deaf and bus.deaf(id, msg) then bus.log[#bus.log + 1] = { from = id, msg = msg, lost = true }; return end
      local reply = bus.base.handleMessage(bus.B, id, copy(msg))
      bus.log[#bus.log + 1] = { from = id, msg = msg, reply = copy(reply) }
      if reply then bus.inbox[id] = bus.inbox[id] or {}; table.insert(bus.inbox[id], copy(reply)) end
      if bus.onMessage then bus.onMessage(id, msg) end
    end,
    receive = function()
      local q = bus.inbox[id]
      if q and #q > 0 then return bus.baseId or 0, table.remove(q, 1) end
      return nil
    end,
  }
  env.sleep = function() yieldIfCo() end
  env.write = function() end
  env.read = function() return env.__answer end
  env.print = function(...)
    if bus then
      bus.prints = bus.prints or {}
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
      bus.prints[#bus.prints + 1] = table.concat(parts, " ")
    end
    if os.getenv("VERBOSE") then print(...) end
  end
  local function ser(v)
    if type(v) == "table" then
      local p = {}
      for kk, vv in pairs(v) do p[#p + 1] = "[" .. ser(kk) .. "]=" .. ser(vv) end
      return "{" .. table.concat(p, ",") .. "}"
    elseif type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
  end
  env.textutils = { serialize = ser, unserialize = function(s) return load("return " .. s)() end }
  env.fs = {
    exists = function(p) return files[p] ~= nil end,
    open = function(p, mode)
      if mode == "w" then
        local buf = {}
        return { write = function(s) buf[#buf + 1] = s end, close = function() files[p] = table.concat(buf) end }
      end
      return { readAll = function() return files[p] end, close = function() end }
    end,
  }
  return env
end

local src = assert(io.open(PROGRAM)):read("*a")

-- The base's dispatcher (factory.lua) with fake storage and the bus clock,
-- wrapped in the small API the scenarios use.
local function loadBase(files, bus)
  local env = makeEnv(nil, nil, nil, files, bus, nil)
  local factory = assert(load(FACTORY_SRC, "factory", "t", env))()
  local UI = assert(load(BASE_SRC, "base", "t", env))("--lib")
  local Base = setmetatable({}, { __index = factory })
  function Base.new()
    local cfg = {}
    for k, v in pairs(factory.DEFAULT_CONFIG) do cfg[k] = v end
    cfg.job = { lanes = 3, length = 64 }
    local stock = {}
    local F = factory.new(cfg, {
      now = function() return bus.clock end,
      storage = { kind = "fake", list = function() return stock end, drainInputs = function() return 0 end,
                  supply = function() return nil end, store = function() return 0 end, send = function() return 0 end },
      writeInstall = function() end,
    })
    return F
  end
  function Base.handleMessage(F, from, msg) return factory.handle(F, from, msg) end
  function Base.draw(F, out) local ui = { F = F, tab = "TURTLES", buttons = {} }; UI.draw(ui, out) end
  return Base
end

local function runProgram(env, ...)
  local chunk = assert(load(src, "oreminer", "t", env))
  return pcall(chunk, ...)
end

local function oresWithin(W, lanes, length, h)
  -- count ores the run *should* reach: within scan radius of lane scan points
  return nil
end

-- Scenario 1: full run for every start heading
for h = 0, 3 do
  print(("scenario: fresh run, facing %s"):format(({ [0] = "north", "east", "south", "west" })[h]))
  local W = newWorld(42 + h, h)
  local T, api, sc = newTurtle(W, h, 0)
  T.inv[1] = { name = "minecraft:coal", count = 64 }
  local files = {}
  local ok, err = runProgram(makeEnv(T, api, sc, files), "lanes=2", "length=32")
  check(ok, "program completed (" .. tostring(err) .. ")")
  check(T.x == 0 and T.y == 0 and T.z == 0, ("back home (at %d,%d,%d)"):format(T.x, T.y, T.z))
  check(T.h == h, "facing original heading")
  check((W.mined or 0) > 20, "mined ores: " .. tostring(W.mined))
  local diamonds = W.chest["minecraft:diamond_ore"] or 0
  check(diamonds > 0, "diamond ore in chest: " .. diamonds)
  -- every ore within the scanned corridor is gone
  local d, r = DIRS[h], DIRS[(h + 1) % 4]
  local left = 0
  for lane = 0, 1 do for p = 0, 32, 16 do
    local along = (lane % 2 == 0) and p or (32 - p)
    local cx, cz = d[1] * along + r[1] * lane * 16, d[2] * along + r[2] * lane * 16
    for x = -8, 8 do for y = -8, 8 do for z = -8, 8 do
      if oreName(W.get(cx + x, y, cz + z)) then left = left + 1 end
    end end end
  end end
  check(left == 0, "no ores left inside scanned cubes: " .. left)
  local state = textutils and nil
  check(files["oreminer.state"] and files["oreminer.state"]:find("done") ~= nil, "state marked done")
end

-- Scenario 2: interrupted run resumes and finishes
print("scenario: interrupt mid-run, then resume")
do
  local W = newWorld(7, 1)
  local T, api, sc = newTurtle(W, 1, 0)
  T.inv[1] = { name = "minecraft:coal", count = 64 }
  local files = {}
  local env = makeEnv(T, api, sc, files)
  local budget = 150
  local realForward = api.forward
  api.forward = function()
    budget = budget - 1
    if budget == 0 then error("CHUNK UNLOADED") end
    return realForward()
  end
  local ok, err = runProgram(env, "lanes=2", "length=32")
  check(not ok and tostring(err):find("CHUNK UNLOADED"), "first run interrupted")
  api.forward = realForward
  ok, err = runProgram(makeEnv(T, api, sc, files), "resume")
  check(ok, "resume completed (" .. tostring(err) .. ")")
  check(T.x == 0 and T.y == 0 and T.z == 0, ("back home after resume (%d,%d,%d)"):format(T.x, T.y, T.z))
  check((W.chest["minecraft:diamond_ore"] or 0) > 0, "diamonds delivered after resume")
end

-- Scenario 3: inventory fills up -> service trips to the chest
print("scenario: small inventory budget forces trips home")
do
  local W = newWorld(99, 2)
  local T, api, sc = newTurtle(W, 2, 0)
  T.inv[1] = { name = "minecraft:coal", count = 64 }
  for i = 2, 14 do T.inv[i] = { name = "minecraft:dirt_filler_" .. i, count = 64 } end -- non-junk filler
  local files = {}
  local ok, err = runProgram(makeEnv(T, api, sc, files), "lanes=3", "length=48")
  check(ok, "completed with service trips (" .. tostring(err) .. ")")
  check((W.chest["minecraft:dirt_filler_2"] or 0) == 64, "filler unloaded into chest")
  check((W.chest["minecraft:iron_ore"] or 0) > 0, "iron ore delivered")
end

-- Scenario 4: never digs a protected block (another turtle in the path)
print("scenario: protected block in the way")
do
  local W = newWorld(5, 1, { protectedTurtle = true })
  local T, api, sc = newTurtle(W, 1, 0)
  T.inv[1] = { name = "minecraft:coal", count = 64 }
  local ok, err = runProgram(makeEnv(T, api, sc, {}), "lanes=1", "length=16")
  check(ok, "completed (" .. tostring(err) .. ")")
  check(W.get(5, 0, 0) == "computercraft:turtle_advanced", "other turtle untouched")
end

-- Scenario 5: go down to a target level, mine only one ore kind, come back up the shaft
print("scenario: preset diamond from 40 blocks above, only diamonds")
do
  local W = newWorld(11, 0, { span = 40, ymin = -60, ymax = 6 })
  local T, api, sc = newTurtle(W, 0, 0)
  T.inv[1] = { name = "minecraft:coal", count = 64 }
  local files = {}
  -- turtle stands at Y -18; diamond preset is -58, i.e. 40 blocks down
  local ok, err = runProgram(makeEnv(T, api, sc, files), "diamond", "at=-18", "lanes=2", "length=32")
  check(ok, "completed (" .. tostring(err) .. ")")
  check(T.x == 0 and T.y == 0 and T.z == 0, ("back home (%d,%d,%d)"):format(T.x, T.y, T.z))
  check((W.chest["minecraft:diamond_ore"] or 0) > 0, "diamonds: " .. tostring(W.chest["minecraft:diamond_ore"]))
  -- iron only gets dug when it is in the way, never targeted
  local iron, dia = W.chest["minecraft:iron_ore"] or 0, W.chest["minecraft:diamond_ore"] or 0
  check(iron * 4 < dia, ("iron only incidental: %d iron vs %d diamonds"):format(iron, dia))
  -- one shaft: no dug cells off the x=0,z=0 column between y=-8 and y=-32
  local stray = 0
  for x = -40, 40 do for y = -31, -8 do for z = -40, 40 do
    if not W.get(x, y, z) and not (x == 0 and z == 0) then stray = stray + 1 end
  end end end
  local ys = {}
  for x = -40, 40 do for y = -31, -8 do for z = -40, 40 do
    if not W.get(x, y, z) and not (x == 0 and z == 0) then ys[y] = (ys[y] or 0) + 1 end
  end end end
  for y = -31, -8 do if ys[y] then print("    stray at y", y, ys[y]) end end
  check(stray == 0, "travels through a single shaft (stray holes: " .. stray .. ")")
  -- diamonds near the mining level are gone (lane 0 first scan cube at y=-40)
  local left = 0
  for x = -8, 8 do for y = -48, -32 do for z = -8, 8 do
    if W.get(x, y, z) == "minecraft:diamond_ore" then left = left + 1 end
  end end end
  check(left == 0, "no diamonds left around the shaft bottom: " .. left)
end

-- Scenario 6: y= with interactive Y prompt
print("scenario: y= asks for current Y")
do
  local W = newWorld(3, 1, { span = 30, ymin = -30, ymax = 6 })
  local T, api, sc = newTurtle(W, 1, 0)
  T.inv[1] = { name = "minecraft:coal", count = 64 }
  local env = makeEnv(T, api, sc, {})
  env.__answer = "64"
  local ok, err = runProgram(env, "y=44", "lanes=1", "length=16")
  check(ok, "completed (" .. tostring(err) .. ")")
  check((W.chest["minecraft:iron_ore"] or 0) > 0, "mined all ores at Y 44 (20 below)")
end



print("scenario: server stops right after a move / a turn, before it was saved")
for _, what in ipairs({ "move", "turn" }) do
  local W = newWorld(31, 2)
  local T, api, sc = newTurtle(W, 2, 0)
  T.inv[1] = { name = "minecraft:coal", count = 64 }
  local files = {}
  local n = 0
  local hook = function() n = n + 1; if n == 137 then error("SERVER STOPPED") end end
  if what == "move" then T.onMove = hook else T.onTurn = hook end
  local ok, err = runProgram(makeEnv(T, api, sc, files), "lanes=2", "length=32")
  check(not ok and tostring(err):find("SERVER STOPPED"), what .. ": stopped mid-job")
  T.onMove, T.onTurn = nil, nil
  ok, err = runProgram(makeEnv(T, api, sc, files), "resume")
  check(ok, what .. ": resume completed (" .. tostring(err) .. ")")
  check(T.x == 0 and T.y == 0 and T.z == 0, ("%s: back exactly home (%d,%d,%d)"):format(what, T.x, T.y, T.z))
  check((W.chest["minecraft:iron_ore"] or 0) > 0, what .. ": unloaded into the chest, not the floor")
end

-- ---------------------------------------------------------------------------
-- Fleet: several turtles running `oreminer serve` as coroutines against the
-- real base.lua (loaded as a library) over a simulated rednet bus.
local function runFleet(W, homes, setup, opts)
  opts = opts or {}
  local baseFiles = {}
  local bus = { clock = 0 }
  local Base = loadBase(baseFiles, bus)
  local B = Base.new()
  bus.base, bus.B, bus.inbox, bus.log = Base, B, {}, {}
  local fleet = {}
  for i, h in ipairs(homes) do
    if i > 1 then W.addHome(h.x, h.z, h.h) end
    local T, api, sc = newTurtle(W, h.h, 0, { x = h.x, y = 0, z = h.z })
    T.label = "T" .. i
    T.inv[1] = { name = "minecraft:coal", count = opts.coal or 64 }
    T.inv[2] = { name = "computercraft:wireless_modem_normal", count = 1 }
    for j = 3, 2 + (opts.filler or 0) do T.inv[j] = { name = "filler:" .. j, count = 64 } end
    local files = {}
    local env = makeEnv(T, api, sc, files, bus, 100 + i)
    local co = coroutine.create(function()
      local chunk = assert(load(src, "oreminer", "t", env))
      chunk("serve", "at=0")
    end)
    fleet[i] = { T = T, co = co, files = files, id = 100 + i }
  end
  setup(Base, B)
  local maxBusy, quietTicks = {}, 0
  for tick = 1, 400000 do
    bus.clock = tick
    for _, f in ipairs(fleet) do
      if coroutine.status(f.co) ~= "dead" then
        local ok, err = coroutine.resume(f.co)
        if not ok then f.err = err end
      end
    end
    if opts.onTick then opts.onTick(Base, B, fleet, tick, bus) end
    for k, r in pairs(Base.summary(B)) do maxBusy[k] = math.max(maxBusy[k] or 0, r.turtles) end
    local allIdle = #B.queue == 0
    for _, f in ipairs(fleet) do
      local t = B.turtles[f.id]
      if not t or t.state ~= "idle" then allIdle = false end
    end
    quietTicks = allIdle and quietTicks + 1 or 0
    if quietTicks > 20 then break end
  end
  -- draw once to make sure the monitor UI renders with real data
  local screen = {}
  local mon = { getSize = function() return 60, 40 end, clear = function() end,
                setCursorPos = function(x, y) screen.y = y end, setTextColor = function() end,
                setBackgroundColor = function() end,
                write = function(t) screen[screen.y] = (screen[screen.y] or "") .. t end }
  Base.draw(B, mon)
  return B, fleet, maxBusy, screen, Base, bus
end

print("scenario: fleet of 3 turtles, 2 iron jobs + 1 diamond job from the base")
do
  local W = newWorld(21, 0, { span = 70, ymin = -40, ymax = 6 })
  local homes = { { x = 0, z = 0, h = 0 }, { x = 3, z = 0, h = 0 }, { x = 6, z = 0, h = 0 } }
  local B, fleet, maxBusy, screen = runFleet(W, homes, function(Base, B)
    B.cfg.job = { lanes = 2, length = 32 }
    Base.selectOre(B, "iron"); B.sel.y = -20; B.sel.qty = 3 -- 32
    Base.start(B); Base.start(B)
    Base.selectOre(B, "diamond"); B.sel.y = -20; B.sel.qty = 1 -- 8
    Base.start(B)
  end)
  for _, f in ipairs(fleet) do check(not f.err, "T" .. f.id .. " ran without error: " .. tostring(f.err)) end
  check(#B.queue == 0, "queue emptied")
  check((B.totals.iron or 0) == 64, "iron total exactly 2 x 32: " .. tostring(B.totals.iron))
  check((B.totals.diamond or 0) == 8, "diamond total exactly 8: " .. tostring(B.totals.diamond))
  check(maxBusy.iron == 2, "summary showed 2 turtles on iron at once: " .. tostring(maxBusy.iron))
  check(maxBusy.diamond == 1, "summary showed 1 turtle on diamond: " .. tostring(maxBusy.diamond))
  local jobsSeen, sectors = {}, {}
  for _, f in ipairs(fleet) do
    local st = load("return " .. f.files["oreminer.state"])()
    jobsSeen[st.job.id] = (jobsSeen[st.job.id] or 0) + 1
    sectors[#sectors + 1] = st.job.sector
    check(f.T.x == f.T.start.x and f.T.y == 0 and f.T.z == f.T.start.z, "T" .. f.id .. " back home")
  end
  check(jobsSeen[1] == 1 and jobsSeen[2] == 1 and jobsSeen[3] == 1, "each job ran on a different turtle")
  table.sort(sectors)
  check(sectors[1] == 0 and sectors[2] == 2 and sectors[3] == 4, "jobs got separate sectors: " .. table.concat(sectors, ","))
  local delivered = 0
  for _, c in pairs(W.chests) do delivered = delivered + (c["minecraft:iron_ore"] or 0) end
  check(delivered >= 64, "iron ore in the turtles' chests: " .. delivered)
  local joined = table.concat({ table.unpack and table.unpack(screen) or unpack(screen) }, "\n")
  local text = ""
  for i = 1, 40 do text = text .. (screen[i] or "") .. "\n" end
  check(text:find("iron%s+64 mined") ~= nil, "monitor shows iron total")
  check(text:find("T1") and text:find("T2") and text:find("T3"), "monitor lists all three turtles")
end

print("scenario: a job above its home (coal's old Y 96 from a base at 77): it mines below home")
print("          instead (16 down at least), never up through the base")
do
  local W = newWorld(5, 1, { span = 60, ymin = -40, ymax = 12 })
  local T, api, sc = newTurtle(W, 1, 0)
  T.inv[1] = { name = "minecraft:coal", count = 64 }
  local files = {}
  local highest, lowest = 0, 0
  local realUp, realDown = api.up, api.down
  api.up = function() local ok = realUp(); highest = math.max(highest, T.y); return ok end
  api.down = function() local ok = realDown(); lowest = math.min(lowest, T.y); return ok end
  local ok, err = runProgram(makeEnv(T, api, sc, files), "y=8", "at=0", "lanes=1", "length=16")
  check(ok, "ran (" .. tostring(err) .. ")")
  check(highest <= 0, "never above home: highest Y " .. highest)
  check(lowest <= -16, "mined 16 below home or deeper: lowest Y " .. lowest)
end

print("scenario: little fuel at home: the miner asks for fuel at its chest, never the wired-network")
print("          push (that one needs its modem on, and says so)")
do
  local W = newWorld(9, 0, { span = 40, ymin = -12, ymax = 6 })
  local B, fleet, _, _, Base, bus = runFleet(W, { { x = 0, z = 0, h = 0 } }, function(Base, B) end,
    { coal = 5, onTick = function(Base, B, fleet, tick) if tick > 200 then fleet[1].stopNow = true end end })
  local asked, pushed = false, false
  for _, e in ipairs(bus.log) do
    if e.msg.state == "supply" and e.msg.supply and (e.msg.supply.fuel or 0) > 0 then asked = true end
    if e.msg.wantFuel then pushed = true end
  end
  check(asked, "asked for fuel at its chest")
  check(not pushed, "no wired-network fuel push")
end

print("scenario: the ore map: job 1 reports every non-filler block it scans (with its wireless")
print("          modem, mid-job too); job 2 gets the known iron and digs it first; dug iron leaves the map")
do
  local W = newWorld(33, 0, { span = 70, ymin = -40, ymax = 6 })
  W.set(4, -20, -20, "minecraft:spawner") -- something that isn't ore, worth knowing of
  local queued2, known2, job1Done = false, nil, nil
  local B, fleet, _, _, Base, bus = runFleet(W, { { x = 0, z = 0, h = 0 } }, function(Base, B)
    table.insert(B.homes, { id = 1, x = 0, y = 0, z = 0, facing = "north", role = "miner", owner = 101 })
    -- job 1 wants more iron than one scan holds: it scans along its lane
    Base.queueJob(B, { only = "iron", y = -20, quantity = 100, lanes = 1, length = 64 })
  end, {
    onTick = function(Base, B, fleet)
      if not queued2 and (B.totals.iron or 0) > 0 then
        queued2 = true
        Base.queueJob(B, { only = "iron", y = -20, quantity = 8, lanes = 1, length = 48 })
      end
    end,
  })
  local f = fleet[1]
  check(not f.err, "ran without error: " .. tostring(f.err))
  local mapMid, doneAt = nil, nil
  for i, e in ipairs(bus.log) do
    if e.msg.state == "map" and not mapMid then mapMid = i end
    if e.msg.state == "done" and not doneAt then doneAt = i end
    if e.reply and e.reply.type == "job" and e.reply.job.id == 2 then known2 = e.reply.known end
  end
  check(mapMid and doneAt and mapMid < doneAt, "a map report came in mid-job, before job 1 was done")
  local ores, spawner, iron = 0, false, 0
  oremap.each(B.map, function(_, _, _, v)
    ores = ores + 1
    if v == "minecraft:spawner" then spawner = true end
    if v == "minecraft:iron_ore" then iron = iron + 1 end
  end)
  check(ores > 20, "the base's map holds what was scanned: " .. ores .. " blocks")
  check(spawner, "the spawner too (not ore, not filler)")
  local stone = false
  oremap.each(B.map, function(_, _, _, v) if v == "minecraft:stone" or v == "minecraft:cobblestone" then stone = true end end)
  check(not stone, "no stone or cobblestone in it")
  check(known2 and #known2 > 0, "job 2 came with known iron: " .. tostring(known2 and #known2))
  local dugKnown = 0
  for _, o in ipairs(known2 or {}) do
    if W.get(o.x, o.y, o.z) == nil and oremap.get(B.map, o.x, o.y, o.z) == nil then dugKnown = dugKnown + 1 end
  end
  check(known2 and dugKnown == math.min(8, #known2),
    ("it dug the known iron it needed (8), the map dropped those: %d of %d known"):format(dugKnown, known2 and #known2 or 0))
  local left = 0
  for _, o in ipairs(known2 or {}) do if oremap.get(B.map, o.x, o.y, o.z) then left = left + 1 end end
  check(left == #(known2 or {}) - dugKnown and next(B.map.held) == nil, "the rest stays known, free for the next job: " .. left)
  check((B.totals.iron or 0) >= 100, "both jobs counted: " .. tostring(B.totals.iron))
end

print("scenario: map review: a known ore that is gone isn't counted and leaves the map; a block")
print("          worth mapping dug in a tunnel leaves it; out of reach it backs off; hand-run keeps no map")
do
  local W = newWorld(41, 0, { span = 70, ymin = -40, ymax = 6 })
  -- the base believes in iron where there is only stone (someone took it)
  local GHOST = { x = 3, y = -20, z = -40 }
  W.set(GHOST.x, GHOST.y, GHOST.z, "minecraft:stone")
  local B, fleet, _, _, Base, bus = runFleet(W, { { x = 0, z = 0, h = 0 } }, function(Base, B)
    table.insert(B.homes, { id = 1, x = 0, y = 0, z = 0, facing = "north", role = "miner", owner = 101 })
    oremap.put(B.map, GHOST.x, GHOST.y, GHOST.z, "minecraft:iron_ore")
    B.map.isOre["minecraft:iron_ore"] = true
    Base.queueJob(B, { only = "iron", y = -20, quantity = 1, lanes = 1, length = 64 })
    Base.queueJob(B, { only = "diamond", y = -20, quantity = 999, lanes = 1, length = 176 })
  end, {
    -- deep and far: the base hears nothing the miner says mid-job
    onTick = function(Base, B, fleet, tick, bus) bus.deaf = function(id, msg) return msg.state == "map" end end,
  })
  local f = fleet[1]
  check(not f.err, "ran without error: " .. tostring(f.err))
  check(oremap.get(B.map, GHOST.x, GHOST.y, GHOST.z) == nil, "the ghost iron left the map")
  local job1Scans
  for _, e in ipairs(bus.log) do
    if e.msg.state == "done" and e.msg.job and e.msg.job.id == 1 then job1Scans = #((e.msg.map or {}).scans or {}) end
  end
  check(job1Scans and job1Scans > 0,
    "the ghost (its only known iron) didn't count: job 1 went on and scanned for real iron: " .. tostring(job1Scans))
  local tries, scans = 0, 0
  for _, e in ipairs(bus.log) do
    if e.msg.state == "map" then tries = tries + 1 end
    if e.msg.map then scans = math.max(scans, #(e.msg.map.scans or {})) end
  end
  check(scans >= 5 and tries <= 3, ("out of reach it backed off: %d tries over %d scans"):format(tries, scans))
  -- (its home report still brought everything: the map knows what it scanned)
  local n = 0
  n = B.map.n
  check(n > 20, "and the home report carried it all: " .. n)
end

print("scenario: a block worth mapping, seen by one scan and dug on the way to the next, leaves the map")
do
  local W = newWorld(43, 0, { span = 70, ymin = -40, ymax = 6 })
  -- on lane 0 (north from home, x 0), in the cube of the scan at z 0 only
  -- (the next one, at z -16, covers z -24..-8)
  local AM = { x = 0, y = -20, z = -7 }
  W.set(AM.x, AM.y, AM.z, "minecraft:amethyst_block")
  local B, fleet = runFleet(W, { { x = 0, z = 0, h = 0 } }, function(Base, B)
    table.insert(B.homes, { id = 1, x = 0, y = 0, z = 0, facing = "north", role = "miner", owner = 101 })
    Base.queueJob(B, { only = "diamond", y = -20, quantity = 999, lanes = 1, length = 32 })
  end)
  check(not fleet[1].err, "ran without error: " .. tostring(fleet[1].err))
  check(W.get(AM.x, AM.y, AM.z) == nil, "the amethyst was dug (tunnel)")
  check(oremap.get(B.map, AM.x, AM.y, AM.z) == nil, "and left the map")
end

print("scenario: out of reach on job 1 (it backs off), in reach on job 2: back home in between")
print("          resets the backoff, so job 2 sends mid-job again")
do
  local W = newWorld(47, 0, { span = 90, ymin = -40, ymax = 6 })
  local deafFor = 1
  local B, fleet, _, _, Base, bus = runFleet(W, { { x = 0, z = 0, h = 0 } }, function(Base, B)
    table.insert(B.homes, { id = 1, x = 0, y = 0, z = 0, facing = "north", role = "miner", owner = 101 })
    Base.queueJob(B, { only = "diamond", y = -20, quantity = 999, lanes = 1, length = 176 })
    Base.queueJob(B, { only = "diamond", y = -30, quantity = 999, lanes = 1, length = 160 })
  end, {
    onTick = function(Base, B, fleet, tick, bus)
      bus.deaf = function(id, msg)
        if msg.state == "done" and msg.job and msg.job.id == 1 then deafFor = 0 end
        return msg.state == "map" and deafFor == 1
      end
    end,
  })
  check(not fleet[1].err, "ran without error: " .. tostring(fleet[1].err))
  local heard2 = 0
  for _, e in ipairs(bus.log) do
    if e.msg.state == "map" and not e.lost and e.msg.job == nil then heard2 = heard2 + 1 end
  end
  local sent2 = 0
  local job2 = false
  for _, e in ipairs(bus.log) do
    if e.reply and e.reply.type == "job" and e.reply.job.id == 2 then job2 = true end
    if job2 and e.msg.state == "map" and not e.lost then sent2 = sent2 + 1 end
  end
  check(sent2 >= 2, "job 2 sent its map mid-job again: " .. sent2 .. " times")
end

print("scenario: gravel falls into the cell of an ore just dug (and is dug too): the ore still counts")
do
  local W = newWorld(51, 0, { span = 70, ymin = -40, ymax = 6 })
  local fell = 0
  W.onDig = function(x, y, z, b)
    if b == "minecraft:iron_ore" and fell < 3 then fell = fell + 1; W.set(x, y, z, "minecraft:gravel") end
  end
  local B, fleet, _, _, _, bus = runFleet(W, { { x = 0, z = 0, h = 0 } }, function(Base, B)
    table.insert(B.homes, { id = 1, x = 0, y = 0, z = 0, facing = "north", role = "miner", owner = 101 })
    Base.queueJob(B, { only = "iron", y = -20, quantity = 6, lanes = 1, length = 64 })
  end)
  check(not fleet[1].err, "ran without error: " .. tostring(fleet[1].err))
  check(fell == 3, "gravel fell in 3 times")
  local gone = 0
  for _, line in ipairs(bus.prints or {}) do if line:find("any more") then gone = gone + 1 end end
  check(gone == 0 and (B.totals.iron or 0) == 6, "every iron dug counted, none taken for gone: " .. gone .. " said gone")
end

print("scenario: the job ends with the turtle below its job level, next to bedrock (the live miner-5")
print("          at Y -61): it climbs back to the job level before heading for the shaft, and gets home")
do
  local W = newWorld(61, 0, { span = 70, ymin = -30, ymax = 6 })
  -- bedrock 3 below the job level (-20) everywhere (random bedrock, as at Y -61)
  for x = -70, 70 do for z = -70, 70 do W.set(x, -23, z, "minecraft:bedrock") end end
  -- but two ores in it near the end of the lane: digging them leaves it there
  -- and no other iron around the lane's last scans: those two are the last digs
  for x = -12, 12 do for y = -30, -10 do for z = -75, -40 do
    if W.get(x, y, z) == "minecraft:iron_ore" then W.set(x, y, z, "minecraft:stone") end
  end end end
  W.set(3, -23, -60, "minecraft:iron_ore"); W.set(3, -23, -62, "minecraft:iron_ore")
  local B, fleet = runFleet(W, { { x = 0, z = 0, h = 0 } }, function(Base, B)
    Base.queueJob(B, { only = "iron", y = -20, quantity = 999, lanes = 1, length = 64 })
  end)
  check(not fleet[1].err, "no 'Cannot reach home': " .. tostring(fleet[1].err))
  check(fleet[1].T.x == 0 and fleet[1].T.y == 0 and fleet[1].T.z == 0, ("home (%d,%d,%d)"):format(fleet[1].T.x, fleet[1].T.y, fleet[1].T.z))
end

print("scenario: a bedrock wall between the lane and the shaft, one hole 10 blocks off: it mines its way")
print("          around to the hole and home, it doesn't give up")
do
  local W = newWorld(65, 0, { span = 70, ymin = -40, ymax = 6 })
  -- a bedrock wall across the lane at z -30, floor to ceiling, one hole 10 off
  for x = -15, 15 do for y = -35, -5 do W.set(x, y, -30, "minecraft:bedrock") end end
  W.set(10, -22, -30, "minecraft:stone")
  -- the job under the slab; nothing else but the slab in the way
  local B, fleet = runFleet(W, { { x = 0, z = 0, h = 0 } }, function(Base, B)
    Base.queueJob(B, { only = "diamond", y = -22, quantity = 999, lanes = 1, length = 64 })
  end)
  check(not fleet[1].err, "no 'Cannot reach home': " .. tostring(fleet[1].err))
  check(fleet[1].T.x == 0 and fleet[1].T.y == 0 and fleet[1].T.z == 0, ("home (%d,%d,%d)"):format(fleet[1].T.x, fleet[1].T.y, fleet[1].T.z))
end

print("scenario: out past a bedrock wall whose only hole is far beyond any detour it may search:")
print("          it walks its trail back (the way it came) and gets home; it can't be sealed in")
do
  local W = newWorld(67, 1, { span = 60, ymin = -30, ymax = 6 })
  -- home faces east (h 1). A wall across x = 10, floor to ceiling; its only
  -- hole 20 blocks south, at z = 20
  for y = -30, 5 do for z = -60, 60 do W.set(10, y, z, "minecraft:bedrock") end end
  W.set(10, -10, 20, nil)
  -- the tunnel it came by: down the shaft, south 20, east through the hole, north 20
  local trail = {}
  local function dig(x, y, z) W.set(x, y, z, nil); trail[#trail + 1] = x .. "," .. y .. "," .. z end
  for y = -1, -10, -1 do dig(0, y, 0) end
  for z = 1, 20 do dig(0, -10, z) end
  for x = 1, 15 do dig(x, -10, 20) end
  for z = 19, 0, -1 do dig(15, -10, z) end
  local T, api, sc = newTurtle(W, 1, 4000)
  T.x, T.y, T.z = 15, -10, 0
  local textutils = {}
  function textutils.serialize(v)
    if type(v) == "table" then
      local p = {}
      for k, x in pairs(v) do p[#p + 1] = "[" .. textutils.serialize(k) .. "]=" .. textutils.serialize(x) end
      return "{" .. table.concat(p, ",") .. "}"
    elseif type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
  end
  local files = {
    ["oreminer.state"] = textutils.serialize({ pos = { x = 15, y = -10, z = 0 }, heading = 1, homeHeading = 1,
      lane = 1, lanes = 1, progress = 0, length = 16, dy = -10, mined = 0, job = { y = -10 } }),
    ["oreminer.trail"] = textutils.serialize(trail),
    ["oreminer.cfg"] = textutils.serialize({ detourMargin = 8 }),
  }
  local ok, err = runProgram(makeEnv(T, api, sc, files), "resume")
  check(ok, "resumed and finished (" .. tostring(err) .. ")")
  check(T.x == 0 and T.y == 0 and T.z == 0, ("home, by its trail (%d,%d,%d)"):format(T.x, T.y, T.z))
end

print("scenario: other turtles in its way (across the lane) for a while: it waits for them and")
print("          goes on, rather than digging around them")
do
  local W = newWorld(69, 0, { span = 60, ymin = -30, ymax = 6 })
  for x = -8, 8 do for y = -28, -12 do W.set(x, y, -6, "computercraft:turtle_advanced") end end
  local gone, still, lastPos = false, 0, nil
  local B, fleet = runFleet(W, { { x = 0, z = 0, h = 0 } }, function(Base, B)
    Base.queueJob(B, { only = "diamond", y = -20, quantity = 999, lanes = 1, length = 16 })
  end, {
    onTick = function(Base, B, fleet, tick)
      if gone then return end
      local T = fleet[1].T
      local pos = T.x .. "," .. T.y .. "," .. T.z
      if T.z == -5 and pos == lastPos then still = still + 1 else still = 0 end
      lastPos = pos
      if still > 5 then -- it stood waiting in front of them: they move on
        for x = -8, 8 do for y = -28, -12 do W.set(x, y, -6, nil) end end
        gone = true
      end
    end,
  })
  check(not fleet[1].err, "ran without error: " .. tostring(fleet[1].err))
  check(gone, "it waited in front of the other turtles until they left")
  check(fleet[1].T.x == 0 and fleet[1].T.y == 0 and fleet[1].T.z == 0, "and got home")
end

print("scenario: modded stone (darkstone) with no tags in the scan stays out of the map; real")
print("          ores and odd blocks go in; a raw scan entry is kept as scan.sample")
do
  local W = newWorld(63, 0, { span = 70, ymin = -40, ymax = 6 })
  for x = -10, 10 do for y = -28, -12 do for z = -40, 0 do
    if W.get(x, y, z) == "minecraft:stone" and (x + y + z) % 3 == 0 then W.set(x, y, z, "forbidden_arcanus:darkstone") end
  end end end
  W.set(2, -20, -12, "minecraft:spawner")
  W.untagged = true -- (the live scans came without usable tags)
  local B, fleet = runFleet(W, { { x = 0, z = 0, h = 0 } }, function(Base, B)
    table.insert(B.homes, { id = 1, x = 0, y = 0, z = 0, facing = "north", role = "miner", owner = 101 })
    Base.queueJob(B, { only = "diamond", y = -20, quantity = 999, lanes = 1, length = 32 })
  end)
  check(not fleet[1].err, "ran without error: " .. tostring(fleet[1].err))
  local dark, spawner, ores = 0, false, 0
  oremap.each(B.map, function(_, _, _, v)
    if v == "forbidden_arcanus:darkstone" then dark = dark + 1 end
    if v == "minecraft:spawner" then spawner = true end
    if v:find("_ore$") then ores = ores + 1 end
  end)
  check(dark == 0, "no darkstone in the map: " .. dark)
  check(spawner and ores > 10, ("the spawner and %d ores are"):format(ores))
  check(fleet[1].files["scan.sample"] ~= nil, "a raw scan entry kept for checking")
end

print("scenario: a hand-run job keeps no map report (nobody to send it to)")
do
  local W = newWorld(7, 1)
  local T, api, sc = newTurtle(W, 1, 0)
  T.inv[1] = { name = "minecraft:coal", count = 64 }
  local files = {}
  local ok, err = runProgram(makeEnv(T, api, sc, files), "lanes=1", "length=16")
  check(ok, "ran (" .. tostring(err) .. ")")
  local p = files["oremap.pending"] and load("return " .. files["oremap.pending"])() or { scans = {}, mined = {} }
  check(#(p.scans or {}) == 0 and #(p.mined or {}) == 0, "no pending map: " .. #(p.scans or {}) .. " scans")
end

print("scenario: STOP a working turtle from the base")
do
  local W = newWorld(8, 1, { span = 90, ymin = -30, ymax = 6 })
  local stopped = false
  local B, fleet = runFleet(W, { { x = 0, z = 0, h = 1 } }, function(Base, B)
    Base.selectOre(B, "iron"); Base.toggleOnly(B); B.sel.y = -10; B.sel.qty = 7 -- all ores, no limit
    Base.start(B)
  end, {
    filler = 12, -- nearly full inventory, so it comes home to unload early
    onTick = function(Base, B, fleet)
      local t = B.turtles[fleet[1].id]
      if not stopped and t and t.state == "assigned" then
        Base.selectTurtle(B, fleet[1].id); Base.stop(B); stopped = true
      end
    end,
  })
  local f = fleet[1]
  check(not f.err, "ran without error: " .. tostring(f.err))
  local st = load("return " .. f.files["oreminer.state"])()
  check(st.stop == true and st.done == true, "turtle stopped and finished the job")
  check(st.lane < st.lanes, ("stopped early (lane %d of %d)"):format(st.lane + 1, st.lanes))
  check(f.T.x == 0 and f.T.y == 0 and f.T.z == 0, "back home")
  check(B.totals.all ~= nil, "base counted the stopped job: " .. tostring(B.totals.all))
end

print(failures == 0 and "ALL PASSED" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
