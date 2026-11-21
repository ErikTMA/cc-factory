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
- [ ] M2 agent + updates: `startup.lua` agent (role from `agent.cfg`), version
      in every status, base serves `/dist` (checksum version) in replies,
      turtle writes files + reboots; installer `disk/startup.lua`
- [ ] M3 `storage.lua` port: chest backend (barrels/chests/trapped chest over
      wired modems) + bridge backend; base drains inputs, shows stock
- [ ] M4 stock rules + fleet targets in `factory.cfg`: base auto-queues jobs
      and build orders
- [ ] M5 `assembler.lua`: crafts turtle + upgrades from supplied parts, places
      it on the build spot, gives it a modem and fuel, turns it on; new turtle
      asks the base for a home slot and walks there (no digging at the base)
- [ ] M6 base UI tabs: Turtles / Stock / Jobs; harness coverage for all of it
- [ ] M7 independent review pass (critic + security), fixes, deploy to server
