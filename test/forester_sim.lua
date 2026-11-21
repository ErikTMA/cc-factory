-- Offline harness for forester.lua: a flat world with grass, saplings that grow
-- into trees when time passes (sleep) or with bone meal, and a turtle.
-- Usage: lua forester_sim.lua <path/to/forester.lua>
local PROGRAM = arg[1] or "../forester.lua"
local SRC = assert(io.open(PROGRAM)):read("*a")
local DIR = PROGRAM:match("^(.*)/[^/]*$") or "."
local MODULES = {}
for _, m in ipairs({ "tmove", "link", "oreconf", "nav" }) do
  MODULES[m] = assert(io.open(DIR .. "/" .. m .. ".lua")):read("*a")
end

local failures = 0
local function check(cond, msg)
  if cond then print("  ok   " .. msg) else print("  FAIL " .. msg); failures = failures + 1 end
end

-- headings in world axes: 0 north(-z), 1 east, 2 south, 3 west
local DIRS = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
local SAP, LOG, LEAF = "minecraft:oak_sapling", "minecraft:oak_log", "minecraft:oak_leaves"

-- A fenced pen: open cells x -4..4, z -9..0; the turtle's home is (0,0,0)
-- facing north with its chest at (0,0,1) in the fence line. An inner fence at
-- z = -5 runs from x = -4 to 2, so the north half is only reachable through
-- the gap at x = 3..4. opts.gap opens the outer fence.
local FENCE = "minecraft:oak_fence"
local function newWorld(opts)
  opts = opts or {}
  local W = { b = {}, chest = {}, saplingsPlanted = 0 }
  local function k(x, y, z) return x .. "," .. y .. "," .. z end
  function W.get(x, y, z) return W.b[k(x, y, z)] end
  function W.set(x, y, z, v) W.b[k(x, y, z)] = v end
  for x = -12, 12 do for z = -40, 6 do
    W.set(x, -1, z, "minecraft:grass_block")
    W.set(x, -2, z, "minecraft:dirt")
  end end
  for z = -10, 1 do W.set(-5, 0, z, FENCE); W.set(5, 0, z, FENCE) end
  for x = -5, 5 do W.set(x, 0, -10, FENCE); W.set(x, 0, 1, FENCE) end
  for x = -4, 2 do W.set(x, 0, -5, FENCE) end
  if opts.gap then W.set(5, 0, -3, nil) end
  W.set(0, 0, 1, "minecraft:chest")
  W.set(2, 0, -2, "minecraft:poppy") -- a flower in the way
  function W.fences() return W.count(FENCE) end
  -- grow every sapling into a 5-high oak with a leaf crown; every third tree
  -- also gets a sideways branch log (acacia-style)
  W.trees = 0
  function W.growAt(x, y, z)
    W.trees = W.trees + 1
    for h = 0, 4 do W.set(x, y + h, z, LOG) end
    for dx = -1, 1 do for dz = -1, 1 do
      if not (dx == 0 and dz == 0) then
        if not W.get(x + dx, y + 4, z + dz) then W.set(x + dx, y + 4, z + dz, LEAF) end
      end
    end end
    W.set(x, y + 5, z, LEAF)
    if W.trees % 3 == 0 then W.set(x + 1, y + 3, z, LOG) end
  end
  function W.growAll()
    local list = {}
    for key, v in pairs(W.b) do if v == SAP then list[#list + 1] = key end end
    for _, key in ipairs(list) do
      local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
      W.growAt(tonumber(x), tonumber(y), tonumber(z))
    end
  end
  function W.count(name)
    local n = 0
    for _, v in pairs(W.b) do if v == name then n = n + 1 end end
    return n
  end
  return W
end

local function newTurtle(W, fuel)
  local T = { x = 0, y = 0, z = 0, h = 0, fuel = fuel, sel = 1, inv = {} }
  local function front() local d = DIRS[T.h]; return T.x + d[1], T.y, T.z + d[2] end
  -- like CC: dug items go into the selected slot first, then onwards, wrapping
  local function add(name, n)
    n = n or 1
    for k = 0, 15 do
      local i = (T.sel - 1 + k) % 16 + 1
      local s = T.inv[i]
      if s and s.name == name and s.count < 64 then s.count = s.count + n; return end
      if not s then T.inv[i] = { name = name, count = n }; return end
    end
  end
  local leafDigs = 0
  local function dig(x, y, z)
    local b = W.get(x, y, z)
    if not b or b == "minecraft:chest" then return false end
    W.set(x, y, z, nil)
    if b == LEAF then
      leafDigs = leafDigs + 1
      if leafDigs % 4 == 0 then add(SAP) end
    elseif b == "minecraft:grass_block" then add("minecraft:dirt")
    else add(b) end
    return true
  end
  local function move(x, y, z)
    if W.get(x, y, z) or T.fuel < 1 then return false end
    T.fuel = T.fuel - 1; T.x, T.y, T.z = x, y, z
    if T.onMove then T.onMove() end -- may throw: stopped after the move, before the save
    return true
  end
  local function insp(b)
    if not b then return false, "No block to inspect" end
    local tags = {}
    if b:find("_log$") then tags["minecraft:logs"] = true end
    if b:find("leaves") then tags["minecraft:leaves"] = true end
    if b:find("sapling") then tags["minecraft:saplings"] = true end
    if b == "minecraft:poppy" then tags["minecraft:small_flowers"] = true end
    return true, { name = b, tags = tags }
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
  function api.inspect() return insp(W.get(front())) end
  function api.inspectUp() return insp(W.get(T.x, T.y + 1, T.z)) end
  function api.inspectDown() return insp(W.get(T.x, T.y - 1, T.z)) end
  function api.attack() return false end
  api.attackUp, api.attackDown = api.attack, api.attack
  function api.suck() return false end
  api.suckDown, api.suckUp = api.suck, api.suck
  function api.place()
    local s = T.inv[T.sel]
    if not s then return false end
    local fx, fy, fz = front()
    if s.name == SAP then
      local below = W.get(fx, fy - 1, fz)
      if W.get(fx, fy, fz) or not (below == "minecraft:grass_block" or below == "minecraft:dirt") then return false end
      W.set(fx, fy, fz, SAP); W.saplingsPlanted = W.saplingsPlanted + 1
    elseif s.name == "minecraft:bone_meal" then
      if W.get(fx, fy, fz) ~= SAP then return false end
      W.growAt(fx, fy, fz)
    else
      return false
    end
    s.count = s.count - 1
    if s.count == 0 then T.inv[T.sel] = nil end
    return true
  end
  function api.getFuelLevel() return T.fuel end
  function api.getFuelLimit() return 20000 end
  function api.select(i) T.sel = i; return true end
  function api.getItemCount(i) return T.inv[i] and T.inv[i].count or 0 end
  function api.getItemDetail(i) local s = T.inv[i]; return s and { name = s.name, count = s.count } or nil end
  function api.transferTo(to)
    local s = T.inv[T.sel]; if not s or to == T.sel then return false end
    local d = T.inv[to]
    if not d then T.inv[to] = s; T.inv[T.sel] = nil; return true end
    if d.name ~= s.name then return false end
    local n = math.min(64 - d.count, s.count)
    d.count, s.count = d.count + n, s.count - n
    if s.count == 0 then T.inv[T.sel] = nil end
    return true
  end
  function api.refuel(n)
    local s = T.inv[T.sel]
    if not s or not s.name:find("_log$") then return false end
    n = n or s.count
    if n == 0 then return true end
    n = math.min(n, s.count)
    T.fuel = T.fuel + 15 * n; s.count = s.count - n
    if s.count == 0 then T.inv[T.sel] = nil end
    return true
  end
  function api.drop()
    local s = T.inv[T.sel]; if not s then return false end
    local fx, fy, fz = front()
    if W.get(fx, fy, fz) ~= "minecraft:chest" then return false end
    W.chest[s.name] = (W.chest[s.name] or 0) + s.count
    T.inv[T.sel] = nil
    return true
  end
  return T, api
end

local function makeEnv(T, api, files, onSleep)
  local env = setmetatable({}, { __index = _G })
  env.turtle = api
  env.require = function(name) return assert(load(assert(MODULES[name], name), name, "t", env))() end
  local compass = { getFacing = function() return ({ [0] = "north", "east", "south", "west" })[T.h] end }
  local PTYPE = { ["minecraft:compass"] = "compass", ["computercraft:wireless_modem_normal"] = "modem" }
  T.left, T.right = T.left or "minecraft:diamond_pickaxe", T.right or (not T.noCompass and "minecraft:compass" or nil)
  env.peripheral = {
    getType = function(side) return PTYPE[T[side] or ""] end,
    find = function(t)
      if t == "compass" and (T.left == "minecraft:compass" or T.right == "minecraft:compass") then return compass end
    end,
  }
  local function equip(side)
    local cur, new = T[side], T.inv[T.sel]
    T[side] = new and new.name or nil
    T.inv[T.sel] = cur and { name = cur, count = 1 } or nil
    return true
  end
  api.equipLeft = function() return equip("left") end
  api.equipRight = function() return equip("right") end
  env.os = setmetatable({ getComputerLabel = function() return "F" end, reboot = function() error("REBOOT") end },
                        { __index = os })
  env.rednet = {
    open = function(side) assert(PTYPE[T[side] or ""] == "modem"); T.open = true end,
    close = function() T.open = false end,
    send = function(_, msg) T.sent = T.sent or {}; T.sent[#T.sent + 1] = msg end,
    broadcast = function(msg) T.sent = T.sent or {}; T.sent[#T.sent + 1] = msg end,
    receive = function() return nil end,
  }
  env.print = os.getenv("VERBOSE") and print or function() end
  env.sleep = onSleep
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

local function run(env, ...)
  return pcall(assert(load(SRC, "forester", "t", env)), ...)
end

-- The run ends when the program sleeps for the Nth time (time passes: trees grow).
local function sleeper(W, rounds)
  local n = 0
  return function()
    n = n + 1
    if n >= rounds then error("END OF TEST") end -- stop before this sleep's growth
    W.growAll()
  end
end

-- tree spots: every 3rd cell from home inside the pen
local SPOTS = {}
for _, x in ipairs({ -3, 0, 3 }) do for _, z in ipairs({ -9, -6, -3, 0 }) do
  if not (x == 0 and z == 0) then SPOTS[#SPOTS + 1] = { x, z } end
end end

local function plantedSpots(W)
  local n = 0
  for _, p in ipairs(SPOTS) do if W.get(p[1], 0, p[2]) == SAP then n = n + 1 end end
  return n
end

print("scenario: measures the pen, plants every spot (around an inner fence), fells, replants")
do
  local W = newWorld()
  local fences = W.fences()
  local T, api = newTurtle(W, 2000)
  T.inv[1] = { name = SAP, count = 64 }
  local files = {}
  local ok, err = run(makeEnv(T, api, files, sleeper(W, 3)), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "ran three rounds (" .. tostring(err) .. ")")
  check(T.x == 0 and T.y == 0 and T.z == 0 and T.h == 0, ("home, facing into the pen (%d,%d,%d h%d)"):format(T.x, T.y, T.z, T.h))
  check(W.fences() == fences, "no fence touched (" .. W.fences() .. " of " .. fences .. ")")
  check(W.count(LOG) == 0, "no logs left standing (branches included): " .. W.count(LOG))
  check(plantedSpots(W) == #SPOTS, ("all %d spots replanted: %d"):format(#SPOTS, plantedSpots(W)))
  check(W.get(3, 0, -9) == SAP and W.get(-3, 0, -9) == SAP, "spots behind the inner fence reached")
  local outside = 0
  for x = -12, 12 do for z = -40, 6 do
    if W.get(x, 0, z) == SAP and (x < -4 or x > 4 or z < -9 or z > 0) then outside = outside + 1 end
  end end
  check(outside == 0, "nothing planted outside the pen: " .. outside)
  check((W.chest[LOG] or 0) > 40, "logs delivered to the chest: " .. tostring(W.chest[LOG]))
  check(T.inv[1] and T.inv[1].name == SAP, "slot 1 still holds the saplings")
  local area = load("return " .. files["forester.area"])()
  local cells = 0
  for _ in pairs(area.cells) do cells = cells + 1 end
  check(area.done and cells == 9 * 10 - 7, "cached the pen: " .. cells .. " open cells")
end

print("scenario: second start uses the cached pen")
do
  local W = newWorld()
  local T, api = newTurtle(W, 2000)
  T.inv[1] = { name = SAP, count = 64 }
  local files = {}
  local lines = {}
  local env = makeEnv(T, api, files, function() error("END OF TEST") end)
  env.print = function(...) lines[#lines + 1] = table.concat({ ... }, " ") end
  run(env, "10")
  local measured = 0
  for _, l in ipairs(lines) do if l:find("Measuring the pen") then measured = measured + 1 end end
  env = makeEnv(T, api, files, function() error("END OF TEST") end)
  env.print = function(...) lines[#lines + 1] = table.concat({ ... }, " ") end
  run(env)
  local again = 0
  for _, l in ipairs(lines) do if l:find("Measuring the pen") then again = again + 1 end end
  check(measured == 1 and again == 1, "measured once over two starts: " .. again)
  env = makeEnv(T, api, files, function() error("END OF TEST") end)
  env.print = function(...) lines[#lines + 1] = table.concat({ ... }, " ") end
  run(env, "rescan")
  local rescan = 0
  for _, l in ipairs(lines) do if l:find("Measuring the pen") then rescan = rescan + 1 end end
  check(rescan == 2, "'forester rescan' measures again")
end

print("scenario: a gap in the fence: it says the pen is not closed")
do
  local W = newWorld({ gap = true })
  local T, api = newTurtle(W, 100000)
  T.inv[1] = { name = SAP, count = 64 }
  local ok, err = run(makeEnv(T, api, {}, function() error("END OF TEST") end), "10")
  check(not ok and tostring(err):find("not closed"), "clear error: " .. tostring(err))
end

print("scenario: bone meal in slot 2 grows trees straight away")
do
  local W = newWorld()
  local T, api = newTurtle(W, 3000) -- full tank: logs go to the chest, not into fuel
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[2] = { name = "minecraft:bone_meal", count = 64 }
  local ok, err = run(makeEnv(T, api, {}, function() error("END OF TEST") end), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "one round (" .. tostring(err) .. ")")
  check((W.chest[LOG] or 0) > 20, "logs from bone-mealed trees in round 1: " .. tostring(W.chest[LOG]))
end

print("scenario: restart in the middle of felling a tree")
do
  local W = newWorld()
  W.set(-3, 0, -3, SAP) -- a grown tree on a spot when it starts
  W.growAll()
  local T, api = newTurtle(W, 2000)
  T.inv[1] = { name = SAP, count = 64 }
  local files = {}
  T.onMove = function() if T.y == 3 then T.onMove = nil; error("SERVER RESTART") end end
  local ok, err = run(makeEnv(T, api, files, function() error("END OF TEST") end), "10")
  check(tostring(err):find("SERVER RESTART") ~= nil, "interrupted up in the tree")
  ok, err = run(makeEnv(T, api, files, function() error("END OF TEST") end))
  check(tostring(err):find("END OF TEST") ~= nil, "resumed and finished the round (" .. tostring(err) .. ")")
  check(T.x == 0 and T.y == 0 and T.z == 0, ("home after resume (%d,%d,%d)"):format(T.x, T.y, T.z))
  check(W.get(-3, 0, -3) == SAP and plantedSpots(W) == #SPOTS, "all spots planted after resume")
end

print("scenario: restart right after a turn, before it was saved")
for _, nth in ipairs({ 5, 61, 230 }) do
  local W = newWorld()
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 64 }
  local files = {}
  local first = true
  local function sl() if first then first = false; W.growAll(); return end; error("END OF TEST") end
  local n = 0
  T.onTurn = function() n = n + 1; if n == nth then T.onTurn = nil; error("SERVER RESTART") end end
  local ok, err = run(makeEnv(T, api, files, sl), "10")
  check(tostring(err):find("SERVER RESTART") ~= nil, "turn " .. nth .. ": interrupted")
  ok, err = run(makeEnv(T, api, files, sl))
  check(tostring(err):find("END OF TEST") ~= nil, "turn " .. nth .. ": resumed (" .. tostring(err) .. ")")
  check(T.x == 0 and T.y == 0 and T.z == 0 and T.h == 0, ("turn %d: home facing in (%d,%d,%d h%d)"):format(nth, T.x, T.y, T.z, T.h))
  check(plantedSpots(W) == #SPOTS, "turn " .. nth .. ": all spots planted")
end

print("scenario: reports each round to the base through a swapped-in modem")
do
  local W = newWorld()
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[2] = { name = "computercraft:wireless_modem_normal", count = 1 }
  local ok, err = run(makeEnv(T, api, {}, sleeper(W, 3)), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "ran (" .. tostring(err) .. ")")
  check(T.sent and #T.sent == 3, "one status per round (3 rounds): " .. tostring(T.sent and #T.sent))
  local last = T.sent and T.sent[#T.sent] or {}
  check(last.type == "status" and last.state == "resting" and (last.delivered or 0) > 0,
    "status carries delivered logs: " .. tostring(last.delivered))
  check(T.right == "minecraft:compass", "compass back in its slot after talking")
  local modemKept = false
  for i = 1, 16 do if T.inv[i] and T.inv[i].name == "computercraft:wireless_modem_normal" then modemKept = true end end
  check(modemKept and not W.chest["computercraft:wireless_modem_normal"], "modem kept, not unloaded")
end

print("scenario: refuses to start without saplings in slot 1")
do
  local W = newWorld()
  local T, api = newTurtle(W, 200)
  local ok, err = run(makeEnv(T, api, {}, function() end))
  check(not ok and tostring(err):find("slot 1"), "clear error: " .. tostring(err))
end

print(failures == 0 and "ALL PASSED" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
