-- homes: the base's list of turtle home spots.
--
-- One frame for everything: the assembler's build spot is (0,0,0); x east,
-- y up, z south (world axes). A home is where a turtle stands, the way it
-- faces there (its chest is behind it) and what kind of turtle lives there:
--   { id, x, y, z, facing = "north"|..., role = "miner"|"forester"|"off",
--     source = "cfg"|"gps"|"survey"|"chat", chest = network name or nil,
--     owner = turtle id | "order:<n>" | nil }
-- Homes come from factory.cfg, `home <role>` on a turtle (GPS), the surveyor
-- and the chat; the monitor cycles their role.

local H = {}

H.ROLES = { "off", "miner", "forester" }

local function samePos(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end

function H.get(F, id)
  for _, h in ipairs(F.homes) do if h.id == id then return h end end
end

-- Add a home, or update the one already at that position (keeping its role
-- unless a role is given and the home is free). Returns the home.
function H.add(F, home)
  for _, h in ipairs(F.homes) do
    if samePos(h, home) then
      h.facing = home.facing or h.facing
      h.chest = home.chest or h.chest
      h.source = home.source or h.source
      if home.role and not h.owner then h.role = home.role end
      return h
    end
  end
  local h = { id = F.nextHomeId or 1, x = home.x, y = home.y or 0, z = home.z,
              facing = home.facing or "north", role = home.role or "off",
              source = home.source or "?", chest = home.chest }
  F.nextHomeId = h.id + 1
  F.homes[#F.homes + 1] = h
  return h
end

-- factory.cfg's homes: { miner = { { east = 4, north = 0, facing = "north" } } },
-- offsets from the build spot (`at` = where the build spot is in the home frame)
function H.import(F, cfgHomes, at)
  at = at or { x = 0, y = 0, z = 0 }
  for role, list in pairs(cfgHomes or {}) do
    for _, slot in ipairs(list) do
      H.add(F, { x = at.x + (slot.east or slot.x or 0), y = at.y + (slot.up or slot.y or 0),
                 z = at.z + (slot.z or -(slot.north or 0)), facing = slot.facing, role = role, source = "cfg" })
    end
  end
end

-- Next role for a free home (the monitor's tap); occupied homes keep theirs.
function H.cycle(F, id)
  local h = H.get(F, id)
  if not h then return nil, "no such home" end
  if h.owner then return nil, ("home %d is lived in (%s)"):format(id, tostring(h.owner)) end
  for i, r in ipairs(H.ROLES) do
    if r == h.role then h.role = H.ROLES[i % #H.ROLES + 1]; return h end
  end
  h.role = "off"
  return h
end

function H.remove(F, id)
  for i, h in ipairs(F.homes) do
    if h.id == id then
      if h.owner then return nil, "lived in" end
      table.remove(F.homes, i)
      return true
    end
  end
  return nil, "no such home"
end

-- The turtle living at the home whose chest is `chest` (network name), or nil.
function H.ownerOfChest(F, chest)
  for _, h in ipairs(F.homes) do
    if h.chest == chest and type(h.owner) == "number" then return h.owner end
  end
end

-- First free home for `role`, claimed for `owner`; nil if none.
function H.claim(F, role, owner)
  for _, h in ipairs(F.homes) do
    if h.role == role and (h.owner == nil or h.owner == owner) then
      h.owner = owner
      return h
    end
  end
end

function H.release(F, owner)
  for _, h in ipairs(F.homes) do if h.owner == owner then h.owner = nil end end
end

-- A built turtle reported in: its order's home now belongs to it.
function H.handOver(F, fromOwner, toOwner)
  for _, h in ipairs(F.homes) do if h.owner == fromOwner then h.owner = toOwner end end
end

-- What a turtle gets to fly home: position (build-spot frame) and facing.
function H.slot(h) return { x = h.x, y = h.y, z = h.z, facing = h.facing } end

function H.count(F, role)
  local n = 0
  for _, h in ipairs(F.homes) do if h.role == role then n = n + 1 end end
  return n
end

return H
