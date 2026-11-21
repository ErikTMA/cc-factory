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

-- On startup: settle a move that was in flight when the turtle stopped.
-- Returns true if the move had happened and was applied now.
function M.recover(st, save, apply)
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
