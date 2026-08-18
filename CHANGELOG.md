# Changelog

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
