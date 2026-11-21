-- Turtle startup: after a reboot, server restart or chunk reload, pick up
-- where it left off.
if fs.exists("forester.state") then
  shell.run("forester")                -- tree farm turtle
elseif fs.exists("oreminer.home") then
  shell.run("oreminer", "serve")       -- mining turtle controlled by the base
elseif fs.exists("oreminer.state") then
  shell.run("oreminer", "resume")      -- mining job started by hand
end
