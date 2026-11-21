-- surveyor: maps the base's wired network and registers the home spots.
--
-- For the early game: a plain advanced turtle, no upgrades needed (a compass
-- is used if it has one). Place it NEXT TO THE BASE COMPUTER (where it stands
-- becomes (0,0,0) for every home) and run `surveyor <facing>`, where <facing>
-- is the way it looks (F3: "Facing: north"). Give it some coal, and a few
-- cheap items as markers (one per home), e.g. cobblestone.
--
-- 1. It explores the open air around the computer and the cables and modems
--    it can see, climbing walls next to them (never digging): a turtle only
--    sees the blocks in front of, above and below it (it turns to see the
--    sides), so cables buried inside walls with no open air next to them are
--    missed (use `$home` in chat for those homes). The installer disk drive it
--    finds tells the base where the build spot is (the block above it).
-- 2. Every free spot next to a home chest (a vanilla chest on the network) with
--    a modem next to it is a home spot: a turtle standing there faces away
--    from the chest. It goes to each, and through that modem asks the base to
--    watch the chests, drops one marker into the chest, and the base sees
--    which network chest it was and registers the home (role "off" until you
--    pick one on the monitor).
-- 3. It returns to the build spot.

local tmove = require("tmove")
local link = require("link")
local nav = require("nav")

local CFG = {
  reach = 32,       -- explore at most this far from the build spot (x and z) ...
  height = 16,      -- ... and up/down
  near = 2,         -- explore open air this close to a cable or modem
  start = 4,        -- and this close to the build spot
  maxSteps = 4000,
  stateFile = "surveyor.state",
  mapFile = "surveyor.map",
}

local DIRS = nav.DIRS
local S   -- { pos = {x,y,z}, heading, pending, done, homes }
local MAP -- [key] = block name, or false for open air

local function log(...) print(...) end

local function writeTable(path, t)
  local f = fs.open(path, "w")
  f.write(textutils.serialize(t))
  f.close()
end

local function readTable(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = textutils.unserialize(f.readAll())
  f.close()
  return t
end

local function save() writeTable(CFG.stateFile, S) end
local function saveMap() writeTable(CFG.mapFile, MAP) end

local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function unkey(k)
  local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
  return tonumber(x), tonumber(y), tonumber(z)
end

-- the six neighbours: { dx, dy, dz, how } with how = heading 0-3, "up", "down"
local SIX = {
  { 0, 0, -1, 0 }, { 1, 0, 0, 1 }, { 0, 0, 1, 2 }, { -1, 0, 0, 3 },
  { 0, 1, 0, "up" }, { 0, -1, 0, "down" },
}

-- cables, modems, and computers (the base computer is where it all starts)
local function isNetwork(name)
  return name and (name:find("^computercraft:cable") or name:find("^computercraft:wired_modem")
    or name:find("^computercraft:computer") or name == "computercraft:disk_drive") and true or false
end
local function isHomeChest(name) return name == "minecraft:chest" end

local function inBounds(x, y, z)
  return math.abs(x) <= CFG.reach and math.abs(z) <= CFG.reach and math.abs(y) <= CFG.height
end

-- ------------------------------------------------------------- movement --
local function turnTo(h)
  local d = (h - S.heading) % 4
  if d == 1 then turtle.turnRight() elseif d == 2 then turtle.turnRight(); turtle.turnRight()
  elseif d == 3 then turtle.turnLeft() end
  S.heading = h
  save()
end

local function applyMove(st, kind)
  if kind == "up" then st.pos.y = st.pos.y + 1
  elseif kind == "down" then st.pos.y = st.pos.y - 1
  else
    local d = DIRS[st.heading]
    st.pos.x, st.pos.z = st.pos.x + d[1], st.pos.z + d[3]
  end
end

-- One step into a cell we know is open; never digs. False if it stays blocked
-- (a mob, a player, a turtle): the caller plans around it.
local function stepTo(how)
  local fn, attack, kind
  if how == "up" then fn, attack, kind = turtle.up, turtle.attackUp, "up"
  elseif how == "down" then fn, attack, kind = turtle.down, turtle.attackDown, "down"
  else turnTo(how); fn, attack, kind = turtle.forward, turtle.attack, "fwd" end
  for _ = 1, 10 do
    if tmove.move(S, save, kind, fn, applyMove) then
      S.steps = (S.steps or 0) + 1
      return true
    end
    attack()
    sleep(0.5)
  end
  return false
end

-- --------------------------------------------------------------- looking --
local function record(dx, dy, dz, ok, b)
  MAP[key(S.pos.x + dx, S.pos.y + dy, S.pos.z + dz)] = ok and b.name or false
end

-- Inspect all six neighbours (turning for the sides), skipping known ones.
local function look()
  local p = S.pos
  if MAP[key(p.x, p.y + 1, p.z)] == nil then record(0, 1, 0, turtle.inspectUp()) end
  if MAP[key(p.x, p.y - 1, p.z)] == nil then record(0, -1, 0, turtle.inspectDown()) end
  for i = 0, 3 do
    local h = (S.heading + i) % 4
    local d = DIRS[h]
    if MAP[key(p.x + d[1], p.y, p.z + d[3])] == nil then
      turnTo(h)
      record(d[1], 0, d[3], turtle.inspect())
    end
  end
  MAP[key(p.x, p.y, p.z)] = false
  saveMap()
end

-- ----------------------------------------------------------------- paths --
-- Breadth-first over known open cells from where we are to the first cell
-- `want(key)` accepts. Returns the list of moves, or nil.
local function pathTo(want, avoid)
  local start = key(S.pos.x, S.pos.y, S.pos.z)
  if want(start) then return {} end
  local prev, queue, head = { [start] = false }, { start }, 1
  while queue[head] do
    local cur = queue[head]
    head = head + 1
    local x, y, z = unkey(cur)
    for _, n in ipairs(SIX) do
      local nx, ny, nz = x + n[1], y + n[2], z + n[3]
      local nk = key(nx, ny, nz)
      if prev[nk] == nil and MAP[nk] == false and not (avoid and avoid[nk]) and inBounds(nx, ny, nz) then
        prev[nk] = { cur, n[4] }
        if want(nk) then
          local moves, k = {}, nk
          while prev[k] do table.insert(moves, 1, prev[k][2]); k = prev[k][1] end
          return moves
        end
        queue[#queue + 1] = nk
      end
    end
  end
end

local blocked = {} -- cells we could not step into this run (a mob, a player...)

local function follow(moves)
  for _, how in ipairs(moves) do
    if not stepTo(how) then
      local d = type(how) == "number" and DIRS[how] or { 0, how == "up" and 1 or -1, 0 }
      blocked[key(S.pos.x + d[1], S.pos.y + d[2], S.pos.z + d[3])] = true
      return false
    end
  end
  return true
end

local function goTo(x, y, z)
  local target = key(x, y, z)
  for _ = 1, 5 do
    local moves = pathTo(function(k) return k == target end, blocked)
    if not moves then return false end
    if follow(moves) then return true end
  end
  return false
end

-- --------------------------------------------------------------- explore --
local networkCells = {}
local function noteNetwork()
  networkCells = {}
  for k, name in pairs(MAP) do
    if name and isNetwork(name) then networkCells[#networkCells + 1] = { unkey(k) } end
  end
end

-- open air worth standing in: near where it started, or horizontally close to
-- the network at any height (so it climbs the wall a cable runs through and
-- gets over to the other side)
local function interesting(x, y, z)
  if math.abs(x) + math.abs(y) + math.abs(z) <= CFG.start then return true end
  for _, c in ipairs(networkCells) do
    if math.abs(c[1] - x) + math.abs(c[3] - z) <= CFG.near then return true end
  end
  return false
end

local function hasUnknownNeighbour(x, y, z)
  for _, n in ipairs(SIX) do
    local nx, ny, nz = x + n[1], y + n[2], z + n[3]
    if MAP[key(nx, ny, nz)] == nil and inBounds(nx, ny, nz) then return true end
  end
  return false
end

local function explore()
  log("Mapping the network around the build spot...")
  look()
  while (S.steps or 0) < CFG.maxSteps do
    noteNetwork()
    local moves = pathTo(function(k)
      local x, y, z = unkey(k)
      return interesting(x, y, z) and hasUnknownNeighbour(x, y, z)
    end, blocked)
    if not moves then break end
    follow(moves)
    look()
  end
  noteNetwork()
  local chests = 0
  for _, name in pairs(MAP) do if name and isHomeChest(name) then chests = chests + 1 end end
  log(("Mapped: %d cable/modem blocks, %d chests."):format(#networkCells, chests))
end

-- ----------------------------------------------------------------- homes --
-- Free spots next to home chests that have a modem next to them.
local function homeSpots()
  local spots = {}
  for k, name in pairs(MAP) do
    if name and isHomeChest(name) then
      local cx, cy, cz = unkey(k)
      for h = 0, 3 do
        local vx, vy, vz = cx + DIRS[h][1], cy, cz + DIRS[h][3]
        if MAP[key(vx, vy, vz)] == false then
          local modem = false
          for _, n in ipairs(SIX) do
            local nb = MAP[key(vx + n[1], vy + n[2], vz + n[3])]
            if nb and nb:find("^computercraft:wired_modem") or (nb and nb:find("^computercraft:cable")) then modem = true end
          end
          if modem then spots[#spots + 1] = { x = vx, y = vy, z = vz, facing = h, chest = k } end
        end
      end
    end
  end
  table.sort(spots, function(a, b) return key(a.x, a.y, a.z) < key(b.x, b.y, b.z) end)
  return spots
end

-- the slot with the most of something to use as markers (not fuel)
local function markerSlot()
  local best, bestN
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name ~= "minecraft:coal" and d.name ~= "minecraft:charcoal" and not link.isKeptItem(d.name)
       and (not bestN or d.count > bestN) then best, bestN = i, d.count end
  end
  return best
end

local function registerHomes()
  local spots = homeSpots()
  log(("%d possible home spots."):format(#spots))
  S.homes = S.homes or {}
  for _, sp in ipairs(spots) do
    local id = key(sp.x, sp.y, sp.z)
    if not S.homes[id] then
      if goTo(sp.x, sp.y, sp.z) then
        turnTo((sp.facing + 2) % 4) -- face the chest
        local slot = markerSlot()
        local home = { x = sp.x, y = sp.y, z = sp.z, facing = nav.NAMES[sp.facing] }
        if not link.hasModem() then
          log("No modem reachable at " .. id .. "; skipped")
        elseif not slot then
          log("Out of marker items; put a few cobblestone in me")
          break
        else
          local r1 = link.talk("mark1", { home = home }, false)
          if r1 and r1.type == "ok" then
            turtle.select(slot)
            turtle.drop(1)
            local r2 = link.talk("mark2", { home = home }, false)
            if r2 and r2.type == "marked" then
              S.homes[id] = r2.chest or true
              save()
              log(("Home at %s -> %s"):format(id, tostring(r2.chest)))
            else
              log("The base did not find the marker for " .. id)
            end
          else
            log("No answer from the base at " .. id)
          end
        end
      end
    end
  end
end

-- ------------------------------------------------------------------ main --
local args = { ... }
S = readTable(CFG.stateFile)
MAP = readTable(CFG.mapFile)
if args[1] and args[1] ~= "resume" then S, MAP = nil, nil end -- a new survey

if S then
  tmove.recover(S, save, applyMove)
  S.heading = nav.compass() or S.heading
  if S.done then log("Survey done. Run 'surveyor <facing>' on the build spot to survey again."); return end
else
  local h = nav.compass() or nav.index(args[1] or "")
  if not h then error("Tell me which way I face (F3): surveyor north|east|south|west", 0) end
  S = { pos = { x = 0, y = 0, z = 0 }, heading = h, steps = 0 }
  MAP = {}
  save()
end
MAP = MAP or {}

if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 200 then
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and (d.name == "minecraft:coal" or d.name == "minecraft:charcoal") then
      turtle.select(i); turtle.refuel(math.min(d.count, 16))
    end
  end
  turtle.select(1)
end

explore()
registerHomes()
-- the installer disk drive: the build spot is the block above it
local drives = {}
for k, name in pairs(MAP) do
  if name == "computercraft:disk_drive" then
    local x, y, z = unkey(k)
    drives[#drives + 1] = { x = x, y = y, z = z }
  end
end
S.drives = drives
save()

-- report from a spot next to a modem (it may have none where it started)
local function nextToModem(k)
  local x, y, z = unkey(k)
  for _, n in ipairs(SIX) do
    local nb = MAP[key(x + n[1], y + n[2], z + n[3])]
    if nb == "computercraft:wired_modem_full" then return true end
  end
  return false
end
local reported = false
local moves = pathTo(nextToModem, blocked)
if moves and follow(moves) then
  reported = link.talk("surveyed", { homes = S.homes, drives = drives }, false) ~= nil
end
if not reported then log("Could not report the survey to the base (no modem reached)") end
if not goTo(0, 0, 0) then log("Could not get back to where I started") end
S.done = true
save()
log("Survey done.")
