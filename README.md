# cc-factory — a self-growing ComputerCraft turtle factory (ATM10)

Work in progress: see [PLAN.md](PLAN.md). What works today is below.

## Ore miners

Mining turtles with an Advanced Peripherals Geo Scanner, dispatched from a
base computer with a touch monitor. Any number of turtles: queue jobs on the
monitor ("32 iron", "8 diamond", "all ores at Y -20"), and each turtle that is
home takes the next job, digs a shaft down to the job's Y level, mines only the
ore it was asked for (nearest first, so it follows veins), comes up to unload
into its own chest and reports back.

Verified against the GamePortal ATM10 8.6 server: CC: Tweaked 1.120.2, Advanced
Peripherals 0.8.2a, Geo Scanner config `scanBlocksMaxFreeRadius = 8`,
`scanBlocksCooldown = 2000` ms. No KubeJS overrides for these recipes.

## Items

Per turtle:

| Craft | Recipe |
|---|---|
| Advanced Computer | 7 gold ingot, 1 redstone dust, 1 glass pane |
| Advanced Turtle | 7 gold ingot, 1 Advanced Computer, 1 wooden chest |
| Diamond Pickaxe | 3 diamond, 2 stick |
| Wired Modem | 8 stone, 1 redstone dust |
| Wired Modem (full block) | 1 Wired Modem, crafted on its own |
| Peripheral Casing | 4 iron ingot, 4 iron bars, 1 block of redstone |
| Observer | 6 cobblestone, 2 redstone dust, 1 nether quartz |
| Geo Scanner | 4 diamond, 1 Wired Modem (full block), 1 Peripheral Casing, 2 block of redstone, 1 Observer |
| Wireless Modem (goes in its inventory) | 8 stone, 1 ender pearl |

Assemble: **Advanced Turtle + Diamond Pickaxe**, then **+ Geo Scanner**. Plus a
chest behind its home spot, and coal.

Base: 1 Advanced Computer, Advanced Monitors (8 gold + 1 glass pane makes 4;
4 wide × 3 high is comfortable), 1 Wireless Modem.

## Files

| File | Goes on |
|---|---|
| `oreconf.lua` | mining turtles **and** base (shared presets and protocol) |
| `tmove.lua` | every turtle (journaled moves, see below) |
| `oreminer.lua`, `startup.lua` | each mining turtle |
| `forester.lua`, `startup.lua` | each forester turtle |
| `base.lua` | base computer (`shell.run("base")` in its startup to auto-start) |

## Forester

A tree-farm turtle: an Advanced Turtle with a Diamond Pickaxe (it breaks wood
fine) and a **Compass** (craft the turtle with a plain compass; Advanced
Peripherals turns it into a compass upgrade). Saplings in **slot 1** (top
left) — only that kind is planted; bone meal in slot 2 is optional.

Place it with a chest behind it and a lane of air in front, with dirt/grass on
both sides of the lane every 3 blocks (`forester.lua` has a diagram). Run
`forester [spots per side] [seconds between rounds]` (default 6 and 300). Each
round it plants empty spots, fells grown trees (including sideways branches)
and replants, then empties wood into the chest, keeping 16 logs for fuel.

## Restarts

Every turtle move is journaled (`tmove.lua`): before moving it records its fuel
level, and since a move costs exactly one fuel, after a server restart it knows
whether the last move happened. Turns cost no fuel, so the facing is measured
again on resume — by the Geo Scanner on mining turtles, by the compass on
foresters. Without this a turtle stopped mid-move ends up one block off for
good and empties its inventory onto the ground instead of into the chest.

## Use

1. Place each turtle at the surface near the base (within wireless range,
   ideally in a row facing the same way) with a chest directly **behind** it,
   coal and a wireless modem in its inventory.
2. On each turtle, first time: `oreminer serve`. It asks its Y (F3), works out
   which way it faces, and from then on waits for jobs. `startup.lua` brings it
   back to that after restarts, resuming a half-done job first.
3. On the base: `base`. Tap an ore (sets its best Y; adjust with -8/-1/+1/+8),
   pick the quantity, "only <ore>" or "all ores", then **START**. Press START
   again to queue more jobs; each idle turtle takes the next one.
4. The monitor lists every turtle (state, job, mined, fuel, last seen) and a
   per-ore summary (mined in total, how many turtles on it, how many queued).
   Tap a turtle, then **STOP**, to call it home — it gets the message the next
   time it comes up to unload. With no turtle selected the button cancels the
   last queued job.

Turtles only talk to the base while at home (swapping the modem in for the
scanner), so the status updates when they come up to unload or finish.

Each job gets its own sector (lanes) at its Y level, so turtles never mine the
same area twice. Turtles don't know absolute coordinates, so this assumes their
homes are close together.

Without the base, a turtle can still be run by hand:
`oreminer diamond`, `oreminer diamond qty=32`, `oreminer y=-30 only=osmium`,
options `at=<Y> lanes=<n> length=<n>`.

It only works while its chunk is loaded: stay nearby or force-load the area.
It never digs computers, turtles, chests, barrels, shulkers or spawners.

## Test

```bash
docker run --rm -v "$PWD":/w -w /w/test nickblah/lua:5.2 lua sim.lua ../oreminer.lua
docker run --rm -v "$PWD":/w -w /w/test nickblah/lua:5.2 lua forester_sim.lua ../forester.lua
```

Runs the turtle and base programs unmodified against a simulated world,
turtles, Geo Scanner, equipment swaps and rednet: hand runs in all four
directions, interrupt + resume, trips home when full, protected blocks, the
shaft to a target Y with an ore filter, a fleet of 3 turtles taking 3 queued
jobs at once (exact quantities, separate sectors, monitor output), STOP from
the base, and a server stop right after a move or a turn. The forester harness
grows trees over time and with bone meal and covers felling with branches,
replanting, fuel from logs, and restarts mid-tree and mid-turn.
