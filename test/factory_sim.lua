-- End-to-end harness: the whole factory with the real code everywhere.
--
-- Base: factory.lua + storage.lua + dist.lua over a fake peripheral network
-- (barrels, a turtle home chest, the assembler on a wired modem, the installer disk
-- drive). Assembler: assembler.lua on a crafty turtle that crafts the way CC
-- does (only the 3x3 window may hold items). New turtles boot like CC: from the
-- disk under the build spot if it has a startup file, else their own
-- startup.lua; os.reboot reboots them. Everything runs as coroutines.
--
-- Usage: lua factory_sim.lua <repo dir>
local REPO = arg[1] or ".."

local failures = 0
local function check(cond, msg)
  if cond then print("  ok   " .. msg) else print("  FAIL " .. msg); failures = failures + 1 end
end
local function readFile(path) local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s end
local VERBOSE = os.getenv("VERBOSE")

-- ------------------------------------------------------------ serialize --
local function ser(v)
  if type(v) == "table" then
    local p = {}
    for k, x in pairs(v) do p[#p + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
    return "{" .. table.concat(p, ",") .. "}"
  elseif type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end
local textutils = { serialize = ser, unserialize = function(s) return load("return " .. s)() end }

-- ------------------------------------------------------------------- vfs --
-- A computer's filesystem: a flat table path -> content, plus mounts
-- (e.g. disk -> the disk's table).
local function newFS(files, mounts)
  mounts = mounts or {}
  local function norm(p) p = p:gsub("^/+", ""):gsub("/+$", ""); return p end
  local function resolve(p)
    p = norm(p)
    local first, rest = p:match("^([^/]+)/?(.*)$")
    if first and mounts[first] then return mounts[first], rest end
    return files, p
  end
  local fs = {}
  function fs.combine(a, b) a, b = norm(a), norm(b); if a == "" then return b end; if b == "" then return a end; return a .. "/" .. b end
  function fs.getDir(p) p = norm(p); return p:match("^(.*)/[^/]*$") or "" end
  function fs.exists(p)
    local t, r = resolve(p)
    if r == "" then return true end
    if t[r] then return true end
    for k in pairs(t) do if k:sub(1, #r + 1) == r .. "/" then return true end end
    return false
  end
  function fs.isDir(p) local t, r = resolve(p); return fs.exists(p) and t[r] == nil end
  function fs.makeDir() end
  function fs.list(p)
    local t, r = resolve(p)
    local out, seen = {}, {}
    local prefix = r == "" and "" or r .. "/"
    for k in pairs(t) do
      if k:sub(1, #prefix) == prefix then
        local name = k:sub(#prefix + 1):match("^([^/]+)")
        if name and not seen[name] then seen[name] = true; out[#out + 1] = name end
      end
    end
    table.sort(out)
    return out
  end
  function fs.open(p, mode)
    local t, r = resolve(p)
    if mode == "r" then
      if not t[r] then return nil end
      local c = t[r]
      return { readAll = function() return c end, close = function() end }
    end
    local buf = { mode == "a" and t[r] or nil }
    return { write = function(s) buf[#buf + 1] = s end, close = function() t[r] = table.concat(buf) end }
  end
  function fs.delete(p)
    local t, r = resolve(p)
    for k in pairs(t) do if k == r or k:sub(1, #r + 1) == r .. "/" then t[k] = nil end end
  end
  function fs.move(a, b) local ta, ra = resolve(a); local tb, rb = resolve(b); tb[rb] = ta[ra]; ta[ra] = nil end
  function fs.copy(a, b) local ta, ra = resolve(a); local tb, rb = resolve(b); tb[rb] = ta[ra] end
  return fs
end

-- ----------------------------------------------------------------- world --
local DIRS = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } } -- dx, dz; 0 = north
local W = { b = {}, inv = {}, turtles = {}, clock = 0 }
local function k(x, y, z) return x .. "," .. y .. "," .. z end
function W.get(x, y, z) return W.b[k(x, y, z)] end
function W.set(x, y, z, v) W.b[k(x, y, z)] = v end

-- Inventories (chests, barrels) live at a position and have a peripheral name.
local function newInv(name, x, y, z, size)
  local I = { name = name, slots = {}, size = size or 27, x = x, y = y, z = z }
  W.inv[name] = I
  if x then W.invAt = W.invAt or {}; W.invAt[k(x, y, z)] = I; W.set(x, y, z, name:match("^(.-)_%d+$")) end
  function I.insert(item, n, toSlot)
    local moved = 0
    local order = {}
    if toSlot then order = { toSlot } else for i = 1, I.size do order[#order + 1] = i end end
    for _, i in ipairs(order) do
      local s = I.slots[i]
      if s and s.name == item and s.count < 64 then
        local m = math.min(64 - s.count, n - moved); s.count = s.count + m; moved = moved + m
      end
      if moved >= n then return moved end
    end
    for _, i in ipairs(order) do
      if not I.slots[i] and moved < n then
        local m = math.min(64, n - moved); I.slots[i] = { name = item, count = m }; moved = moved + m
      end
    end
    return moved
  end
  function I.take(slot, n)
    local s = I.slots[slot]
    if not s then return nil, 0 end
    local m = math.min(n or s.count, s.count)
    s.count = s.count - m
    if s.count == 0 then I.slots[slot] = nil end
    return s.name, m
  end
  function I.firstSlot()
    for i = 1, I.size do if I.slots[i] then return i end end
  end
  function I.count(item)
    local n = 0
    for _, s in pairs(I.slots) do if s.name == item then n = n + s.count end end
    return n
  end
  return I
end

-- ------------------------------------------------------- wired modems --
-- As strict as CC 1.120.2 (WiredModemFullBlockEntity): a full modem the player
-- enabled stays on while it shares at least one peripheral; when the last one
-- goes (a turtle leaving) it switches OFF and does not re-attach anything that
-- arrives later. W.modemOff[key] records that.
local SIX6 = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
W.modemOff = {}
local function isPeripheralBlock(b)
  return b and (b:find("^computercraft:computer") or b:find("^computercraft:turtle") or b == "computercraft:disk_drive"
    or b:find("chest") or b:find("barrel") or b:find("furnace")) and true or false
end
local function modemAt(x, y, z) return W.get(x, y, z) == "computercraft:wired_modem_full" end
-- after a turtle left (x,y,z): modems next to it with nothing left to share go off
local function turtleLeft(x, y, z)
  for _, d in ipairs(SIX6) do
    local mx, my, mz = x + d[1], y + d[2], z + d[3]
    if modemAt(mx, my, mz) then
      local any = false
      for _, e in ipairs(SIX6) do
        if isPeripheralBlock(W.get(mx + e[1], my + e[2], mz + e[3])) then any = true end
      end
      if not any then W.modemOff[mx .. "," .. my .. "," .. mz] = true end
    end
  end
end
-- is turtle T shared on the network (touching a modem that is on)?
local function turtleShared(T)
  for _, d in ipairs(SIX6) do
    local mx, my, mz = T.x + d[1], T.y + d[2], T.z + d[3]
    if modemAt(mx, my, mz) and not W.modemOff[mx .. "," .. my .. "," .. mz] then return true end
  end
  return false
end

-- ----------------------------------------------------- peripheral network --
-- The base's view: every inventory plus the disk drive, by name.
local DISK = {}
local function baseNetwork()
  local api = {}
  -- A turtle touching a full wired modem is on the network as turtle_<id>
  -- (in the game the modem must be enabled; the sim assumes it is). Its
  -- peripheral has getID, and its inventory takes pushItems (CC 1.120.2:
  -- the peripheral's target is the turtle block, a Container).
  local function netTurtle(name)
    local id = tonumber((name or ""):match("^turtle_(%d+)$"))
    local T = id and W.turtles[id]
    if T and turtleShared(T) then return T end
  end
  local function intoTurtle(T, item, n)
    local moved = 0
    for i = 1, 16 do
      local s = T.inv[i]
      if moved >= n then break end
      if s and s.name == item and s.count < 64 then
        local m = math.min(64 - s.count, n - moved); s.count = s.count + m; moved = moved + m
      elseif not s then
        local m = math.min(64, n - moved); T.inv[i] = { name = item, count = m }; moved = moved + m
      end
    end
    return moved
  end
  function api.getNames()
    local n = { "drive_0" }
    for name in pairs(W.inv) do n[#n + 1] = name end
    for id in pairs(W.turtles) do if netTurtle("turtle_" .. id) then n[#n + 1] = "turtle_" .. id end end
    table.sort(n)
    return n
  end
  function api.hasType(name, t)
    if name == "drive_0" then return t == "drive" end
    if netTurtle(name) then return t == "turtle" end
    return W.inv[name] ~= nil and t == "inventory"
  end
  function api.call(name, method, ...)
    local a = { ... }
    if name == "drive_0" then
      if method == "hasData" then return true end
      if method == "getMountPath" then return "disk" end
    end
    local NT = netTurtle(name)
    if NT then
      if method == "getID" then return NT.id end
      error("turtle peripheral: no method " .. method)
    end
    local I = assert(W.inv[name], name)
    if method == "list" then
      local out = {}
      for i, s in pairs(I.slots) do out[i] = { name = s.name, count = s.count } end
      return out
    elseif method == "getItemDetail" then
      local st = I.slots[a[1]]
      return st and { name = st.name, count = st.count, damage = st.damage or 0, enchantments = st.enchantments,
                      nbt = st.nbt, displayName = st.displayName } or nil
    elseif method == "pushItems" then
      local to, slot, limit, toSlot = W.inv[a[1]], a[2], a[3], a[4]
      local s = I.slots[slot]
      local TT = netTurtle(a[1])
      if s and TT then
        local moved = intoTurtle(TT, s.name, math.min(limit or s.count, s.count))
        I.take(slot, moved)
        return moved
      end
      if not s or not to then return 0 end
      local n = math.min(limit or s.count, s.count)
      local moved = to.insert(s.name, n, toSlot)
      I.take(slot, moved)
      return moved
    elseif method == "pullItems" then
      -- from an inventory or a networked turtle, by slot, into this one
      local fromName, slot, limit, toSlot = a[1], a[2], a[3], a[4]
      local FT = netTurtle(fromName)
      if FT then
        local st = FT.inv[slot]
        if not st then return 0 end
        local moved = I.insert(st.name, math.min(limit or st.count, st.count), toSlot)
        st.count = st.count - moved
        if st.count <= 0 then FT.inv[slot] = nil end
        return moved
      end
      local from = W.inv[fromName]
      if not from then error("pullItems: no inventory " .. tostring(fromName)) end
      local st = from.slots[slot]
      if not st then return 0 end
      local moved = I.insert(st.name, math.min(limit or st.count, st.count), toSlot)
      from.take(slot, moved)
      return moved
    end
    error("unknown method " .. method)
  end
  return api
end

-- ---------------------------------------------------------------- turtles --
local PTYPE = { ["advancedperipherals:geo_scanner"] = "geo_scanner", ["minecraft:compass"] = "compass",
                ["computercraft:wireless_modem_normal"] = "modem", ["minecraft:crafting_table"] = "workbench" }
local TURTLE_ITEM = "computercraft:turtle_advanced"
local DROPS = { ["minecraft:iron_ore"] = "minecraft:raw_iron", ["minecraft:stone"] = "minecraft:cobblestone" }

local bus = { inbox = {}, sent = {} }

local function newTurtleEntity(id, x, y, z, h, files)
  local T = { id = id, x = x, y = y, z = z, h = h, fuel = 0, sel = 1, inv = {}, files = files or {},
              label = nil, on = false }
  W.turtles[id] = T
  W.set(x, y, z, TURTLE_ITEM)
  return T
end

local function turtleAt(x, y, z)
  for _, T in pairs(W.turtles) do if T.x == x and T.y == y and T.z == z then return T end end
end

local function addItem(T, item, n, meta)
  while n > 0 do
    local placed = false
    for kk = 0, 15 do
      local i = (T.sel - 1 + kk) % 16 + 1
      local s = T.inv[i]
      if s and s.name == item and s.count < 64 and not meta and not s.meta then
        local m = math.min(64 - s.count, n); s.count = s.count + m; n = n - m; placed = true; break
      end
      if not s then
        local m = math.min(64, n); T.inv[i] = { name = item, count = m, meta = meta }; n = n - m; placed = true; break
      end
    end
    if not placed then return false end
  end
  return true
end

-- crafting the way TurtleInventoryCrafting does it, against the REAL recipes
-- extracted from the server's jars (test/fixtures/recipes.json)
local FIX = dofile(REPO .. "/test/fixtures/recipes.lua")
local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local IS_GRID = {}
for _, c in ipairs(GRID) do IS_GRID[c] = true end
local HAMMER_USES = 64 -- sim durability of an ore hammer

local function matches(name, ing)
  if type(ing) == "string" then return name == ing end
  if ing.item then return name == ing.item end
  if ing.tag then
    for _, it in ipairs(FIX.tags[ing.tag] or {}) do if it == name then return true end end
    return false
  end
  for _, alt in ipairs(ing) do if matches(name, alt) then return true end end
  return false
end

local function shapedMatch(r, g)
  local pat = r.pattern
  local h, w = #pat, #pat[1]
  for _, mirror in ipairs({ false, true }) do
    for dr = 0, 3 - h do for dc = 0, 3 - w do
      local ok = true
      for row = 0, 2 do for col = 0, 2 do
        local pr, pc = row - dr, col - dc
        local want
        if pr >= 0 and pr < h and pc >= 0 and pc < w then
          local ci = mirror and (w - pc) or (pc + 1)
          local ch = pat[pr + 1]:sub(ci, ci)
          if ch ~= " " then want = r.key[ch] end
        end
        local have = g[row * 3 + col]
        if want then
          if not have or not matches(have, want) then ok = false end
        elseif have then ok = false end
      end end
      if ok then return true end
    end end
  end
  return false
end

local function shapelessMatch(r, names)
  if #names ~= #r.ingredients then return false end
  local used = {}
  for _, ing in ipairs(r.ingredients) do
    local found = false
    for i, name in ipairs(names) do
      if not used[i] and matches(name, ing) then used[i], found = true, true; break end
    end
    if not found then return false end
  end
  return true
end

local function craft(T, limit)
  for i = 1, 16 do if T.inv[i] and not IS_GRID[i] then return false end end
  local g, names, minStack = {}, {}, math.huge
  for idx, c in ipairs(GRID) do
    local st = T.inv[c]
    if st then g[idx - 1] = st.name; names[#names + 1] = st.name; minStack = math.min(minStack, st.count) end
  end
  if #names == 0 then return false end
  local result, count, meta
  -- CC's own turtle upgrade recipe: an upgrade left and/or right of a turtle in a row
  local function isUpgrade(n) return n and (PTYPE[n] or n:find("pickaxe")) end
  if g[1] and g[1]:find("^computercraft:turtle_") and (isUpgrade(g[0]) or isUpgrade(g[2]))
     and (not g[0] or isUpgrade(g[0])) and (not g[2] or isUpgrade(g[2])) and #names == (g[0] and 1 or 0) + (g[2] and 1 or 0) + 1 then
    result, count, meta = g[1], 1, { right = g[0], left = g[2] }
  else
    for _, r in pairs(FIX.crafting) do
      local shaped = r.type == "minecraft:crafting_shaped" or r.type == "computercraft:transform_shaped"
      if (shaped and shapedMatch(r, g)) or (r.type == "minecraft:crafting_shapeless" and shapelessMatch(r, names)) then
        result, count = r.result.id, r.result.count or 1
        break
      end
    end
  end
  if not result then return false end
  local times = math.min(limit or 64, minStack)
  local remainders = {}
  for _, c in ipairs(GRID) do
    local st = T.inv[c]
    if st then
      if st.name:find("_ore_hammer$") then
        local uses = (st.meta and st.meta.uses or HAMMER_USES) - times
        if uses > 0 then remainders[#remainders + 1] = { name = st.name, meta = { uses = uses } } end
      end
      st.count = st.count - times
      if st.count <= 0 then T.inv[c] = nil end
    end
  end
  addItem(T, result, count * times, meta)
  for _, rem in ipairs(remainders) do addItem(T, rem.name, 1, rem.meta) end
  return true
end

-- furnaces, smelting by the REAL smelting recipes
local SMELT_OUT = {}
for _, r in pairs(FIX.smelting) do
  local ing = r.ingredient
  local list = ing.tag and FIX.tags[ing.tag] or { ing.item }
  for _, it in ipairs(list or {}) do SMELT_OUT[it] = r.result.id end
end
W.furnaces = {}
local function newFurnace(name, blast)
  local I = newInv(name, nil, nil, nil, 3)
  I.burn, I.progress, I.blast = 0, 0, blast
  W.furnaces[#W.furnaces + 1] = I
  return I
end
function W.smeltTick()
  for _, I in ipairs(W.furnaces) do
    local inp = I.slots[1]
    local out = inp and SMELT_OUT[inp.name]
    if out and I.blast and not (inp.name:find("raw_") or inp.name:find("_dust$")) then out = nil end
    if out and (not I.slots[3] or I.slots[3].name == out) then
      if I.burn <= 0 and I.slots[2] then I.take(2, 1); I.burn = 8 end
      if I.burn > 0 then
        I.progress = I.progress + 1
        if I.progress >= 3 then
          I.progress, I.burn = 0, I.burn - 1
          I.take(1, 1)
          I.insert(out, 1, 3)
          W.smelted = (W.smelted or 0) + 1
        end
      end
    end
  end
end

local scheduler = { cos = {} }
local function yield() local _, main = coroutine.running(); if not main then coroutine.yield() end end

local bootTurtle -- forward

local function turtleApi(T)
  local function front() local d = DIRS[T.h]; return T.x + d[1], T.y, T.z + d[2] end
  local function at(dir)
    if dir == "up" then return T.x, T.y + 1, T.z elseif dir == "down" then return T.x, T.y - 1, T.z end
    return front()
  end
  local function move(x, y, z)
    if W.get(x, y, z) or T.fuel < 1 then return false end
    W.set(T.x, T.y, T.z, nil)
    turtleLeft(T.x, T.y, T.z)
    T.fuel = T.fuel - 1; T.x, T.y, T.z = x, y, z
    W.set(x, y, z, TURTLE_ITEM)
    yield()
    return true
  end
  local function dig(x, y, z)
    local b = W.get(x, y, z)
    if not b or b == "minecraft:bedrock" or b:find("^computercraft") or b:find("chest") or b:find("barrel")
       or b == "computercraft:disk_drive" then return false end
    W.set(x, y, z, nil)
    addItem(T, DROPS[b] or b, 1)
    return true
  end
  local function insp(b) if b then return true, { name = b, tags = {} } end; return false, "No block" end
  local function invAt(x, y, z) return W.invAt and W.invAt[k(x, y, z)] end
  local function suck(dir, n)
    local I = invAt(at(dir))
    if not I then return false end
    local slot = I.firstSlot()
    if not slot then return false end
    local s = I.slots[slot]
    local m = math.min(n or s.count, s.count)
    local item = s.name
    I.take(slot, m)
    addItem(T, item, m)
    return true
  end
  local function drop(dir, n)
    local s = T.inv[T.sel]
    if not s then return false end
    local m = math.min(n or s.count, s.count)
    local x, y, z = at(dir)
    local I = invAt(x, y, z)
    local other = turtleAt(x, y, z)
    if I then
      m = I.insert(s.name, m)
    elseif other then
      for i = 1, 16 do
        if not other.inv[i] then other.inv[i] = { name = s.name, count = m, meta = s.meta }; break end
        if other.inv[i].name == s.name and i == 16 then m = 0 end
      end
    end
    s.count = s.count - m
    if s.count == 0 then T.inv[T.sel] = nil end
    return m > 0
  end
  local api = {}
  function api.forward() return move(front()) end
  function api.back() local d = DIRS[T.h]; return move(T.x - d[1], T.y, T.z - d[2]) end
  function api.up() return move(T.x, T.y + 1, T.z) end
  function api.down() return move(T.x, T.y - 1, T.z) end
  function api.turnLeft() T.h = (T.h + 3) % 4; return true end
  function api.turnRight() T.h = (T.h + 1) % 4; return true end
  function api.dig() return dig(at("fwd")) end
  function api.digUp() return dig(at("up")) end
  function api.digDown() return dig(at("down")) end
  function api.detect() return W.get(at("fwd")) ~= nil end
  function api.detectUp() return W.get(at("up")) ~= nil end
  function api.detectDown() return W.get(at("down")) ~= nil end
  function api.inspect() return insp(W.get(at("fwd"))) end
  function api.inspectUp() return insp(W.get(at("up"))) end
  function api.inspectDown() return insp(W.get(at("down"))) end
  function api.attack() return false end
  api.attackUp, api.attackDown = api.attack, api.attack
  function api.suck(n) return suck("fwd", n) end
  function api.suckUp(n) return suck("up", n) end
  function api.suckDown(n) return suck("down", n) end
  function api.drop(n) return drop("fwd", n) end
  function api.dropUp(n) return drop("up", n) end
  function api.dropDown(n) return drop("down", n) end
  function api.getFuelLevel() return T.fuel end
  function api.getFuelLimit() return 20000 end
  function api.select(i) T.sel = i; return true end
  function api.getItemCount(i) return T.inv[i] and T.inv[i].count or 0 end
  function api.getItemDetail(i) local s = T.inv[i]; return s and { name = s.name, count = s.count } or nil end
  function api.transferTo(to, n)
    local s = T.inv[T.sel]
    if not s or to == T.sel then return false end
    n = math.min(n or s.count, s.count)
    local d = T.inv[to]
    if d and (d.name ~= s.name or d.meta or s.meta) then return false end
    if d then d.count = d.count + n else T.inv[to] = { name = s.name, count = n, meta = s.meta } end
    s.count = s.count - n
    if s.count == 0 then T.inv[T.sel] = nil end
    return true
  end
  function api.refuel(n)
    local s = T.inv[T.sel]
    if not s or (s.name ~= "minecraft:coal" and s.name ~= "minecraft:charcoal") then return false end
    if n == 0 then return true end
    n = math.min(n or s.count, s.count)
    T.fuel = T.fuel + 80 * n; s.count = s.count - n
    if s.count == 0 then T.inv[T.sel] = nil end
    return true
  end
  function api.place()
    local s = T.inv[T.sel]
    if not s or not s.name:find("^computercraft:turtle_") then return false end
    local x, y, z = front()
    if W.get(x, y, z) then return false end
    local id = scheduler.nextId; scheduler.nextId = id + 1
    local N = newTurtleEntity(id, x, y, z, T.h)
    N.left, N.right = s.meta and s.meta.left, s.meta and s.meta.right
    T.inv[T.sel] = nil
    return true
  end
  local function equip(side)
    local cur, new = T[side], T.inv[T.sel]
    T[side] = new and new.name or nil
    T.inv[T.sel] = cur and { name = cur, count = 1 } or nil
    return true
  end
  function api.equipLeft() return equip("left") end
  function api.equipRight() return equip("right") end
  if T.left == "minecraft:crafting_table" or T.right == "minecraft:crafting_table" then
    function api.craft(limit) return craft(T, limit) end
  end
  return api, front
end

local function scannerFor(T)
  return { scan = function(r)
    local out = {}
    for x = -r, r do for y = -r, r do for z = -r, r do
      local b = W.get(T.x + x, T.y + y, T.z + z)
      if b then
        local tags = b:find("_ore$") and { "c:ores" } or {}
        out[#out + 1] = { name = b, tags = tags, x = x, y = y, z = z }
      end
    end end end
    return out
  end }
end

-- A turtle computer's Lua environment
local function turtleEnv(T)
  local api, front = turtleApi(T)
  local mounts = {}
  -- the installer disk is attached when the drive is right below the turtle
  local function diskAttached() return W.get(T.x, T.y - 1, T.z) == "computercraft:disk_drive" end
  if diskAttached() then mounts.disk = DISK end
  local env = setmetatable({}, { __index = _G })
  env.turtle = api
  env.textutils = textutils
  env.fs = newFS(T.files, mounts)
  env.colors = setmetatable({}, { __index = function(_, kk) return kk end })
  env.print = VERBOSE and function(...) print("[" .. T.id .. "]", ...) end or function() end
  env.write = env.print
  env.read = function() return "0" end
  env.sleep = function() yield() end
  -- a block next to the turtle, by side (left/right are its upgrade slots)
  local function adjacent(side)
    if side == "top" then return W.get(T.x, T.y + 1, T.z) end
    if side == "bottom" then return W.get(T.x, T.y - 1, T.z) end
    local h = side == "front" and T.h or side == "back" and (T.h + 2) % 4
           or side == "left" and (T.h + 3) % 4 or side == "right" and (T.h + 1) % 4
    if h then local d = DIRS[h]; return W.get(T.x + d[1], T.y, T.z + d[2]) end
  end
  local function ptype(side)
    -- left/right are upgrade slots; with no upgrade there, the block beside it
    if (side == "left" or side == "right") and T[side] then return PTYPE[T[side]] end
    local b = adjacent(side)
    if b == "computercraft:wired_modem_full" then return "modem" end
    if b == "computercraft:disk_drive" then return "drive" end
  end
  env.disk = { getMountPath = function(side) if ptype(side) == "drive" then return "disk" end end }
  env.peripheral = {
    getType = ptype,
    find = function(t)
      for _, side in ipairs({ "left", "right" }) do
        if PTYPE[T[side] or ""] == t then
          if t == "geo_scanner" then return scannerFor(T) end
          if t == "compass" then return { getFacing = function() return ({ [0] = "north", "east", "south", "west" })[T.h] end } end
          return {}
        end
      end
    end,
    call = function(side, method)
      if side == "front" and method == "turnOn" then
        local x, y, z = front()
        local N = turtleAt(x, y, z)
        if N and not N.on then bootTurtle(N) end
        return
      end
      error("peripheral.call " .. side .. " " .. method)
    end,
  }
  env.os = setmetatable({
    getComputerID = function() return T.id end,
    getComputerLabel = function() return T.label end,
    setComputerLabel = function(l) T.label = l end,
    reboot = function() error("REBOOT", 0) end,
    clock = function() return W.clock end,
    -- a queued event comes straight back (the turtle yields once, like in CC)
    queueEvent = function(name) T.queued = name end,
    pullEvent = function(filter)
      if T.queued and (not filter or filter == T.queued) then local e = T.queued; T.queued = nil; yield(); return e end
      error("pullEvent(" .. tostring(filter) .. "): nothing queued in the sim", 0)
    end,
  }, { __index = os })
  env.rednet = {
    open = function(side) assert(ptype(side) == "modem", "rednet.open: no modem on " .. side); T.rednet = true end,
    close = function() T.rednet = false end,
    send = function(to, msg) assert(T.rednet, "rednet not open"); bus.deliver(T.id, msg) end,
    broadcast = function(msg) assert(T.rednet, "rednet not open"); bus.deliver(T.id, msg) end,
    receive = function()
      local q = bus.inbox[T.id]
      if q and #q > 0 then return 0, table.remove(q, 1) end
      return nil
    end,
  }
  -- GPS: answers once four hosts agree on one frame and are in range
  env.gps = { locate = function()
    assert(T.rednet, "gps.locate needs an open modem")
    local hosts, off = {}, nil
    for _, H in pairs(W.turtles) do
      if H.gpsHost then
        local o = { H.gpsHost.x - H.x, H.gpsHost.y - H.y, H.gpsHost.z - H.z }
        if off and (o[1] ~= off[1] or o[2] ~= off[2] or o[3] ~= off[3]) then return nil end
        off = o
        local d = math.sqrt((H.x - T.x)^2 + (H.y - T.y)^2 + (H.z - T.z)^2)
        if d <= 64 then hosts[#hosts + 1] = H end
      end
    end
    if #hosts < 4 then return nil end
    return T.x + off[1], T.y + off[2], T.z + off[3]
  end }
  env.require = function(name)
    local src = T.files[name .. ".lua"]
    assert(src, "require " .. name .. ": not installed on turtle " .. T.id)
    return assert(load(src, name, "t", env))()
  end
  env.shell = {}
  local running = {}
  function env.shell.getRunningProgram() return running[#running] end
  function env.shell.run(path, ...)
    if path == "gps" then -- CC's rom program: `gps host x y z` serves forever
      local a = { ... }
      assert(a[1] == "host" and T.rednet, "gps host needs an open modem")
      T.gpsHost = { x = tonumber(a[2]), y = tonumber(a[3]), z = tonumber(a[4]) }
      while true do yield() end
    end
    local p = path:gsub("^/", "")
    if not p:find("%.lua$") and not env.fs.exists(p) then p = p .. ".lua" end
    local fh = env.fs.open(p, "r")
    assert(fh, "shell.run: no program " .. p)
    local fn = assert(load(fh.readAll(), p, "t", env))
    running[#running + 1] = p
    fn(...)
    running[#running] = nil
    return true
  end
  return env
end

-- CC boot: disk startup if an attached disk has one, else /startup.lua.
-- os.reboot (error "REBOOT") boots again.
bootTurtle = function(T)
  T.on = true
  T.boots = (T.boots or 0) + 1
  local co = coroutine.create(function()
    while true do
      local env = turtleEnv(T)
      local ok, err = pcall(function()
        if env.fs.exists("disk/startup.lua") then env.shell.run("disk/startup.lua")
        elseif env.fs.exists("startup.lua") then env.shell.run("startup.lua") end
      end)
      if ok then return end
      if err ~= "REBOOT" then error(err, 0) end
      T.boots = T.boots + 1
    end
  end)
  scheduler.cos[#scheduler.cos + 1] = { T = T, co = co }
end

-- --------------------------------------------------------------- the base --
local repoFile = function(name) return readFile(REPO .. "/" .. name) end
local manifest = load(repoFile("manifest.lua"), "manifest", "t", {})()

local baseFiles = {}
for _, name in ipairs(manifest.base) do baseFiles[name] = repoFile(name) end
for _, name in ipairs(manifest.turtle) do baseFiles["dist/" .. name] = repoFile(name) end
baseFiles["dist/" .. manifest.installer] = repoFile(manifest.installer)

local baseEnv = setmetatable({}, { __index = _G })
baseEnv.fs = newFS(baseFiles, { disk = DISK })
baseEnv.textutils = textutils
baseEnv.colors = setmetatable({}, { __index = function(_, kk) return kk end })
baseEnv.os = setmetatable({ getComputerID = function() return 0 end }, { __index = os })
baseEnv.require = function(name) return assert(load(assert(baseFiles[name .. ".lua"], name), name, "t", baseEnv))() end
local factory = baseEnv.require("factory")
local storage = baseEnv.require("storage")
local dist = baseEnv.require("dist")
local net = baseNetwork()

local release = dist.load(manifest, "/dist")

local config = {
  build = { y = 64 },
  homes = { miner = { { east = 4, north = 0, facing = "north" } } },
  fleet = { miner = 1 },
  rules = { { item = "minecraft:raw_iron", min = 6, job = { only = "iron", y = 54, quantity = 8, lanes = 1, length = 16 } } },
  forester = { sapling = "minecraft:oak_sapling", trees = 3, wait = 10 },
  job = { lanes = 1, length = 16 },
}
local F = factory.new(config, {
  storage = storage.open(net),
  now = function() return W.clock end,
  dist = release,
  writeInstall = function(install) install.base = 0; dist.writeDisk(net, release, install) end,
})

function bus.deliver(from, msg)
  local reply = factory.handle(F, from, msg)
  bus.sent[#bus.sent + 1] = { from = from, msg = msg, reply = reply }
  if VERBOSE then print(("  [bus] %s %s -> %s"):format(from, tostring(msg.state), reply and reply.type or "nil")) end
  if bus.lose and bus.lose(from, msg, reply) then
    if VERBOSE then print("  [bus] reply LOST") end
    return
  end
  if reply then bus.inbox[from] = bus.inbox[from] or {}; table.insert(bus.inbox[from], reply) end
end

-- ----------------------------------------------------------------- layout --
-- ground at y = -1, an iron layer at y = -10 (absolute Y 54), air above 0
for x = -12, 24 do for z = -30, 12 do
  for y = -14, -1 do
    local b = "minecraft:stone"
    if y == -10 and (x + z) % 3 == 0 then b = "minecraft:iron_ore" end
    if y == -14 then b = "minecraft:bedrock" end
    W.set(x, y, z, b)
  end
end end
-- assembler at (0,0,0) facing north on a wired modem (0,-1,0): the base fills
-- and empties it over the network; build spot (0,0,-1); drive under it
W.set(0, -1, -1, "computercraft:disk_drive")
W.set(0, -1, 0, "computercraft:wired_modem_full")
-- storage barrels (no position needed: only reached over the network)
newInv("minecraft:barrel_0"); newInv("minecraft:barrel_1")
-- the miner home slot: 4 east of the build spot, facing north, chest behind it
-- and a wired modem (cabled to the base) in front of it: no wireless modems
newInv("minecraft:chest_0", 4, 0, 0)
W.set(4, 0, -2, "computercraft:wired_modem_full")

local stockParts = {
  { "minecraft:gold_ingot", 40 }, { "minecraft:redstone", 5 }, { "minecraft:glass_pane", 5 },
  { "minecraft:chest", 5 }, { "minecraft:diamond_pickaxe", 1 }, { "advancedperipherals:geo_scanner", 1 },
  { "minecraft:coal", 64 },
}
for _, p in ipairs(stockParts) do W.inv["minecraft:barrel_0"].insert(p[1], p[2]) end

-- the assembler turtle, installed by hand (as you would do the very first one)
scheduler.nextId = 2
local A = newTurtleEntity(1, 0, 0, 0, 0)
A.left = "minecraft:crafting_table" -- and no wireless modem: it talks over the wired one
for _, name in ipairs(manifest.turtle) do A.files[name] = repoFile(name) end
A.files["agent.cfg"] = ser({ role = "assembler", base = 0 })

-- ----------------------------------------------------------------- run it --
print("scenario: the base builds a miner (no wireless modems: wired at home), it installs itself,")
print("          flies home and fills a stock rule")
bootTurtle(A)
local function runUntil(cond, maxTicks)
  for tick = 1, maxTicks do
    W.clock = W.clock + 1
    W.smeltTick()
    for _, c in ipairs(scheduler.cos) do
      if coroutine.status(c.co) ~= "dead" then
        local ok, err = coroutine.resume(c.co)
        if not ok then c.err = err; print("  turtle " .. c.T.id .. " crashed: " .. tostring(err)) end
      end
    end
    if tick % 20 == 0 then
      local ok, err = pcall(factory.tick, F)
      if not ok then print("  tick failed: " .. tostring(err)); return false end
    end
    if cond() then return true end
  end
  return false
end

local stock = function() return F.deps.storage.list() end
local done = runUntil(function()
  local M = W.turtles[2]
  return M and (stock()["minecraft:raw_iron"] or 0) >= 6 and F.turtles[2] and F.turtles[2].state == "idle"
end, 200000)
check(done, "reached: miner built, installed, home, rule filled")

local M = W.turtles[2]
check(F.orders[1] and F.orders[1].state == "built", "build order #1 built: " .. tostring(F.orders[1] and F.orders[1].state))
check(M ~= nil, "a new turtle was placed on the build spot")
if M then
  check(M.right == "minecraft:diamond_pickaxe" and M.left == "advancedperipherals:geo_scanner",
    "it has a pickaxe and a Geo Scanner")
  local cfg = M.files["agent.cfg"] and textutils.unserialize(M.files["agent.cfg"]) or {}
  check(cfg.role == "miner" and cfg.base == 0, "installed as a miner pinned to the base")
  check(M.files["version"] == release.version, "installed the base's code version")
  check(M.label == "miner-2", "labelled miner-2: " .. tostring(M.label))
  check(M.x == 4 and M.y == 0 and M.z == -1 and M.h == 0,
    ("walked to its home slot facing north (%d,%d,%d h%d)"):format(M.x, M.y, M.z, M.h))
  check(cfg.home and cfg.home.y == 64, "home Y recorded from the base config")
  local wireless = false
  for i = 1, 16 do if M.inv[i] and M.inv[i].name:find("wireless") then wireless = true end end
  check(not wireless and M.left ~= "computercraft:wireless_modem_normal", "it has no wireless modem: talks over the wired one at home")
  check(F.orders[1].arrived and F.homes[1].owner == 2, "its reserved home now belongs to it")
end
check((stock()["minecraft:raw_iron"] or 0) >= 6, "raw iron drained into storage: " .. tostring(stock()["minecraft:raw_iron"]))
check(W.inv["minecraft:chest_0"].count("minecraft:raw_iron") == 0, "home chest emptied by the base")
check(stock()["minecraft:gold_ingot"] == 40 - 14, "14 gold used: " .. tostring(stock()["minecraft:gold_ingot"]))
check(stock()["advancedperipherals:geo_scanner"] == nil, "geo scanner used")
local aLeft = 0
for _ in pairs(A.inv) do aLeft = aLeft + 1 end
check(aLeft == 0, "assembler inventory empty")
check(W.get(0, 0, -1) == nil, "build spot free again")

print("scenario: every monitor tab renders with live data")
do
  local UIlib = assert(load(baseFiles["base.lua"], "base", "t", baseEnv))("--lib")
  local UI = { F = F, buttons = {}, stock = F.deps.storage.list() }
  for _, tab in ipairs({ "TURTLES", "GATHERING/MINING", "GATHERING/FORESTRY", "FACTORY" }) do
    UI.tab, UI.sub = tab:match("^([^/]+)/?(.*)$")
    if UI.sub == "" then UI.sub = nil end
    local screen = {}
    local mon = { getSize = function() return 57, 30 end, clear = function() end,
                  setCursorPos = function(_, y) screen.y = y end, setTextColor = function() end,
                  setBackgroundColor = function() end,
                  write = function(t) screen[screen.y] = (screen[screen.y] or "") .. t end }
    local ok, err = pcall(UIlib.draw, UI, mon)
    local text = ""
    for i = 1, 30 do text = text .. (screen[i] or "") .. "\n" end
    check(ok, tab .. " tab draws (" .. tostring(err) .. ")")
    if os.getenv("DUMP") then print(text) end
    if tab == "TURTLES" then check(text:find("miner%-2") and text:find("assembler"), "lists the miner and the assembler") end
    if tab == "GATHERING/MINING" then check(text:find("MINING") and text:find("START") and text:find("FORESTRY"), "MINING sub-tab: the job buttons") end
    if tab == "GATHERING/FORESTRY" then check(text:find("SAPLINGS") and text:find("BONE MEAL"), "FORESTRY sub-tab: sapling choice and bone meal") end
    if tab == "FACTORY" then
      check(text:find("raw_iron") ~= nil, "shows the stock rule")
      check(text:find("miner%s+1 / 1") ~= nil, "shows the fleet target met")
      check(text:find("#1 miner: built") ~= nil, "shows the build")
    end
    -- every button's action runs without error
    for _, b in ipairs(UI.buttons) do
      if b.label ~= "UPDATE" and not b.label:find("^HAMMER") then
        local okb, errb = pcall(b.action)
        if not okb then check(false, tab .. " button " .. b.label .. ": " .. tostring(errb)) end
      end
    end
  end
end

print("scenario: a code update reaches the idle miner")
do
  -- a new release: change one turtle file, as bootstrap would after a push
  baseFiles["dist/oreminer.lua"] = baseFiles["dist/oreminer.lua"] .. "\n-- v2\n"
  local r2 = dist.load(manifest, "/dist")
  F.deps.dist = r2
  check(r2.version ~= release.version, "new release has a new version")
  local bootsBefore = M and M.boots or 0
  local ok = runUntil(function() return M and M.files["version"] == r2.version and F.turtles[2].version == r2.version end, 20000)
  check(ok, "miner installed the update and reports the new version")
  check(M and M.files["oreminer.lua"]:find("%-%- v2") ~= nil, "new file content on the turtle")
  check(M and M.boots > bootsBefore, "it rebooted into the new code")
end


print("scenario: a lost reply to the assembler does not stall the next build")
do
  config.fleet.miner = 2
  factory.addHome(F, { x = 6, y = 0, z = 0, facing = "north", role = "miner", source = "cfg" })
  newInv("minecraft:chest_1", 6, 0, 0)
  W.set(6, 0, -2, "computercraft:wired_modem_full")
  for _, p in ipairs(stockParts) do W.inv["minecraft:barrel_1"].insert(p[1], p[2]) end
  local lost = false
  bus.lose = function(from, msg, reply)
    if not lost and from == 1 and reply and reply.type == "step" and reply.step == 2 then lost = true; return true end
  end
  local ok = runUntil(function()
    return W.turtles[3] and W.turtles[3].x == 6 and W.turtles[3].z == -1 and F.turtles[3]
  end, 200000)
  bus.lose = nil
  check(lost, "the step-2 reply was lost on the way")
  check(ok, "the second miner was still built and flew to home slot 2")
  local built = 0
  for _, o in ipairs(F.orders) do if o.role == "miner" and o.state == "built" then built = built + 1 end end
  check(built == 2, "two miner orders built: " .. built)
end

print("scenario: a lost 'done' neither blocks the stock rule nor counts twice")
do
  local before = F.totals.iron or 0
  config.rules[1].min = (stock()["minecraft:raw_iron"] or 0) + 4
  local lostDone = false
  bus.lose = function(from, msg, reply)
    if not lostDone and msg.state == "done" then lostDone = true; return true end
  end
  local ok = runUntil(function() return lostDone and next(F.ruleJobs) == nil and #F.queue == 0
    and F.turtles[2].state == "idle" and F.turtles[3].state == "idle" end, 200000)
  bus.lose = nil
  check(lostDone, "a done reply was lost")
  check(ok, "the miner said done again, went idle, the rule is free")
  -- what each distinct job reported as done (a repeated done must not add up twice)
  local perJob, dones = {}, 0
  for _, e in ipairs(bus.sent) do
    if e.msg.state == "done" and e.msg.job and e.msg.job.only == "iron" then
      perJob[e.msg.job.id] = e.msg.mined; dones = dones + 1
    end
  end
  local expected, jobs = 0, 0
  for _, n in pairs(perJob) do expected = expected + n; jobs = jobs + 1 end
  check(dones > jobs, ("a done was repeated (%d dones for %d jobs)"):format(dones, jobs))
  check((F.totals.iron or 0) == expected, ("iron counted once per job: %d, expected %d"):format(F.totals.iron or 0, expected))
end

print("scenario: a damaged pickaxe in storage is not used; the base asks for diamonds instead")
do
  config.fleet.miner = 3
  factory.addHome(F, { x = 8, y = 0, z = 0, facing = "north", role = "miner", source = "cfg" })
  -- only a damaged pickaxe left in storage
  for _, I in pairs(W.inv) do
    for i, sl in pairs(I.slots) do if sl.name == "minecraft:diamond_pickaxe" then I.slots[i] = nil end end
  end
  for _, p in ipairs(stockParts) do W.inv["minecraft:barrel_1"].insert(p[1], p[2]) end
  for _, sl in pairs(W.inv["minecraft:barrel_1"].slots) do
    if sl.name == "minecraft:diamond_pickaxe" then sl.damage = 120 end
  end
  local orders = #F.orders
  runUntil(function() return false end, 3000)
  check(#F.orders == orders, "no order placed with only a damaged pickaxe")
  check((F.prod.missing["minecraft:diamond"] or 0) >= 3, "it needs 3 diamonds to make a pickaxe: "
    .. tostring(F.prod.missing["minecraft:diamond"]))
  check(W.get(0, 0, -1) == nil, "nothing left on the build spot")
  local held = 0
  for _ in pairs(A.inv) do held = held + 1 end
  check(held == 0, "assembler holds nothing")
end

print("scenario: from raw materials only: smelt, craft every part, double gold with a hammer, build")
do
  -- furnaces on the wired network
  newFurnace("minecraft:furnace_0"); newFurnace("minecraft:furnace_1"); newFurnace("minecraft:blast_furnace_0", true)
  -- the home slot for the new miner
  newInv("minecraft:chest_2", 8, 0, 0)
  W.set(8, 0, -2, "computercraft:wired_modem_full")
  -- empty storage, then only raw materials. 7 raw gold: 14 gold needed, so
  -- only the hammer's 2 dust per raw ore makes it.
  for _, name in ipairs({ "minecraft:barrel_0", "minecraft:barrel_1" }) do W.inv[name].slots = {} end
  local raw = {
    { "minecraft:raw_gold", 7 }, { "minecraft:raw_iron", 10 }, { "minecraft:raw_copper", 18 },
    { "minecraft:diamond", 7 }, { "minecraft:redstone", 40 }, { "minecraft:cobblestone", 40 },
    { "minecraft:sand", 6 }, { "minecraft:oak_log", 24 }, { "minecraft:quartz", 1 }, { "minecraft:coal", 128 },
  }
  for _, r in ipairs(raw) do W.inv["minecraft:barrel_0"].insert(r[1], r[2]) end
  F.failStreak, F.lastFail = 0, nil
  if not F.hammer then factory.toggleHammer(F) end -- (the tab test pressed it already)
  check(F.hammer, "hammer toggle on")
  local ok = runUntil(function()
    local T = W.turtles[4]
    return T and T.x == 8 and T.z == -1 and F.turtles[4]
  end, 400000)
  check(ok, "a miner was built from raw materials and flew to home slot 3")
  local c = F.crafted
  check((c["alltheores:copper_ore_hammer"] or 0) >= 1, "crafted a copper ore hammer")
  check((c["alltheores:gold_dust"] or 0) >= 14, "hammered 7 raw gold into 14 gold dust: " .. tostring(c["alltheores:gold_dust"]))
  for _, part in ipairs({ "advancedperipherals:geo_scanner", "advancedperipherals:peripheral_casing",
                          "computercraft:wired_modem_full", "minecraft:observer", "minecraft:diamond_pickaxe",
                          "minecraft:chest", "minecraft:glass_pane", "minecraft:iron_bars", "minecraft:redstone_block" }) do
    check((c[part] or 0) >= 1, "crafted " .. part)
  end
  check((W.smelted or 0) > 30, "furnaces smelted: " .. tostring(W.smelted))
  if not ok then
    print("    missing raw:", textutils.serialize(F.prod.missing), "note:", F.note)
    print("    stock:", textutils.serialize(F.deps.storage.list()))
  end
end


print("scenario: AE2-style: a plain turtle in storage is used, the build only fits the upgrades;")
print("          an upgraded turtle in storage is left alone")
do
  config.fleet.miner = config.fleet.miner + 1
  factory.addHome(F, { x = 10, y = 0, z = 0, facing = "north", role = "miner", source = "cfg" })
  newInv("minecraft:chest_60", 10, 0, 0)
  W.set(10, 0, -2, "computercraft:wired_modem_full")
  local B = W.inv["minecraft:barrel_1"]
  local function freeSlot() for i = 1, B.size do if not B.slots[i] then return i end end end
  -- the upgraded and the labelled one first: a careless pick would take them
  B.slots[freeSlot()] = { name = "computercraft:turtle_advanced", count = 1, nbt = "UPGRADED",
                          displayName = "Advanced Mining Turtle" }                               -- someone's mining turtle
  B.slots[freeSlot()] = { name = "computercraft:turtle_advanced", count = 1, nbt = "LABEL",
                          displayName = "Bob" }                                                  -- a labelled one
  B.slots[freeSlot()] = { name = "computercraft:turtle_advanced", count = 1, nbt = "OLD-ID-7",
                          displayName = "Advanced Turtle" }                                      -- stripped, used before
  B.insert("minecraft:diamond_pickaxe", 1); B.insert("advancedperipherals:geo_scanner", 1); B.insert("minecraft:coal", 32)
  B.insert("minecraft:gold_ingot", 20); B.insert("minecraft:redstone", 2); B.insert("minecraft:glass_pane", 2)
  B.insert("minecraft:chest", 2) -- (enough to build from scratch too)
  local computersBefore = F.crafted["computercraft:computer_advanced"] or 0
  local goldBefore = stock()["minecraft:gold_ingot"] or 0
  check(factory.startFor(F, "miner") == 3, "the base starts at step 3 (upgrades)")
  local ok = runUntil(function()
    for _, T in pairs(W.turtles) do if T.x == 10 and T.z == -1 and F.turtles[T.id] then return true end end
  end, 200000)
  check(ok, "a miner was built and flew to its new home")
  check(goldBefore >= 20 and (stock()["minecraft:gold_ingot"] or 0) == goldBefore,
    ("no gold used: %d before, %d after"):format(goldBefore, stock()["minecraft:gold_ingot"] or 0))
  check((F.crafted["computercraft:computer_advanced"] or 0) == computersBefore, "no computer crafted")
  local left = {}
  for _, I in pairs(W.inv) do for _, st in pairs(I.slots) do if st.nbt then left[st.nbt] = true end end end
  check(left.UPGRADED and left.LABEL, "the upgraded and the labelled turtle are still in storage")
  check(not left["OLD-ID-7"], "the stripped, used one (plain name) was the one used")
  -- a fresh computer in storage (and no plain turtle): start at the body step,
  -- with the computer delivered into its cell like the other parts
  local B2 = W.inv["minecraft:barrel_0"]
  B2.insert("computercraft:computer_advanced", 1)
  for _, st in pairs(B2.slots) do if st.name == "computercraft:computer_advanced" then st.displayName = "Advanced Computer" end end
  local Cf = baseEnv.require("oreconf")
  local first = Cf.buildSteps("miner", factory.startFor(F, "miner"))[1]
  check(factory.startFor(F, "miner") == 2 and first.grid[6] == "computercraft:computer_advanced" and not first.keep,
    "a computer in storage: starts at step 2, the computer goes into cell 6")
end

print("scenario: a plain turtle next to the base computer climbs the wall the cable goes through,")
print("          maps the network, finds the build spot and registers homes")
do
  -- the base computer stands against a 3-high wall (z = -4); the modem is in
  -- the wall right behind it and the cable runs on the far side to two home
  -- chests (one a level up); a modem in front of each home spot. A chest with
  -- no modem near it is not a home. A cable also runs to the installer drive
  -- under the build spot.
  for x = -9, 1 do for y = 0, 2 do W.set(x, y, -4, "minecraft:cobblestone") end end
  W.set(-2, 0, -3, "computercraft:computer_advanced")
  W.set(-2, 0, -4, "computercraft:wired_modem_full")
  for x = -2, -7, -1 do W.set(x, 0, -5, "computercraft:cable") end
  newInv("minecraft:chest_3", -4, 0, -7)          -- home spot (-4,0,-6) faces south
  W.set(-4, 0, -5, "computercraft:wired_modem_full")
  newInv("minecraft:chest_4", -7, 1, -7)          -- home spot (-7,1,-6), a level up
  W.set(-7, 1, -5, "computercraft:wired_modem_full")
  W.set(-9, 0, -7, "minecraft:chest")             -- not wired: no home here
  W.set(-1, 0, -3, "computercraft:cable"); W.set(-1, 0, -2, "computercraft:cable")
  W.set(-1, -1, -1, "computercraft:cable")        -- to the drive under the build spot
  -- the surveyor: a plain turtle in front of the computer, facing it (north)
  local SV = newTurtleEntity(50, -2, 0, -2, 0)
  SV.fuel = 4000
  for _, name in ipairs(manifest.turtle) do SV.files[name] = repoFile(name) end
  SV.files["agent.cfg"] = ser({ role = "surveyor", base = 0 })
  SV.inv[1] = { name = "minecraft:cobblestone", count = 8 }
  local env = turtleEnv(SV)
  local co = coroutine.create(function() env.shell.run("surveyor", "north") end)
  scheduler.cos[#scheduler.cos + 1] = { T = SV, co = co }
  local homesBefore = #F.homes
  local cfgHome = F.homes[1] and { x = F.homes[1].x, y = F.homes[1].y, z = F.homes[1].z }
  local ok = runUntil(function() return coroutine.status(co) == "dead" end, 400000)
  check(ok, "the survey finished")
  -- frame: the surveyor's start, world (-2,0,-2), is (0,0,0)
  local function rel(x, y, z) return x + 2, y, z + 2 end
  local bx, by, bz = rel(0, 0, -1)
  check(F.buildSpot and F.buildSpot.x == bx and F.buildSpot.y == by and F.buildSpot.z == bz,
    "found the build spot above the disk drive: " .. textutils.serialize(F.buildSpot))
  local found = {}
  for _, h in ipairs(F.homes) do if h.source == "survey" then found[h.chest] = h end end
  local h3, h4 = found["minecraft:chest_3"], found["minecraft:chest_4"]
  local x3, y3, z3 = rel(-4, 0, -6)
  check(h3 and h3.x == x3 and h3.y == y3 and h3.z == z3 and h3.facing == "south",
    "home behind the wall at chest_3, facing away from it: " .. (h3 and ("%d,%d,%d %s"):format(h3.x, h3.y, h3.z, h3.facing) or "none"))
  local x4, y4, z4 = rel(-7, 1, -6)
  check(h4 and h4.x == x4 and h4.y == y4 and h4.z == z4, "home a level up at chest_4: " ..
    (h4 and ("%d,%d,%d"):format(h4.x, h4.y, h4.z) or "none"))
  check(#F.homes == homesBefore + 2, ("only those two homes added (%d -> %d)"):format(homesBefore, #F.homes))
  check(h3 and h3.role == "off" and h4 and h4.role == "off", "new homes wait for a role")
  -- homes from before (factory.cfg) moved into the new frame with the build spot
  local h1 = F.homes[1]
  check(cfgHome and h1.x == cfgHome.x + bx and h1.z == cfgHome.z + bz, "earlier homes moved along with the build spot")
  check(SV.x == -2 and SV.y == 0 and SV.z == -2, ("surveyor back where it started (%d,%d,%d)"):format(SV.x, SV.y, SV.z))
  check(W.get(-2, 0, -4) == "computercraft:wired_modem_full" and W.get(-3, 1, -4) == "minecraft:cobblestone",
    "nothing dug: it went over the wall")
  -- tap the home on the monitor: off -> miner; a new miner would fly to it
  if h3 then factory.cycleHome(F, h3.id) end
  check(h3 and h3.role == "miner", "the monitor sets its role: " .. tostring(h3 and h3.role))
  -- a new miner asking for a home gets it relative to the build spot:
  -- world (-4,0,-6) seen from the build spot at world (0,0,-1)
  for _, h in ipairs(F.homes) do if h.role == "miner" and h ~= h3 then h.role = "off" end end
  local r = factory.handle(F, 77, { type = "status", state = "new", role = "miner", label = "new-77" })
  check(r and r.type == "home" and r.home.x == -4 and r.home.y == 0 and r.home.z == -5 and r.home.facing == "south",
    "a new miner is sent to it from the build spot: " .. textutils.serialize(r and r.home))
  runUntil(function() return false end, 400)
  check(W.inv["minecraft:chest_3"].count("minecraft:cobblestone") == 0, "the marker got drained into storage afterwards")
end


print("scenario: a surveyor with a compass in its inventory starts by itself, any facing")
do
  -- the first surveyor goes away; a new one in the same spot, facing EAST,
  -- compass in its inventory, started only by its own startup (agent)
  W.set(-2, 0, -2, nil); W.turtles[50] = nil
  local SV2 = newTurtleEntity(51, -2, 0, -2, 1)
  SV2.fuel = 4000
  for _, name in ipairs(manifest.turtle) do SV2.files[name] = repoFile(name) end
  SV2.files["agent.cfg"] = ser({ role = "surveyor", base = 0 })
  SV2.inv[1] = { name = "minecraft:cobblestone", count = 8 }
  SV2.inv[2] = { name = "minecraft:compass", count = 1 }
  local homesBefore = #F.homes
  bootTurtle(SV2)
  local ok = runUntil(function() return SV2.files["surveyor.state"] and SV2.files["surveyor.state"]:find("done") end, 400000)
  check(ok, "it surveyed without being told its facing")
  check(SV2.left == "minecraft:compass" or SV2.right == "minecraft:compass", "it fitted the compass itself")
  check(#F.homes == homesBefore, "found the same homes again, no duplicates (" .. #F.homes .. ")")
  local again = 0
  for _, h in ipairs(F.homes) do if h.source == "survey" and (h.chest == "minecraft:chest_3" or h.chest == "minecraft:chest_4") then again = again + 1 end end
  check(again == 2, "both surveyed homes still there")
  check(SV2.x == -2 and SV2.y == 0 and SV2.z == -2, "back where it started")
end

print("scenario: BUILD GPS: the factory builds four GPS host turtles above the base")
do
  for _, r in ipairs({ { "minecraft:iron_ingot", 64 }, { "minecraft:stone", 64 }, { "minecraft:redstone", 16 },
                       { "minecraft:glass_pane", 8 }, { "minecraft:chest", 6 }, { "minecraft:ender_pearl", 4 },
                       { "minecraft:coal", 64 } }) do
    W.inv["minecraft:barrel_1"].insert(r[1], r[2])
  end
  F.failStreak, F.lastFail = 0, nil
  factory.wantGps(F)
  local function hosts()
    local list = {}
    for _, T in pairs(W.turtles) do if T.gpsHost then list[#list + 1] = T end end
    return list
  end
  local ok = runUntil(function() return #hosts() == 4 end, 600000)
  check(ok, "four GPS hosts are running: " .. #hosts())
  local hs = hosts()
  if #hs == 4 then
    -- they agree on one frame: the home frame (survey start = world (-2,0,-2))
    local agree = true
    for _, H in ipairs(hs) do
      if H.gpsHost.x ~= H.x + 2 or H.gpsHost.y ~= H.y or H.gpsHost.z ~= H.z + 2 then agree = false end
    end
    check(agree, "every host announces its real position in the home frame")
    -- not all in one plane (else GPS can't tell above from below)
    local a, b, c, d = hs[1], hs[2], hs[3], hs[4]
    local function v(p, q) return { q.x - p.x, q.y - p.y, q.z - p.z } end
    local u, w, x = v(a, b), v(a, c), v(a, d)
    local det = u[1] * (w[2] * x[3] - w[3] * x[2]) - u[2] * (w[1] * x[3] - w[3] * x[1]) + u[3] * (w[1] * x[2] - w[2] * x[1])
    check(det ~= 0, "the four hosts are not in one plane")
    local high = true
    for _, H in ipairs(hs) do if H.y < 20 then high = false end end
    check(high, "they fly up high above the base")
  end
end

print("scenario: with GPS, a turtle placed by hand runs `home miner` and lives there")
do
  local HT = newTurtleEntity(60, 12, 0, 6, 1) -- somewhere east of the base, facing east
  HT.left, HT.right = "minecraft:compass", "computercraft:wireless_modem_normal"
  HT.fuel = 100
  for _, name in ipairs(manifest.turtle) do HT.files[name] = repoFile(name) end
  HT.files["agent.cfg"] = ser({ base = 0 })
  local env = turtleEnv(HT)
  local ok, err = pcall(env.shell.run, "home", "miner")
  check(not ok and tostring(err):find("REBOOT"), "registered and rebooted into its role (" .. tostring(err) .. ")")
  local reg
  for _, h in ipairs(F.homes) do if h.source == "gps" then reg = h end end
  check(reg and reg.x == 14 and reg.y == 0 and reg.z == 8 and reg.facing == "east" and reg.role == "miner" and reg.owner == 60,
    "home at its spot in the home frame, facing east, owned by it: " .. textutils.serialize(reg))
  local cfg = textutils.unserialize(HT.files["agent.cfg"])
  check(cfg.role == "miner" and cfg.home and cfg.home.y == F.cfg.build.y and cfg.home.heading == 1,
    "agent.cfg: role miner, home Y and heading: " .. HT.files["agent.cfg"])
end

print("scenario: chat fallback: $build on the build spot, then $home on a home spot")
do
  local F2 = factory.new({ build = { y = 64 }, homes = {}, fleet = {}, rules = {}, job = { lanes = 1, length = 16 },
                          forester = { sapling = "minecraft:oak_sapling", trees = 3, wait = 10 } },
                        { storage = F.deps.storage, now = function() return W.clock end })
  check(factory.chatCommand(F2, "alex", "$home miner", { x = 104.5, y = 70.0, z = 201.3, yaw = 180 }):find("build"),
    "$home before $build asks for $build")
  local r1 = factory.chatCommand(F2, "alex", "$build", { x = 100.7, y = 70.0, z = 200.2, yaw = 0 })
  check(r1:find("build spot set at 100 70 200"), "$build: " .. r1)
  local r2 = factory.chatCommand(F2, "alex", "$home miner", { x = 104.5, y = 71.0, z = 197.9, yaw = 180 })
  local h = F2.homes[1]
  check(h and h.x == 4 and h.y == 1 and h.z == -3 and h.facing == "north" and h.role == "miner" and h.source == "chat",
    "home from the player's block and look direction: " .. r2)
  check(factory.chatCommand(F2, "alex", "$home miner", nil):find("can't see"), "no detector: says so")
  check(factory.chatCommand(F2, "alex", "$homes"):find("#1 miner 4,1,%-3"), "$homes lists it")
  check(F2.cfg.build.y == 70, "the build spot's Y comes from $build")
  check(factory.chatCommand(F2, "alex", "hello") == nil, "ordinary chat is ignored")
end

print("scenario: the monitor shows what is on the network; a queued build can be removed")
do
  local d = storage.devices(net)
  check(#d.storage == 2 and #d.furnace == 3 and #d.drive == 1 and #d.input >= 3,
    ("devices: barrels %d furnaces %d drives %d home chests %d"):format(#d.storage, #d.furnace, #d.drive, #d.input))
  local UIlib = assert(load(baseFiles["base.lua"], "base", "t", baseEnv))("--lib")
  local screen = {}
  local mon = { getSize = function() return 70, 60 end, clear = function() end,
                setCursorPos = function(_, y) screen.y = y end, setTextColor = function() end,
                setBackgroundColor = function() end,
                write = function(t) screen[screen.y] = (screen[screen.y] or "") .. t end }
  local ui = { F = F, tab = "FACTORY", buttons = {}, devices = d }
  UIlib.draw(ui, mon)
  local text = ""
  for i = 1, 60 do text = text .. (screen[i] or "") .. "\n" end
  check(text:find("NETWORK") and text:find("barrels 2") and text:find("furnaces 3"), "FACTORY tab lists the network")
  check(not text:find("No storage"), "no warning when there are barrels")
  check(text:find("assembler %d") and text:find("surveyor%s+%d"), "FLEET lists assemblers and surveyors")
  ui.devices = { storage = {}, input = { "minecraft:chest_9" }, furnace = {}, drive = {}, bridge = {}, other = {} }
  screen = {}
  UIlib.draw(ui, mon)
  text = ""
  for i = 1, 60 do text = text .. (screen[i] or "") .. "\n" end
  check(text:find("No storage"), "warns when there are no barrels")
  local o = factory.orderTurtle(F, "forester", true)
  local n = #F.orders
  factory.cancelOrder(F, o.id)
  check(#F.orders == n - 1, "a queued build is removed")
end

print("scenario: the installer leaves turtles that aren't on the build spot alone")
do
  local T = newTurtleEntity(99, 10, 0, 5, 0) -- somewhere else, sees the disk over the network
  local env = turtleEnv(T)
  env.fs = newFS(T.files, { disk = DISK }) -- disk visible (wired network), drive not below
  local ran = false
  env.shell.getRunningProgram = function() return "disk/startup.lua" end
  local realRun = env.shell.run
  env.shell.run = function(p, ...) if p == "/startup.lua" then ran = true; return end; return realRun(p, ...) end
  local ok, err = pcall(assert(load(DISK["startup.lua"], "installer", "t", env)))
  check(ok, "installer exited (" .. tostring(err) .. ")")
  check(T.files["agent.cfg"] == nil and T.files["oreminer.lua"] == nil, "nothing installed on it")
end

print("scenario: an update with a path in a file name is rejected")
do
  local env = turtleEnv(M)
  local link = env.require("link")
  local diskBefore = DISK["startup.lua"]
  local ok = pcall(link.applyUpdate, { version = "evil", files = { ["disk/startup.lua"] = "print('owned')" } })
  check(DISK["startup.lua"] == diskBefore and M.files["version"] ~= "evil", "disk and turtle untouched")
end

print("scenario: the installer disk never installs onto the base")
do
  local files = { ["startup.lua"] = "BASE_STARTUP_RAN = true" }
  local env = setmetatable({ turtle = nil }, { __index = _G })
  env.fs = newFS(files, { disk = DISK })
  env.textutils = textutils
  env.shell = { getRunningProgram = function() return "disk/startup.lua" end,
                run = function(p) BASE_STARTUP_RAN = (p == "/startup.lua") end }
  env.os = setmetatable({ reboot = function() error("REBOOT") end }, { __index = os })
  local fn = assert(load(DISK["startup.lua"], "installer", "t", env))
  BASE_STARTUP_RAN = false
  local ok, err = pcall(fn)
  check(ok, "installer exits quietly on a computer (" .. tostring(err) .. ")")
  check(BASE_STARTUP_RAN, "and runs the base's own startup instead")
  check(files["agent.cfg"] == nil and files["oreminer.lua"] == nil, "nothing copied onto the base")
end

-- The layout from the real base: computer at (ox,0,oz) with a monitor next to
-- it, the modem BEHIND it, a cable over a 4-high wall to a home (chest at
-- oz+13, home spot oz+12 facing north), a branch running out of range.
local function topLayout(ox, oz, chest)
  W.set(ox, 0, oz, "computercraft:computer_advanced")
  W.set(ox - 1, 0, oz, "computercraft:monitor_advanced")
  W.set(ox, 0, oz + 1, "computercraft:wired_modem_full")
  for z = oz + 2, oz + 6 do W.set(ox, 0, z, "computercraft:cable") end
  for x = ox - 4, ox + 4 do for y = 0, 3 do W.set(x, y, oz + 7, "minecraft:cobblestone") end end
  for y = 1, 4 do W.set(ox, y, oz + 6, "computercraft:cable") end
  W.set(ox, 4, oz + 7, "computercraft:cable")
  for y = 4, 0, -1 do W.set(ox, y, oz + 8, "computercraft:cable") end
  for z = oz + 9, oz + 10 do W.set(ox, 0, z, "computercraft:cable") end
  W.set(ox, 0, oz + 11, "computercraft:wired_modem_full")
  newInv(chest, ox, 0, oz + 13)
  for z = oz + 2, oz + 60 do W.set(ox + 1, 0, z, "computercraft:cable") end
end

local function surveyorOnTop(id, ox, oz, coal)
  local T = newTurtleEntity(id, ox, 1, oz, 0)
  T.fuel = 0
  for _, name in ipairs(manifest.turtle) do T.files[name] = repoFile(name) end
  T.files["agent.cfg"] = ser({ role = "surveyor", base = 0 })
  T.inv[1] = { name = "minecraft:cobblestone", count = 8 }
  T.inv[2] = { name = "minecraft:compass", count = 1 }
  if coal > 0 then T.inv[3] = { name = "minecraft:coal", count = coal } end
  return T
end

local function homeAt(chest)
  for _, h in ipairs(F.homes) do if h.chest == chest then return h end end
end

print("scenario: surveyor on TOP of the computer, no fuel but coal; modem behind the computer a")
print("          level down, cable over a 4-high wall to a home, a branch running out of range")
do
  topLayout(40, 40, "minecraft:chest_77")
  local T = surveyorOnTop(60, 40, 40, 16)
  local minY, maxY, maxZ = 1, 1, 40
  local homesBefore = #F.homes
  bootTurtle(T)
  local ok = runUntil(function()
    minY, maxY, maxZ = math.min(minY, T.y), math.max(maxY, T.y), math.max(maxZ, T.z)
    return T.files["surveyor.state"] and T.files["surveyor.state"]:find("done")
  end, 400000)
  check(ok, "the survey finished")
  check(T.fuel > 0 and (not T.inv[3] or T.inv[3].count < 16), "it fuelled itself from its coal")
  check(minY <= 0, "it climbed down off the computer: lowest y " .. minY)
  check(maxY >= 5, "it climbed over the wall: highest y " .. maxY)
  check(maxZ <= 40 + 33, "stayed within range of where it started: furthest z " .. maxZ)
  local home = homeAt("minecraft:chest_77")
  check(home ~= nil and home.facing == "north", "registered the home behind the wall, facing away from its chest")
  check(#F.homes == homesBefore + 1, "one new home")
  check(T.x == 40 and T.y == 1 and T.z == 40, ("back on the computer (%d,%d,%d)"):format(T.x, T.y, T.z))
  check(W.get(40, 3, 47) == "minecraft:cobblestone" and W.get(40, 0, 41) == "computercraft:wired_modem_full", "nothing dug")
  check((T.files["surveyor.log"] or ""):find("Survey done"), "it keeps a log: surveyor.log")
end

-- take every `item` out of storage (returns a function that puts it back)
local function withoutInStorage(item)
  local held = {}
  for name, I in pairs(W.inv) do
    if name:find("barrel") then
      for slot, st in pairs(I.slots) do if st.name == item then held[#held + 1] = { I, st.count }; I.take(slot) end end
    end
  end
  return function() for _, h in ipairs(held) do h[1].insert(item, h[2]) end end
end

print("scenario: the same with only 4 coal and none in storage: it stops exploring in time,")
print("          marks the home, gets back")
do
  local backs = {}
  for _, item in ipairs(baseEnv.require("oreconf").FUEL_ORDER) do backs[#backs + 1] = withoutInStorage(item) end
  local function putBack() for _, b in ipairs(backs) do b() end end
  topLayout(140, 40, "minecraft:chest_78")
  local T = surveyorOnTop(62, 140, 40, 4)
  local lowest = math.huge
  bootTurtle(T)
  local ok = runUntil(function()
    lowest = math.min(lowest, T.fuel)
    return T.files["surveyor.state"] and T.files["surveyor.state"]:find("done")
  end, 400000)
  check(ok, "the survey finished")
  check(T.x == 140 and T.y == 1 and T.z == 40, ("back on the computer (%d,%d,%d)"):format(T.x, T.y, T.z))
  check(homeAt("minecraft:chest_78") ~= nil, "registered the home")
  check(lowest > 0, "never ran dry: lowest fuel " .. lowest)
  check((T.files["surveyor.log"] or ""):find("stop exploring"), "said it stopped exploring for fuel")
  check((T.files["surveyor.log"] or ""):find("No fuel from the base"), "it asked the base first (storage had none)")
  putBack()
end

print("scenario: with 2 coal it makes a fuel run: the base pushes coal into it at a modem")
do
  W.inv["minecraft:barrel_0"].insert("minecraft:coal", 64)
  topLayout(240, 40, "minecraft:chest_79")
  local T = surveyorOnTop(64, 240, 40, 2)
  local lowest, maxZ = math.huge, 40
  bootTurtle(T)
  local ok = runUntil(function()
    lowest, maxZ = math.min(lowest, T.fuel), math.max(maxZ, T.z)
    return T.files["surveyor.state"] and T.files["surveyor.state"]:find("done")
  end, 400000)
  check(ok, "the survey finished")
  check((T.files["surveyor.log"] or ""):find("The base gave me"), "got fuel from the base")
  check(maxZ >= 40 + 30, "so it explored the whole range: furthest z " .. maxZ)
  check(homeAt("minecraft:chest_79") ~= nil, "registered the home")
  check(T.x == 240 and T.y == 1 and T.z == 40 and lowest > 0, "back on the computer, never ran dry")
end

print("scenario: fuel on request: a turtle next to a modem gets coal pushed in; one off the network is told why")
do
  local barrel = W.inv["minecraft:barrel_0"]
  barrel.insert("minecraft:coal", 64)
  barrel.insert("minecraft:charcoal", 5)
  local function stored(item)
    local n = 0
    for _, I in pairs(W.inv) do if I.name:find("barrel") then n = n + I.count(item) end end
    return n
  end
  local coalBefore, charBefore = stored("minecraft:coal"), stored("minecraft:charcoal")
  local ask = 'local link = require("link"); local got, why = link.requestFuel(500); ' ..
              'local f = fs.open("ask.out", "w"); f.write(tostring(got) .. "|" .. tostring(why)); f.close()'
  local function asker(id, x, z, extra)
    local T = newTurtleEntity(id, x, 0, z, 0)
    T.fuel = 5
    for _, name in ipairs(manifest.turtle) do T.files[name] = repoFile(name) end
    T.files["agent.cfg"] = ser({ role = "miner", base = 0 })
    T.files["ask.lua"] = ask
    if extra then extra(T) end
    local env = turtleEnv(T)
    local co = coroutine.create(function() env.shell.run("ask") end)
    scheduler.cos[#scheduler.cos + 1] = { T = T, co = co }
    runUntil(function() return coroutine.status(co) == "dead" end, 5000)
    return T
  end
  W.set(300, 0, 299, "computercraft:wired_modem_full")
  local T = asker(70, 300, 300)
  local usedChar, usedCoal = charBefore - stored("minecraft:charcoal"), coalBefore - stored("minecraft:coal")
  check(T.fuel >= 505, "on the network: fuel 5 -> " .. T.fuel .. " (" .. tostring(T.files["ask.out"]) .. ")")
  check(usedChar == math.min(charBefore, 7) and usedChar + usedCoal == 7,
    ("charcoal first, then coal: %d charcoal + %d coal for 500 asked"):format(usedChar, usedCoal))
  local T2 = asker(71, 310, 300, function(t) t.left = "computercraft:wireless_modem_normal" end)
  check(T2.fuel == 5 and (T2.files["ask.out"] or ""):find("modem is off"), "off the network: no fuel, and why: " .. tostring(T2.files["ask.out"]))
end

print("scenario: a cable buried in the ground and a chest wall nearby: the survey ends, it")
print("          doesn't try to tunnel in its head or look at chests far from the network")
do
  local ox, oz = 700, 400
  for x = ox - 20, ox + 20 do for z = oz - 20, oz + 40 do for y = -6, -1 do W.set(x, y, z, "minecraft:stone") end end end
  W.set(ox, 0, oz, "computercraft:computer_advanced")
  W.set(ox, 0, oz + 1, "computercraft:wired_modem_full")          -- behind the computer, on the ground
  W.set(ox, -1, oz + 1, "computercraft:cable")                     -- then down into the ground
  for z = oz + 1, oz + 20 do W.set(ox, -2, z, "computercraft:cable") end -- buried
  W.set(ox, -1, oz + 21, "computercraft:cable")
  W.set(ox, 0, oz + 21, "computercraft:wired_modem_full")         -- up at the home
  newInv("minecraft:chest_90", ox, 0, oz + 23)                   -- home spot (ox,0,oz+22)
  -- a player's chest wall right next to the base, not on the network
  for x = ox - 12, ox - 1 do for y = 0, 1 do W.set(x, y, oz - 1, "minecraft:chest") end end
  local T = surveyorOnTop(90, ox, oz, 32)
  local maxZ, minX = oz, ox
  bootTurtle(T)
  local ok = runUntil(function()
    maxZ, minX = math.max(maxZ, T.z), math.min(minX, T.x)
    return T.files["surveyor.state"] and T.files["surveyor.state"]:find("done")
  end, 400000)
  local st = textutils.unserialize(T.files["surveyor.state"] or "{}") or {}
  check(ok, "the survey finished")
  check((st.steps or 0) < 400, "in a bounded number of steps: " .. tostring(st.steps))
  check(minX > ox - 6, "didn't walk along the chest wall: furthest west " .. (minX - ox))
  -- (a cable buried all the way can't be followed without digging: that home
  -- is registered with $home or `home <role>`, as SETUP says)
  check(homeAt("minecraft:chest_90") == nil, "the home behind a fully buried cable is not guessed")
  check(T.x == ox and T.y == 1 and T.z == oz, "back on the computer")
  check((T.files["surveyor.log"] or ""):find("out of reach"), "reports the buried sides as out of reach")
end

print("scenario: the home chest is a mailbox: a turtle claims it, the base keeps its supplies")
print("          in it (selected saplings in equal amounts, bone meal, fuel) and empties the rest")
do
  local barrel = W.inv["minecraft:barrel_0"]
  for _, p in ipairs({ { "minecraft:charcoal", 64 }, { "minecraft:oak_sapling", 64 }, { "minecraft:birch_sapling", 64 },
                       { "minecraft:bone_meal", 64 }, { "minecraft:spruce_sapling", 200 } }) do barrel.insert(p[1], p[2]) end
  local chest = newInv("minecraft:chest_95", 800, 0, 800)
  local other = newInv("minecraft:chest_96", 810, 0, 800)
  -- a forester claims chest_95 with the marker trick
  local r1 = factory.handle(F, 95, { type = "status", state = "mark1", role = "forester", label = "f-95" })
  chest.insert("minecraft:cobblestone", 1)
  local r2 = factory.handle(F, 95, { type = "status", state = "mark2", role = "forester", label = "f-95" })
  check(r1.type == "ok" and r2.type == "marked" and r2.chest == "minecraft:chest_95" and F.turtles[95].chest == "minecraft:chest_95",
    "claimed: " .. tostring(r2.chest))
  factory.handle(F, 95, { type = "status", state = "resting", role = "forester", label = "f-95" }) -- (keeps it)
  check(F.turtles[95].chest == "minecraft:chest_95", "the claim survives its next status")
  -- its haul, plus too many oak saplings from its own trees
  chest.insert("minecraft:oak_log", 40); chest.insert("minecraft:oak_sapling", 100)
  other.insert("minecraft:oak_log", 5) -- nobody's chest: just emptied
  F.saplings = {}
  factory.toggleSapling(F, "minecraft:oak_sapling"); factory.toggleSapling(F, "minecraft:birch_sapling")
  F.boneMeal = false; factory.toggleBoneMeal(F)
  factory.serviceChests(F)
  local function has(I, item) return I.count(item) end
  check(has(chest, "minecraft:oak_log") == 0 and has(chest, "minecraft:cobblestone") == 0, "its haul went to storage")
  check(has(chest, "minecraft:oak_sapling") == 16 and has(chest, "minecraft:birch_sapling") == 16,
    ("selected kinds, 16 each: oak %d, birch %d"):format(has(chest, "minecraft:oak_sapling"), has(chest, "minecraft:birch_sapling")))
  check(has(chest, "minecraft:spruce_sapling") == 0, "not the unselected spruce")
  check(has(chest, "minecraft:bone_meal") == 32 and has(chest, "minecraft:charcoal") == 16, "bone meal 32 and charcoal 16")
  check(has(other, "minecraft:oak_log") == 0, "an unclaimed chest is just emptied")
  -- auto (nothing selected): the kind storage has most of
  F.saplings = {}
  factory.serviceChests(F)
  check(has(chest, "minecraft:spruce_sapling") == 16 and has(chest, "minecraft:oak_sapling") == 0,
    "auto: spruce (most in storage), the others back to storage")
  -- a miner's chest gets fuel only
  local mc = newInv("minecraft:chest_97", 820, 0, 800)
  F.turtles[97] = { id = 97, role = "miner", chest = "minecraft:chest_97", seen = W.clock }
  factory.serviceChests(F)
  check(has(mc, "minecraft:charcoal") == 16 and has(mc, "minecraft:bone_meal") == 0, "a miner's mailbox: 16 charcoal, nothing else")
end

print("scenario: a modem that only touches a turtle goes off when it leaves; one with a barrel stays on")
do
  local function probe(id, x, withBarrel)
    W.set(x, -1, 400, "computercraft:wired_modem_full")       -- under the turtle's home spot
    if withBarrel then newInv("minecraft:barrel_" .. id, x + 1, -1, 400) end
    local T = newTurtleEntity(id, x, 0, 400, 0)
    T.fuel = 100
    local api = turtleEnv(T).turtle
    local before = storage.open(net).findTurtle(id) ~= nil
    api.forward(); api.back()                                  -- leaves home and comes back
    return before, storage.open(net).findTurtle(id) ~= nil
  end
  local b1, a1 = probe(80, 500, false)
  check(b1 and not a1, "alone: on the network at first, off after it left and came back")
  local b2, a2 = probe(81, 510, true)
  check(b2 and a2, "with a barrel against the modem: still on when it comes back")
end

print("scenario: TINY FUEL: furnaces get one tiny coal per item (blast: per two); off: coal as before")
do
  local production = baseEnv.require("production")
  local sent = {}
  local fake = {
    furnaces = function() return { { name = "furnace_a" }, { name = "blast_b", blast = true } } end,
    slots = function() return {} end,
    storeSlot = function() end,
    send = function(to, item, n, _, slot) sent[#sent + 1] = { to, item, n, slot }; return n end,
  }
  local stock = { ["minecraft:raw_gold"] = 3, ["minecraft:raw_iron"] = 5, ["utilitarian:tiny_charcoal"] = 20,
                  ["minecraft:coal"] = 100 }
  local function fuelOf(to)
    for _, x in ipairs(sent) do if x[1] == to and x[4] == 2 then return x[2], x[3] end end
  end
  production.smelt(fake, production.DEFAULTS, false, stock, true)
  local i1, n1 = fuelOf("furnace_a")
  local i2, n2 = fuelOf("blast_b")
  check(i1 == "utilitarian:tiny_charcoal" and n1 == 3, "furnace, 3 raw gold: 3 tiny (" .. tostring(i1) .. " " .. tostring(n1) .. ")")
  check(i2 == "utilitarian:tiny_charcoal" and n2 == 3, "blast furnace, 5 raw iron: 3 tiny (" .. tostring(i2) .. " " .. tostring(n2) .. ")")
  sent = {}
  production.smelt(fake, production.DEFAULTS, false, stock, false)
  i1, n1 = fuelOf("furnace_a")
  check(i1 == "minecraft:coal" and n1 == 8, "switch off: 8 coal as before (" .. tostring(i1) .. " " .. tostring(n1) .. ")")
  -- the craft: wanted only with charcoal to make it from, then the REAL recipe
  local w = production.wantedTiny({ ["minecraft:charcoal"] = 3 }, production.DEFAULTS)
  check(w[1] and w[1][1] == "utilitarian:tiny_charcoal" and w[1][2] == 24, "wants 3 charcoal made into 24 tiny")
  check(#production.wantedTiny({ ["minecraft:coal"] = 10 }, production.DEFAULTS) == 0, "never eats the turtles' coal reserve")
  local job = production.plan({ ["minecraft:charcoal"] = 3 }, false, w)
  check(job and job.item == "utilitarian:tiny_charcoal" and job.grid[1] == "minecraft:charcoal", "the planner makes it a craft job")
  local CT = newTurtleEntity(72, 320, 0, 300, 0)
  CT.right = "minecraft:crafting_table"
  CT.inv[1] = { name = "minecraft:charcoal", count = 3 }
  local env = turtleEnv(CT)
  env.turtle.select(1)
  check(env.turtle.craft() and CT.inv[1] and CT.inv[1].name == "utilitarian:tiny_charcoal" and CT.inv[1].count == 24,
    "crafted by the real Utilitarian recipe: " .. textutils.serialize(CT.inv[1]))
end

print("scenario: stranded away from its start: 'surveyor survey' refuses, 'surveyor home' brings it back")
do
  W.set(200, 0, 40, "computercraft:computer_advanced")
  local T = newTurtleEntity(63, 203, 1, 40, 1) -- 3 east of its start, facing east
  T.fuel = 100
  for _, name in ipairs(manifest.turtle) do T.files[name] = repoFile(name) end
  T.files["agent.cfg"] = ser({ role = "surveyor", base = 0 })
  T.inv[2] = { name = "minecraft:compass", count = 1 }
  T.files["surveyor.state"] = ser({ pos = { x = 3, y = 0, z = 0 }, heading = 1, steps = 50, stranded = true, homes = {} })
  T.files["surveyor.map"] = ser({ ["0,0,0"] = false, ["1,0,0"] = false, ["2,0,0"] = false, ["3,0,0"] = false })
  local env = turtleEnv(T)
  local co = coroutine.create(function() env.shell.run("surveyor", "survey") end)
  scheduler.cos[#scheduler.cos + 1] = { T = T, co = co }
  runUntil(function() return coroutine.status(co) == "dead" end, 2000)
  check(T.x == 203 and (T.files["surveyor.state"] or ""):find("stranded"), "'surveyor survey' refused: map and state kept")
  co = coroutine.create(function() env.shell.run("surveyor", "home") end)
  scheduler.cos[#scheduler.cos + 1] = { T = T, co = co }
  runUntil(function() return coroutine.status(co) == "dead" end, 20000)
  check(T.x == 200 and T.y == 1 and T.z == 40, ("'surveyor home' took it back (%d,%d,%d)"):format(T.x, T.y, T.z))
  check((T.files["surveyor.state"] or ""):find("done") and not T.files["surveyor.state"]:find("stranded"), "and marked the survey done")
end

print("scenario: a surveyor with no fuel and nothing to burn says so and waits")
do
  W.set(60, 0, 60, "computercraft:computer_advanced")
  local T = newTurtleEntity(61, 60, 1, 60, 0)
  T.fuel = 0
  for _, name in ipairs(manifest.turtle) do T.files[name] = repoFile(name) end
  T.files["agent.cfg"] = ser({ role = "surveyor", base = 0 })
  T.inv[1] = { name = "minecraft:cobblestone", count = 8 }
  T.inv[2] = { name = "minecraft:compass", count = 1 }
  bootTurtle(T)
  runUntil(function() return false end, 2000)
  check(T.x == 60 and T.y == 1 and T.z == 60, "did not move")
  check(not (T.files["surveyor.state"] or ""):find("done"), "not marked done: it carries on after it gets fuel")
end

print(failures == 0 and "ALL PASSED" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
