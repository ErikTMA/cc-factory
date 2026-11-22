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
local BIRCH = "minecraft:birch_sapling"
local function isSap(v) return v ~= nil and v:find("sapling") ~= nil end

-- A fenced pen: open cells x -4..4, z -9..0; the turtle's home is (0,0,0)
-- facing north with its chest at (0,0,1) in the fence line. An inner fence at
-- z = -5 runs from x = -4 to 2, so the north half is only reachable through
-- the gap at x = 3..4. opts.gap opens the outer fence.
local FENCE = "minecraft:oak_fence"
local function newWorld(opts)
  opts = opts or {}
  local W = { b = {}, saplingsPlanted = 0, clock = 0 }
  -- items lying on the floor (in the air cell at y 0): { x, z, name, count, t }
  W.items = {}
  function W.drop(x, z, name, n) W.items[#W.items + 1] = { x = x, z = z, name = name, count = n, t = W.clock } end
  function W.ground(name)
    local c = 0
    for _, it in ipairs(W.items) do if not name or it.name == name then c = c + it.count end end
    return c
  end
  -- the home chest, like CC's: 27 ordered slots of up to 64. W.slots is the
  -- truth; W.chest[name] reads the total and setting it replaces that item.
  W.slots = {}
  function W.insert(name, n)
    for i = 1, 27 do
      local st = W.slots[i]
      if n > 0 and st and st.name == name and st.count < 64 then
        local m = math.min(64 - st.count, n); st.count = st.count + m; n = n - m
      end
    end
    for i = 1, 27 do
      if n > 0 and not W.slots[i] then
        local m = math.min(64, n); W.slots[i] = { name = name, count = m }; n = n - m
      end
    end
    return n -- what did not fit
  end
  W.chest = setmetatable({}, {
    __index = function(_, name)
      local c = 0
      for i = 1, 27 do local st = W.slots[i]; if st and st.name == name then c = c + st.count end end
      return c > 0 and c or nil
    end,
    __newindex = function(_, name, v)
      for i = 1, 27 do if W.slots[i] and W.slots[i].name == name then W.slots[i] = nil end end
      if v and v > 0 then W.insert(name, v) end
    end,
  })
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
    for key, v in pairs(W.b) do if isSap(v) then list[#list + 1] = key end end
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
  if opts.rough then
    W.set(1, -1, -1, nil); W.set(-2, -1, -7, nil)        -- holes in the floor
    W.set(-1, -1, -8, "minecraft:water")                 -- a puddle
    W.set(3, -1, -2, "minecraft:stone")                  -- a tree spot on stone
    W.set(-4, 0, -2, "minecraft:short_grass")
    W.set(4, 0, -7, "minecraft:red_mushroom")
    W.set(1, 0, -7, SAP); W.growAt(1, 0, -7); W.trees = 0            -- an old tree, off the grid
  end
  return W
end

local function newTurtle(W, fuel)
  local T = { x = 0, y = 0, z = 0, h = 0, fuel = fuel, sel = 1, inv = {} }
  local function front() local d = DIRS[T.h]; return T.x + d[1], T.y, T.z + d[2] end
  -- like CC: dug items go into the selected slot first, then onwards, wrapping
  -- (stacks of 64); what doesn't fit drops on the ground, where the turtle is
  local function add(name, n)
    n = n or 1
    for pass = 1, 2 do
      for k = 0, 15 do
        local i = (T.sel - 1 + k) % 16 + 1
        local s = T.inv[i]
        if n > 0 and pass == 1 and s and s.name == name and s.count < 64 then
          local m = math.min(64 - s.count, n); s.count = s.count + m; n = n - m
        elseif n > 0 and pass == 2 and not s then
          T.inv[i] = { name = name, count = math.min(64, n) }; n = n - math.min(64, n)
        end
      end
    end
    if n > 0 then W.drop(T.x, T.z, name, n) end
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
    if b == "minecraft:short_grass" then tags["minecraft:replaceable"] = true end
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
  -- from the home chest in front, like CC: the FIRST non-empty slot, into
  -- the turtle from the selected slot on (stacking); false if none fits
  function api.suck(limit)
    if W.get(front()) ~= "minecraft:chest" then return false end
    local ci
    for i = 1, 27 do if W.slots[i] then ci = i; break end end
    if not ci then return false end
    local st = W.slots[ci]
    local want = math.min(limit or 64, st.count)
    local moved = 0
    for pass = 1, 2 do
      for k = 0, 15 do
        local i = (T.sel - 1 + k) % 16 + 1
        local t = T.inv[i]
        if moved < want then
          if pass == 1 and t and t.name == st.name and t.count < 64 then
            local m = math.min(64 - t.count, want - moved); t.count = t.count + m; moved = moved + m
          elseif pass == 2 and not t then
            local m = want - moved; T.inv[i] = { name = st.name, count = m }; moved = moved + m
          end
        end
      end
    end
    if moved == 0 then return false end
    st.count = st.count - moved
    if st.count == 0 then W.slots[ci] = nil end
    return true
  end
  function api.suckDown() return false end
  api.suckUp = api.suckDown
  function api.place()
    local s = T.inv[T.sel]
    if not s then return false end
    local fx, fy, fz = front()
    if isSap(s.name) then
      local below = W.get(fx, fy - 1, fz)
      if W.get(fx, fy, fz) or not (below == "minecraft:grass_block" or below == "minecraft:dirt") then return false end
      W.set(fx, fy, fz, s.name); W.saplingsPlanted = W.saplingsPlanted + 1
      W.planted = W.planted or {}
      W.planted[s.name] = (W.planted[s.name] or 0) + 1
    elseif s.name == "minecraft:bone_meal" then
      if not isSap(W.get(fx, fy, fz)) then return false end
      W.growAt(fx, fy, fz)
    else
      return false
    end
    s.count = s.count - 1
    if s.count == 0 then T.inv[T.sel] = nil end
    return true
  end
  -- blocks placed under the turtle: into air or a fluid, like in the game
  function api.placeDown()
    local s = T.inv[T.sel]
    if not s or isSap(s.name) or s.name == "minecraft:bone_meal" then return false end
    local below = W.get(T.x, T.y - 1, T.z)
    if below and not below:find("water") and not below:find("lava") then return false end
    W.set(T.x, T.y - 1, T.z, s.name)
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
  -- fuel per item like CC (burn ticks * 5 / 100): logs 15, coal/charcoal 80
  function api.refuel(n)
    local s = T.inv[T.sel]
    local per = s and (s.name:find("_log$") and 15 or (s.name == "minecraft:coal" or s.name == "minecraft:charcoal") and 80)
    if not per then return false end
    n = n or s.count
    if n == 0 then return true end
    n = math.min(n, s.count)
    T.fuel = T.fuel + per * n; s.count = s.count - n
    if s.count == 0 then T.inv[T.sel] = nil end
    return true
  end
  function api.drop(n)
    local s = T.inv[T.sel]; if not s then return false end
    local fx, fy, fz = front()
    if W.get(fx, fy, fz) ~= "minecraft:chest" then return false end
    local m = math.min(n or s.count, s.count)
    local left = W.insert(s.name, m)
    if left == m then return false end -- chest full
    s.count = s.count - (m - left)
    if s.count == 0 then T.inv[T.sel] = nil end
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
    -- an optional base: T.reply(msg) -> reply
    receive = function()
      local last = T.sent and T.sent[#T.sent]
      local r = T.reply and last and T.reply(last)
      if r then return 0, r end
      return nil
    end,
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

-- A base like factory.supply: on "supply" it empties the chest into its
-- storage, then sends what the turtle lacks from storage. `stock` = { [item]
-- = n }; `plant` = the kinds to plant (nil: any). The turtle needs a modem.
local function fakeBase(W, T, stock, plant)
  local B = { stock = stock or {}, asks = {} }
  T.reply = function(msg)
    if msg.state == "supply" then
      B.asks[#B.asks + 1] = msg
      for i = 1, 27 do local st = W.slots[i]; if st then B.stock[st.name] = (B.stock[st.name] or 0) + st.count end end
      W.slots = {}
      local req, have = msg.supply or {}, msg.have or {}
      local function send(item, n)
        local m = math.min(math.max(0, n - (have[item] or 0)), B.stock[item] or 0)
        if m > 0 then B.stock[item] = B.stock[item] - m; W.insert(item, m) end
      end
      for item in pairs(B.stock) do
        if item:find("sapling") and (not plant or plant[item]) then send(item, req.saplings or 0) end
      end
      send("minecraft:dirt", req.dirt or 0)
      local pl = false
      if plant then pl = {}; for k in pairs(plant) do pl[#pl + 1] = k end end
      return { type = "supplied", sent = {}, short = {}, plant = pl }
    end
    if msg.state == "resting" then return { type = "ok" } end
  end
  return B
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
-- Tree spots: every `spacing` cells from the pen's corner (x -4, z -9),
-- starting one cell in: x -3, 0, 3 and z -8, -5, -2 for oak (3), minus the
-- inner fence (z -5, x -4..2).
local function spotsFor(spacing)
  local list = {}
  for x = -3, 4, spacing do for z = -8, 0, spacing do
    local fence = (z == -5 and x <= 2)
    if not fence and not (x == 0 and z == 0) then list[#list + 1] = { x, z } end
  end end
  return list
end
local SPOTS = spotsFor(3)

local function plantedSpots(W)
  local n = 0
  for _, p in ipairs(SPOTS) do if isSap(W.get(p[1], 0, p[2])) then n = n + 1 end end
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
  check(isSap(W.get(3, 0, -8)) and isSap(W.get(-3, 0, -8)), "spots behind the inner fence reached")
  local outside = 0
  for x = -12, 12 do for z = -40, 6 do
    if W.get(x, 0, z) == SAP and (x < -4 or x > 4 or z < -9 or z > 0) then outside = outside + 1 end
  end end
  check(outside == 0, "nothing planted outside the pen: " .. outside)
  check((W.chest[LOG] or 0) > 40, "logs delivered to the chest: " .. tostring(W.chest[LOG]))
  local carried = 0
  for i = 1, 16 do if T.inv[i] and isSap(T.inv[i].name) then carried = carried + T.inv[i].count end end
  check(carried > 0, "still carries saplings: " .. carried)
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
  W.set(-3, 0, -2, SAP) -- a grown tree on a spot when it starts
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
  check(isSap(W.get(-3, 0, -2)) and plantedSpots(W) == #SPOTS, "all spots planted after resume")
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
  local rounds = 0
  for _, m in ipairs(T.sent or {}) do if m.state == "resting" then rounds = rounds + 1 end end
  check(rounds == 3, "one round status per round (3 rounds): " .. rounds)
  local last = T.sent and T.sent[#T.sent] or {}
  check(last.type == "status" and last.state == "resting" and (last.delivered or 0) > 0,
    "status carries delivered logs: " .. tostring(last.delivered))
  check(T.right == "minecraft:compass", "compass back in its slot after talking")
  local modemKept = false
  for i = 1, 16 do if T.inv[i] and T.inv[i].name == "computercraft:wireless_modem_normal" then modemKept = true end end
  check(modemKept and not W.chest["computercraft:wireless_modem_normal"], "modem kept, not unloaded")
end

print("scenario: a rough pen: holes, water, a stone tree spot, an old tree, plants;")
print("          the whole floor ends up dirt or grass, paths too (never the modem under home)")
do
  local W = newWorld({ rough = true })
  W.set(-3, -1, -3, "minecraft:stone")                  -- path cells that aren't dirt or grass
  W.set(2, -1, -4, "minecraft:sand")
  W.set(-1, -1, -3, "minecraft:podzol")
  W.set(0, -1, 0, "computercraft:wired_modem_full")      -- its modem, under home
  W.set(2, -1, -1, "computercraft:cable")                -- a cable under a path cell
  local fences = W.fences()
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[5] = { name = "minecraft:dirt", count = 16 }
  local ok, err = run(makeEnv(T, api, {}, function() error("END OF TEST") end), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "one round (" .. tostring(err) .. ")")
  check(W.get(1, -1, -1) == "minecraft:dirt" and W.get(-2, -1, -7) == "minecraft:dirt", "holes filled with dirt")
  check(W.get(-1, -1, -8) == "minecraft:dirt", "the puddle filled with dirt")
  check(W.get(3, -1, -2) == "minecraft:dirt", "stone under a tree spot swapped for dirt")
  check(W.get(-3, -1, -3) == "minecraft:dirt" and W.get(2, -1, -4) == "minecraft:dirt"
    and W.get(-1, -1, -3) == "minecraft:dirt", "stone, sand and podzol under paths swapped for dirt")
  check(W.get(0, -1, 0) == "computercraft:wired_modem_full" and W.get(2, -1, -1) == "computercraft:cable",
    "the modem under home and a cable under a path left alone")
  check(isSap(W.get(3, 0, -2)) and plantedSpots(W) == #SPOTS, "every spot planted, the fixed one too")
  check(W.get(1, 0, -7) == nil and W.get(1, 4, -7) == nil and W.count(LOG) == 0, "the old tree is gone")
  check(W.get(-4, 0, -2) == nil and W.get(4, 0, -7) == nil, "grass and mushroom cleared")
  check(W.fences() == fences, "no fence touched")
  check(not W.chest["minecraft:dirt"], "dirt kept, not unloaded")
  check(W.chest["minecraft:cobblestone"] or W.chest["minecraft:stone"], "the dug-out stone went to the chest")
end

print("scenario: no dirt: the stone spot waits, and gets fixed once it has dirt")
do
  local W = newWorld({ rough = true })
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 64 }
  local files = {}
  local rounds = 0
  local function sl()
    rounds = rounds + 1
    if rounds == 1 then
      check(not isSap(W.get(3, 0, -2)) and W.get(3, -1, -2) == "minecraft:stone", "round 1: no dirt, the stone spot is left alone")
      T.inv[6] = { name = "minecraft:dirt", count = 8 } -- someone gives it dirt
      return
    end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, files, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  check(W.get(3, -1, -2) == "minecraft:dirt" and isSap(W.get(3, 0, -2)), "round 2: dirt laid and the spot planted")
end

print("scenario: no dirt while measuring: the holes in the path wait, and get filled once it has dirt;")
print("          at its chest it asks the base for the dirt the pen still needs")
do
  local W = newWorld({ rough = true })
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[4] = { name = "computercraft:wireless_modem_normal", count = 1 } -- (to report)
  fakeBase(W, T, { ["minecraft:dirt"] = 2 }) -- the base has 2 dirt (sent at the end of round 1)
  local rounds, need1 = 0, nil
  local function lastAsk()
    for i = #(T.sent or {}), 1, -1 do if T.sent[i].state == "supply" then return T.sent[i] end end
  end
  local function sl()
    rounds = rounds + 1
    if rounds == 1 then
      check(W.get(1, -1, -1) == nil and W.get(-1, -1, -8) == "minecraft:water", "round 1: no dirt, holes and puddle still open")
      local a = lastAsk() or { supply = {}, have = {} }
      -- 2 holes + the puddle + the stone spot; the 2 in the chest came after it asked
      check(a.supply.dirt == 4 and (a.have["minecraft:dirt"] or 0) == 0,
        "round 1: at its chest it asks for dirt for 4 cells, carrying none: " .. tostring(a.supply.dirt))
      check(a.supply.fuel and a.supply.saplings and a.supply.bonemeal, "and for fuel, saplings, bone meal")
      T.inv[6] = { name = "minecraft:dirt", count = 1 } -- one more (still not enough)
      return
    end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, {}, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  local filled = 0
  for _, c in ipairs({ { 1, -1 }, { -2, -7 }, { -1, -8 }, { 3, -2 } }) do
    if W.get(c[1], -1, c[2]) == "minecraft:dirt" then filled = filled + 1 end
  end
  check(filled == 3, "round 2: its 3 dirt went into 3 of the 4 cells: " .. filled)
  local a2 = lastAsk() or { supply = {} }
  check(a2.supply.dirt == 1, "round 2: it asks for dirt for the 1 cell left: " .. tostring(a2.supply.dirt))
end

print("scenario: the live forester-4: it comes home full of haul, 7 kinds selected; the base")
print("          sends fuel, 7 sapling kinds, bone meal and dirt (in that order): it takes the dirt too")
do
  local KINDS = { "minecraft:acacia_sapling", BIRCH, "minecraft:cherry_sapling", "minecraft:jungle_sapling",
                  SAP, "minecraft:spruce_sapling", "minecraft:mangrove_propagule" }
  local W = newWorld({ rough = true })
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[4] = { name = "computercraft:wireless_modem_normal", count = 1 }
  for i = 5, 16 do T.inv[i] = { name = "minecraft:stick", count = 64 } end -- (haul from the trees)
  local stored, asked = {}, nil
  -- a base like factory.supply: it empties the chest into storage, then sends
  T.reply = function(msg)
    if msg.state == "supply" then
      asked = asked or msg.supply -- (the first time it asks)
      for i = 1, 27 do local st = W.slots[i]; if st then stored[st.name] = (stored[st.name] or 0) + st.count end end
      W.slots = {}
      W.insert("minecraft:charcoal", 16)
      for _, k in ipairs(KINDS) do W.insert(k, 16) end
      W.insert("minecraft:bone_meal", 32)
      W.insert("minecraft:dirt", msg.supply.dirt or 0)
      return { type = "supplied", sent = {}, short = {}, plant = KINDS }
    end
    if msg.state == "resting" then return { type = "ok", plant = KINDS } end
  end
  local ok, err = run(makeEnv(T, api, {}, function() error("END OF TEST") end), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "one round (" .. tostring(err) .. ")")
  check(asked and asked.dirt == 4, "it asked for dirt for 4 cells: " .. tostring(asked and asked.dirt))
  local fixed = 0
  for _, c in ipairs({ { 1, -1 }, { -2, -7 }, { -1, -8 }, { 3, -2 } }) do
    if W.get(c[1], -1, c[2]) == "minecraft:dirt" then fixed = fixed + 1 end
  end
  check(fixed == 4, "it took the dirt and laid it: " .. fixed .. "/4 cells")
  check(not W.chest["minecraft:dirt"], "no dirt left in the chest")
  check((stored["minecraft:stick"] or 0) >= 12 * 64, "its haul was unloaded before it asked: " .. tostring(stored["minecraft:stick"]))
end

print("scenario: 7 kinds selected, 7 kinds of logs: after unloading it keeps 16 logs in all and")
print("          16 saplings per kind, so it goes out with room for its haul")
do
  local KINDS = { "minecraft:acacia_sapling", BIRCH, "minecraft:cherry_sapling", "minecraft:jungle_sapling",
                  SAP, "minecraft:spruce_sapling", "minecraft:mangrove_propagule" }
  local LOGS = { "minecraft:acacia_log", "minecraft:birch_log", "minecraft:cherry_log", "minecraft:jungle_log",
                 LOG, "minecraft:spruce_log", "minecraft:mangrove_log" }
  local W = newWorld()
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[4] = { name = "computercraft:wireless_modem_normal", count = 1 }
  for i, k in ipairs(KINDS) do if k ~= SAP then T.inv[4 + i] = { name = k, count = 64 } end end
  for i, l in ipairs(LOGS) do if i <= 4 then T.inv[11 + i] = { name = l, count = 64 } end end
  local plant = {}
  for _, k in ipairs(KINDS) do plant[k] = true end
  fakeBase(W, T, {}, plant)
  local after
  local ok, err = run(makeEnv(T, api, {}, function() after = {}; for i = 1, 16 do after[i] = T.inv[i] end; error("END OF TEST") end), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "one round (" .. tostring(err) .. ")")
  local logs, perKind, free = 0, {}, 0
  for i = 1, 16 do
    local d = after[i]
    if not d then free = free + 1
    elseif d.name:find("_log") then logs = logs + d.count
    elseif d.name:find("sapling") or d.name:find("propagule") then perKind[d.name] = (perKind[d.name] or 0) + d.count end
  end
  local most = 0
  for _, n in pairs(perKind) do most = math.max(most, n) end
  check(logs <= 16, "16 logs at most, all kinds together: " .. logs)
  check(most <= 16, "16 saplings at most of each kind: " .. most)
  check(free >= 5, "room for its haul: " .. free .. " free slots")
end

print("scenario: its inventory fills up during a round: it goes home to unload and carries on;")
print("          nothing it digs is dropped on the ground")
do
  local W = newWorld()
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[4] = { name = "computercraft:wireless_modem_normal", count = 1 }
  fakeBase(W, T, {})
  local n = 0
  local function sl()
    n = n + 1
    if n == 1 then
      W.growAll() -- every spot a tree; and it comes back with its pockets full of junk
      for i = 5, 16 do T.inv[i] = { name = "minecraft:stick", count = 64 } end
      T.inv[2] = { name = "minecraft:apple", count = 64 }; T.inv[3] = { name = "minecraft:apple", count = 64 }
      return
    end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, {}, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  check(W.ground() == 0, "nothing dropped on the ground: " .. W.ground())
  check(W.count(LOG) == 0, "every tree felled")
end

print("scenario: starts without saplings, asks the base and takes them from its home chest")
do
  local W = newWorld()
  local T, api = newTurtle(W, 3000)
  T.inv[4] = { name = "computercraft:wireless_modem_normal", count = 1 }
  fakeBase(W, T, { [SAP] = 64 })
  local ok, err = run(makeEnv(T, api, {}, sleeper(W, 3)), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "ran (" .. tostring(err) .. ")")
  check(plantedSpots(W) == #SPOTS, ("round 1 took the saplings, round 2 planted every spot: %d/%d"):format(plantedSpots(W), #SPOTS))
end

print("scenario: two kinds of saplings: it plants them in turn")
do
  local W = newWorld()
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 32 }
  T.inv[4] = { name = BIRCH, count = 32 }
  local ok, err = run(makeEnv(T, api, {}, sleeper(W, 2)), "10")
  local oak, birch = (W.planted or {})[SAP] or 0, (W.planted or {})[BIRCH] or 0
  check(oak > 0 and birch > 0 and math.abs(oak - birch) <= 1, ("both kinds, alternating: %d oak, %d birch"):format(oak, birch))
end

print("scenario: the base selected birch only: oak goes back into the chest, birch is planted")
do
  local W = newWorld()
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 32 }
  T.inv[4] = { name = BIRCH, count = 32 }
  T.inv[5] = { name = "computercraft:wireless_modem_normal", count = 1 }
  T.reply = function(msg) if msg.state == "resting" then return { type = "ok", plant = { BIRCH } } end end
  local ok, err = run(makeEnv(T, api, {}, sleeper(W, 3)), "10")
  local oakLeft = 0
  for i = 1, 16 do if T.inv[i] and T.inv[i].name == SAP then oakLeft = oakLeft + T.inv[i].count end end
  check(oakLeft == 0 and (W.chest[SAP] or 0) > 0, "oak saplings went into the chest: " .. tostring(W.chest[SAP]))
  local before = (W.planted or {})[SAP] or 0
  check(((W.planted or {})[BIRCH] or 0) > 0, "birch planted")
end

print("scenario: little fuel but coal in its inventory: it refuels while measuring the pen")
do
  local W = newWorld()
  local T, api = newTurtle(W, 40)            -- not enough to measure the pen
  T.inv[1] = { name = SAP, count = 32 }
  T.inv[5] = { name = "minecraft:coal", count = 16 }
  local ok, err = run(makeEnv(T, api, {}, sleeper(W, 2)), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "measured the pen and finished a round (" .. tostring(err) .. ")")
  check(plantedSpots(W) == #SPOTS, "every spot planted: " .. plantedSpots(W))
end

print("scenario: it starts with fuel 0 but coal in its inventory (the live forester): it burns that")
do
  local W = newWorld()
  local T, api = newTurtle(W, 0)
  T.inv[1] = { name = SAP, count = 32 }
  T.inv[5] = { name = "minecraft:coal", count = 16 }
  local ok, err = run(makeEnv(T, api, {}, sleeper(W, 2)), "10")
  check(tostring(err):find("END OF TEST") ~= nil and plantedSpots(W) == #SPOTS, "fuelled itself and worked: " .. tostring(err))
end

print("scenario: too little fuel to measure the whole pen: it goes HOME before it runs dry, and says so")
do
  local W = newWorld()
  local T, api = newTurtle(W, 40)
  T.inv[1] = { name = SAP, count = 32 }
  T.inv[5] = { name = "minecraft:coal", count = 1 }
  local files = {}
  local ok, err = run(makeEnv(T, api, files, sleeper(W, 2)), "10")
  check(tostring(err):find("I'm home") ~= nil, "stopped with a clear message: " .. tostring(err))
  check(T.x == 0 and T.z == 0, ("at home, not stranded in the pen (%d,%d)"):format(T.x, T.z))
  -- given coal, the next start carries on from its map instead of starting over
  local cellsBefore = 0
  for _ in pairs((load("return " .. files["forester.area"])() or {}).cells or {}) do cellsBefore = cellsBefore + 1 end
  T.inv[6] = { name = "minecraft:coal", count = 16 }
  local moves0 = T.moves or 0
  ok, err = run(makeEnv(T, api, files, sleeper(W, 2)), "10")
  check(tostring(err):find("END OF TEST") ~= nil and plantedSpots(W) == #SPOTS,
    ("carried on (%d cells known) and finished: %s, %d spots"):format(cellsBefore, tostring(err), plantedSpots(W)))
end

print("scenario: a round with little fuel and nothing to burn: it turns back in time and waits at home")
do
  local W = newWorld()
  -- the pen is already measured: a round needs ~100 moves, it has 150
  local files = {}
  do
    local T0, api0 = newTurtle(W, 3000)
    T0.inv[1] = { name = SAP, count = 64 }
    run(makeEnv(T0, api0, files, sleeper(W, 1)), "10") -- measures and plants, stops at its first rest
  end
  local T, api = newTurtle(W, 30) -- (no trees grown: nothing to burn; below the 60 a round needs)
  T.inv[1] = { name = SAP, count = 64 }
  local moved0 = T.moves
  local ok, err = run(makeEnv(T, api, files, sleeper(W, 3)), "10")
  check(T.fuel == 30, "it didn't set out: waits at home with its 30 fuel (fuel now " .. T.fuel .. ")")
  check(T.x == 0 and T.z == 0, ("at home, not stranded in the pen (%d,%d), fuel %d"):format(T.x, T.z, T.fuel))
  check(T.fuel >= 0 and tostring(err):find("END OF TEST") ~= nil, "no 'out of fuel' error: " .. tostring(err))
end

local MENRIL = "integrateddynamics:menril_sapling"
local function plantedAt(W, list)
  local n = 0
  for _, p in ipairs(list) do if isSap(W.get(p[1], 0, p[2])) then n = n + 1 end end
  return n
end

print("scenario: menril needs more room: spots 4 apart from the corner, dirt under its side cells")
do
  local W = newWorld()
  local M4 = spotsFor(4)
  W.set(1, -1, -7, "minecraft:stone") -- the floor north... south of spot (1,-8): a side cell on stone
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = MENRIL, count = 32 }
  T.inv[5] = { name = "minecraft:dirt", count = 8 }
  local ok, err = run(makeEnv(T, api, {}, sleeper(W, 2)), "10")
  local onGrid, menril = plantedAt(W, M4), 0
  for _, p in ipairs(M4) do if W.get(p[1], 0, p[2]) == MENRIL then menril = menril + 1 end end
  check(onGrid == #M4 and menril == #M4,
    ("all %d spots 4 apart hold menril: %d"):format(#M4, menril))
  local off = 0
  for key, v in pairs(W.b) do
    local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if y == 0 and isSap(v) and not ((x + 3) % 4 == 0 and (z + 8) % 4 == 0) then off = off + 1 end
  end
  check(off == 0, "nothing planted off the 4-grid: " .. off)
  check(W.get(1, -1, -7) == "minecraft:dirt", "the stone under a menril spot's side cell became dirt")
end

print("scenario: the base selects menril instead of oak: the next round lays out a new grid")
do
  local W = newWorld()
  local T, api = newTurtle(W, 4000)
  T.inv[1] = { name = SAP, count = 32 }
  T.inv[4] = { name = MENRIL, count = 32 }
  T.inv[6] = { name = "computercraft:wireless_modem_normal", count = 1 }
  T.reply = function(msg) if msg.state == "resting" then return { type = "ok", plant = { MENRIL } } end end
  local files = {}
  local ok, err = run(makeEnv(T, api, files, sleeper(W, 3)), "10")
  local area = files["forester.area"] and load("return " .. files["forester.area"])() or {}
  check(area.spacing == 4, "the pen's grid is 4 apart now: " .. tostring(area.spacing))
  check((W.planted[MENRIL] or 0) > 0, "menril planted")
end

print(failures == 0 and "ALL PASSED" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
