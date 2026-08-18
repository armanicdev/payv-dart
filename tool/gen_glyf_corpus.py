#!/usr/bin/env python3
"""Generates test/fixtures/glyf_golden.json — outline parity against fontTools.

Why this exists
---------------
`test/font/glyf_test.dart` asserts topology and inequality: same contour count
at every weight, bold differs from regular, nothing throws. That cannot fail on
a coordinate. Three severe mutations proved it — removing IUP interpolation
entirely, dropping the tuple scalar's axis interpolation, and removing the
implied on-curve midpoint — all passed 32/32.

So this file pins the numbers themselves, against a second implementation. It
is the same idea as `gen_harfbuzz_corpus.py`: the reference tool runs once,
here, and the answer is committed so the suite needs no Python.

    python3 tool/gen_glyf_corpus.py

Weights are not arbitrary
-------------------------
payv quantises an axis coordinate to F2Dot14 BEFORE the `avar` map, because a
float 0.6 interpolates across the segment past the knot the font pinned and
draws a weight nobody designed. fontTools does not quantise. So the corpus uses
only user weights whose normalised value is exactly representable in F2Dot14 —
otherwise the two tools would legitimately disagree and the fixture would be
measuring the quantisation, not the outlines.

For a 100/400/900 axis that means steps of 75 below the default and 125 above.
The extremes alone would not do: at ±1 and 0 every tuple scalar is 1 or 0, and
the mutation that drops the scalar's axis interpolation survives untouched.
"""

import json
import os
import sys

from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.ttLib import TTFont

FONT = os.environ.get(
    "PAYV_TEST_FONT", "test/fonts/Vazirmatn.ttf"
)
OUT = "test/fixtures/glyf_golden.json"

# Exactly F2Dot14-representable once normalised; see the module docstring.
WEIGHTS = [100, 250, 400, 525, 650, 775, 900]

# The glyphs the rest of the suite pins by id, so a fixture swap breaks loudly.
PINNED = [
    2,  # 'A' — simple, three contours
    9,  # 'Aacute' — composite
    474,  # lamVabove_alef.isol — reachable only through GSUB
    839,  # uni06B5.init
    896,  # uni06D5.fina
]


def midpoint(a, b):
    return ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)


class Segments:
    """Canonicalises a pen's calls into payv's own command vocabulary.

    `qCurveTo` may carry a whole run of off-curve points, and the on-curve
    points between them are NOT stored by the font — they are implied at the
    midpoints. Expanding them here, from the spec rather than from payv, is what
    makes the comparison mean something: it is the exact rule the reviewer's
    third mutation deleted.
    """

    def __init__(self):
        self.out = []
        self.current = None
        self.start = None

    def moveTo(self, pt):
        self.out.append(["M", pt[0], pt[1]])
        self.current = pt
        self.start = pt

    def lineTo(self, pt):
        self.out.append(["L", pt[0], pt[1]])
        self.current = pt

    def qCurveTo(self, *points):
        if points[-1] is None:
            # A contour with no on-curve point at all — a circle drawn as four
            # control points. The start is implied at the midpoint of the last
            # and first, and there is no preceding moveTo.
            offs = list(points[:-1])
            self.moveTo(midpoint(offs[-1], offs[0]))
            for i, off in enumerate(offs):
                self._quad(off, midpoint(off, offs[(i + 1) % len(offs)]))
            return
        offs = list(points[:-1])
        on = points[-1]
        for i, off in enumerate(offs):
            end = on if i == len(offs) - 1 else midpoint(off, offs[i + 1])
            self._quad(off, end)

    def curveTo(self, *points):
        raise SystemExit("a TrueType outline produced a cubic: " + str(points))

    def _quad(self, control, end):
        self.out.append(["Q", control[0], control[1], end[0], end[1]])
        self.current = end

    def closePath(self):
        self.out.append(["Z"])
        self.current = self.start

    def endPath(self):
        self.closePath()

    def addComponent(self, name, transform):
        raise SystemExit("the glyph set did not decompose " + name)


def main():
    font = TTFont(FONT)
    order = font.getGlyphOrder()
    num_glyphs = len(order)

    # The pinned glyphs plus a spread across the whole glyph order, so the
    # corpus covers simple and composite, Latin and Arabic, without committing
    # a megabyte of coordinates.
    ids = sorted(set(PINNED) | set(range(0, num_glyphs, 47)))

    cases = []
    for weight in WEIGHTS:
        glyph_set = font.getGlyphSet(location={"wght": weight})
        for gid in ids:
            name = order[gid]
            # A composite has to be flattened here the same way payv flattens
            # it — against the VARIED glyph set, so the component's own outline
            # moves with the axis too, not just its offset.
            recorder = DecomposingRecordingPen(glyph_set)
            glyph_set[name].draw(recorder)
            pen = Segments()
            recorder.replay(pen)
            if not pen.out:
                continue
            cases.append(
                {
                    "gid": gid,
                    "name": name,
                    "wght": weight,
                    # 6 decimals: far below a design unit, and enough that a
                    # real disagreement cannot hide inside the rounding.
                    "path": [
                        [c[0]] + [round(v, 6) for v in c[1:]] for c in pen.out
                    ],
                }
            )

    golden = {
        "font": os.path.basename(FONT),
        "unitsPerEm": font["head"].unitsPerEm,
        "numGlyphs": num_glyphs,
        "fontTools": __import__("fontTools").version,
        "weights": WEIGHTS,
        "glyphs": ids,
        "cases": cases,
    }
    with open(OUT, "w") as f:
        json.dump(golden, f, separators=(",", ":"))
        f.write("\n")

    commands = sum(len(c["path"]) for c in cases)
    print(
        f"{OUT}: {len(cases)} outlines, {commands} commands, "
        f"{os.path.getsize(OUT)} bytes",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
