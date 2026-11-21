#!/usr/bin/env python3
"""Draw the setup diagrams in docs/img/*.svg (one shared style).

    python3 docs/diagrams.py

Side views: x to the right, up is up. Top views: north is up.
"""
import os
from xml.sax.saxutils import escape as esc

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "img")
CELL = 44

COL = {
    "chest": "#a0522d", "trapped": "#7c2d12", "barrel": "#c8a165", "computer": "#e8c547",
    "monitor": "#2b2b2b", "turtle": "#4b5563", "drive": "#9ca3af", "modem": "#d1d5db",
    "furnace": "#6b7280", "fence": "#8b5a2b", "grass": "#86b95b", "dirt": "#8d6e4f",
    "wall": "#8a8a8a", "air": "#ffffff", "spot": "#2e7d32", "path": "#e8f5e9",
    "text": "#1f2937", "muted": "#6b7280", "cable": "#6b7280", "accent": "#d97706",
}


class Svg:
    def __init__(self, cols, rows, title, legend=None, note=None):
        self.cols, self.rows = cols, rows
        self.pad, self.top = 24, 56
        self.legend = legend or []
        self.note = note or []
        self.w = self.pad * 2 + cols * CELL + (320 if self.legend else 0)
        self.h = max(self.top + rows * CELL + self.pad + 22 * len(self.note),
                     self.top + 30 * len(self.legend) + 40)
        self.parts = [f'<text x="{self.pad}" y="34" font-size="20" font-weight="bold" '
                      f'fill="{COL["text"]}">{esc(title)}</text>']
        self.under = []  # cables: drawn below the blocks

    def xy(self, c, r):
        return self.pad + c * CELL, self.top + r * CELL

    def block(self, c, r, color, label="", stroke="#374151", dashed=False, text="#fff", w=1, h=1):
        x, y = self.xy(c, r)
        dash = ' stroke-dasharray="6 4"' if dashed else ""
        self.parts.append(f'<rect x="{x+1}" y="{y+1}" width="{CELL*w-2}" height="{CELL*h-2}" rx="4" '
                          f'fill="{color}" stroke="{stroke}" stroke-width="1.5"{dash}/>')
        if label:
            lines = label.split("\n")
            longest = max(len(l) for l in lines)
            size = min(11, (CELL * w - 6) / (0.62 * longest))  # shrink to fit the block
            for i, line in enumerate(lines):
                ty = y + CELL * h / 2 + size / 3 + (i - (len(lines) - 1) / 2) * (size + 1)
                self.parts.append(f'<text x="{x + CELL*w/2}" y="{ty}" font-size="{size:.1f}" text-anchor="middle" '
                                  f'font-weight="bold" fill="{text}">{esc(line)}</text>')

    def turtle(self, c, r, facing, label="T"):
        self.block(c, r, COL["turtle"], "", stroke="#111827")
        x, y = self.xy(c, r)
        cx, cy = x + CELL / 2, y + CELL / 2
        d = {"right": (1, 0), "left": (-1, 0), "up": (0, -1), "down": (0, 1)}[facing]
        tip = (cx + d[0] * 15, cy + d[1] * 15)
        perp = (-d[1], d[0])
        b1 = (cx - d[0] * 6 + perp[0] * 9, cy - d[1] * 6 + perp[1] * 9)
        b2 = (cx - d[0] * 6 - perp[0] * 9, cy - d[1] * 6 - perp[1] * 9)
        self.parts.append(f'<polygon points="{tip[0]},{tip[1]} {b1[0]},{b1[1]} {b2[0]},{b2[1]}" '
                          f'fill="{COL["accent"]}"/>')
        self.parts.append(f'<text x="{cx}" y="{y+CELL-5}" font-size="9" text-anchor="middle" '
                          f'fill="#fff">{esc(label)}</text>')

    def modem(self, c, r, label="modem"):
        self.block(c, r, COL["modem"], label, text=COL["text"])

    def cable(self, points):
        pts = " ".join(f"{self.xy(c, r)[0] + CELL/2},{self.xy(c, r)[1] + CELL/2}" for c, r in points)
        self.under.append(f'<polyline points="{pts}" fill="none" stroke="{COL["cable"]}" stroke-width="6" '
                          f'stroke-linecap="round" stroke-linejoin="round"/>')

    def arrow(self, points, color=None, dashed=True):
        color = color or COL["accent"]
        pts = " ".join(f"{self.xy(c, r)[0] + CELL/2},{self.xy(c, r)[1] + CELL/2}" for c, r in points)
        dash = ' stroke-dasharray="7 5"' if dashed else ""
        self.parts.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="3"{dash} '
                          f'marker-end="url(#head)"/>')

    def label(self, c, r, text, color=None, size=12, anchor="start", bold=False):
        x, y = self.xy(c, r)
        b = ' font-weight="bold"' if bold else ""
        self.parts.append(f'<text x="{x}" y="{y}" font-size="{size}" text-anchor="{anchor}"{b} '
                          f'fill="{color or COL["muted"]}">{esc(text)}</text>')

    def ground(self, row, c0, c1, color=None):
        for c in range(c0, c1):
            self.block(c, row, color or COL["grass"], stroke="#5a7d3c")

    def render(self, name):
        lx = self.pad + self.cols * CELL + 30
        leg = []
        for i, (color, text) in enumerate(self.legend):
            y = self.top + i * 30
            leg.append(f'<rect x="{lx}" y="{y}" width="22" height="22" rx="4" fill="{color}" stroke="#374151"/>')
            leg.append(f'<text x="{lx+32}" y="{y+16}" font-size="13" fill="{COL["text"]}">{esc(text)}</text>')
        notes = []
        ny = self.top + self.rows * CELL + 28
        for i, n in enumerate(self.note):
            notes.append(f'<text x="{self.pad}" y="{ny + i*22}" font-size="13" fill="{COL["text"]}">{esc(n)}</text>')
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
               f'viewBox="0 0 {self.w} {self.h}" font-family="DejaVu Sans, Verdana, sans-serif">'
               f'<defs><marker id="head" markerWidth="10" markerHeight="10" refX="6" refY="3" orient="auto">'
               f'<path d="M0,0 L6,3 L0,6 z" fill="{COL["accent"]}"/></marker></defs>'
               f'<rect width="100%" height="100%" fill="#fafaf9"/>'
               + "".join(self.parts[:1] + self.under + self.parts[1:] + leg + notes) + "</svg>")
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, name), "w") as f:
            f.write(svg)


def base_top():
    s = Svg(13, 7, "The base, seen from above (north is up)", legend=[
        (COL["computer"], "base computer"), (COL["monitor"], "advanced monitor"),
        (COL["modem"], "wired modem"), (COL["cable"], "network cable"),
        (COL["barrel"], "barrels: storage"), (COL["furnace"], "furnaces (optional)"),
        (COL["chest"], "chests: turtle homes"), (COL["trapped"], "trapped chest: supply"),
        (COL["turtle"], "turtle (arrow = facing)"), (COL["drive"], "disk drive + floppy"),
    ], note=[
        "Everything with a wired modem joins the network; the base sorts blocks by type:",
        "barrels = storage, plain chests = turtle homes (drained), trapped chest = assembler supply.",
        "Right-click each modem once so its red ring lights up (connects the block to the network).",
    ])
    s.block(0, 0, COL["monitor"], "monitor", stroke=COL["computer"], w=3)
    s.block(1, 1, COL["computer"], "base", text=COL["text"])
    s.modem(1, 2)
    s.cable([(1, 2), (1, 4), (11, 4)])
    s.cable([(4, 4), (4, 3)]); s.cable([(5, 4), (5, 3)]); s.cable([(6, 4), (6, 3)])
    s.block(4, 2, COL["barrel"], "barrel", text=COL["text"]); s.modem(4, 3, "")
    s.block(5, 2, COL["barrel"], "barrel", text=COL["text"]); s.modem(5, 3, "")
    s.block(6, 2, COL["barrel"], "barrel", text=COL["text"]); s.modem(6, 3, "")
    s.cable([(8, 4), (8, 5)])
    s.block(8, 6, COL["furnace"], "furnace"); s.modem(8, 5, "")
    s.cable([(9, 4), (9, 5)])
    s.block(9, 6, COL["furnace"], "furnace"); s.modem(9, 5, "")
    s.cable([(11, 4), (11, 3)])
    s.modem(11, 3, "")
    s.block(11, 2, COL["chest"], "home\nchest")
    s.turtle(11, 1, "up", "miner")
    s.modem(11, 0)
    s.label(9.0, 1.4, "a miner home", COL["text"], 12, bold=True)
    s.label(9.0, 1.75, "(own picture)", COL["muted"], 11)
    s.label(2.2, 6.9, "assembler + build spot: see the side view", COL["muted"], 12)
    s.render("base-top.svg")


def assembler_side():
    s = Svg(8, 6, "Assembler and build spot, seen from the side", legend=[
        (COL["turtle"], "assembler (crafting table + modem)"), (COL["trapped"], "supply: trapped chest"),
        (COL["drive"], "disk drive + floppy"), (COL["modem"], "wired modem"),
    ], note=[
        "The assembler faces the build spot. Keep the build spot empty: new turtles appear there.",
        "The disk drive goes UNDER the build spot, never next to the assembler",
        "(a computer boots from an attached disk). Base, supply chest and drive share the network.",
    ])
    s.ground(5, 0, 8)
    s.block(2, 3, COL["trapped"], "supply")
    s.turtle(2, 4, "right", "assembler")
    s.block(3, 4, COL["air"], "build\nspot", stroke=COL["accent"], dashed=True, text=COL["accent"])
    s.block(3, 5, COL["drive"], "disk\ndrive", text=COL["text"])
    s.modem(4, 5, "")
    s.modem(1, 3, "")
    s.cable([(1, 3), (0, 3)]); s.cable([(4, 5), (6, 5)])
    s.label(0, 2.7, "to the base network", COL["muted"], 11)
    s.label(5.2, 4.75, "to the base network", COL["muted"], 11)
    s.render("assembler-side.svg")


def miner_home():
    s = Svg(9, 9, "A miner home, seen from the side", legend=[
        (COL["chest"], "home chest (wired)"), (COL["turtle"], "miner (facing away)"),
        (COL["modem"], "wired modem"), (COL["dirt"], "ground"),
    ], note=[
        "The chest is right behind the miner; a wired modem in front of it (or a wireless modem",
        "in its inventory). Keep the block above the miner free: new turtles fly in from above.",
        "The miner digs its shaft straight down from its home, so don't put the modem below it.",
    ])
    for c in range(0, 9):
        for r in range(3, 9):
            s.block(c, r, COL["dirt"], stroke="#6d533a")
    s.block(3, 2, COL["chest"], "chest")
    s.turtle(4, 2, "right", "miner")
    s.modem(5, 2)
    s.cable([(3, 2), (0, 2)]); s.cable([(5, 2), (8, 2)])
    s.label(0, 1.8, "to the base", COL["muted"], 11)
    s.label(6.2, 1.8, "to the base", COL["muted"], 11)
    for r in range(3, 9):
        s.block(4, r, "#ffffff", "shaft" if r == 5 else ("down" if r == 6 else ""),
                stroke=COL["accent"], dashed=True, text=COL["accent"])
    s.block(4, 1, COL["air"], "keep\nfree", stroke=COL["accent"], dashed=True, text=COL["accent"])
    s.render("miner-home.svg")


def forester_pen():
    cols, rows = 11, 12
    s = Svg(cols, rows, "A forester pen, seen from above (north is up)", legend=[
        (COL["fence"], "fence / wall / gate"), (COL["spot"], "tree spot"),
        (COL["path"], "path it walks"), (COL["chest"], "home chest (in the fence)"),
        (COL["turtle"], "forester (facing in)"),
    ], note=[
        "Any shape works as long as it is closed and all of it is connected. Dirt or grass floor.",
        "Tree spots: every 3rd cell counted from the forester's home. Saplings go in its slot 1.",
        "Put its wired modem UNDER the home spot (in front of it is the pen). Changed the fence? 'forester rescan'.",
    ])
    hx, hy = 2, 10  # home cell (column, row); pen interior cols 1..9, rows 1..10
    for c in range(cols):
        for r in range(rows):
            border = c in (0, cols - 1) or r in (0, rows - 1)
            if border:
                s.block(c, r, COL["fence"], stroke="#5c3b1e")
            else:
                dx, dz = c - hx, r - hy
                if (dx, dz) != (0, 0) and dx % 3 == 0 and dz % 3 == 0:
                    s.block(c, r, COL["spot"], "tree", stroke="#1b5e20")
                else:
                    s.block(c, r, COL["path"], stroke="#c8e6c9")
    for c in range(1, 7):  # an inner fence, to show it routes around
        s.block(c, 5, COL["fence"], stroke="#5c3b1e")
    s.block(hx, rows - 1, COL["chest"], "chest")
    s.turtle(hx, hy, "up", "home")
    s.render("forester-pen.svg")


def surveyor_top():
    s = Svg(12, 6, "Surveyor: place it in front of the base computer (top view)", legend=[
        (COL["computer"], "base computer"), (COL["turtle"], "surveyor (plain turtle)"),
        (COL["wall"], "wall"), (COL["modem"], "wired modem"), (COL["chest"], "home chest"),
        (COL["accent"], "its route (over the wall)"),
    ], note=[
        "Place a plain advanced turtle in front of the base computer and run: surveyor <facing>",
        "(the way it looks, from F3). Give it coal and a few cobblestone (one marker per home).",
        "It climbs walls next to cables but never digs: cables buried in walls are not found.",
        "Every free spot beside a home chest with a modem next to it becomes a home (role: off).",
    ])
    for c in range(0, 12):
        s.block(c, 3, COL["wall"], stroke="#5f5f5f")
    s.modem(4, 3, "modem")
    s.block(4, 4, COL["computer"], "base", text=COL["text"])
    s.turtle(4, 5, "up", "surveyor")
    s.cable([(4, 3), (4, 2), (10, 2)])
    s.block(7, 1, COL["chest"], "chest")
    s.turtle(8, 1, "right", "home")
    s.modem(9, 1, "")
    s.cable([(9, 1), (9, 2)])
    s.arrow([(4, 5), (5.5, 5), (5.5, 1.5), (7.6, 1.5)])
    s.label(5.75, 4.75, "climbs up the wall and over (never digs)", COL["accent"], 12)
    s.label(7.0, 0.9, "home: chest behind, modem in front", COL["text"], 11)
    s.render("surveyor-top.svg")


def gps_side():
    s = Svg(12, 9, "GPS: four host turtles above the base (side view)", legend=[
        (COL["turtle"], "GPS host turtle"), (COL["accent"], "height above the build spot"),
    ], note=[
        "Press BUILD GPS on the FACTORY tab: the factory builds 4 iron turtles with a compass and a",
        "wireless modem (4 ender pearls) and they fly to (-4,20,-4) (4,20,-4) (-4,20,4) (4,26,4)",
        "from the build spot. One is higher on purpose: four points in one flat plane can't tell",
        "above from below. Keep the sky above the base open so they can fly up.",
    ])
    s.ground(8, 0, 12)
    s.block(6, 7, COL["air"], "build\nspot", stroke=COL["accent"], dashed=True, text=COL["accent"])
    s.turtle(2, 2, "right", "GPS")
    s.turtle(10, 2, "right", "GPS")
    s.turtle(4, 3, "right", "GPS")
    s.turtle(9, 0, "right", "GPS")
    s.label(2.5, 1.8, "y 20", COL["accent"], 12, "middle", bold=True)
    s.label(10.5, 1.8, "y 20", COL["accent"], 12, "middle", bold=True)
    s.label(4.5, 2.8, "y 20 (behind)", COL["accent"], 12, "middle", bold=True)
    s.label(8.4, 0.5, "y 26", COL["accent"], 12, "end", bold=True)
    s.arrow([(6, 7), (6, 4.2)])
    s.render("gps-side.svg")


if __name__ == "__main__":
    base_top(); assembler_side(); miner_home(); forester_pen(); surveyor_top(); gps_side()
    print("wrote", sorted(os.listdir(OUT)))
