# cc-factory — a self-growing ComputerCraft turtle factory (ATM10)

A base computer with a touch monitor runs a turtle factory:

- **Ore miners** dig a shaft to a Y level and mine only the ore they were
  asked for (Advanced Peripherals Geo Scanner), then unload into their chest.
- **Foresters** run a tree farm and deliver logs.
- **Stock rules** ("keep 256 raw iron") queue mining jobs on their own.
- **Fleet targets** ("3 miners") make the base **build new turtles**: an
  assembler turtle crafts them from parts in storage, places them, and they
  install themselves from a disk, fly to a home slot and start working.
- **Code updates** come from this repository: press UPDATE on the base and
  every turtle gets the new version the next time it is home.

Built and tested for ATM10 8.6 (Minecraft 1.21.1, CC: Tweaked 1.120.2,
Advanced Peripherals 0.8.2a). Facts it relies on were checked against those
jars; see [PLAN.md](PLAN.md).

## Quick start

1. Place an **advanced computer** with a **wireless modem** and an **advanced
   monitor** (4 wide × 3 high is comfortable). This is the base.
2. On it run:

   ```
   wget run https://raw.githubusercontent.com/ErikTMA/cc-factory/main/bootstrap.lua
   ```

   It downloads everything and starts the base. It writes `/factory.cfg` with
   defaults on first start: `edit factory.cfg` to set things up, then reboot.
3. Add turtles (by hand, or let the base build them — see below).

## Turtles

| Role | Turtle | Notes |
|---|---|---|
| miner | Advanced Turtle + Diamond Pickaxe + **Geo Scanner** | wireless modem + coal in its inventory, chest behind its home spot |
| forester | Advanced Turtle + Diamond Pickaxe + **Compass** | saplings in slot 1, wireless modem + coal, chest behind, a lane of dirt/grass spots (see `forester.lua`) |
| assembler | Advanced Turtle + **Crafting Table** + **Wireless Modem** | builds the others (see below) |

Upgrades are crafted next to the turtle in a crafting grid (pickaxe left of
the turtle, scanner/compass right of it, both in one craft).

**Installing a turtle by hand** (built turtles install themselves): on the
turtle run

```
wget run https://raw.githubusercontent.com/ErikTMA/cc-factory/main/bootstrap.lua miner
```

(or `forester` / `assembler`). It pins itself to the first base that answers.
A miner set up by hand asks for its Y once (F3); a forester needs its saplings
in slot 1 first.

### Recipes (verified against the pack)

| Item | Recipe |
|---|---|
| Advanced Computer | 7 gold ingot, 1 redstone, 1 glass pane |
| Advanced Turtle | 7 gold ingot, 1 Advanced Computer, 1 chest |
| Geo Scanner | 4 diamond, 1 Wired Modem (full block), 1 Peripheral Casing, 2 redstone block, 1 observer |
| Peripheral Casing | 4 iron ingot, 4 iron bars, 1 redstone block |
| Wired Modem / full block | 8 stone + 1 redstone; then craft it alone |
| Wireless Modem | 8 stone, 1 ender pearl |
| Advanced Monitor ×4 | 8 gold ingot, 1 glass pane |

## The base's network

Connect these to the base with **wired modems and cable**. The base tells
them apart by block type, nothing to configure:

| Block | Use |
|---|---|
| **barrels** | storage (or an AE2 **ME Bridge** / RS **RS Bridge** instead) |
| **chests** | turtle home chests: the base drains them into storage every 10 s |
| **trapped chest** | the assembler's supply chest |
| **disk drive** (with a floppy) | the installer disk, under the build spot |

## Building turtles automatically

```
        [trapped chest]          <- supply chest (wired to the base)
        [  assembler  ] -> [build spot]   (keep empty)
                           [disk drive]   <- under the build spot, with a floppy
```

- The assembler faces the build spot. The disk drive must be **under the build
  spot**, not next to the assembler (a computer boots from an attached disk).
- Put the parts in storage. Per turtle: 14 gold ingots, 1 redstone, 1 glass
  pane, 1 chest, 1 diamond pickaxe, a Geo Scanner (miner) or compass
  (forester), 1 wireless modem, coal (and 16 saplings for a forester).
- In `factory.cfg` set `build.y` (Y of the build spot), the home slots, and the
  fleet:

  ```lua
  build = { y = 64 },
  homes = {
    miner = { { east = 4, north = 0, facing = "north" },
              { east = 6, north = 0, facing = "north" } },
  },
  fleet = { miner = 2 },
  ```

  A home slot is an offset from the build spot. Build each slot yourself: a
  chest (wired to the base) behind the spot, room in front. New turtles fly 3
  blocks above the build spot to get there and never dig inside the base.
- The FACTORY tab shows what each role still needs and has a BUILD button.

## Stock rules

```lua
rules = {
  { item = "minecraft:raw_iron", min = 256, job = { only = "iron", y = 16, quantity = 64 } },
  { item = "minecraft:diamond", min = 32, job = { only = "diamond", y = -58, quantity = 16 } },
},
```

When storage holds less than `min`, the base queues the job (once; the next
one when it is done and stock is still low). Miners dig with a pickaxe, so
rules are about the drops: `raw_iron`, `raw_gold`, `raw_copper`, `diamond`,
`coal`, `redstone`, `lapis_lazuli`, `emerald`.

## The monitor

- **TURTLES**: every turtle (role, state, job, mined, fuel, last seen) and
  what is being fetched per ore. Tap a turtle, then STOP to call it home.
- **JOBS**: pick an ore (sets its best Y), Y, quantity, "only <ore>" or "all
  ores", then START. Every press queues one job; idle miners take them.
- **FACTORY**: storage kind, code version, UPDATE, stock rules, fleet and
  builds.

## Restarts

Every turtle move is journaled (`tmove.lua`): before moving it records its
fuel, and since a move costs exactly one fuel it knows after a restart whether
the move happened. Turns are free, so the heading is measured again on resume
(Geo Scanner or compass). Miners never unload without a chest in front.

## Tests

```bash
test/run.sh
```

Three offline harnesses (Lua 5.2 in Docker) run the real programs against a
simulated world: the miner and dispatcher (hand runs, resume, service trips,
fleets, STOP, server stops mid-move/turn), the forester, and the **whole
factory** — base with real storage over fake barrels/chests, the assembler
crafting the way CC does, a new turtle booting from the installer disk,
flying home, filling a stock rule, and taking a code update.
