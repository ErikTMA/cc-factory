-- oremap: what the miners have seen underground, at the base, in the base's
-- home frame (the frame of F.homes). Pure: no peripherals, no files. Every
-- block but filler (stone, dirt...) and liquids: ores, and amethyst, chests,
-- spawners...
--
-- Miners report every scan they take (where, and every block in it worth
-- keeping) and every block they dig. A scan is the truth for what it covers:
-- blocks it lists are added, known ones inside it that it no longer lists are
-- gone (someone dug them). A job is handed the known ores of its kind nearest
-- the miner's home; those are held for that job until it ends, so two jobs
-- don't race for them.
--
-- In memory the map is kept per 16x16x16 cell, so a scan or a search only
-- touches the cells around it, however big the map grows:
--   map = { cells = { ["cx,cy,cz"] = { ["x,y,z"] = name } }, n = blocks,
--           isOre = { [name] = kind or true }, scans = { ["x,y,z"] = radius },
--           held = { ["x,y,z"] = jobId } }

local M = {}

local CELL = 16

local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function unkey(k)
  local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
  return tonumber(x), tonumber(y), tonumber(z)
end
local function cellOf(v) return math.floor(v / CELL) end
local function cellKey(x, y, z) return key(cellOf(x), cellOf(y), cellOf(z)) end
M.key, M.unkey = key, unkey

function M.new() return { cells = {}, n = 0, isOre = {}, scans = {}, held = {} } end

function M.get(map, x, y, z)
  local c = map.cells[cellKey(x, y, z)]
  return c and c[key(x, y, z)]
end

function M.put(map, x, y, z, name)
  local ck = cellKey(x, y, z)
  local c = map.cells[ck]
  if not c then c = {}; map.cells[ck] = c end
  local k = key(x, y, z)
  if c[k] == nil then map.n = map.n + 1 end
  if c[k] ~= name then map.rev = (map.rev or 0) + 1 end -- (what changed: for views of the map)
  c[k] = name
end

function M.del(map, x, y, z)
  local ck = cellKey(x, y, z)
  local c = map.cells[ck]
  local k = key(x, y, z)
  if c and c[k] ~= nil then
    c[k] = nil
    map.n = map.n - 1
    map.rev = (map.rev or 0) + 1
    if next(c) == nil then map.cells[ck] = nil end
  end
  map.held[k] = nil
end

-- Every block within r (a cube) of x,y,z: fn(bx, by, bz, name). Touches only
-- the cells around it.
function M.around(map, x, y, z, r, fn)
  for cx = cellOf(x - r), cellOf(x + r) do
    for cy = cellOf(y - r), cellOf(y + r) do
      for cz = cellOf(z - r), cellOf(z + r) do
        local c = map.cells[key(cx, cy, cz)]
        if c then
          for k, name in pairs(c) do
            local bx, by, bz = unkey(k)
            if math.abs(bx - x) <= r and math.abs(by - y) <= r and math.abs(bz - z) <= r then fn(bx, by, bz, name) end
          end
        end
      end
    end
  end
end

-- Every block: fn(x, y, z, name).
function M.each(map, fn)
  for _, c in pairs(map.cells) do
    for k, name in pairs(c) do
      local x, y, z = unkey(k)
      fn(x, y, z, name)
    end
  end
end

-- What a scan covers: the cube of `r` around its center (AP 0.8.2a
-- ScanUtil.traverseBlocks: BlockPos.betweenClosed(-r..r) on each axis, every
-- block but air listed; checked in the jar). A known block in there that the
-- scan doesn't list is gone.
-- A scan at `c` (radius `r`) listing `blocks` = { { x, y, z, name, ore, kind }, ... }.
function M.scan(map, c, r, blocks)
  local listed = {}
  for _, b in ipairs(blocks) do listed[key(b.x, b.y, b.z)] = true end
  for cx = cellOf(c.x - r), cellOf(c.x + r) do
    for cy = cellOf(c.y - r), cellOf(c.y + r) do
      for cz = cellOf(c.z - r), cellOf(c.z + r) do
        local cell = map.cells[key(cx, cy, cz)]
        if cell then
          local gone = {}
          for k in pairs(cell) do
            local x, y, z = unkey(k)
            if not listed[k] and math.abs(x - c.x) <= r and math.abs(y - c.y) <= r and math.abs(z - c.z) <= r then
              gone[#gone + 1] = { x, y, z }
            end
          end
          for _, g in ipairs(gone) do M.del(map, g[1], g[2], g[3]) end
        end
      end
    end
  end
  for _, b in ipairs(blocks) do
    M.put(map, b.x, b.y, b.z, b.name)
    if b.ore then map.isOre[b.name] = b.kind or map.isOre[b.name] or true end
  end
  map.scans[key(c.x, c.y, c.z)] = r
end

-- Blocks dug: { { x, y, z }, ... }.
function M.mined(map, list)
  for _, p in ipairs(list) do M.del(map, p.x, p.y, p.z) end
end

-- Does block `name` match a job's `only` (nil: every ore)? By name, or by
-- the ore kind its tag gave (c:ores/<kind>).
function M.matches(map, name, only)
  local ore = map.isOre[name]
  if not ore then return false end
  return only == nil or name:find(only, 1, true) ~= nil or ore == only
end

-- Up to `max` known ores matching `only`, nearest `from` first, not held by
-- another job, at most `below.y` high (never above the miner's home: its
-- way there goes down its shaft), within 256 blocks across and 128 down:
-- { { x, y, z, name }, ... }.
local FIND_ACROSS, FIND_DOWN = 16, 8 -- in cells
function M.find(map, from, only, max, below)
  local top = below and below.y or math.huge
  local list = {}
  local fx, fy, fz = cellOf(from.x), cellOf(from.y), cellOf(from.z)
  for cx = fx - FIND_ACROSS, fx + FIND_ACROSS do
    for cz = fz - FIND_ACROSS, fz + FIND_ACROSS do
      for cy = fy - FIND_DOWN, fy + 1 do
        local cell = map.cells[key(cx, cy, cz)]
        if cell then
          for k, name in pairs(cell) do
            if not map.held[k] and M.matches(map, name, only) then
              local x, y, z = unkey(k)
              if y <= top then
                list[#list + 1] = { x = x, y = y, z = z, name = name, k = k,
                                    d = math.abs(x - from.x) + math.abs(y - from.y) + math.abs(z - from.z) }
              end
            end
          end
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.k < b.k
  end)
  local out = {}
  for i = 1, math.min(max, #list) do
    local o = list[i]
    out[i] = { x = o.x, y = o.y, z = o.z, name = o.name }
  end
  return out
end

function M.hold(map, list, jobId)
  for _, p in ipairs(list) do map.held[key(p.x, p.y, p.z)] = jobId end
end

function M.release(map, jobId)
  for k, id in pairs(map.held) do if id == jobId then map.held[k] = nil end end
end

-- The job ids that hold something.
function M.holders(map)
  local ids = {}
  for _, id in pairs(map.held) do ids[id] = true end
  return ids
end

-- How many known blocks of each kind: { [name] = n }.
function M.counts(map)
  local n = {}
  M.each(map, function(_, _, _, name) n[name] = (n[name] or 0) + 1 end)
  return n
end

-- ------------------------------------------------------------------ disk --
-- On disk the map is packed: every block name once, and per cell a string
-- of "x y z i" (offsets in the cell, name index): ~10 bytes a block instead
-- of ~45. (A base may have 1 MB in all, code included.)
function M.pack(map)
  local names, index, cells = {}, {}, {}
  for ck, c in pairs(map.cells) do
    local cx, cy, cz = unkey(ck)
    local list = {}
    for k, name in pairs(c) do
      local x, y, z = unkey(k)
      if not index[name] then names[#names + 1] = name; index[name] = #names end
      list[#list + 1] = (x - cx * CELL) .. " " .. (y - cy * CELL) .. " " .. (z - cz * CELL) .. " " .. index[name]
    end
    table.sort(list)
    cells[ck] = table.concat(list, ",")
  end
  local ore = {}
  for i, name in ipairs(names) do
    local o = map.isOre[name]
    if o then ore[#ore + 1] = o == true and tostring(i) or (i .. "=" .. o) end
  end
  local scans = {}
  for k, r in pairs(map.scans) do scans[#scans + 1] = k .. "," .. r end
  table.sort(scans)
  return { v = 3, names = names, ore = ore, cells = cells, scans = table.concat(scans, ";"), held = map.held }
end

-- A map read back from disk (packed, or nothing).
function M.load(t)
  local map = M.new()
  if type(t) ~= "table" or not t.cells then return map end
  for _, o in ipairs(t.ore or {}) do
    local i, kind = tostring(o):match("^(%d+)=?(.*)$")
    local name = t.names[tonumber(i)]
    if name then map.isOre[name] = (kind ~= "" and kind) or true end
  end
  for ck, s in pairs(t.cells) do
    local cx, cy, cz = unkey(ck)
    for x, y, z, i in s:gmatch("(%d+) (%d+) (%d+) (%d+)") do
      M.put(map, cx * CELL + tonumber(x), cy * CELL + tonumber(y), cz * CELL + tonumber(z), t.names[tonumber(i)])
    end
  end
  for x, y, z, r in (t.scans or ""):gmatch("(-?%d+),(-?%d+),(-?%d+),(%d+)") do
    map.scans[key(tonumber(x), tonumber(y), tonumber(z))] = tonumber(r)
  end
  map.held = t.held or {}
  return map
end

-- Make room: drop the blocks (and scans) farthest from `center` until at most
-- `keep` (at least 1) are left. Returns how many were dropped.
function M.prune(map, center, keep)
  keep = math.max(1, keep)
  if map.n <= keep then return 0 end
  local list = {}
  M.each(map, function(x, y, z)
    list[#list + 1] = { x = x, y = y, z = z,
                        d = math.abs(x - center.x) + math.abs(y - center.y) + math.abs(z - center.z) }
  end)
  table.sort(list, function(a, b) return a.d < b.d end)
  local maxD = list[keep].d
  for i = keep + 1, #list do M.del(map, list[i].x, list[i].y, list[i].z) end
  for k in pairs(map.scans) do
    local x, y, z = unkey(k)
    if math.abs(x - center.x) + math.abs(y - center.y) + math.abs(z - center.z) > maxD then map.scans[k] = nil end
  end
  return #list - keep
end

-- The map as it goes to disk, at most `budget` bytes: `ser` serializes a
-- table. Too big: the farthest from `center` are dropped until it fits.
-- Returns the text and how many blocks were dropped, or nil and why (no
-- room at all: better keep the old file than write nothing).
local MIN_BUDGET = 16 * 1024
function M.encode(map, budget, ser, center)
  if budget < MIN_BUDGET then return nil, "no room on this computer for the ore map" end
  local data = ser(M.pack(map))
  local dropped = 0
  for _ = 1, 8 do
    if #data <= budget then return data, dropped end
    dropped = dropped + M.prune(map, center or { x = 0, y = 0, z = 0 },
                                math.floor(map.n * budget / #data * 0.9))
    data = ser(M.pack(map))
  end
  if #data <= budget then return data, dropped end
  return nil, "the ore map doesn't fit, even pruned"
end

return M
