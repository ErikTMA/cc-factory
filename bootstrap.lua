-- bootstrap: install or update cc-factory on the base computer from GitHub.
--
-- On the base computer (first time; later the base's UPDATE button runs it):
--   wget run https://raw.githubusercontent.com/ErikTMA/cc-factory/main/bootstrap.lua
-- It downloads the base files into / and the turtle files into /dist (the base
-- hands those to turtles over rednet), and makes the base start on boot.
--
-- On a turtle you set up by hand (built ones install from the disk):
--   wget run https://raw.githubusercontent.com/ErikTMA/cc-factory/main/bootstrap.lua miner
-- (or forester / assembler / surveyor: with a compass in its inventory it
-- starts surveying by itself). It installs the turtle files, sets the role and
-- reboots; the turtle pins itself to the first base that answers it.

local REPO = "ErikTMA/cc-factory"
local BRANCH = "main"

local function get(url)
  local res, err = http.get(url, { ["User-Agent"] = "cc-factory" })
  if not res then error("download failed: " .. url .. " (" .. tostring(err) .. ")", 0) end
  local body = res.readAll()
  res.close()
  return body
end

-- Pin every file to one commit so a push in the middle of the download can't
-- mix two versions (raw.githubusercontent.com also caches "main" for minutes).
local function latestCommit()
  local ok, body = pcall(get, ("https://api.github.com/repos/%s/commits/%s"):format(REPO, BRANCH))
  if ok then
    local sha = body:match('"sha"%s*:%s*"(%x+)"')
    if sha then return sha end
  end
  return BRANCH -- API unavailable (rate limit): fall back to the branch
end

local function write(path, content)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  f.write(content)
  f.close()
end

local args = { ... }
local role = args[1]
if turtle and not role then error("On a turtle, give its role: bootstrap miner|forester|assembler", 0) end

local ref = latestCommit()
local function raw(name) return get(("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO, ref, name)) end

print("cc-factory: fetching " .. ref:sub(1, 12))
local manifest = load(raw("manifest.lua"), "manifest", "t", {})()

if role then
  local files = {}
  for _, name in ipairs(manifest.turtle) do files["/" .. name] = raw(name) end
  for path, content in pairs(files) do write(path, content) end
  local cfg = {}
  if fs.exists("/agent.cfg") then
    local h = fs.open("/agent.cfg", "r")
    cfg = textutils.unserialize(h.readAll()) or {}
    h.close()
  end
  cfg.role = role
  write("/agent.cfg", textutils.serialize(cfg))
  print(("cc-factory %s installed as %s. Rebooting."):format(ref:sub(1, 12), role))
  os.reboot()
end

-- download everything first, write after: a failed download changes nothing
local files = {}
for _, name in ipairs(manifest.base) do files["/" .. name] = raw(name) end
for _, name in ipairs(manifest.turtle) do files["/dist/" .. name] = raw(name) end
files["/dist/" .. manifest.installer] = raw(manifest.installer)

if fs.exists("/dist") then fs.delete("/dist") end
for path, content in pairs(files) do write(path, content) end
write("/startup.lua", 'shell.run("base")\n')
write("/release", ref)

print(("cc-factory %s installed: %d files. Starting the base."):format(ref:sub(1, 12), #manifest.base + #manifest.turtle + 1))
