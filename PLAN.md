# Turtle factory — build plan (checkpoint)

Goal: the base computer runs a self-growing turtle factory. Stock targets send
miners/foresters; turtles unload into chests the base drains into storage; the
base builds new turtles through an assembler turtle; new turtles install
themselves from a disk, walk to a home slot and take jobs; code updates roll out
over rednet. Friends-only server: base-ID pinning, no signing.

## Verified facts (GamePortal ATM10 8.6: CC: Tweaked 1.120.2, AP 0.8.2a)

- `rom/startup.lua`: if an *attached* disk drive's disk has a startup file it
  runs **instead of** the computer's own startup (`shell.allow_disk_startup`).
  So the installer disk drive sits under the build spot, never next to the
  assembler.
- `ComputerPeripheral` (computers and turtles as peripherals): `turnOn`,
  `shutdown`, `reboot`, `getID`, `isOn`, `getLabel`.
- AP storage bridges (ME + RS, both enabled): `getItems`, `getItem`,
  `exportItem(filter, toName)`, `importItem(filter, fromName)`, `craftItem`,
  `isCraftable`. Argument order of import/export is from jar strings only:
  **verify-live** with `factory probe` before relying on the ME adapter.
- Peripheral types (jar strings, AP 0.8.2a): Geo Scanner is **`geo_scanner`**
  (docs and older AP say `geoScanner`), `compass`, `me_bridge`, `rs_bridge`.
- Turtle upgrades: geo scanner, compass (item
  `minecraft:compass`, `getFacing()`), crafting table (`workbench`).
- `TurtleInventoryCrafting.tryCrafting` (decompiled): the recipe is read from a
  3x3 window of the 4x4 inventory and **every slot outside the window must be
  empty**, or crafting fails. The result goes to the selected slot first.
- `computercraft:turtle_upgrade` is a generic special recipe (any registered
  upgrade, left and right of the turtle in one row), so one craft
  `[pickaxe, turtle, scanner]` fits both upgrades.

## Production facts (jars, 2026-11-21)

- All The Ores 3.2.0: `alltheores:{copper,iron,bronze,invar,platinum}_ore_hammer`
  (tag `alltheores:ore_hammers`), shaped ` as / sa / s  ` (a = storage block,
  s = stick). `hammer + #c:raw_materials/<m>` shapeless -> 2 `alltheores:<m>_dust`;
  OreHammer has durability and a crafting remainder. Dust smelts 1:1 to the
  ingot (iron/gold/copper -> minecraft ingots). ATM10 KubeJS keeps these.
- Observer needs nether quartz: a raw input the base cannot make.

## Assembly procedure (base stages, assembler crafts)

Supply trapped chest above the assembler; build spot in front of it with the
installer disk drive under the build spot. Per step the base empties the supply
chest into storage and pushes exactly that step's parts into supply slots
1..k, in ascending grid-cell order; the assembler selects each cell and
`suckUp(1)`s. Grid cells = slots 1,2,3,5,6,7,9,10,11.

1. computer: G G G / G R G / G P G, select cell 6, craft -> computer stays in 6
2. turtle: G G G / G [6] G / G chest G (cell 6 already holds the computer),
   select cell 2, craft -> turtle in 2
3. upgrades: [pickaxe] [2] [scanner or compass], craft -> finished turtle
4. place it on the build spot; base stages the loadout (saplings first for a
   forester, wireless modem, coal); assembler drops each into the new turtle;
   `turnOn` it. The disk installs it.

## Topology (by block type, no config needed)

Base computer: wireless modem (turtles) + wired modem network with
- **barrels** = storage (or an ME/RS bridge, if present, replaces them)
- **chests** = input: turtle home chests, drained into storage
- **trapped chest** = assembler supply (above the assembler)
- **disk drive** = installer disk, under the build spot (in front of the assembler)

## Distribution

Public repo github.com/ErikTMA/cc-factory. The base pulls the code over CC's
http API (enabled on the server; public hosts allowed, private ranges denied)
with one starter script, keeps it in `/dist`, and hands it to turtles over
rednet. Turtles never need http.

## Milestones

- [x] M0 miner + base dispatcher + forester + journaled moves (tested)
- [x] M1 `link.lua`: one shared base link (modem swap at home, pinned base id,
      status/reply); oreminer + forester use it; forester reports to the base
- [x] M2 agent + updates: `startup.lua` agent (role from `agent.cfg`), version
      in every status, base serves `/dist` (checksum version) in replies,
      turtle writes files + reboots; installer `disk/startup.lua`
- [x] M3 `storage.lua` port: chest backend (barrels/chests/trapped chest over
      wired modems) + bridge backend; base drains inputs, shows stock
- [x] M4 stock rules + fleet targets in `factory.cfg`: base auto-queues jobs
      and build orders
- [x] M5 `assembler.lua`: crafts turtle + upgrades from supplied parts, places
      it on the build spot, gives it a modem and fuel, turns it on; new turtle
      asks the base for a home slot and walks there (no digging at the base)
- [x] M6 base UI tabs: Turtles / Stock / Jobs; harness coverage for all of it
- [x] M7 independent review pass (critic + security), fixes
- [ ] M8 deploy to the server and first live run (verify-live items below)
- [ ] M10 homes without typing coordinates. Home frame: where the surveyor
      started (next to the base computer) is (0,0,0), world axes (x east, y up,
      z south); the build spot is found by the survey (above the installer
      drive) and turtles get homes relative to it. No survey: frame = build spot.
  - [x] M10a base-managed home list (F.homes: pos, facing, role, source);
        FACTORY tab cycles each home's role miner/forester/off; factory.cfg
        homes imported; travel to homes at any height
  - [ ] M10b GPS: "gps" role = iron turtle + wireless modem, built by the
        factory, flies to a host point above the base and runs `gps host` in
        the build-spot frame; turtles use gps.locate when in range; `home
        <role>` on a turtle registers its spot
  - [x] M10c no GPS: surveyor = a plain advanced turtle (no upgrades; early
        game). Sees only front/up/down via inspect (turning for sides), so it
        follows cables/modems it can reach from open air; cables fully inside
        walls are missed (chat fallback). Heading from a compass if equipped,
        else `survey <facing>` (F3). Talks through a modem block on any of its
        6 sides (home spots have one). Drops a
        marker into each chest to learn its network name, proposes home slots
        (free cell next to a home chest with a modem in front or below)
  - [ ] M10d chat fallback: Chat Box + Player Detector at the base; `$build`
        on the build spot, `$home [role]` on a home spot (player position and
        facing); verify-live: Player Detector's return fields
- [x] M9 production: furnaces on the wired network run by the base (raw ore/dust
      -> ingots, logs -> charcoal, cobble -> stone, sand -> glass); a recipe
      planner crafts every part of a turtle through the assembler (craft jobs,
      several sets at once); ore-hammer doubling toggle (All The Ores hammers:
      raw ore + hammer -> 2 dust, hammer comes back damaged; assembler repeats).
      Recipes are tested against the real recipe JSONs extracted from the jars
      (test/fixtures/recipes.json), not against our own copy.

## Bugs the harnesses caught on the way (each test was red before its fix)

- Geo Scanner peripheral type is `geo_scanner` in AP 0.8.2a; `geoScanner`
  found nothing, every miner would have stopped at start.
- A server stop right after a move or turn left a turtle 1 (move) to 19 (turn)
  blocks off home; it then unloaded onto the ground. Fixed by tmove journaling
  plus re-measuring the heading on resume.
- Forester: dug items land in the selected slot, so logs filled slot 1/2 and
  were never delivered or burned; it ran dry.
- Miner: a job less than 12 blocks below home surfaced wherever it was, walked
  the surface into its own chest and unloaded 2 blocks off home. Every trip
  that touches the home level now uses the shaft, and unload refuses to drop
  anything without a chest in front.
- Idle miners would have polled the base every tick.

## Independent review (2026-11-21) — fixed

Base main loop rebuilt as receiver/worker/ticker/screen coroutines (peripheral
calls swallow other events); assembler repeats its last status until answered
and the base re-sends a lost build reply; builds time out; miners repeat
"done" until acknowledged and the base frees rule jobs nobody works on; base
restart rewrites the active build's install data; installer only installs on
a turtle directly on top of the drive; failed builds free their home slot and
pause auto-ordering after 3 in a row; only undamaged, unenchanted pickaxes are
staged; a turtle stranded on the build spot is picked up; miners wait at home
while the chest is full; sectors are bounded (job.maxLanes); at home a resuming
miner finds its heading from the chest, never digging; updates accept plain
`*.lua` names only; only vanilla chests are inputs; fleet ignores turtles
unseen for 2 h; refuel stops at 4000.

Each tested fix was proven by mutation (scenario fails without it).

## Still verify-live

- ME/RS bridge argument order (`base probe`).
- Rednet message size of a full code update (~55 KB in one message).
- Orientation of a turtle placed by the assembler (code measures it anyway).
- Base event loop under real tick costs (not simulated).

## M9 notes (2026-11-22)

Bugs the production harness caught: rules on raw ore never filled once
furnaces smelt it (rules now count dust and ingots too); a miner flew to a far
lane without fuel to return (fuel is checked for the round trip, short jobs
end early or are handed back as "no fuel"); a queued order waiting for parts
blocked every other build (head-of-line); missing-raw lists depended on table
order. Proven by mutation: hammer off -> 7 raw gold cannot build a turtle; one
wrong observer cell -> no Geo Scanner.

verify-live: furnace slot pushes with a bridge backend; real hammer durability.
