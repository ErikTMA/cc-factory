# Turtle factory — build plan (checkpoint)

Goal: the base computer runs a self-growing turtle factory. Stock targets send
miners/foresters; turtles unload into chests the base drains into storage; the
base builds new turtles through an assembler turtle; new turtles install
themselves from a disk, walk to a home slot and take jobs; code updates roll out
over rednet. Friends-only server: base-ID pinning, no signing.

## Verified facts (GamePortal ATM10 8.6: CC: Tweaked 1.120.2, AP 0.8.2a)

- Inventory methods (`InventoryMethods`: `size`, `list`, `getItemDetail`,
  `pushItems`, `pullItems`) are all `@LuaFunction(mainThread = true)`: each
  call is queued for the server tick and the caller yields until it ran. So
  calls one after another cost a tick each; calls from coroutines run side
  by side (`parallel.waitForAll`) share one. `pushItems`/`pullItems` take an
  optional target slot. CC has no event for an inventory's contents
  changing: storage.lua reads all barrels side by side once per decision and
  keeps a journal of its own moves within it.
- `list()` gives name, count and an `nbt` hash (different components:
  different hash; such stacks never merge). `getItemLimit(slot)` is the
  handler's `getSlotLimit`.
- Functional Storage 1.5.8: plain drawers `<wood>_<1|2|4>` (fluid drawers
  excluded) have 1/2/4 slots, plus one more with a void upgrade (always
  empty, deletes what goes in). A slot holding an item refuses others; an
  emptied slot forgets its item unless locked (locked + empty: count 0, CC
  doesn't list it, it refuses other items). Counts above 64 are real.
  `getSlotLimit` = stacks x the stored item's max stack (64 x stacks when
  empty). The storage controller and extensions show every connected
  drawer's slots again; compacting drawers show one amount in 2-3 slots.
  (How Titanium attaches the handler: not in the jars, unconfirmed.)
- Sophisticated Storage 1.6.18 / Core 1.5.35: barrels, chests, shulker boxes
  (tiers copper..netherite: 27/45/54/81/108/132 slots), limited barrels 1-4.
  `getSlotLimit` = 64 x stack-upgrade multipliers whatever the item; the real
  per-item limit is max stack x that / 64 (CC over-reports for pearls). A
  double chest's second half serves the first half's inventory (counted
  twice); the controller and storage_io show everything again.
  An insert IGNORES the slot asked for (Core 1.5.35
  InventoryHandlerSlotTracker.insertItemIntoHandler: only a simulated insert
  looks at the slot): it goes into stacks of the same item first
  (insertIntoSlotsThatMatchStack), then the lowest empty slot (emptySlots is
  a TreeSet). So nothing can be placed in a chosen slot: DEFRAG rebuilds an
  inventory (empty it, fill it in name order) instead of moving slots.
- CC's pushItems/pullItems (ForgeContainerTransfer.moveItem): simulated
  extract, then the REAL insert, then the real extract. A push from an
  inventory into itself can land back in the source stack: useless for
  merging inside one Sophisticated barrel.
- Environment Detector `scanEntities(radius, [detailed], [filter])` (AP
  0.8.2a EnvironmentDetectorPeripheral): with no filter it lists LIVING
  entities only (`isAlive() && instanceof LivingEntity`): never a dropped
  item. `"minecraft:item"` (an entity type id; `"#ns:tag"` a tag) lists
  dropped items. x/y/z are world-axis offsets from the turtle's centre
  (`getCenterPos`); forward/right/up come as extra fields.
- Shearing leaves: CC 1.120.2 has no shears upgrade (its upgrades: the
  diamond tools, crafting table, modems, speaker) and `turtle.dig()` breaks
  with the equipped tool only; using shears (`turtle.place()` with them
  selected) shears sheep, not leaves. AP 0.8.2a's Weak Automata Core
  (upgrade type `weak_automata`, peripheral type `weak_automata`):
  `digBlock({ sneak, yaw, pitch })` breaks the block as a fake player holding
  the turtle's SELECTED slot item (`TurtlePeripheralOwner.getToolInMainHand`
  -> `getInventory().getItem(getSelectedSlot())`); yaw/pitch are added to
  the turtle's facing (`doActionWithRot`), so pitch -90 is up, 90 down.
  Cost: 1 fuel, cooldown 1000 ms (`SingleOperation.DIG`). The core's recipe
  needs a long-regeneration potion: the base can't craft it. Vanilla shears:
  shaped, iron at (2,1) and (1,2) (server-1.21.1 extra jar, in the fixture).

- `rom/startup.lua`: if an *attached* disk drive's disk has a startup file it
  runs **instead of** the computer's own startup (`shell.allow_disk_startup`).
  So the installer disk drive sits under the build spot, never next to the
  assembler.
- `TurtleSuckCommand` (decompiled, 1.120.2): with an inventory in that
  direction it takes from it (first slot); otherwise it takes the
  `ItemEntity`s inside that block's box (x..x+1, y..y+1, z..z+1), "No items
  to take" if none. Items on the floor lie in the air cell above it: face
  that cell with `suck()`; `suckDown()` only reaches inside the floor block.
- Geo Scanner `scanBlocks(r)` (AP 0.8.2a, `GeoScannerPeripheral` +
  `ScanUtil.traverseBlocks`, decompiled): a CUBE, every block from -r to +r on
  each axis; air is skipped, every other block (stone too) is listed as
  `{ name, tags, x, y, z }` relative to the scanner. Server config
  (`Advancedperipherals/peripherals.toml`): free up to r 8, 9-16 costs fuel,
  2 s cooldown. The Geo Scanner has only `scanBlocks` and `chunkAnalyze`:
  no `scanEntities` (that setting belongs to another peripheral).
- Environment Detector (AP 0.8.2a, `EnvironmentDetectorPeripheral`, type
  `environment_detector`, item `advancedperipherals:environment_detector`,
  also a turtle upgrade): `scanEntities(r)` lists EVERY entity in the box of
  r (`ALL_ENTITY_TYPES`, alive, up to 4096), dropped items included, through
  the generic Entity converter: `name = "minecraft:item"`, x/y/z relative to
  the turtle, id, uuid (no item stack). Free up to r 8, 16 with cost, 2 s
  cooldown. A turtle can find every item lying around without walking over it.
- Iron Furnaces 4.3.2: its block entity is a `WorldlyContainer`; the item
  capability is `InvWrapper` (whole inventory) for a null side,
  `SidedInvWrapper` otherwise. CC (`CapabilityUtil.getCapability`) asks with
  a null side first: slots as vanilla, input 1, fuel 2, output 3, augments
  4-6, generator fuel 7.
- Turtle movement (`TurtleMoveCommand.canEnter` + `WorldUtil.isEmptyBlock`,
  CC 1.120.2): it may move into air **or any liquid** (water, lava), or a
  block that `canBeReplaced()`. Liquids never block a turtle: no need to dig
  or plan around them.
- Space limits (server `config/computercraft-server.toml`):
  `computer_space_limit = 1000000` (GamePortal: raised to 16000000 on
  2026-11-22, takes effect at the next server restart; other servers may keep
  1 MB, the ore map must fit either), `floppy_space_limit = 125000` bytes;
  writing past it fails with "Out of space". All turtle files (~130 KB) don't
  fit a floppy, so the installer disk carries only `manifest.boot` plus the
  built role's program; the rest arrives as a code update (version "boot").
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

## Tree facts (jars, 2026-11-21)

- Vanilla 1.21.1 configured features (trunk placer, foliage radius): oak /
  birch / small jungle / spruce straight 1x1, radius 2 (spruce 2-3); acacia
  forking trunk; cherry radius 4, branches 2-4 sideways; mangrove
  upwards-branching (+roots); dark oak 2x2. Leaves are replaceable by tree
  growth, so crowns may overlap; spacing follows how far LOGS reach.
- Integrated Dynamics 1.39.0 `tree_menril`: TrunkPlacerMenril returns no tree
  unless the ground under the sapling's N/E/S/W cells is grass/dirt
  (TreeFeature.isGrassOrDirt), and places a log on each side for the first
  `trunk_height_wider` (3) blocks (plus-shaped base).
- Spacing table: oreconf.TREES (3 / menril 4 / acacia, cherry, mangrove 5 /
  unknown 4); the grid starts one cell in from the pen's min-x/min-z corner.

## Fuel facts (jars, 2026-11-21)

- CC 1.120.2 `FurnaceRefuelHandler`: turtle fuel per item = burn ticks * 5 / 100
  (coal 1600 -> 80). Tiny coal/charcoal burn 200 ticks (neoforge furnace_fuels
  data map in Utilitarian 0.19.2 and Actually Additions 1.3.26) -> 10 fuel: 8
  tiny = 1 coal, no gain for turtles. In a furnace 200 ticks = exactly one
  smelt (blast furnace: two), so tiny fuel removes the burn-off waste there.
- Utilitarian `tiny_fuel/tiny_coal|tiny_charcoal`: shapeless 1 coal/charcoal ->
  8 (fixture). AA's recipes depend on its `tinyCoalStuff` config. Almost
  Unified (`unification/materials.json`) prefers utilitarian for
  `atm10:tiny_coals` / `atm10:tiny_charcoals`.
- Fuel on request: `pushItems` targets come from `InventoryMethods.extractHandler`:
  any peripheral whose `getTarget()` is a block entity with an item capability
  or a vanilla `Container`. `ComputerPeripheral.getTarget()` returns the
  computer/turtle block entity, and `TurtleBlockEntity implements
  BasicContainer`, so a turtle on the wired network (`turtle_N`, `getID()`)
  takes items pushed from a barrel.
- `WiredModemFullBlockEntity` (1.120.2): on a neighbour change it re-attaches
  peripherals only while it is ON (`isPeripheralOn`), then sets ON = "any
  peripheral attached". So a full modem whose only neighbour is a turtle turns
  OFF when the turtle leaves and stays off when it returns; one that also
  touches a chest/barrel stays on and re-attaches the returning turtle by
  itself. A home's turtle modem needs a second neighbour (the home chest, or
  a barrel) for fuel on request; talking (rednet) works either way.

## Assembly procedure (base stages, assembler crafts)

The assembler touches an enabled wired modem (it is `turtle_N` on the
network); build spot in front of it with the installer disk drive under the
build spot. Per step the base pulls back what the assembler holds (by slot,
from the slot list in its status; `pullItems` from a turtle works like
`pushItems` into one) except the kept cells, then pushes exactly that step's
parts in; the assembler sorts them into its grid. Hammer rounds: after each
craft the assembler reports "crafting", the base pulls the dust out (crafting
needs the non-grid slots empty) and says "continue". (Until 2026-11-21 a
trapped supply chest above the assembler did this.) Grid cells = slots
1,2,3,5,6,7,9,10,11.

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
- **assembler** = a turtle on the network (enabled modem): the base fills and empties it
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
- [x] M10 homes without typing coordinates. Home frame: where the surveyor
      started (next to the base computer) is (0,0,0), world axes (x east, y up,
      z south); the build spot is found by the survey (above the installer
      drive) and turtles get homes relative to it. No survey: frame = build spot.
  - [x] M10a base-managed home list (F.homes: pos, facing, role, source);
        FACTORY tab cycles each home's role miner/forester/off; factory.cfg
        homes imported; travel to homes at any height
  - [x] M10b GPS: "gps" role = iron turtle + wireless modem, built by the
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
  - [x] M10d chat fallback: Chat Box + Player Detector at the base; `$build`
        on the build spot, `$home [role]` on a home spot (player position and
        facing); Player Detector checked in AP 0.8.2a: Lua `getPlayer(name)` -> x, y, z, yaw, pitch, dimension (server: enablePlayerPosFunction and morePlayerInformation on, no random error); Chat Box event is `chat, uuid, username, message, hidden`
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
- Dismantle: a turtle with a diamond pickaxe digging another (switched off)
  turtle collects it as an item (turtles are in mineable/pickaxe, checked);
  `turtle.drop` into a turtle in front fills its inventory; `isOn`/`getID`
  on the turtle peripheral in front. The sim models all three.
- Surveys re-register homes that were defined another way (factory.cfg,
  $home) as new ones: homes aren't de-duplicated across frames yet.
- ME/RS bridge (AP 0.8.2a): item entries include `components` and `nbt`
  (LuaConverter). Check live what a fresh turtle's entry looks like and that
  `exportItem` with a filter takes that exact stack; then the AE2-style
  shortcut can work with a bridge too (today: barrels only).
- The AE2-style shortcut takes turtles/computers by displayName (CC en_us:
  "Advanced Turtle"; upgraded "Advanced %s Turtle"; a label replaces it) or
  the untranslated key. Check live that getItemDetail's displayName on the
  dedicated server is the translated name (if not, the key matches).
- `pushItems` from a remote barrel into a turtle next to the base computer
  with no modem (assumed NOT to work; fuel on request asks for a modem).

## M9 notes (2026-11-22)

Bugs the production harness caught: rules on raw ore never filled once
furnaces smelt it (rules now count dust and ingots too); a miner flew to a far
lane without fuel to return (fuel is checked for the round trip, short jobs
end early or are handed back as "no fuel"); a queued order waiting for parts
blocked every other build (head-of-line); missing-raw lists depended on table
order. Proven by mutation: hammer off -> 7 raw gold cannot build a turtle; one
wrong observer cell -> no Geo Scanner.

verify-live: furnace slot pushes with a bridge backend; real hammer durability.

## Mining grid and ore map (decided 2026-11-22, in progress)

- **One fixed grid for every miner**, in the base's frame (anchored at the
  build spot; levels fixed to world Y, clear of the bedrock layers). Scan
  points every 16 (2 x scan radius 8) in x, y and z, so the 17-cubes tile the
  ground once: a trunk along x at z = 0 and branches along z every 16 in x,
  on levels every 16 in Y. The base remembers which points are scanned and
  hands each job points of its own (reserved), plus the known ores of its
  kind; nothing is scanned twice, everything can be cleared.
- **Shafts at the homes, not one central shaft.** Each miner goes down at its
  own home and digs a connector at its level to the nearest grid point. (A
  single shaft is gridlock: turtles are solid and can't pass in a 1x1 tunnel.)
- **Several miners may share a home (and its shaft).** When two meet, the one
  going down (outbound) digs a pocket aside, waits there until the way is
  clear, then goes on; in tunnels and lanes the outbound one yields to the one coming
  back.
- **The ore map: shipped 2026-11-22** (4e085d2, two independent reviews,
  every finding fixed with a test that failed first): every scanned block
  but filler and liquids, in the base's frame, kept per 16-cell; scans drop
  what they no longer list (holds on what they still see stay); every
  non-filler block a miner digs leaves it; a known ore counts only if what
  was dug there was ore; jobs get known ores below home, held per job, freed
  when the job is gone; packed on disk, saved from the ticker, fitted to
  free space; a new build spot clears it.
- **Next:** the shared grid (base-side points and levels, reserved per job;
  the miner's route: home shaft, connector, grid lines), then yielding in
  shafts, trunk and lanes, with a sim where turtles meet.

