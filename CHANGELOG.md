# Changelog

## 0.1.1 — 2026-08-18

One correctness fix, plus packaging.

### Fixed — a table's version tail could decode out of the NEXT table

`OpenTypeFont` now passes each table's directory-recorded length to the parsers
whose format has a version tail: `OS/2`, `post` and `maxp`.

`SfntFile.table()` hands back a reader over the whole file positioned at the
table — deliberately, because an OpenType offset may point backwards into a
parent and slicing per table would break real fonts. The consequence was that a
parser's own bounds check asked "does the FILE have room", and for any table that
is not the last one the answer is always yes. A version word claiming more than
its body holds was therefore believed, and the tail decoded out of whichever
table happened to follow.

Measured on Vazirmatn with its `OS/2` version word flipped to 5 over a 96-byte
body: `usLowerOpticalPointSize` came back as **908**, read out of `post`. On that
path `sCapHeight` and `sxHeight` are fabricated the same way, and both go
straight into the PDF `/CapHeight` and `/XHeight`. `post` was reading its glyph
names — and `maxp` its outline limits — out of the following table under the same
conditions.

Only malformed or unusually-truncated fonts reach it; a well-formed face is
unaffected, and no output changes for one. `doc/DEFECTS.md` O3 has the full
account, including why the parameter existing and being tested was not enough.

### Packaging

- Shortened the pubspec `description` to the 60–180 characters pub.dev's
  analysis asks for.
- Dropped the `documentation:` field. pub.dev generates and links the API docs
  itself; pointing the field back at that same URL only created a link that is
  unreachable until the docs finish building.

## 0.1.0 — 2026-08-18

First release.

- **Pure-Dart OpenType layout engine.** `GSUB` types 1–8 and `GPOS` types 1–9,
  executed against the font's own tables, so glyphs that exist only as the
  output of a lookup — and have no Unicode codepoint at all — are reachable.
  This is what makes Kurdish Sorani render correctly: `ڕ` `ڵ` `ە` `ێ` have no
  presentation forms in Unicode, and neither does the `ڵ`+`ا` ligature.
- **Arabic joining state machine** with the transparent mark class, ZWJ/ZWNJ,
  tatweel, and the `fin2`/`fin3`/`med2` features.
- **UAX #9 bidi**, including isolate formatting characters and paired brackets.
- **Variable-font support** — `fvar`/`gvar`/`avar`/`HVAR`, with static
  instancing, because a PDF cannot carry a variable font.
- **Font subsetting** with composite-glyph closure.
- **PDF 1.7 writer** — CIDFontType2 / Identity-H, embedded subsetted fonts,
  `ToUnicode` CMaps, and RTL text stored in visual order so every extractor
  reads it back correctly.
- **Zero runtime dependencies.** No FFI, no platform channels; runs on the VM,
  in Flutter, and on the web.
- Graded byte-exact against HarfBuzz: 53 corpus cases, 371 glyphs, 16 distinct
  GSUB-only glyphs.
