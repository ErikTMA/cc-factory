#!/usr/bin/env python3
"""Extract the real recipes/tags the factory uses from the server's jars.

Runs INSIDE the Minecraft server container (it reads /data/libraries and
/data/mods) and prints recipes.json to stdout:

    kubectl exec -i -n mc <pod> -- python3 - < test/fixtures/extract.py > test/fixtures/recipes.json
    python3 test/fixtures/to_lua.py

Add an item to WANT / SMELT when recipes.lua or oreconf.lua starts using it.
"""
import glob
import json
import sys
import zipfile

jars = glob.glob("/data/libraries/net/minecraft/server/*/server-*-extra.jar")
jars += glob.glob("/data/libraries/net/neoforged/neoforge/*/neoforge-*-universal.jar")
jars += glob.glob("/data/mods/cc-tweaked-*.jar") + glob.glob("/data/mods/AdvancedPeripherals*.jar")
jars += glob.glob("/data/mods/alltheores*.jar")
jars += glob.glob("/data/mods/utilitarian-*.jar")
Z = [zipfile.ZipFile(j) for j in jars]


def read(path):
    for z in Z:
        if path in z.namelist():
            return json.loads(z.read(path))
    return None


WANT = {
    "minecraft": ["observer", "diamond_pickaxe", "stick", "oak_planks", "chest", "glass_pane", "compass",
                  "iron_bars", "redstone_block", "copper_block", "iron_block", "furnace"],
    "computercraft": ["computer_advanced", "turtle_advanced", "computer_normal", "turtle_normal",
                      "wired_modem", "wired_modem_full_from", "turtle_upgrade", "wireless_modem_normal"],
    "advancedperipherals": ["geo_scanner", "peripheral_casing"],
    "utilitarian": ["tiny_fuel/tiny_coal", "tiny_fuel/tiny_charcoal"],
    "alltheores": ["copper_ore_hammer", "iron_ore_hammer", "crafting/hammer/iron/dust_from_raw",
                   "crafting/hammer/gold/dust_from_raw", "crafting/hammer/copper/dust_from_raw"],
}
SMELT = {
    "minecraft": ["iron_ingot_from_smelting_raw_iron", "gold_ingot_from_smelting_raw_gold",
                  "copper_ingot_from_smelting_raw_copper", "charcoal", "stone", "glass"],
    "alltheores": ["smelting/iron/dust_smelting", "smelting/gold/dust_smelting", "smelting/copper/dust_smelting"],
}

out = {"crafting": {}, "smelting": {}, "tags": {}, "sources": sorted(j.split("/")[-1] for j in jars)}
for section, table in (("crafting", WANT), ("smelting", SMELT)):
    for ns, names in table.items():
        for n in names:
            r = read(f"data/{ns}/recipe/{n}.json")
            if r is None:
                print("MISSING", section, ns, n, file=sys.stderr)
                continue
            out[section][f"{ns}:{n}"] = r


def tagfile(tag):
    ns, p = tag.split(":", 1)
    for folder in ("item", "items"):
        t = read(f"data/{ns}/tags/{folder}/{p}.json")
        if t:
            return t


def resolve(tag, seen=None):
    seen = seen or set()
    if tag in seen:
        return []
    seen.add(tag)
    t = tagfile(tag)
    if not t:
        return []
    items = []
    for v in t.get("values", []):
        if isinstance(v, dict):
            v = v.get("id")
        items += resolve(v[1:], seen) if v.startswith("#") else [v]
    return items


def tags_in(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "tag":
                yield v
            else:
                yield from tags_in(v)
    elif isinstance(o, list):
        for v in o:
            yield from tags_in(v)


for r in list(out["crafting"].values()) + list(out["smelting"].values()):
    for t in tags_in(r):
        out["tags"][t] = sorted(set(resolve(t)))
print(json.dumps(out, indent=1, sort_keys=True))
