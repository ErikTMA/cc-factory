-- Boots base.lua for real (its main loop, not --lib) on a mocked computer:
-- CC-strict timers (sleep/startTimer refuse non-finite numbers, like CC's
-- bios), parallel.waitForAny, rednet over events, a wired modem network with a
-- barrel, no monitor and no Chat Box. It must start, answer a turtle and keep
-- running through several ticks.
-- Usage: lua base_sim.lua <repo dir>
local REPO = arg[1] or ".."

local failures = 0
local function check(cond, msg)
  if cond then print("  ok   " .. msg) else print("  FAIL " .. msg); failures = failures + 1 end
end
local function readFile(path) local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s end

local function ser(v)
  if type(v) == "table" then
    local p = {}
    for k, x in pairs(v) do p[#p + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
    return "{" .. table.concat(p, ",") .. "}"
  elseif type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

-- the computer's files: what bootstrap installs
local manifest = load(readFile(REPO .. "/manifest.lua"), "manifest", "t", {})()
local files = {}
for _, n in ipairs(manifest.base) do files[n] = readFile(REPO .. "/" .. n) end
for _, n in ipairs(manifest.turtle) do files["dist/" .. n] = readFile(REPO .. "/" .. n) end
files["dist/" .. manifest.installer] = readFile(REPO .. "/" .. manifest.installer)

local fs = {}
local function norm(p) return (p:gsub("^/+", "")) end
function fs.exists(p) p = norm(p); if files[p] then return true end
  for k in pairs(files) do if k:sub(1, #p + 1) == p .. "/" then return true end end; return false end
function fs.open(p, mode)
  p = norm(p)
  if mode == "r" then
    if not files[p] then return nil end
    local c = files[p]; return { readAll = function() return c end, close = function() end }
  end
  local buf = {}
  return { write = function(s) buf[#buf + 1] = s end, close = function() files[p] = table.concat(buf) end }
end
function fs.combine(a, b) a, b = norm(a), norm(b); if a == "" then return b end; return a .. "/" .. b end
function fs.getDir(p) return norm(p):match("^(.*)/[^/]*$") or "" end
function fs.makeDir() end
function fs.delete(p) files[norm(p)] = nil end

-- events and timers, CC style
local queue, clock, timers, nextTimer = {}, 0, {}, 1
local os2 = setmetatable({}, { __index = os })
function os2.queueEvent(...) queue[#queue + 1] = { ... } end
function os2.startTimer(t)
  if type(t) ~= "number" or t ~= t or t == math.huge or t == -math.huge then
    error("bad argument #1 (number expected, got " .. tostring(t) .. ")", 2)
  end
  local id = nextTimer; nextTimer = nextTimer + 1
  timers[id] = clock + t
  return id
end
function os2.pullEventRaw(filter) return coroutine.yield(filter) end
function os2.pullEvent(filter)
  local ev = { coroutine.yield(filter) }
  if ev[1] == "terminate" then error("Terminated", 0) end
  return table.unpack(ev)
end
function os2.epoch() return clock * 1000 end
function os2.clock() return clock end
function os2.getComputerID() return 0 end
function os2.getComputerLabel() return "miningbase" end
function os2.reboot() error("REBOOT", 0) end
local function sleep(t)
  local id = os2.startTimer(t)
  repeat local _, tid = os2.pullEvent("timer") until tid == id
end

-- peripherals: a wired modem with a barrel on its network; no monitor, no chat box
local barrel = { slots = { [1] = { name = "minecraft:cobblestone", count = 10 } } }
local sent = {}
local periph = {}
function periph.getNames() return { "back", "minecraft:barrel_0" } end
function periph.getType(n) if n == "back" then return "modem" end; if n == "minecraft:barrel_0" then return "inventory" end end
function periph.hasType(n, t) return periph.getType(n) == t end
function periph.call(n, m, ...)
  if n == "minecraft:barrel_0" then
    if m == "list" then return barrel.slots end
    if m == "getItemDetail" then return barrel.slots[...] end
    if m == "pushItems" then return 0 end
  end
end
function periph.find(t) return nil end
function periph.getName() return "back" end
function periph.wrap() return nil end

local rednet = {}
function rednet.open() end
function rednet.send(to, msg, proto) sent[#sent + 1] = { to = to, msg = msg } end
function rednet.receive(proto)
  while true do
    local _, from, msg, p = os2.pullEvent("rednet_message")
    if not proto or p == proto then return from, msg, p end
  end
end

local term = { getSize = function() return 51, 19 end, clear = function() end, setCursorPos = function() end,
               setTextColor = function() end, setBackgroundColor = function() end, write = function() end }

local parallel = {}
function parallel.waitForAny(...)
  local cos, filters = {}, {}
  for i, f in ipairs({ ... }) do cos[i] = coroutine.create(f) end
  local ev = {}
  while true do
    for i, co in ipairs(cos) do
      if coroutine.status(co) ~= "dead" and (filters[i] == nil or filters[i] == ev[1] or ev[1] == "terminate") then
        local res = { coroutine.resume(co, table.unpack(ev)) }
        if not res[1] then error(res[2], 0) end
        if coroutine.status(co) == "dead" then return i end
        filters[i] = res[2]
      end
    end
    ev = { coroutine.yield() }
  end
end

local env = setmetatable({}, { __index = _G })
env.fs, env.os, env.sleep, env.peripheral, env.rednet, env.term = fs, os2, sleep, periph, rednet, term
env.parallel = parallel
env.textutils = { serialize = ser, unserialize = function(s) return load("return " .. s)() end }
env.colors = setmetatable({}, { __index = function(_, k) return k end })
env.print = function() end
env.shell = { run = function() return true end }
env.dofile = function(p) return assert(load(assert(files[norm(p)], p), p, "t", env))() end
env.require = function(name) return assert(load(assert(files[name .. ".lua"], name), name, "t", env))() end

-- GitHub's latest commit (the auto-updater asks it)
local githubSha = nil
env.http = { get = function()
  if not githubSha then return nil end
  return { readAll = function() return '{"sha": "' .. githubSha .. '"}' end, close = function() end }
end }

-- Boot base.lua and drive it: queued events first, else the next timer. A
-- turtle talks at step 50; `during(step)` may change the world. Returns the
-- error that ended it (nil = still running), steps and the sim clock.
local function boot(maxSteps, during)
  queue, timers, clock, sent = {}, {}, 0, {}
  local main = coroutine.create(function() return assert(load(files["base.lua"], "base", "t", env))() end)
  local ok, err = coroutine.resume(main)
  local steps, crashed = 0, nil
  if not ok then crashed = err end
  while not crashed and coroutine.status(main) ~= "dead" and steps < maxSteps do
    steps = steps + 1
    if during then during(steps) end
    local ev
    if steps == 50 then
      ev = { "rednet_message", 7, { type = "status", state = "idle", role = "miner", label = "miner-7", fuel = 500 }, "oreminer" }
    elseif #queue > 0 then
      ev = table.remove(queue, 1)
    else
      local id, at
      for tid, t in pairs(timers) do if not at or t < at then id, at = tid, t end end
      if not id then break end
      timers[id] = nil
      clock = math.max(clock, at)
      ev = { "timer", id }
    end
    ok, err = coroutine.resume(main, table.unpack(ev))
    if not ok then crashed = err end
  end
  return crashed, steps, coroutine.status(main)
end

print("scenario: base.lua boots and runs (no monitor, no chat box, wired modem only)")
files["release"] = "aaa"
githubSha = "aaa"
local crashed, steps, status = boot(3000)
check(not crashed, "no crash: " .. tostring(crashed))
check(steps >= 3000 or status ~= "dead", "still running after " .. steps .. " events")
check(clock >= 30, ("ran through %d s of ticks"):format(clock))
check(#sent >= 1 and sent[1].to == 7 and sent[1].msg.type == "ok", "answered the turtle")
check(files["base.state"] ~= nil, "saved its state")
check(files["factory.cfg"] ~= nil, "wrote factory.cfg with defaults on first start")

print("scenario: a Chat Box connected while it runs is picked up (no restart): $help gets an answer")
do
  local said = {}
  local chat = { sendMessageToPlayer = function(text, user) said[#said + 1] = { text, user } return true end,
                 sendMessage = function(text) said[#said + 1] = { text } return true end }
  local attached = false
  local oldFind = periph.find
  periph.find = function(t) if attached and t == "chat_box" then return chat end return oldFind(t) end
  files["release"] = "aaa"; githubSha = "aaa"
  boot(400, function(step)
    if step == 100 then attached = true; queue[#queue + 1] = { "peripheral", "chat_box_0" } end
    -- AP 0.8.2a's order: uuid, username, message, hidden, message
    if step == 120 then queue[#queue + 1] = { "chat", "6a1e-uuid", "Erik", "$help", true, "$help" } end
  end)
  periph.find = oldFind
  check(#said >= 1 and said[1][1]:find("%$build"), "answered $help after the Chat Box was connected: " .. tostring(said[1] and said[1][1]))
  check(said[1] and said[1][2] == "Erik", "to the player who asked: " .. tostring(said[1] and said[1][2]))
end

print("scenario: new files copied in while it runs: the updater restarts it (no download)")
files["release"] = "aaa"
githubSha = "bbb"
local downloads = 0
env.shell.run = function(p) if p:find("bootstrap") then downloads = downloads + 1 end; return true end
crashed = boot(20000, function(step) if step == 10 then files["release"] = "bbb" end end)
check(crashed == "REBOOT", "it rebooted into the new files: " .. tostring(crashed))
check(downloads == 0, "without downloading again")

print("scenario: a newer commit on GitHub, nothing on disk: it downloads and restarts")
files["release"] = "bbb"
githubSha = "ccc"
downloads = 0
crashed = boot(20000)
check(downloads == 1 and crashed == "REBOOT", ("downloaded %d time(s), then: %s"):format(downloads, tostring(crashed)))

print(failures == 0 and "ALL PASSED" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
