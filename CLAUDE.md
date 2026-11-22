# cc-factory — guide for agents

ComputerCraft (CC: Tweaked 1.120.2) Lua for the GamePortal ATM10 server
(Minecraft 1.21.1, Advanced Peripherals 0.8.2a). A base computer dispatches
turtles that mine, farm trees and build more turtles. Public repo; the base
downloads it with `bootstrap.lua`.

## Mental model

1. **Turtles talk first, only at home.** The base never pushes; every turtle
   status (link.talk) gets one reply: a job, a build step, a stop, a home slot,
   a code update or "ok". So a turtle with no modem in reach is never missed.
2. **The base decides, files on disk are truth.** `factory.lua` holds every
   decision and has no peripheral access: storage, clock, code release and the
   installer disk are injected (`deps`). Turtles persist their own state after
   every move (`tmove` journal) and resume from it after any restart.
3. **Verify CC/AP behaviour against the jars, not docs.** PLAN.md lists what was
   checked in the real 1.120.2 / AP 0.8.2a jars (geo scanner type is
   `geo_scanner`, crafting needs everything outside the 3x3 empty, disk
   startup replaces the computer's own). Add to that list when you verify more.

## Layout

| Where | Files |
|---|---|
| Base | `base.lua` (screen + wiring), `factory.lua` (decisions), `production.lua` (furnaces + crafting planner), `recipes.lua` (recipe tree), `storage.lua` (chest/bridge backends), `dist.lua` (code release + installer disk) |
| Every turtle | `startup.lua` (agent: role -> program), `link.lua` (talk to base, modem selection, updates), `tmove.lua` (journaled moves), `nav.lua` (heading), `oreconf.lua` (shared constants, build recipes) |
| Roles | `oreminer.lua`, `forester.lua`, `assembler.lua`; `travel.lua` (new turtle -> home slot) |
| Install | `bootstrap.lua` (GitHub -> base, or `bootstrap <role>` on a turtle), `install.lua` (installer disk), `manifest.lua` (which files go where) |

Rules: role programs use `link` for all base traffic and `tmove` for every
move that changes position. Shared behaviour lives in one module (modem
choice in link, heading in nav, recipes in oreconf) — don't copy it into a
role.

## Recipes for changes

- **New turtle role:** program `<role>.lua`; add it to `manifest.turtle`; a
  branch in `startup.lua`; upgrades/loadout in `oreconf.ROLES` (the base then
  can build it); base-side handling in `factory.handle` if it reports anything.
- **New status or reply:** both sides — `link.talk` callers and
  `factory.handle` — plus the harness that exercises it.
- **New file:** add it to `manifest.lua`, or bootstrap and turtles never get it.
- **New CC/AP API use:** check it in the jar (decompile with javap in
  `eclipse-temurin:21-jdk`, or jar strings) and note it in PLAN.md.

## Recipes are tested against the game

`test/fixtures/recipes.json` holds the real recipe/tag JSON extracted from the
server's jars (vanilla, NeoForge, CC, AP, All The Ores); the factory harness
crafts with those, so a wrong grid in `recipes.lua` fails. To add a recipe:
extract it into the fixture (see PLAN.md), run `test/fixtures/to_lua.py`, then
add it to `recipes.lua`.

## Tests

`test/run.sh` (Docker, Lua 5.2 like CC's Cobalt; ~35 s, each suite capped at 60 s so a loop fails as STUCK). Three harnesses run the real
files unchanged: `sim.lua` (miner + dispatcher), `forester_sim.lua`,
`factory_sim.lua` (whole factory: base over fake barrels/chests, assembler
crafting the way CC does, disk boot, wired modems, updates). Every fix lands
with a scenario that fails without it; prove it by mutating the fix.

Mocks must be at least as strict as the game (e.g. dug items go to the selected
slot, crafting fails with items outside the grid). A green test against a
forgiving mock is the bug to fix first.

## Deploy

Push to `main`, then UPDATE on the base (or `bootstrap` on it). Turtles pick up
the new version at their next safe point at home. The server's world files are
reachable with kubectl (GamePortal kubeconfig) under
`/data/world/computercraft/computer/<id>/` and `.../disk/<id>/`.
