-- tmove: journaled turtle moves, shared by oreminer.lua and forester.lua.
--
-- A server restart or chunk unload can stop a turtle after a move happened but
-- before its new position was saved; from then on it would be one block off
-- for good. So every move is written ahead to the state: the fuel level before
-- the move and what the move does. Each move costs exactly one fuel, so after a
-- restart the fuel level says whether the pending move happened.

local M = {}

-- Run move() (e.g. turtle.forward); if it succeeds, apply(st, kind) updates
-- the position. save() persists st.
function M.move(st, save, kind, move, apply)
  st.pending = { kind = kind, fuel = turtle.getFuelLevel() }
  save()
  local ok = move()
  if ok then apply(st, kind) end
  st.pending = nil
  save()
  return ok
end

-- Step back one block; a mob behind must not leave it a block off.
function M.stepBack()
  for _ = 1, 20 do
    if turtle.back() then return true end
    turtle.turnRight(); turtle.turnRight()
    turtle.attack()
    turtle.turnRight(); turtle.turnRight()
    sleep(0.5)
  end
  return false
end

-- The heading probe (nav.scanHeading) steps forward, scans (up to 2 s) and
-- steps back: unjournaled, a stop in between leaves it a block ahead of its
-- saved position. So the probe is journaled too: the fuel level before the
-- step forward (st.probe). One fuel used since then: it stepped forward and
-- not back. Turns don't change between the two steps, so stepping back puts
-- it where its state says.
function M.probeStart(st, save)
  if not st then return end
  st.probe = { fuel = turtle.getFuelLevel() }
  save()
end
function M.probeDone(st, save)
  if not (st and st.probe) then return end
  st.probe = nil
  save()
end
local function recoverProbe(st, save)
  local p = st.probe
  if not p then return end
  local fuel = turtle.getFuelLevel()
  if fuel ~= "unlimited" and p.fuel ~= "unlimited" and fuel == p.fuel - 1 then
    if not M.stepBack() then
      error("Stopped while measuring my heading: one block ahead of my saved position and can't step back", 0)
    end
  end
  st.probe = nil
  save()
end

-- On startup: settle a move that was in flight when the turtle stopped.
-- Returns true if the move had happened and was applied now.
function M.recover(st, save, apply)
  recoverProbe(st, save)
  local p = st.pending
  if not p then return false end
  st.pending = nil
  local moved = false
  local fuel = turtle.getFuelLevel()
  if fuel ~= "unlimited" and p.fuel ~= "unlimited" and fuel == p.fuel - 1 then
    apply(st, p.kind)
    moved = true
  end
  save()
  return moved
end

return M
