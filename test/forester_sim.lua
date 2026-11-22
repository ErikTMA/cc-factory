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
  function W.drop(x, z, name, n, spill)
    W.items[#W.items + 1] = { x = x, z = z, name = name, count = n, t = W.clock, spill = spill }
    if spill then W.spilled = (W.spilled or 0) + n end
  end
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
  for z = -19, 1 do W.set(-9, 0, z, FENCE); W.set(9, 0, z, FENCE) end
  for x = -9, 9 do W.set(x, 0, -19, FENCE); W.set(x, 0, 1, FENCE) end
  for x = -8, 4 do W.set(x, 0, -9, FENCE) end
  if opts.gap then W.set(9, 0, -3, nil) end
  W.set(0, 0, 1, "minecraft:chest")
  W.set(2, 0, -2, "minecraft:poppy") -- a flower in the way
  function W.fences() return W.count(FENCE) end
  -- grow every sapling into a 5-high oak with a leaf crown; every third tree
  -- also gets a sideways branch log (acacia-style)
  W.trees = 0
  -- its leaves are of the sapling's kind (they drop that sapling, like the game)
  function W.growAt(x, y, z)
    local kind = W.get(x, y, z)
    local leaf = isSap(kind) and kind:gsub("_sapling$", "_leaves") or LEAF
    W.trees = W.trees + 1
    for h = 0, 4 do W.set(x, y + h, z, LOG) end
    for dx = -1, 1 do for dz = -1, 1 do
      if not (dx == 0 and dz == 0) then
        if not W.get(x + dx, y + 4, z + dz) then W.set(x + dx, y + 4, z + dz, leaf) end
      end
    end end
    W.set(x, y + 5, z, leaf)
    if W.trees % 3 == 0 then W.set(x + 1, y + 3, z, LOG) end
  end
  -- a bent tree like acacia/cherry: 3 logs up, then the trunk steps one cell
  -- east AND one up (only edge-touching), 3 more up, a branch; leaves on top
  function W.growBent(x, y, z)
    for h = 0, 2 do W.set(x, y + h, z, LOG) end
    W.set(x, y + 3, z, LEAF) -- (leaves over the bend, like the game)
    for h = 3, 5 do W.set(x + 1, y + h, z, LOG) end
    W.set(x + 1, y + 4, z - 1, LOG) -- a side branch, face-touching
    for dx = 0, 2 do for dz = -1, 1 do
      if not W.get(x + dx, y + 6, z + dz) then W.set(x + dx, y + 6, z + dz, LEAF) end
    end end
  end
  -- a big oak like ATM10's: a trunk 13 high, branches and a canopy of logs
  -- above 8 (out of a Geo Scanner's reach from the ground), leaves around
  function W.growTall(x, y, z)
    for h = 0, 12 do W.set(x, y + h, z, LOG) end
    for _, b in ipairs({ { 1, 10, 0 }, { 2, 11, 0 }, { -1, 11, 1 }, { 0, 13, -1 }, { 1, 14, -1 }, { -1, 12, -1 } }) do
      W.set(x + b[1], y + b[2], z + b[3], LOG)
    end
    for dx = -2, 2 do for dz = -2, 2 do for h = 11, 15 do
      if not W.get(x + dx, y + h, z + dz) then W.set(x + dx, y + h, z + dz, LEAF) end
    end end end
  end
  -- an ATM10 oak whose canopy spreads over the neighbouring spots: trunk 7
  -- high, branches out 3 each way at 5..7 (over the next spots' columns),
  -- leaves around them
  function W.growWide(x, y, z)
    for h = 0, 6 do W.set(x, y + h, z, LOG) end
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      for r = 1, 3 do W.set(x + d[1] * r, y + 4 + r, z + d[2] * r, LOG) end
    end
    for dx = -4, 4 do for dz = -4, 4 do for h = 8, 9 do
      if not W.get(x + dx, y + h, z + dz) then W.set(x + dx, y + h, z + dz, LEAF) end
    end end end
  end
  -- a 2x2 trunk (dark oak, giant spruce): the spot and the cells east, south, south-east
  function W.grow2x2(x, y, z)
    for h = 0, 4 do for _, d in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
      W.set(x + d[1], y + h, z + d[2], LOG)
    end end
    W.set(x, y + 5, z, LEAF)
  end
  function W.growAll()
    local list = {}
    for key, v in pairs(W.b) do if isSap(v) then list[#list + 1] = key end end
    for _, key in ipairs(list) do
      local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
      W.growAt(tonumber(x), tonumber(y), tonumber(z))
    end
  end
  -- time passes: leaves with no log within 2 decay; every 2nd drops its
  -- sapling onto the floor below; items lying 300 s despawn (like the game)
  local decayed = 0
  function W.tick(secs)
    local start = W.clock
    W.clock = W.clock + secs
    local gone = {}
    for key, v in pairs(W.b) do
      if v:find("_leaves$") then
        local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        local near = false
        for dx = -2, 2 do for dy = -2, 2 do for dz = -2, 2 do
          local o = W.get(x + dx, y + dy, z + dz)
          if o and o:find("_log$") then near = true end
        end end end
        if not near then gone[#gone + 1] = { x, y, z, v } end
      end
    end
    for _, g in ipairs(gone) do
      W.set(g[1], g[2], g[3], nil)
      decayed = decayed + 1
      if decayed % 2 == 0 and not W.get(g[1], 0, g[3]) then -- (onto a fence/chest: out of reach)
        W.drop(g[1], g[3], (g[4]:gsub("_leaves$", "_sapling")), 1)
        W.items[#W.items].t = start + math.min(secs, 10) -- (leaves start decaying within seconds)
      end
    end
    local keep = {}
    for _, it in ipairs(W.items) do if W.clock - it.t < 300 then keep[#keep + 1] = it end end
    W.items = keep
  end
  function W.count(name)
    local n = 0
    for _, v in pairs(W.b) do if v == name then n = n + 1 end end
    return n
  end
  if opts.rough then
    W.set(1, -1, -1, nil); W.set(-2, -1, -7, nil)        -- holes in the floor
    W.set(-1, -1, -8, "minecraft:water")                 -- a puddle
    W.set(3, -1, -4, "minecraft:stone")                  -- a tree spot on stone
    W.set(-4, 0, -2, "minecraft:short_grass")
    W.set(4, 0, -7, "minecraft:red_mushroom")
    W.set(1, 0, -7, SAP); W.growAt(1, 0, -7); W.trees = 0            -- an old tree, off the grid
  end
  return W
end

local function newTurtle(W, fuel)
  local T = { x = 0, y = 0, z = 0, h = 0, fuel = fuel, sel = 1, inv = {}, W = W }
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
    if n > 0 then W.drop(T.x, T.z, name, n, true) end -- (spilled: its inventory is full)
  end
  local leafDigs = 0
  local function dig(x, y, z)
    local b = W.get(x, y, z)
    if not b or b == "minecraft:chest" then return false end
    W.set(x, y, z, nil)
    if b:find("_leaves$") then
      leafDigs = leafDigs + 1
      if leafDigs % 4 == 0 then add((b:gsub("_leaves$", "_sapling"))) end
    elseif b == "minecraft:grass_block" then add("minecraft:dirt")
    else add(b) end
    return true
  end
  local function move(x, y, z)
    if W.get(x, y, z) or T.fuel < 1 then return false end
    W.clock = W.clock + 0.4
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
  -- (a turtle move or turn takes 8 ticks: 0.4 s; items on the ground age meanwhile)
  function api.turnLeft() W.clock = W.clock + 0.4; T.h = (T.h + 3) % 4; if T.onTurn then T.onTurn() end; return true end
  function api.turnRight() W.clock = W.clock + 0.4; T.h = (T.h + 1) % 4; if T.onTurn then T.onTurn() end; return true end
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
    local fx, fy, fz = front()
    if W.get(fx, fy, fz) ~= "minecraft:chest" then
      -- no inventory there: the items lying in that cell (CC: ItemEntity in its box)
      if fy ~= 0 then return false end
      local alive = {}
      for _, it in ipairs(W.items) do if W.clock - it.t < 300 then alive[#alive + 1] = it end end
      W.items = alive -- (despawned: 300 s on the ground)
      for i, it in ipairs(W.items) do
        if it.x == fx and it.z == fz then
          table.remove(W.items, i)
          if it.old then W.pickedOld = (W.pickedOld or 0) + it.count end
          add(it.name, it.count)
          return true
        end
      end
      return false
    end
    W.chestSucks = (W.chestSucks or 0) + 1
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
  function api.getSelectedSlot() return T.sel end
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
  local PTYPE = { ["minecraft:compass"] = "compass", ["computercraft:wireless_modem_normal"] = "modem",
                  ["advancedperipherals:geo_scanner"] = "geo_scanner",
                  ["advancedperipherals:environment_detector"] = "environment_detector",
                  ["advancedperipherals:weak_automata_core"] = "weak_automata",
                  ["computercraft:wired_modem_full"] = "modem" }
  -- like AP 0.8.2a's Weak Automata Core: digBlock({ pitch }) breaks the block
  -- ahead (pitch -90 above, 90 below) as a player holding the item in the
  -- turtle's SELECTED slot; 1 fuel, then 1 s cooldown. Leaves broken with
  -- shears drop themselves (the shears wear: 238 uses); with anything else
  -- they drop nothing here. The drop falls to the floor.
  local core = { digBlock = function(args)
    args = args or {}
    if T.lastCoreDig and T.W.clock - T.lastCoreDig < 1 then return nil, "Operation is on cooldown" end
    local d = DIRS[T.h]
    local x, y, z = T.x + d[1], T.y, T.z + d[2]
    if args.pitch == -90 then x, y, z = T.x, T.y + 1, T.z elseif args.pitch == 90 then x, y, z = T.x, T.y - 1, T.z end
    local b = T.W.get(x, y, z)
    if not b then return false, "Nothing to break" end
    if T.fuel < 1 then return nil, "Not enough fuel" end
    T.fuel = T.fuel - 1
    T.lastCoreDig = T.W.clock
    T.W.set(x, y, z, nil)
    local held = T.inv[T.sel]
    if b:find("_leaves$") then
      if held and held.name == "minecraft:shears" then
        T.W.drop(x, z, b, 1)
        T.sheared = (T.sheared or 0) + 1
        held.uses = (held.uses or 0) + 1
        if held.uses >= 238 then T.inv[T.sel] = nil end
      end
    else
      T.W.drop(x, z, b, 1)
      if b:find("_log$") then T.coreLogs = (T.coreLogs or 0) + 1 end
    end
    return true
  end }
  -- like AP 0.8.2a: scanBlocks lists every block but air in the cube, tags as a list
  local scanner = { scanBlocks = function(r)
    T.scans = (T.scans or 0) + 1
    local out = {}
    for dx = -r, r do for dy = -r, r do for dz = -r, r do
      local b = T.W.get(T.x + dx, T.y + dy, T.z + dz)
      if b then
        local tags = {}
        if b:find("_log$") then tags[#tags + 1] = "minecraft:logs" end
        if b:find("_leaves$") then tags[#tags + 1] = "minecraft:leaves" end
        out[#out + 1] = { name = b, tags = tags, x = dx, y = dy, z = dz }
      end
    end end end
    return out
  end }
  -- like AP 0.8.2a's scanEntities(radius, [detailed], [filter]): with no
  -- filter only LIVING entities (EnvironmentDetectorPeripheral: isAlive and a
  -- LivingEntity), so never a dropped item; "minecraft:item" (an entity type
  -- id; "#..." a tag) lists dropped items
  local detector = { scanEntities = function(r, a, b)
    T.looks = (T.looks or 0) + 1
    local filter = type(a) == "string" and a or (type(b) == "string" and b or nil)
    local out = {}
    if filter ~= "minecraft:item" then return out end
    for _, it in ipairs(T.W.items) do
      if T.W.clock - it.t < 300 and math.abs(it.x - T.x) <= r and math.abs(it.z - T.z) <= r and math.abs(0 - T.y) <= r then
        out[#out + 1] = { name = "minecraft:item", x = it.x - T.x, y = 0.1 - (T.y + 0.5), z = it.z - T.z }
      end
    end
    return out
  end }
  T.left, T.right = T.left or "minecraft:diamond_pickaxe", T.right or (not T.noCompass and "minecraft:compass" or nil)
  env.peripheral = {
    getType = function(side) return PTYPE[T[side] or ""] end,
    find = function(t)
      if t == "compass" and (T.left == "minecraft:compass" or T.right == "minecraft:compass") then return compass end
    end,
    wrap = function(side)
      local t = PTYPE[T[side] or ""]
      if t == "compass" then return compass end
      if t == "geo_scanner" then return scanner end
      if t == "environment_detector" then return detector end
      if t == "weak_automata" then return core end
      if t then return {} end
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
  env.os = setmetatable({ getComputerLabel = function() return "F" end, reboot = function() error("REBOOT") end,
                          epoch = function() return (1700000000 + (T.W and T.W.clock or 0)) * 1000 end },
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
  env.sleep = function(secs) T.W.tick(tonumber(secs) or 0); return onSleep(secs) end
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
  local B = { stock = stock or {}, asks = {}, plant = plant }
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
        if item:find("sapling") and (not B.plant or B.plant[item]) then send(item, req.saplings or 0) end
      end
      send("minecraft:dirt", req.dirt or 0)
      send("minecraft:charcoal", req.fuel or 0)
      for _, item in ipairs(req.tools or {}) do send(item, 1) end
      -- (like factory.supply: a forester set to shear gets them unasked)
      if B.shear then
        send("minecraft:shears", 1); send("advancedperipherals:weak_automata_core", 1)
      end
      -- (like factory.supply: the accessories it is to carry, sorted)
      local acc = B.shear and { "advancedperipherals:weak_automata_core", "minecraft:shears" } or {}
      return { type = "supplied", sent = {}, short = {}, plant = B.plantList(), shear = B.shear, accessories = acc }
    end
    if msg.state == "resting" then return { type = "ok", plant = B.plantList() } end
  end
  function B.plantList()
    if not B.plant then return false end
    local pl = {}
    for k in pairs(B.plant) do pl[#pl + 1] = k end
    table.sort(pl)
    return pl
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

-- The pen: cells x -8..8, z -18..0, minus the inner fence (z -9, x -8..4;
-- its gap at x 5..8). Tree spots: every `spacing` cells from `reach` cells in
-- from the corner (x -8, z -18), each with `reach` open cells all around
-- (canopy inside the fence). Oak (3, 2): x -6, -3, 0, 3, 6 at z -16, -13, -4.
local function openCell(x, z) return x >= -8 and x <= 8 and z >= -18 and z <= 0 and not (z == -9 and x <= 4) end
local function spotsFor(spacing, reach)
  reach = reach or 2
  local list = {}
  for x = -8 + reach, 8, spacing do for z = -18 + reach, 0, spacing do
    local ok = not (x == 0 and z == 0)
    for dx = -reach, reach do for dz = -reach, reach do
      if not openCell(x + dx, z + dz) then ok = false end
    end end
    if ok then list[#list + 1] = { x, z } end
  end end
  return list
end
local SPOTS = spotsFor(3, 2)

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
  check(isSap(W.get(3, 0, -13)) and isSap(W.get(-3, 0, -13)), "spots behind the inner fence reached")
  local outside = 0
  for x = -12, 12 do for z = -40, 6 do
    if W.get(x, 0, z) == SAP and not openCell(x, z) then outside = outside + 1 end
  end end
  check(outside == 0, "nothing planted outside the pen: " .. outside)
  local isSpotXZ, offGrid = {}, 0
  for _, p in ipairs(SPOTS) do isSpotXZ[p[1] .. "," .. p[2]] = true end
  for x = -12, 12 do for z = -40, 6 do
    if isSap(W.get(x, 0, z)) and not isSpotXZ[x .. "," .. z] then offGrid = offGrid + 1 end
  end end
  check(offGrid == 0, "no tree closer than 2 to a fence (oak's reach), nothing off the grid: " .. offGrid)
  check((W.chest[LOG] or 0) > 40, "logs delivered to the chest: " .. tostring(W.chest[LOG]))
  local carried = 0
  for i = 1, 16 do if T.inv[i] and isSap(T.inv[i].name) then carried = carried + T.inv[i].count end end
  check(carried > 0, "still carries saplings: " .. carried)
  local area = load("return " .. files["forester.area"])()
  local cells = 0
  for _ in pairs(area.cells) do cells = cells + 1 end
  check(area.done and cells == 17 * 19 - 13, "cached the pen: " .. cells .. " open cells")
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
  W.set(-3, 0, -4, SAP) -- a grown tree on a spot when it starts
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
  check(isSap(W.get(-3, 0, -4)) and plantedSpots(W) == #SPOTS, "all spots planted after resume")
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
  check(W.get(3, -1, -4) == "minecraft:dirt", "stone under a tree spot swapped for dirt")
  check(W.get(-3, -1, -3) == "minecraft:dirt" and W.get(2, -1, -4) == "minecraft:dirt"
    and W.get(-1, -1, -3) == "minecraft:dirt", "stone, sand and podzol under paths swapped for dirt")
  check(W.get(0, -1, 0) == "computercraft:wired_modem_full" and W.get(2, -1, -1) == "computercraft:cable",
    "the modem under home and a cable under a path left alone")
  check(isSap(W.get(3, 0, -4)) and plantedSpots(W) == #SPOTS, "every spot planted, the fixed one too")
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
      check(not isSap(W.get(3, 0, -4)) and W.get(3, -1, -4) == "minecraft:stone", "round 1: no dirt, the stone spot is left alone")
      T.inv[6] = { name = "minecraft:dirt", count = 8 } -- someone gives it dirt
      return
    end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, files, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  check(W.get(3, -1, -4) == "minecraft:dirt" and isSap(W.get(3, 0, -4)), "round 2: dirt laid and the spot planted")
end

print("scenario: PREPARE before planting: measured without dirt, it asks the base for dirt for")
print("          all 4 cells, lays what it gets, waits for more; nothing is planted until the floor is done")
do
  local W = newWorld({ rough = true })
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[4] = { name = "computercraft:wireless_modem_normal", count = 1 } -- (to report)
  local B = fakeBase(W, T, { ["minecraft:dirt"] = 2 }) -- the base has only 2 dirt
  local CELLS = { { 1, -1 }, { -2, -7 }, { -1, -8 }, { 3, -4 } } -- 2 holes, a puddle, a stone spot
  local function fixed()
    local n = 0
    for _, c in ipairs(CELLS) do if W.get(c[1], -1, c[2]) == "minecraft:dirt" then n = n + 1 end end
    return n
  end
  local n = 0
  local function sl()
    n = n + 1
    if n == 1 then
      local a = B.asks[1] or { supply = {}, have = {} }
      check(a.supply.dirt == 4 and (a.have["minecraft:dirt"] or 0) == 0,
        "it asks for dirt for the 4 cells, carrying none: " .. tostring(a.supply.dirt))
      check(a.supply.fuel and a.supply.saplings and a.supply.bonemeal, "and for fuel, saplings, bone meal")
      check(fixed() == 2, "it laid the 2 the base had: " .. fixed() .. "/4")
      check(plantedSpots(W) == 0, "nothing planted: the floor isn't done: " .. plantedSpots(W))
      check(B.asks[#B.asks].supply.dirt == 2, "it asked again for the 2 still needed: " .. tostring(B.asks[#B.asks].supply.dirt))
      B.stock["minecraft:dirt"] = 5 -- the base gets dirt
      return
    end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, {}, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  check(fixed() == 4, "then it finished the floor: " .. fixed() .. "/4")
  check(plantedSpots(W) == #SPOTS, ("and planted every spot: %d/%d"):format(plantedSpots(W), #SPOTS))
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
  for _, c in ipairs({ { 1, -1 }, { -2, -7 }, { -1, -8 }, { 3, -4 } }) do
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
  check(logs == 0, "no logs kept: they go to the chest (fuel comes from the base): " .. logs)
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
  check((W.spilled or 0) == 0, "nothing it dug dropped on the ground: " .. (W.spilled or 0))
  check(W.count(LOG) == 0, "every tree felled")
end

print("scenario: bent trees (acacia, cherry) and 2x2 trunks: it fells every log, no stumps,")
print("          nothing left floating")
do
  local W = newWorld()
  local fences = W.fences()
  local T, api = newTurtle(W, 5000)
  T.inv[1] = { name = SAP, count = 64 }
  local n = 0
  local function sl()
    n = n + 1
    if n == 1 then
      local i = 0
      for key, v in pairs(W.b) do
        if isSap(v) then
          local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
          x, y, z = tonumber(x), tonumber(y), tonumber(z)
          W.set(x, y, z, nil)
          i = i + 1
          if i % 2 == 0 then W.grow2x2(x, y, z) else W.growBent(x, y, z) end
        end
      end
      check(W.count(LOG) > 30, "round 1 grew bent and 2x2 trees: " .. W.count(LOG) .. " logs")
      return
    end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, {}, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  check(W.count(LOG) == 0, "every log felled: " .. W.count(LOG) .. " left")
  check(T.x == 0 and T.y == 0 and T.z == 0, ("home again (%d,%d,%d)"):format(T.x, T.y, T.z))
  check(W.fences() == fences, "no fence touched")
end

print("scenario: after felling, the leaves decay and drop saplings on the ground: the next")
print("          round comes back soon and picks them all up")
do
  local W = newWorld()
  local T, api = newTurtle(W, 5000)
  T.inv[1] = { name = SAP, count = 64 }
  local n, dropped, sapsBefore = 0, 0, 0
  local function saps()
    local c = 0
    for i = 1, 16 do if T.inv[i] and T.inv[i].name == SAP then c = c + T.inv[i].count end end
    return c + (W.chest[SAP] or 0)
  end
  local function sl()
    n = n + 1
    if n == 1 then                                    -- round 2 fells it
      -- ONE tree, at the spot (0,-4), with a wide canopy (cherry, acacia):
      -- leaves out to 4 cells from the trunk
      for key, v in pairs(W.b) do
        local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
        if isSap(v) and not (tonumber(x) == 0 and tonumber(z) == -4) then W.b[key] = nil end
      end
      W.growAll()
      for dx = -4, 4 do for dz = -4, 4 do
        local lx, lz = dx, -4 + dz
        if openCell(lx, lz) and not W.get(lx, 4, lz) then W.set(lx, 4, lz, LEAF) end
      end end
      return
    end
    if n == 2 then                                    -- the leaves have decayed by now
      for _, it in ipairs(W.items) do it.old = true; dropped = dropped + it.count end
      sapsBefore = saps()
      return
    end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, {}, sl), "300")
  check(tostring(err):find("END OF TEST") ~= nil, "three rounds (" .. tostring(err) .. ")")
  check(dropped > 0, "the leaves dropped saplings on the ground: " .. dropped)
  check((W.pickedOld or 0) == dropped,
    ("round 3 picked them all up before they despawned: %d of %d"):format(W.pickedOld or 0, dropped))
  check(saps() >= sapsBefore + dropped, "and kept them")
  check((W.chestSucks or 0) == 0, "never took from its home chest while sweeping: " .. (W.chestSucks or 0))
end

print("scenario: the base switches oak to acacia: a wider grid further from the fence; PREPARE")
print("          first fells the old trees and digs the old saplings, then the new spots are planted")
do
  local ACACIA = "minecraft:acacia_sapling"
  local W = newWorld()
  local T, api = newTurtle(W, 8000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[4] = { name = "computercraft:wireless_modem_normal", count = 1 }
  local B = fakeBase(W, T, { [ACACIA] = 64 }, { [SAP] = true })
  local n = 0
  local function sl()
    n = n + 1
    if n == 1 then
      check(plantedSpots(W) == #SPOTS, "oak planted: " .. plantedSpots(W))
      B.plant = { [ACACIA] = true }  -- the monitor: acacia now (it hears so at its next report)
      return
    end
    if n == 2 then
      W.growAll()                    -- then the old oaks grow, on the old grid
      for y = 0, 5 do for dx = -1, 1 do for dz = -1, 1 do W.set(-6 + dx, y, -13 + dz, nil) end end end
      W.set(-6, 0, -13, SAP)         -- (and one still a sapling)
      return
    end
    if n < 5 then return end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, {}, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "rounds ran (" .. tostring(err) .. ")")
  local A = spotsFor(5, 4)
  local isA, onA, stray = {}, 0, 0
  for _, p in ipairs(A) do isA[p[1] .. "," .. p[2]] = true end
  for key, v in pairs(W.b) do
    local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if y == 0 and isSap(v) then
      if isA[x .. "," .. z] and v == ACACIA then onA = onA + 1 else stray = stray + 1 end
    end
  end
  check(#A == 4 and onA == 4, ("the %d acacia spots planted: %d"):format(#A, onA))
  check(stray == 0, "no old sapling left: " .. stray)
  check(W.count(LOG) == 0, "every old tree felled: " .. W.count(LOG))
end

print("scenario: low on fuel at home: it asks for enough fuel through its chest (no modem on the")
print("          wired network needed), takes it and burns it; never the old push request")
do
  local W = newWorld()
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[4] = { name = "computercraft:wireless_modem_normal", count = 1 }
  fakeBase(W, T, { ["minecraft:charcoal"] = 64 })
  local fuelAfter
  local ok, err = run(makeEnv(T, api, {}, function() fuelAfter = T.fuel; error("END OF TEST") end), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "one round (" .. tostring(err) .. ")")
  local asked, pushed = nil, false
  for _, m in ipairs(T.sent or {}) do
    if m.state == "supply" then asked = m.supply.fuel end
    if m.wantFuel then pushed = true end
  end
  check(not pushed, "no wired-network fuel request (the one that needs its modem on)")
  check(asked and asked >= 16, "asked for fuel at its chest: " .. tostring(asked))
  check(fuelAfter and fuelAfter >= 600, "and has it: fuel " .. tostring(fuelAfter))
end

print("scenario: the base has no fuel (the live forester-4): nearly empty at home it asks at its")
print("          chest, says the base had none, and waits; no wired-network request, no modem message")
do
  local W = newWorld()
  local T, api = newTurtle(W, 3000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[4] = { name = "computercraft:wireless_modem_normal", count = 1 }
  fakeBase(W, T, {}) -- no fuel at the base
  local n = 0
  local function sl()
    n = n + 1
    if n == 1 then T.fuel = 40; return end
    if n < 3 then return end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, {}, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "it waits at home, no error (" .. tostring(err) .. ")")
  local pushed = false
  for _, m in ipairs(T.sent or {}) do if m.wantFuel then pushed = true end end
  check(not pushed, "never the wired-network fuel request")
  check(T.x == 0 and T.z == 0, "at home")
end

print("scenario: with a Geo Scanner in its toolbelt it fells every log by its scanned position,")
print("          logs floating in the leaves too; the compass goes back in its slot")
do
  local W = newWorld()
  local T, api = newTurtle(W, 8000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[6] = { name = "advancedperipherals:geo_scanner", count = 1 }
  local n = 0
  local floating = 0
  local function sl()
    n = n + 1
    if n == 1 then
      local i = 0
      for key, v in pairs(W.b) do
        if isSap(v) then
          local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
          x, y, z = tonumber(x), tonumber(y), tonumber(z)
          W.set(x, y, z, nil)
          i = i + 1
          if i % 2 == 0 then W.grow2x2(x, y, z) else W.growBent(x, y, z) end
          -- a log in the canopy touching no other log (big modded trees)
          W.set(x + 2, y + 5, z + 2, LOG); floating = floating + 1
        end
      end
      return
    end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, {}, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  check(W.count(LOG) == 0, ("every log felled, %d floating ones too: %d left"):format(floating, W.count(LOG)))
  check((T.scans or 0) > 0, "it scanned: " .. tostring(T.scans))
  local kept = false
  for i = 1, 16 do if T.inv[i] and T.inv[i].name == "advancedperipherals:geo_scanner" then kept = true end end
  check(T.right == "minecraft:compass" and kept, "compass back in its slot, scanner in its toolbelt")
end

print("scenario: SHEAR on: it shears every leaf of the tree with the Weak Automata Core and shears")
print("          BEFORE it cuts a log; leaf blocks, not saplings; the core and compass go back")
do
  local W = newWorld()
  local T, api = newTurtle(W, 8000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[6] = { name = "advancedperipherals:geo_scanner", count = 1 }
  -- the base sends the shears and the core with its first supply, and says SHEAR
  local B = fakeBase(W, T, { ["minecraft:shears"] = 1, ["advancedperipherals:weak_automata_core"] = 1,
                             ["minecraft:charcoal"] = 64 })
  B.shear = true
  T.inv[7] = { name = "computercraft:wireless_modem_normal", count = 1 } -- (to talk at home)
  local n, grown, leavesAtFell = 0, 0, {}
  local function sl(secs)
    if (tonumber(secs) or 0) < 5 then return end -- (a cooldown, not the wait between rounds)
    n = n + 1
    if n == 1 then
      for key, v in pairs(W.b) do
        if isSap(v) then
          local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
          W.growAt(tonumber(x), tonumber(y), tonumber(z))
        end
      end
      grown = W.count("minecraft:oak_leaves")
      return
    end
    error("END OF TEST")
  end
  -- every log cut: how many leaves still touch it (none, if it sheared first;
  -- the next tree's canopy never touches this tree's logs)
  local origDig = api.dig
  local function watch(fn, dx, dy)
    return function()
      local d = DIRS[T.h]
      local x, y, z = T.x + (dx and d[1] or 0), T.y + (dy or 0), T.z + (dx and d[2] or 0)
      local b = W.get(x, y, z)
      if b and b:find("_log$") and y > 1 then
        local near = 0
        for _, a in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
          local o = W.get(x + a[1], y + a[2], z + a[3])
          if o and o:find("_leaves$") then near = near + 1 end
        end
        leavesAtFell[#leavesAtFell + 1] = near
      end
      return fn()
    end
  end
  api.dig = watch(origDig, true, 0)
  api.digUp = watch(api.digUp, false, 1)
  api.digDown = watch(api.digDown, false, -1)
  local ok, err = run(makeEnv(T, api, {}, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  check(grown > 20 and (T.sheared or 0) >= grown * 0.8,
    ("it sheared the leaves: %d of %d"):format(T.sheared or 0, grown))
  check(W.count(LOG) == 0, "every log felled after: " .. W.count(LOG) .. " left")
  local worst = 0
  for _, v in ipairs(leavesAtFell) do worst = math.max(worst, v) end
  check(#leavesAtFell > 0 and worst == 0,
    ("no log is cut while a leaf still touches it (most touching a cut: %d, of %d cuts)"):format(worst, #leavesAtFell))
  local core, shears = false, false
  for i = 1, 16 do
    local it = T.inv[i]
    if it and it.name == "advancedperipherals:weak_automata_core" then core = true end
    if it and it.name == "minecraft:shears" then shears = true end
  end
  check(core and shears and T.right == "minecraft:compass", "the core and shears in its toolbelt, the compass on")
  local leafItems = W.ground("minecraft:oak_leaves")
  for i = 1, 27 do if W.slots[i] and W.slots[i].name == "minecraft:oak_leaves" then leafItems = leafItems + W.slots[i].count end end
  for i = 1, 16 do if T.inv[i] and T.inv[i].name == "minecraft:oak_leaves" then leafItems = leafItems + T.inv[i].count end end
  check(leafItems > 0, "leaf blocks to keep (on the ground, carried or in the chest): " .. leafItems)
end

print("scenario: big oaks taller than the Geo Scanner's reach: it scans again higher up and fells the")
print("          whole canopy, nothing left floating")
do
  local W = newWorld()
  local T, api = newTurtle(W, 8000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[6] = { name = "advancedperipherals:geo_scanner", count = 1 }
  local n = 0
  local function sl(secs)
    if (tonumber(secs) or 0) < 5 then return end
    n = n + 1
    if n == 1 then
      for key, v in pairs(W.b) do
        if isSap(v) then
          local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
          W.set(tonumber(x), tonumber(y), tonumber(z), nil)
          W.growTall(tonumber(x), tonumber(y), tonumber(z))
        end
      end
      return
    end
    error("END OF TEST")
  end
  local files = {}
  local ok, err = run(makeEnv(T, api, files, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  check(W.count(LOG) == 0, "every log of the big oaks felled, the canopy too: " .. W.count(LOG) .. " left")
  local flog = files["forester.log"] or ""
  check(flog:find("fell %-?%d+,%-?%d+ layer 2") ~= nil, "forester.log says what each felling saw, layer by layer")
end

print("scenario: oaks whose canopies reach over the neighbouring spots (live: 40-55 logs 'another spot's',")
print("          canopies left floating): every log felled, nothing left hanging")
do
  local W = newWorld()
  local T, api = newTurtle(W, 8000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[6] = { name = "advancedperipherals:geo_scanner", count = 1 }
  local n = 0
  local function sl(secs)
    if (tonumber(secs) or 0) < 5 then return end
    n = n + 1
    if n == 1 then
      for key, v in pairs(W.b) do
        if isSap(v) then
          local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
          x, y, z = tonumber(x), tonumber(y), tonumber(z)
          W.set(x, y, z, nil)
          W.growWide(x, y, z)
        end
      end
      return
    end
    error("END OF TEST")
  end
  local files = {}
  local ok, err = run(makeEnv(T, api, files, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  check(W.count(LOG) == 0, "every log felled, the spread canopies too: " .. W.count(LOG) .. " left")
end

print("scenario: canopies floating with no trunk at all (live: left by older code), over other spots'")
print("          columns: debris, taken by whichever tree is felled near it")
do
  local W = newWorld()
  local T, api = newTurtle(W, 8000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[6] = { name = "advancedperipherals:geo_scanner", count = 1 }
  local n, floating = 0, 0
  local function sl(secs)
    if (tonumber(secs) or 0) < 5 then return end
    n = n + 1
    if n == 1 then
      local spots = {}
      for key, v in pairs(W.b) do
        if isSap(v) then
          local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
          spots[#spots + 1] = { tonumber(x), tonumber(y), tonumber(z) }
        end
      end
      for i, p in ipairs(spots) do
        W.set(p[1], p[2], p[3], nil)
        W.growWide(p[1], p[2], p[3])
        if i % 2 == 0 then
          -- this one's trunk gone: its branches and canopy float over the
          -- neighbouring spots (and a sapling planted under it again)
          for h = 0, 6 do W.set(p[1], p[2] + h, p[3], nil) end
          W.set(p[1], p[2], p[3], SAP)
          floating = floating + 1
        end
      end
      return
    end
    error("END OF TEST")
  end
  local files = {}
  local ok, err = run(makeEnv(T, api, files, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  check(floating > 0 and W.count(LOG) == 0, ("%d trunkless canopies, every log taken: %d left"):format(floating, W.count(LOG)))
end

print("scenario: a tree hangs over its spot (its bottom log cut, live): it fells it, never plants under it")
do
  local W = newWorld()
  local T, api = newTurtle(W, 8000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[6] = { name = "advancedperipherals:geo_scanner", count = 1 }
  local n, hanging = 0, 0
  local function sl(secs)
    if (tonumber(secs) or 0) < 5 then return end
    n = n + 1
    if n == 1 then
      for key, v in pairs(W.b) do
        if isSap(v) then
          local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
          x, y, z = tonumber(x), tonumber(y), tonumber(z)
          W.set(x, y, z, nil)
          W.growTall(x, y, z)
          W.set(x, y, z, nil) -- (the bottom log gone: the tree hangs one above the ground)
          hanging = hanging + 1
        end
      end
      return
    end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, {}, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "two rounds (" .. tostring(err) .. ")")
  check(hanging > 0 and W.count(LOG) == 0, ("%d hanging trees, every log felled: %d left"):format(hanging, W.count(LOG)))
end

print("scenario: accessories: kept while picked; an unpicked one goes back, but never the modem a turtle")
print("          talks through (no wired modem at its home)")
do
  local W = newWorld()
  local T, api = newTurtle(W, 100)
  local files = {}
  local env = makeEnv(T, api, files, function() end)
  local link = env.require("link")
  local MODEM, SHEARS = "computercraft:wireless_modem_normal", "minecraft:shears"
  local function told(list) files["agent.cfg"] = env.textutils.serialize({ role = "forester", accessories = list }) end
  told({})
  check(link.isKeptItem(MODEM), "no wired modem at home: its wireless modem is kept, even unpicked")
  check(not link.isKeptItem(SHEARS), "unpicked shears: not kept (they go back into the chest)")
  T.back = "computercraft:wired_modem_full" -- (its home's wired modem, behind it)
  check(not link.isKeptItem(MODEM), "a wired modem at home: an unpicked wireless modem goes back")
  told({ MODEM, SHEARS })
  check(link.isKeptItem(MODEM) and link.isKeptItem(SHEARS), "picked: both kept")
  files["agent.cfg"] = env.textutils.serialize({ role = "forester" })
  check(link.isKeptItem(MODEM), "never told (an older turtle): its modem kept as before")
end

print("scenario: with an Environment Detector it finds every item lying in the pen after each tree")
print("          (preparing too: no blind sweep), wherever it fell; the compass goes back")
do
  local ACACIA = "minecraft:acacia_sapling"
  local W = newWorld()
  local T, api = newTurtle(W, 8000)
  T.inv[1] = { name = SAP, count = 64 }
  T.inv[4] = { name = "computercraft:wireless_modem_normal", count = 1 }
  T.inv[6] = { name = "advancedperipherals:environment_detector", count = 1 }
  local B = fakeBase(W, T, { [ACACIA] = 64 }, { [SAP] = true })
  local n, dropped = 0, 0
  local function sl()
    n = n + 1
    if n == 1 then
      W.growAll()                    -- the oak spots grow
      B.plant = { [ACACIA] = true }  -- acacia now: PREPARE clears the old spots
      return
    end
    if n == 2 then
      -- items far from any route (corners), as if dropped by decaying leaves
      W.pickedOld = 0
      for _, c in ipairs({ { 8, -18 }, { -8, -18 }, { 8, -1 }, { -8, -10 } }) do
        W.drop(c[1], c[2], SAP, 1); W.items[#W.items].old = true; dropped = dropped + 1
      end
      return
    end
    if n < 4 then return end
    error("END OF TEST")
  end
  local ok, err = run(makeEnv(T, api, {}, sl), "10")
  check(tostring(err):find("END OF TEST") ~= nil, "rounds ran (" .. tostring(err) .. ")")
  check((T.looks or 0) > 0, "it looked with the detector: " .. tostring(T.looks))
  check((W.pickedOld or 0) == dropped, ("every item picked up: %d of %d"):format(W.pickedOld or 0, dropped))
  local t = (B.asks[1] and B.asks[1].supply.tools) or {}
  check(#t == 1 and t[1] == "advancedperipherals:geo_scanner", "it asks for the tool it lacks (the scanner), not the one it has: " .. table.concat(t, ","))
  check(T.right == "minecraft:compass", "compass back in its slot")
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
  local M4 = spotsFor(4, 3)
  W.set(-1, -1, -2, "minecraft:stone") -- south of the spot (-1,-3): a side cell on stone
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
    if y == 0 and isSap(v) and not ((x + 5) % 4 == 0 and (z + 15) % 4 == 0) then off = off + 1 end
  end
  check(off == 0, "nothing planted off the 4-grid: " .. off)
  check(W.get(-1, -1, -2) == "minecraft:dirt", "the stone under a menril spot's side cell became dirt")
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
