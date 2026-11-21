-- dist: the turtle code release the base hands out.
--
-- bootstrap.lua downloads the turtle files into /dist. The base loads them,
-- versions them by content (a hash, so any change is a new version), sends
-- them to turtles that report an older version, and keeps the installer disk
-- in sync so newly built turtles start on the same version.

local M = {}

local function read(path)
  local f = fs.open(path, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end

local function write(path, content)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  f.write(content)
  f.close()
end

-- djb2 over the file names and contents, as 8 hex digits
local function hash(s, h)
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return h
end

-- Load the release from `dir` using the manifest's turtle file list.
-- Returns nil if /dist is missing (base installed by hand, no bootstrap yet).
function M.load(manifest, dir)
  local files, h = {}, 5381
  for _, name in ipairs(manifest.turtle) do
    local content = read(fs.combine(dir, name))
    if not content then return nil end
    files[name] = content
    h = hash(name .. "\0" .. content, h)
  end
  return { files = files, version = ("%08x"):format(h),
           installer = read(fs.combine(dir, manifest.installer)) }
end

-- Write the installer onto every disk in a drive the base can see: the disk's
-- startup.lua, the turtle files in dist/, and install.cfg for the next turtle.
-- `api` is CC's peripheral API (injected for the harness).
function M.writeDisk(api, release, install)
  local written = 0
  for _, n in ipairs(api.getNames()) do
    if api.hasType(n, "drive") and api.call(n, "hasData") then
      local mount = api.call(n, "getMountPath")
      write(fs.combine(mount, "startup.lua"), release.installer)
      for name, content in pairs(release.files) do write(fs.combine(mount, "dist/" .. name), content) end
      local cfg = {}
      for k, v in pairs(install) do cfg[k] = v end
      cfg.version = release.version
      write(fs.combine(mount, "install.cfg"), textutils.serialize(cfg))
      written = written + 1
    end
  end
  return written
end

return M
