-- oremap: what the miners have seen underground, at the base, in the base's
-- home frame (the frame of F.homes). Pure: no peripherals, no files. Every
-- block but filler (stone, dirt...) and liquids: ores, and amethyst, chests,
-- spawners...
--
-- Miners report every scan they take (where, and every ore in it) and every
-- ore they dig. A scan is the truth for what it covers: ores it lists are
-- added, known ores inside it that it no longer lists are gone (someone dug
-- them). A job is handed the known ores of its kind nearest the miner's home;
-- those are held for that job until it ends, so two jobs don't race for them.
--
--   map = { ores = { ["x,y,z"] = name }, isOre = { [name] = true },
--           scans = { ["x,y,z"] = radius }, held = { ["x,y,z"] = jobId } }
-- (`ores` holds every block kept, ore or not; isOre says which names are ores.)

local M = {}

local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function unkey(k)
  local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
  return tonumber(x), tonumber(y), tonumber(z)
end
M.key, M.unkey = key, unkey

function M.new() return { ores = {}, isOre = {}, scans = {}, held = {} } end

-- ------------------------------------------------------------------ disk --
-- On disk the map is packed: every block name once, and per 16x16x16 cell a
-- string of "x y z i" (offsets in the cell, name index): ~8 bytes a block
-- instead of ~45. (A base may have 1 MB in all, code included.)
local CELL = 16
local function cellOf(v) return math.floor(v / CELL) end

function M.pack(map)
  local names, index, cells = {}, {}, {}
  for k, name in pairs(map.ores) do
    local x, y, z = unkey(k)
    if not index[name] then names[#names + 1] = name; index[name] = #names end
    local ck = key(cellOf(x), cellOf(y), cellOf(z))
    cells[ck] = cells[ck] or {}
    local c = cells[ck]
    c[#c + 1] = (x - cellOf(x) * CELL) .. " " .. (y - cellOf(y) * CELL) .. " " .. (z - cellOf(z) * CELL) .. " " .. index[name]
  end
  local packed, ore = {}, {}
  for ck, list in pairs(cells) do table.sort(list); packed[ck] = table.concat(list, ",") end
  for i, name in ipairs(names) do if map.isOre[name] then ore[#ore + 1] = i end end
  local scans = {}
  for k, r in pairs(map.scans) do scans[#scans + 1] = k .. "," .. r end
  table.sort(scans)
  return { v = 2, names = names, ore = ore, cells = packed, scans = table.concat(scans, ";"), held = map.held }
end

-- A map read back from disk (packed, an older plain one, or nothing).
function M.load(t)
  if type(t) ~= "table" then return M.new() end
  if t.v ~= 2 then
    t.ores, t.isOre, t.scans, t.held = t.ores or {}, t.isOre or {}, t.scans or {}, t.held or {}
    return t
  end
  local map = M.new()
  for _, i in ipairs(t.ore or {}) do map.isOre[t.names[i]] = true end
  for ck, s in pairs(t.cells or {}) do
    local cx, cy, cz = unkey(ck)
    for x, y, z, i in s:gmatch("(%d+) (%d+) (%d+) (%d+)") do
      map.ores[key(cx * CELL + tonumber(x), cy * CELL + tonumber(y), cz * CELL + tonumber(z))] = t.names[tonumber(i)]
    end
  end
  for x, y, z, r in (t.scans or ""):gmatch("(-?%d+),(-?%d+),(-?%d+),(%d+)") do
    map.scans[key(tonumber(x), tonumber(y), tonumber(z))] = tonumber(r)
  end
  map.held = t.held or {}
  return map
end

-- Make room: drop the blocks (and scans) farthest from `center` until at most
-- `keep` blocks are left. Returns how many were dropped.
function M.prune(map, center, keep)
  local list = {}
  for k in pairs(map.ores) do
    local x, y, z = unkey(k)
    list[#list + 1] = { k = k, d = math.abs(x - center.x) + math.abs(y - center.y) + math.abs(z - center.z) }
  end
  if #list <= keep then return 0 end
  table.sort(list, function(a, b) return a.d < b.d end)
  local maxD = list[keep] and list[keep].d or 0
  for i = keep + 1, #list do map.ores[list[i].k], map.held[list[i].k] = nil, nil end
  for k in pairs(map.scans) do
    local x, y, z = unkey(k)
    if math.abs(x - center.x) + math.abs(y - center.y) + math.abs(z - center.z) > maxD then map.scans[k] = nil end
  end
  return #list - keep
end

-- What a scan covers: the cube of `r` around its center (AP 0.8.2a
-- ScanUtil.traverseBlocks: BlockPos.betweenClosed(-r..r) on each axis, every
-- block but air listed; checked in the jar). A known ore in there that the
-- scan doesn't list is gone.
local function covered(c, r, x, y, z)
  return math.abs(x - c.x) <= r and math.abs(y - c.y) <= r and math.abs(z - c.z) <= r
end

-- A scan at `c` (radius `r`) listing `ores` = { { x, y, z, name }, ... }.
function M.scan(map, c, r, ores)
  for k in pairs(map.ores) do
    local x, y, z = unkey(k)
    if covered(c, r, x, y, z) then map.ores[k] = nil end
  end
  for _, o in ipairs(ores) do
    map.ores[key(o.x, o.y, o.z)] = o.name
    if o.ore then map.isOre[o.name] = true end
  end
  map.scans[key(c.x, c.y, c.z)] = r
end

-- Ores dug: { { x, y, z }, ... }.
function M.mined(map, list)
  for _, p in ipairs(list) do
    local k = key(p.x, p.y, p.z)
    map.ores[k], map.held[k] = nil, nil
  end
end

-- Does block `name` match a job's `only` (nil: every ore)?
function M.matches(map, name, only)
  if not map.isOre[name] then return false end
  return only == nil or name:find(only, 1, true) ~= nil
end

-- Up to `max` known ores matching `only`, nearest `from` first, not held by
-- another job: { { x, y, z, name }, ... }.
function M.find(map, from, only, max)
  local list = {}
  for k, name in pairs(map.ores) do
    if not map.held[k] and M.matches(map, name, only) then
      local x, y, z = unkey(k)
      list[#list + 1] = { x = x, y = y, z = z, name = name,
                          d = math.abs(x - from.x) + math.abs(y - from.y) + math.abs(z - from.z) }
    end
  end
  table.sort(list, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return key(a.x, a.y, a.z) < key(b.x, b.y, b.z)
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

-- The map as it goes to disk, at most `budget` bytes: `ser` serializes a
-- table. Too big: the farthest from `center` are dropped until it fits.
-- Returns the text and how many blocks were dropped.
function M.encode(map, budget, ser, center)
  local data = ser(M.pack(map))
  local dropped = 0
  for _ = 1, 8 do
    if #data <= budget then break end
    local n = 0
    for _ in pairs(map.ores) do n = n + 1 end
    dropped = dropped + M.prune(map, center or { x = 0, y = 0, z = 0 }, math.floor(n * budget / #data * 0.9))
    data = ser(M.pack(map))
  end
  return data, dropped
end

-- How many known blocks of each kind: { [name] = n }.
function M.counts(map)
  local n = {}
  for _, name in pairs(map.ores) do n[name] = (n[name] or 0) + 1 end
  return n
end

return M
