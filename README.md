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

**New here? Follow the illustrated [setup guide](docs/SETUP.md).**

## Quick start

1. Place an **advanced computer** with a **wireless modem** and an **advanced
   monitor** (4 wide × 3 high is comfortable). This is the base.
2. On it run:

   ```
   wget run https://raw.githubusercontent.com/ErikTMA/cc-factory/main/bootstrap.lua
   ```

   It downloads everything and starts the base, and from then on keeps itself
   up to date (it checks GitHub every 30 minutes; `base update` updates right
   away, `autoUpdate = false` in `factory.cfg` turns it off). It writes `/factory.cfg` with
   defaults on first start: `edit factory.cfg` to set things up, then reboot.
3. Add turtles (by hand, or let the base build them — see below).

## Turtles

| Role | Turtle | Notes |
|---|---|---|
| miner | Advanced Turtle + Diamond Pickaxe + **Geo Scanner** | wireless modem + coal in its inventory, chest behind its home spot |
| forester | Advanced Turtle + Diamond Pickaxe + **Compass** | coal (saplings come from the base); home spot inside a **fenced pen**, chest behind it (see below) |
| assembler | Advanced Turtle + **Crafting Table** + **Wireless Modem** | builds the others (see below) |

Upgrades are crafted next to the turtle in a crafting grid (pickaxe left of
the turtle, scanner/compass right of it, both in one craft).

**Installing a turtle by hand** (built turtles install themselves): on the
turtle run

```
wget run https://raw.githubusercontent.com/ErikTMA/cc-factory/main/bootstrap.lua miner
```

(or `forester` / `assembler`). It pins itself to the first base that answers.
A miner set up by hand asks for its Y once (F3); a forester gets its saplings
from the base through its home chest (or give it some).

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

## Forester pens

Fence off an area with dirt or grass as the floor (fence, wall, gate or any
solid block as the border). Put the forester's home spot inside the pen,
facing in, with its chest directly behind it — the chest can be part of the
fence line.

On its first start the forester walks every open cell of the pen once,
clearing grass and flowers and felling any trees already in there, and caches
the pen (`forester.area`). It plants a tree on every 3rd cell (counted from
home) and walks the cells between as paths, so inner fences and odd shapes are
fine as long as everything is connected. If the fence has a gap it stops at
1024 cells and says the pen is not closed. After changing the fence run
`forester rescan`.

## Wired or wireless

Turtles only talk to the base while at home, so they don't need wireless
modems (ender pearls):

- **Wired:** put a wired modem next to each home spot, cabled to the base's
  network. Miner: **in front** of the home spot (below is its shaft).
  Forester: **below** it (in front is its tree lane). Assembler: below it.
- **Wireless:** a wireless modem in the turtle's inventory; it swaps it in for
  the Geo Scanner or compass while it talks. If storage has wireless modems,
  newly built turtles get one; otherwise they rely on the wired modem.

The base talks over every modem attached to it.

## The base's network

Connect these to the base with **wired modems and cable**. The base tells
them apart by block type, nothing to configure:

| Block | Use |
|---|---|
| **barrels** | storage (or an AE2 **ME Bridge** / RS **RS Bridge** instead) |
| **chests** | turtle home chests: the base drains them into storage every 10 s |
| **disk drive** (with a floppy) | the installer disk, under the build spot |

## Building turtles automatically

```
[modem] [  assembler  ] -> [build spot]   (keep empty)
   ^                       [disk drive]   <- under the build spot, with a floppy
   enabled wired modem: the base pushes parts into the assembler and takes results back
```

- The assembler (crafting table upgrade) faces the build spot and touches an
  enabled wired modem. The disk drive must be **under the build spot**, not
  next to the assembler (a computer boots from an attached disk).
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

## Production: furnaces, crafting parts, ore doubling

Put **furnaces** (and blast furnaces, for ores) on the base's wired network.
Every 10 s the base takes finished items out, keeps them fuelled (charcoal
first; coal only above a reserve the turtles need) and gives idle furnaces
work: raw ore and dust → ingots, logs → charcoal, cobblestone → stone, sand →
glass (each up to a target, see `production` in `factory.cfg`).

When the fleet is short of turtles, the base works out every part a new
turtle needs and has the **assembler craft them**: advanced computer, chest,
glass panes, sticks/planks, diamond pickaxe, iron bars, redstone blocks,
wired modem, peripheral casing, observer, Geo Scanner, compass. The FACTORY
tab shows what it is crafting and which **raw** items it is waiting for.

Raw inputs it cannot make itself: raw ores (miners), diamonds, redstone,
coal, cobblestone, sand, logs (forester), and **nether quartz** (for the
observer in a Geo Scanner) — bring that one yourself.

**HAMMER** (FACTORY tab): doubles ores with an All The Ores ore hammer. Raw
ore is hammered into 2 dust (1 raw → 2 dust → 2 ingots) instead of being
smelted directly. The base crafts a copper ore hammer when it has none (2
copper blocks + 3 sticks; it smelts the copper for that one directly) and
replaces it when it breaks.

```lua
production = { enabled = true, hammer = false, charcoal = 64, stone = 64,
               glass = 32, coalReserve = 64, keepLogs = 16, keepCobble = 16 },
```

Smelting needs barrel storage (exact furnace slots); with an ME/RS bridge as
storage it is untested.

## Stock rules

```lua
rules = {
  { item = "minecraft:raw_iron", min = 256, job = { only = "iron", y = 16, quantity = 64 } },
  { item = "minecraft:diamond", min = 32, job = { only = "diamond", y = -58, quantity = 16 } },
},
```

When storage holds less than `min`, the base queues the job (once; the next
one when it is done and stock is still low). A rule for a raw ore also counts
what it becomes (iron dust, iron ingots), since the furnaces smelt it. Miners dig with a pickaxe, so
rules are about the drops: `raw_iron`, `raw_gold`, `raw_copper`, `diamond`,
`coal`, `redstone`, `lapis_lazuli`, `emerald`.

## The monitor

- **TURTLES**: every turtle (role, state, job, mined, fuel, last seen) and
  what is being fetched per ore. Tap a turtle, then STOP to call it home,
  DISMANTLE to take it apart (parts and the plain turtle back into storage), or
  FORGET to drop a turtle that will never report again (its home frees up).
- **GATHERING > MINING**: pick an ore (sets its best Y), Y, quantity, "only
  <ore>" or "all ores", then START. Every press queues one job; idle miners
  take them.
- **GATHERING > FORESTRY**: the foresters, which sapling kinds they plant
  (selected kinds take turns; none = auto) and bone meal on/off. The base
  keeps those, and fuel, in each home chest (the mailbox).
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
