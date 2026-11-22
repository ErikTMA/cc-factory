-- surveyor: maps the base's wired network and registers the home spots.
--
-- For the early game: a plain advanced turtle. Place it NEXT TO THE BASE
-- COMPUTER (where it stands becomes (0,0,0) for every home) with some coal, a
-- few cheap items as markers (one per home, e.g. cobblestone) and a COMPASS in
-- its inventory: it fits the compass itself to know which way it faces and
-- starts on its own (`bootstrap ... surveyor` installs it). Without a compass,
-- run `surveyor <facing>` with the way it looks (F3: "Facing: north").
--
-- 1. It looks at every side of every network block it knows (computer,
--    cable, modem, disk drive) and of every chest, starting with the base
--    computer next to it, so it follows the cables wherever they go. To see an
--    unseen side it plans the shortest way there through open air, treating
--    unknown space as open until it sees otherwise (so it climbs walls and
--    goes round them); it never digs. A turtle only sees the blocks next to
--    it, so a side with no open air next to it (a cable buried in a wall) is
--    never seen: use `$home` in chat for homes behind those. It stays within
--    CFG.reach / CFG.height of where it started, and gives up on a side when
--    no way to it turns up within CFG.maxSearch cells of searching. The
--    installer disk drive it finds tells the base where the build spot is.
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
local C = require("oreconf")

local CFG = {
  reserve = 20,      -- fuel kept on top of what the way home needs
  reach = 32,        -- never further than this from where it started (x and z) ...
  height = 16,       -- ... and up/down
  maxSearch = 20000, -- cells one path search may visit before it gives up
  maxUnknown = 12,   -- a planned way may cross at most this many unknown cells
                     -- (enough to go over a ~5-high wall, not to "tunnel" through
                     -- earth that has never been seen)
  unknownCost = 3,   -- an unknown cell counts as this many steps when planning
  maxTries = 3,      -- give up on a side after its way was blocked this often
  chainDepth = 3,    -- no cable seen yet: follow a hidden chain this many cells
                     -- out from the computer's hidden side
  maxSteps = 4000,
  minFuel = 100,     -- refuel from its inventory below this
  askMargin = 150,   -- go ask the base for fuel while this much above the need is left
                     -- (so the trip to a modem is still affordable)
  stateFile = "surveyor.state",
  mapFile = "surveyor.map",
}

local DIRS = nav.DIRS
local S   -- { pos = {x,y,z}, heading, pending, done, homes }
local MAP -- [key] = block name, or false for open air

-- Everything it says also goes to surveyor.log (readable after the fact).
local function log(...)
  print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  local f = fs.open("surveyor.log", "a")
  if f then f.write(table.concat(parts, " ") .. "\n"); f.close() end
end

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

-- Burn fuel items from the inventory (coal, charcoal, logs...; not the
-- markers' slot if it can help it) until it has `want` fuel.
local function refuel(want)
  if turtle.getFuelLevel() == "unlimited" then return true end
  for i = 1, 16 do
    if turtle.getFuelLevel() >= want then break end
    if turtle.getItemCount(i) > 0 then
      turtle.select(i)
      while turtle.getFuelLevel() < want and turtle.getItemCount(i) > 0 and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
  return turtle.getFuelLevel() >= want
end

local function fuel()
  local f = turtle.getFuelLevel()
  return f == "unlimited" and math.huge or f
end

local lastFail -- why the last step failed: "fuel" or "blocked"

-- One step into a cell we know is open; never digs. False if it stays blocked
-- (a mob, a player, a turtle): the caller plans around it.
local function stepTo(how)
  local fn, attack, kind
  if how == "up" then fn, attack, kind = turtle.up, turtle.attackUp, "up"
  elseif how == "down" then fn, attack, kind = turtle.down, turtle.attackDown, "down"
  else turnTo(how); fn, attack, kind = turtle.forward, turtle.attack, "fwd" end
  if fuel() < CFG.minFuel then refuel(1000) end
  if fuel() < 1 then log("Out of fuel: put coal or charcoal in me"); lastFail = "out of fuel"; return false end
  for _ = 1, 10 do
    if tmove.move(S, save, kind, fn, applyMove) then
      S.steps = (S.steps or 0) + 1
      return true
    end
    attack()
    sleep(0.5)
  end
  lastFail = "something stays in the way"
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
  local first = S.heading -- turnTo changes S.heading inside the loop
  for i = 0, 3 do
    local h = (first + i) % 4
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

-- Go to a known open cell. Returns true, or false and why not.
local function goTo(x, y, z)
  local target = key(x, y, z)
  for _ = 1, 5 do
    local moves = pathTo(function(k) return k == target end, blocked)
    if not moves then return false, "no known way there" end
    lastFail = nil
    if follow(moves) then return true end
    if lastFail == "out of fuel" then return false, lastFail end
  end
  return false, lastFail or "blocked"
end

-- --------------------------------------------------------------- fuel --
-- Steps from every known open cell back to the start (through known open
-- cells): the real way home, not the straight line.
local function stepsHome()
  local origin = key(0, 0, 0)
  local dist, queue, head = { [origin] = 0 }, { origin }, 1
  while queue[head] do
    local cur = queue[head]
    head = head + 1
    if head % 2000 == 0 then os.queueEvent("surveyor_yield"); os.pullEvent("surveyor_yield") end
    local x, y, z = unkey(cur)
    for _, n in ipairs(SIX) do
      local nk = key(x + n[1], y + n[2], z + n[3])
      if dist[nk] == nil and MAP[nk] == false and not blocked[nk] then
        dist[nk] = dist[cur] + 1
        queue[#queue + 1] = nk
      end
    end
  end
  return dist
end

local homeSpots -- (below)

-- Fuel the rest of the job needs from here: home, plus a round trip from the
-- start to every home spot still to mark (an upper bound), plus a reserve.
local function fuelToFinish(dist, at)
  at = at or key(S.pos.x, S.pos.y, S.pos.z)
  local ax, ay, az = unkey(at)
  local here = dist[at] or 2 * (math.abs(ax) + math.abs(ay) + math.abs(az))
  local spots = 0
  for _, sp in ipairs(homeSpots()) do
    if not (S.homes or {})[key(sp.x, sp.y, sp.z)] then spots = spots + 2 * (dist[key(sp.x, sp.y, sp.z)] or 0) end
  end
  return here + spots + CFG.reserve
end

-- True when it has (or can burn its way to) `need` fuel.
local function haveFuel(need)
  if fuel() < need then refuel(need + 500) end
  return fuel() >= need
end

-- a cell next to a full wired modem: from there it can talk to the base, and
-- (with the modem enabled) the base can push fuel into it
local function nextToModem(k)
  local x, y, z = unkey(k)
  for _, n in ipairs(SIX) do
    if MAP[key(x + n[1], y + n[2], z + n[3])] == "computercraft:wired_modem_full" then return true end
  end
  return false
end

-- Fuel run: go to the nearest spot next to a modem (if it can still finish
-- the job from there) and ask the base for fuel. True when it got some; the
-- caller plans again from where it now is. Gives up for this run after the
-- base said no once.
local function fuelRun(need)
  if S.noFuelFromBase then return false end
  local moves = pathTo(nextToModem, blocked)
  if not moves then log("Low on fuel, and I know no modem to ask the base from"); return false end
  local at = key(S.pos.x, S.pos.y, S.pos.z)
  for _, how in ipairs(moves) do
    local d = type(how) == "number" and DIRS[how] or { 0, how == "up" and 1 or -1, 0 }
    local x, y, z = unkey(at)
    at = key(x + d[1], y + d[2], z + d[3])
  end
  local cost = #moves + fuelToFinish(stepsHome(), at)
  if fuel() < cost then
    log(("Low on fuel: the nearest modem is %d steps away, %d fuel with the way back; I have %d"):format(#moves, cost, fuel()))
    return false
  end
  log("Going to a modem to ask the base for fuel...")
  if not follow(moves) then return false end
  local got, why = link.requestFuel(need + 1000 - fuel())
  if not got or got <= 0 then
    log("No fuel from the base: " .. tostring(why))
    S.noFuelFromBase = true
    save()
    return false
  end
  log(("The base gave me %d fuel"):format(got))
  return true
end

-- --------------------------------------------------------------- explore --
local networkCells = {}
local function noteNetwork()
  networkCells = {}
  for k, name in pairs(MAP) do
    if name and isNetwork(name) then networkCells[#networkCells + 1] = { unkey(k) } end
  end
end

-- What is still to see: the unknown sides of every network block and chest,
-- and of every open cell next to a network block (a home spot is such a cell:
-- its chest is one further).
local given = {} -- sides it gave up on (no way there)
local tries = {} -- [side] = times its way was blocked
local function nextToNetwork(x, y, z)
  for _, n in ipairs(SIX) do
    if isNetwork(MAP[key(x + n[1], y + n[2], z + n[3])] or nil) then return true end
  end
  return false
end
-- a chest can only be a home if a network block is within 2 of it (others,
-- e.g. a player's storage wall, are not worth looking at)
local function nearNetwork(x, y, z)
  for dx = -2, 2 do for dy = -2, 2 do for dz = -2, 2 do
    if math.abs(dx) + math.abs(dy) + math.abs(dz) <= 2 and isNetwork(MAP[key(x + dx, y + dy, z + dz)] or nil) then
      return true
    end
  end end end
  return false
end

local function unseenSides()
  local want = {}
  for k, name in pairs(MAP) do
    local x, y, z = unkey(k)
    if (name and isNetwork(name)) or (name and isHomeChest(name) and nearNetwork(x, y, z))
       or (name == false and nextToNetwork(x, y, z)) then
      for _, n in ipairs(SIX) do
        local nx, ny, nz = x + n[1], y + n[2], z + n[3]
        local nk = key(nx, ny, nz)
        if MAP[nk] == nil and not given[nk] and inBounds(nx, ny, nz) then want[nk] = true end
      end
    end
  end
  return want
end

-- let CC breathe during a long search ("too long without yielding")
local function breathe()
  os.queueEvent("surveyor_yield")
  os.pullEvent("surveyor_yield")
end

-- Cheapest way from here to a cell next to one of `targets`: known open air
-- costs 1 a step, an unknown cell (treated as open until seen) costs
-- CFG.unknownCost, and a way may cross at most CFG.maxUnknown unknown cells:
-- it goes over walls, but doesn't imagine tunnels through earth it never saw.
-- Inside the bounds, visiting at most CFG.maxSearch cells.
-- Returns the moves and the target side it goes to see, or nil.
local function planToSee(targets)
  local start = key(S.pos.x, S.pos.y, S.pos.z)
  local prev, cost, unk = { [start] = false }, { [start] = 0 }, { [start] = 0 }
  local buckets, at, visited = { [0] = { start } }, 0, 0
  local maxCost = 0
  while at <= maxCost and visited <= CFG.maxSearch do
    local bucket = buckets[at]
    local cur = bucket and table.remove(bucket)
    if not cur then
      at = at + 1
    elseif cost[cur] == at then -- (skip stale entries)
      visited = visited + 1
      if visited % 2000 == 0 then breathe() end
      local x, y, z = unkey(cur)
      for _, n in ipairs(SIX) do
        local nx, ny, nz = x + n[1], y + n[2], z + n[3]
        local nk = key(nx, ny, nz)
        if targets[nk] and cur ~= start then
          local moves, k = {}, cur
          while prev[k] do table.insert(moves, 1, prev[k][2]); k = prev[k][1] end
          return moves, nk
        end
        local open, unknown = MAP[nk] == false, MAP[nk] == nil
        if (open or unknown) and not blocked[nk] and not targets[nk] and inBounds(nx, ny, nz) then
          local u = unk[cur] + (unknown and 1 or 0)
          local c = at + (unknown and CFG.unknownCost or 1)
          if u <= CFG.maxUnknown and (cost[nk] == nil or c < cost[nk]) then
            cost[nk], unk[nk], prev[nk] = c, u, { cur, n[4] }
            buckets[c] = buckets[c] or {}
            table.insert(buckets[c], nk)
            if c > maxCost then maxCost = c end
          end
        end
      end
    end
  end
end

local function cellAfter(how)
  local d = type(how) == "number" and DIRS[how] or { 0, how == "up" and 1 or -1, 0 }
  return key(S.pos.x + d[1], S.pos.y + d[2], S.pos.z + d[3])
end

-- Walk a planned way, looking around at every cell; stop as soon as the next
-- cell turns out not to be open (then it plans again with what it learned).
-- Returns true when it got all the way.
local function walkSeeing(moves)
  for _, how in ipairs(moves) do
    local nk = cellAfter(how)
    if MAP[nk] == nil then
      -- look() sees all six sides, so this never happens; if it does, say so
      -- and stop instead of planning the same way forever
      error("surveyor: unseen cell next to me at " .. nk, 0)
    end
    if MAP[nk] ~= false then return false end
    if not stepTo(how) then blocked[nk] = true; return false end
    look()
  end
  return true
end

-- Is any cable or modem known yet?
local function cableKnown()
  for _, name in pairs(MAP) do
    if name and (name:find("^computercraft:cable") or name:find("^computercraft:wired_modem")) then return true end
  end
  return false
end

-- No cable or modem seen yet: the chain broke right at the start. The base
-- computer has a wired modem, so one of its sides IS the network; when that
-- side can't be seen (e.g. the modem sits inside a wall), the chain goes on
-- from that hidden cell: the next link is one of ITS neighbours. Those are
-- looked at next; one that can't be seen either is followed the same way, up
-- to CFG.chainDepth cells out. Never anywhere else.
local chainDepth = {} -- [hidden cell] = how far out along the hidden chain
local function hiddenChainTargets()
  -- the computer's (network blocks') sides it gave up on start the chain
  for k in pairs(given) do
    if chainDepth[k] == nil then
      local x, y, z = unkey(k)
      if nextToNetwork(x, y, z) then chainDepth[k] = 0 end
    end
  end
  local want = {}
  for k, d in pairs(chainDepth) do
    if d < CFG.chainDepth and given[k] then
      local x, y, z = unkey(k)
      for _, n in ipairs(SIX) do
        local nx, ny, nz = x + n[1], y + n[2], z + n[3]
        local nk = key(nx, ny, nz)
        if MAP[nk] == nil and not given[nk] and inBounds(nx, ny, nz) then
          want[nk] = true
          if chainDepth[nk] == nil then chainDepth[nk] = d + 1 end
        end
      end
    end
  end
  return want
end

local function explore()
  log("Mapping the network around the base computer...")
  look()
  while (S.steps or 0) < CFG.maxSteps do
    local targets = unseenSides()
    if next(targets) == nil and not cableKnown() then
      targets = hiddenChainTargets()
      if next(targets) ~= nil and not S.searching then
        log("The computer's network side is hidden: following it from the cells next to it...")
        S.searching = true
      end
    end
    if next(targets) == nil then break end
    local moves, target = planToSee(targets)
    if not moves then
      for k in pairs(targets) do given[k] = true end -- no way to any of them
      break
    end
    -- there, back the same way, and then everything still to do
    local need = 2 * #moves + fuelToFinish(stepsHome())
    local fuelled = haveFuel(need)
    if not haveFuel(need + CFG.askMargin) and fuelRun(need + CFG.askMargin) then
      fuelled = "replan" -- it moved: plan again from here
    end
    if not fuelled then
      log(("Fuel %d: only enough to finish from here, so I stop exploring (give me more coal for a bigger survey)")
        :format(fuel()))
      break
    end
    if fuelled ~= "replan" then
      local before = S.steps or 0
      if not walkSeeing(moves) and MAP[target] == nil then
        -- the way there was blocked: after a few tries this side is out of reach
        tries[target] = (tries[target] or 0) + 1
        if tries[target] >= CFG.maxTries then given[target] = true end
      end
      if (S.steps or 0) == before and #moves > 0 and fuel() < 1 then break end
    end
  end
  noteNetwork()
  local chests, left = 0, 0
  for _, name in pairs(MAP) do if name and isHomeChest(name) then chests = chests + 1 end end
  for _ in pairs(unseenSides()) do left = left + 1 end
  for _ in pairs(given) do left = left + 1 end
  log(("Mapped: %d cable/modem blocks, %d chests, %d sides out of reach, %d steps.")
    :format(#networkCells, chests, left, S.steps or 0))
end

-- ----------------------------------------------------------------- homes --
-- Free spots next to home chests that have a modem next to them.
homeSpots = function()
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

-- A marker: anything the base can spot in the chest (it empties it again).
-- Something that isn't fuel first (cobblestone...); else a piece of fuel, as
-- long as more than one is left.
local function markerSlot()
  local best, bestN, fuelSlot, fuelN
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and not link.isKeptItem(d.name) then
      if C.isFuel(d.name) then
        if d.count > 1 and (not fuelN or d.count > fuelN) then fuelSlot, fuelN = i, d.count end
      elseif not bestN or d.count > bestN then
        best, bestN = i, d.count
      end
    end
  end
  return best or fuelSlot
end

local function registerHomes()
  local spots = homeSpots()
  log(("%d possible home spots."):format(#spots))
  S.homes = S.homes or {}
  for _, sp in ipairs(spots) do
    local id = key(sp.x, sp.y, sp.z)
    local reachable = true
    if not S.homes[id] then
      local function plan()
        local dist = stepsHome()
        local w = pathTo(function(k) return k == id end, blocked)
        return w, w and (#w + (dist[id] or 0) + CFG.reserve)
      end
      local way, need = plan()
      if way and not haveFuel(need) and fuelRun(need) then way, need = plan() end
      if not way then
        log("No known way to the home spot at " .. id .. "; skipped")
        reachable = false
      elseif not haveFuel(need) then
        log(("Not enough fuel to reach the home at %s and get back (%d needed); skipped"):format(id, need))
        reachable = false
      end
    end
    if not S.homes[id] and reachable then
      local arrived, why = goTo(sp.x, sp.y, sp.z)
      if not arrived then log("Could not get to the home spot at " .. id .. ": " .. tostring(why)) end
      if arrived then
        turnTo((sp.facing + 2) % 4) -- face the chest
        local slot = markerSlot()
        local home = { x = sp.x, y = sp.y, z = sp.z, facing = nav.NAMES[sp.facing] }
        if not link.hasModem() then
          log("No modem reachable at " .. id .. "; skipped")
        elseif not slot then
          log("Nothing to mark the home chests with: put a few cobblestone (or coal) in me")
          break
        else
          local r1 = link.talk("mark1", { home = home }, false)
          if r1 and r1.type == "ok" then
            local marker = turtle.getItemDetail(slot).name
            turtle.select(slot)
            turtle.drop(1)
            local r2 = link.talk("mark2", { home = home, marker = marker }, false)
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
-- surveyor [resume]          carry on (what startup runs)
-- surveyor survey | <facing>  a new survey from here (next to the base computer)
-- surveyor survey here        a new survey even though the last one did not end
--                             back at its start (you carried it back yourself)
-- surveyor home               go back to where the survey started
local args = { ... }
S = readTable(CFG.stateFile)
MAP = readTable(CFG.mapFile)
local rest0 = S and S.rest or { x = 0, y = 0, z = 0 }
local away = S and (S.pos.x ~= rest0.x or S.pos.y ~= rest0.y or S.pos.z ~= rest0.z)
if args[1] and args[1] ~= "resume" and args[1] ~= "home" then -- a new survey ("survey", or a facing)
  if S and (away or not S.done) and args[2] ~= "here" then
    print(("My last survey isn't finished: I'm %d,%d,%d from where it started."):format(S.pos.x, S.pos.y, S.pos.z))
    print("'surveyor home' takes me back there. If you put me next to the base computer")
    print("yourself, run 'surveyor survey here' to start a new survey from this spot.")
    return
  end
  S, MAP = nil, nil
  if fs.exists("surveyor.log") then fs.delete("surveyor.log") end
end

-- A compass in the inventory: fit it (a plain turtle has both upgrade slots
-- free), so the turtle knows which way it faces.
local function fitCompass()
  if nav.compass() then return true end
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == "minecraft:compass" then
      turtle.select(i)
      local ok = turtle.equipLeft() or turtle.equipRight()
      turtle.select(1)
      return ok and nav.compass() ~= nil
    end
  end
  return false
end

fitCompass()
-- Where it rests after a survey: where it started, unless that is the build
-- spot (the disk drive right under it: the factory built it there). Then the
-- nearest known spot next to a modem, off the build spot and the column above
-- it (new turtles fly up from there), so the next build isn't blocked.
local function restPlace()
  if S.rest then return S.rest end
  if MAP[key(0, -1, 0)] ~= "computercraft:disk_drive" then return { x = 0, y = 0, z = 0 } end
  local dist = stepsHome()
  -- next to a modem (it can check in from there) if it can, else anywhere
  -- off the build spot and its column
  local best, bestD, bestM
  for k, name in pairs(MAP) do
    local x, y, z = unkey(k)
    if name == false and dist[k] and not (x == 0 and z == 0 and y >= 0) then
      local m = nextToModem(k)
      if best == nil or (m and not bestM) or (m == bestM and (dist[k] < bestD or (dist[k] == bestD and k < best))) then
        best, bestD, bestM = k, dist[k], m
      end
    end
  end
  if not best then return { x = 0, y = 0, z = 0 } end
  if not bestM then log("No modem near the build spot to park by: parking off the build spot") end
  local x, y, z = unkey(best)
  S.rest = { x = x, y = y, z = z }
  save()
  return S.rest
end

-- Started by the agent (a built surveyor): after the survey it checks in from
-- where it rests every 5 minutes, so it keeps counting in the fleet (and can
-- get code updates, or be taken apart). A survey run by hand just ends.
local function restLoop()
  if args[1] ~= "resume" then return end
  while true do
    link.talk("resting", {}, true)
    sleep(300)
  end
end

-- Back to where it rests. Marks the survey done there; otherwise it stays
-- "stranded" and tries again on the next start.
local function returnHome()
  local r = restPlace()
  local ok, why = goTo(r.x, r.y, r.z)
  if not ok then
    S.stranded = true
    save()
    log(("Could not get back to where I started (I'm at %d,%d,%d from it): %s.")
      :format(S.pos.x, S.pos.y, S.pos.z, tostring(why)))
    log("Fix that (fuel, something in the way) and reboot me, or carry me back and run 'surveyor survey here'.")
    return false
  end
  S.stranded = nil
  S.done = true
  save()
  return true
end

if S then
  tmove.recover(S, save, applyMove)
  S.heading = nav.compass() or S.heading
  MAP = MAP or {}
  if S.stranded or (args[1] == "home" and away) then
    log("Going back to where the survey started...")
    refuel(1000)
    if returnHome() then log("Back where I started.") end
    return
  end
  if S.done then
    log("Survey done. Run 'surveyor survey' next to the base computer to survey again.")
    restLoop()
    return
  end
else
  local h = nav.compass() or nav.index(args[1] or "")
  if not h then
    print("I don't know which way I face. Put a compass in my inventory (4 iron + 1 redstone)")
    print("and reboot, or tell me: surveyor north|east|south|west (F3: Facing)")
    return
  end
  S = { pos = { x = 0, y = 0, z = 0 }, heading = h, steps = 0 }
  MAP = {}
  save()
end
MAP = MAP or {}

refuel(1000)
if fuel() < CFG.minFuel then
  print(("I have %d fuel and nothing to burn. Put coal or charcoal in me and reboot."):format(fuel()))
  return -- not done: it carries on from here after the reboot
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
local reported = false
local moves = pathTo(nextToModem, blocked)
if moves and follow(moves) then
  reported = link.talk("surveyed", { homes = S.homes, drives = drives }, false) ~= nil
end
if not reported then log("Could not report the survey to the base (no modem reached)") end
if returnHome() then
  log("Survey done.")
  restLoop()
end
