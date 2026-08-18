#!/usr/bin/env python3
"""Generates the HarfBuzz ground-truth corpus that grades payv's shaper.

    pip install uharfbuzz fonttools
    python3 tool/gen_harfbuzz_corpus.py

Writes `test/fixtures/harfbuzz_golden.json`: for every probe string, the exact
glyph ids, clusters and positions HarfBuzz produces, in font design units.

WHY THIS EXISTS. "Our Kurdish looks right" is not a claim anyone can check, and
extraction cannot prove shaping — a PDF can carry a perfect `/ActualText` string
over completely wrong glyphs. The only honest gate is glyph-level: run the same
string through HarfBuzz, the reference implementation of OpenType shaping, and
demand our glyph ids and advances match it exactly. Where we differ, we are
wrong; there is no second opinion to appeal to.

The corpus deliberately over-weights the four Sorani letters with NO Unicode
presentation forms (ڕ ڵ ە ێ), the ڵ+ا ligature that has no codepoint at all, and
the contextual `.long` alternates — the exact cases that defeat every
presentation-form-based PDF library.
"""

import json
import os
import sys

try:
    import uharfbuzz as hb
except ImportError:
    sys.exit("pip install uharfbuzz")
from fontTools.ttLib import TTFont

FONT = os.environ.get(
    "PAYV_TEST_FONT", "test/fonts/Vazirmatn.ttf"
)

# ── the probe corpus ──────────────────────────────────────────────────────────
# Each entry is (id, text, note). The note lands in the JSON so a failing test
# says WHY the string is in the corpus, not just that it differs.

CASES = [
    # -- the four letters with no presentation form, in every joining position --
    ("re-isol", "ڕ", "U+0695 alone — no presentation form exists"),
    ("re-fina", "بڕ", "ڕ final after a dual-joiner"),
    ("re-init", "ڕب", "ڕ is right-joining, so it must NOT take an initial form"),
    ("re-word", "ڕووکار", "ڕ opening a real word"),
    ("lam-v-isol", "ڵ", "U+06B5 alone"),
    ("lam-v-init", "ڵا", "ڵ + alef — the ligature with no codepoint"),
    ("lam-v-medi", "بڵب", "ڵ medial: dual-joining needs all four shapes"),
    ("lam-v-fina", "بڵ", "ڵ final"),
    ("ae-isol", "ە", "U+06D5 alone — the most frequent Sorani vowel"),
    ("ae-fina", "نامە", "ە final — reached only through GSUB (uni06D5.fina)"),
    ("ye-isol", "ێ", "U+06CE alone"),
    ("ye-init", "ێگ", "ێ initial — uni06CE.init, GSUB-only"),
    ("ye-medi", "بێب", "ێ medial"),
    ("ye-fina", "بێ", "ێ final"),
    # -- the ligature that defeats presentation-form mapping entirely --
    ("lam-alef", "لا", "the standard lam-alef ligature"),
    ("lam-v-alef", "ڵا", "lamVabove_alef.isol — gid 474, NO codepoint"),
    ("palawtn", "پاڵاوتن", "the canonical failure case: ڵ+ا inside a word"),
    # -- contextual alternates (GSUB type 6 chaining context) --
    ("kurdistan", "کوردستان", "produces uniFE98.long — a contextual alternate"),
    ("seen-long", "دستان", "the .long seen form again, shorter context"),
    # -- real Kurdish, the kind that ships on an invoice or a receipt --
    ("gorini", "گۆڕینی ڕووکار", "change appearance"),
    ("jmara", "ژمارەی ناسنامە", "identity number"),
    ("rega", "ڕێگە", "three GSUB-only glyphs in four letters"),
    ("kurdi", "کوردی", "Kurdish"),
    ("herem", "هەرێمی کوردستان", "Kurdistan Region"),
    ("paresga", "پارێزگای هەولێر", "Erbil Governorate"),
    ("pare", "پارە", "money"),
    ("wesl", "وەسڵی پارەدان", "payment receipt"),
    ("kompanya", "کۆمپانیای کارەبا", "electricity company"),
    ("bru", "بڕی پارە", "amount"),
    ("berwar", "بەرواری پارەدان", "payment date"),
    ("nawnishan", "ناونیشان", "address"),
    ("koy", "کۆی گشتی", "total"),
    ("zhmara-wesl", "ژمارەی وەسڵ", "receipt number"),
    # -- diacritics: the transparent joining class --
    ("shadda", "بّب", "shadda between joiners must not break the join"),
    ("fatha", "بَب", "fatha, likewise"),
    ("marks-stack", "بِّب", "two stacked marks — exercises mkmk"),
    # -- Arabic and Persian, since the package is not Kurdish-only --
    ("arabic-basic", "العربية", "Arabic"),
    ("arabic-bism", "بسم الله الرحمن الرحيم", "long Arabic with ligatures"),
    ("persian", "فارسی", "Persian"),
    ("persian-sent", "زبان فارسی شیرین است", "a Persian sentence"),
    ("urdu", "اردو", "Urdu"),
    # -- digits and mixed direction --
    ("arabic-digits", "٤٥٠٠٠", "Arabic-Indic digits"),
    ("western-digits", "45000", "Western digits"),
    ("mixed-num", "بڕ ٤٥٬٠٠٠ دینار", "an amount in a Kurdish sentence"),
    ("mixed-latin", "Payv ژمارە", "Latin inside an RTL run"),
    ("mixed-both", "Invoice ژمارەی 2026-0415", "the real invoice header"),
    ("iqd", "٤٥٬٠٠٠ د.ع", "Iraqi dinar"),
    # -- zero-width joiner control, the shaper's escape hatch --
    ("zwj-init", "ڵ‍", "ZWJ forces the initial form"),
    ("zwj-medi", "‍ڵ‍", "ZWJ on both sides forces medial"),
    ("zwj-fina", "‍ڵ", "ZWJ forces the final form"),
    ("tatweel", "بــب", "tatweel is join-causing"),
    # -- Latin, to prove the default shaper still works --
    ("latin", "Payment Receipt", "plain Latin, kern applies"),
    ("latin-kern", "AV To Ta We", "classic kerning pairs"),
]


def main():
    if not os.path.exists(FONT):
        sys.exit(f"font not found: {FONT} (set PAYV_TEST_FONT)")

    data = open(FONT, "rb").read()
    face = hb.Face(data)
    font = hb.Font(face)
    upem = face.upem
    names = TTFont(FONT, lazy=True).getGlyphOrder()

    out = {
        "font": os.path.basename(FONT),
        "unitsPerEm": upem,
        "harfbuzzVersion": hb.version_string(),
        "note": (
            "Ground truth for payv's shaper. Regenerate with "
            "tool/gen_harfbuzz_corpus.py. Positions are in font design units "
            "at the default variation instance."
        ),
        "cases": [],
    }

    for case_id, text, note in CASES:
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(font, buf, None)

        glyphs = [
            {
                "gid": i.codepoint,
                "name": names[i.codepoint] if i.codepoint < len(names) else "?",
                "cluster": i.cluster,
                "xAdvance": p.x_advance,
                "yAdvance": p.y_advance,
                "xOffset": p.x_offset,
                "yOffset": p.y_offset,
            }
            for i, p in zip(buf.glyph_infos, buf.glyph_positions)
        ]
        out["cases"].append(
            {
                "id": case_id,
                "text": text,
                "note": note,
                "direction": str(buf.direction).split(".")[-1].lower(),
                "script": str(buf.script),
                "glyphs": glyphs,
            }
        )

    os.makedirs("test/fixtures", exist_ok=True)
    path = "test/fixtures/harfbuzz_golden.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)

    total = sum(len(c["glyphs"]) for c in out["cases"])
    gsub_only = {
        g["name"]
        for c in out["cases"]
        for g in c["glyphs"]
        if "." in g["name"] or "_" in g["name"]
    }
    print(f"wrote {path}: {len(out['cases'])} cases, {total} glyphs")
    print(f"HarfBuzz {out['harfbuzzVersion']}, upem {upem}")
    print(f"GSUB-only glyphs exercised: {', '.join(sorted(gsub_only))}")


if __name__ == "__main__":
    main()
