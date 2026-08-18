# Confirmed defect ledger

Findings from the adversarial review passes over this engine, and from the
defects found since. Every entry below was **reproduced**, not inferred —
synthetic fonts were built, the code was compiled to dart2js, and the suites
were mutation-tested.

A fixed entry MOVES to the FIXED section and keeps its number, because the code
cites these by name (`tool/web_number_parity.dart` says "defect O5"). Nothing is
struck through and nothing is deleted: what was wrong, and what proved it is no
longer wrong, is the whole value of the file.

Status key: **OPEN** · **FIXED** (with what closed it) · **WONTFIX** (with the
reason).

---

## FIXED

### F1 — `OpenTypeFont` read table fields at absolute file offsets
`lib/src/font/open_type_font.dart`

`SfntFile.table()` returns a reader over the *whole file* positioned at the
table; it does not slice. `uint16At(4)` therefore read file offset 4 — the SFNT
header's `numTables`. Measured on Vazirmatn: `numGlyphs` → **20** instead of
1333, `numberOfHMetrics` → **26501** instead of 1333. `HmtxTable` then clamped
its metrics array to 20, so `advanceWidth()` returned **0 for every glyph above
19**, and `GlyfTable` was constructed with a bound of 20. Nothing threw.

Fixed by routing both through a `_u16(tag, offsetInTable)` helper that adds
`t.position`.

### F2 — `HVAR` delta-set index map was ignored
`lib/src/font/open_type_font.dart`

The facade built the variation store from the VarStore offset alone and relied
on the spec's implicit `(outer 0, inner glyphId)` fallback. Vazirmatn ships a
1333-entry `advanceWidthMapping`. Measured against fontTools at wght 100/700/900:
mapped path **1333/1333** advances correct, fallback path **179/1333**.

Fixed by calling `ItemVariationStore.parseHvar()`, which reads the map.

### F3 — variable outlines were unreachable through the facade
`lib/src/font/open_type_font.dart`

`GlyfTable.outline` accepts `coords`/`gvar`, but nothing on the facade supplied
them, so a variable font could only ever be drawn at its default instance — every
export would have come out Regular regardless of the weight requested. Fixed by
adding `OpenTypeFont.gvar` and `OpenTypeFont.outline(gid)`.

### F4 — `lookupsFor` returned FeatureList order and discarded the feature tag
`lib/src/layout/script_list.dart`

Two defects in one method.

*Order.* The LookupList table is normative: the font developer defines the lookup
sequence there to control application order, and HarfBuzz sorts its stage map by
lookup index for that reason. Measured on Vazirmatn, the method returned
`[28, 26, 22, 24, 32, 33, 23, 25, 35, 36]` where the font asked for
`[22, 23, 24, 25, 26, 28, 32, 33, 35, 36]`. On a Urdu-tagged run it placed `locl`
after `rlig` and `calt`, so localisation would land on already-ligated glyphs.

*Association.* Returning a bare `List<int>` threw away which feature selected
each lookup — and it cannot be reconstructed, because two features routinely
share a lookup. The shaper's entire design depends on knowing that lookup 22 is
`fina` and 24 is `init` so it can set mutually exclusive per-glyph mask bits. A
shaper applying those unmasked isolate-forms every glyph.

Fixed by adding `stagedLookups()` returning `StagedLookup(lookupIndex,
featureTags)` sorted ascending, with `lookupsFor` delegating to it.

### F5 — an RTL ligature extracted backwards despite a correct `ToUnicode`
`lib/src/layout/text_engine.dart`, `lib/src/pdf/content_stream.dart`

`pdftotext` returned `پاڵاوتن` as `پااڵوتن` and `ڵا` as `اڵ` — the ڵ and the ا
swapped, and only those two. The CMap was never the defect: `<0004> <06B50627>`
is exactly right for a ligature that is ONE glyph (gid 474,
`lamVabove_alef.isol`) carrying TWO codepoints in logical order. RTL glyphs are
stored VISUALLY, which is invariant 1 and non-negotiable, so a reader reorders
the line back to logical order — and reverses the ligature's two characters
along with everything else, having no way to know the pair is one glyph.

Fixed by wrapping every glyph whose cluster is longer than one codepoint in
`/Span <</ActualText …>> BDC … EMC`, with the pending `TJ` flushed at both ends
so no array straddles the boundary. Single-codepoint glyphs are left bare: one
codepoint cannot be reversed against itself, and wrapping them would add a
dictionary per glyph for nothing.

The part that is not obvious, and is now pinned cell by cell in
`test/pdf/actual_text_test.dart`: **the span's text is written in VISUAL order.**
A reader does not take `/ActualText` as finished logical text — it spreads those
characters across the span's box left to right and runs the same bidi pass over
them it runs over glyphs. Measured on `ڵا · ڵا ژمارە · ژمارە ڵا · پاڵاوتن ·
ڵاو`, one line each, compared line-exact:

|                     | pdftotext 26.06 | mutool 1.28.2 | PDFKit (macOS) |
| ------------------- | --------------- | ------------- | -------------- |
| no span             | 0/5             | 1/5           | 5/5            |
| span, logical order | 0/5             | 1/5           | 5/5            |
| span, VISUAL order  | 5/5             | 4/5           | 5/5            |

The first two rows are identical: a span in logical order is worth nothing, cell
for cell. Visual order is worth 14 of 15. PDFKit ignores `/ActualText` outright —
its column never moves — and already treats the cluster as atomic.

The remaining cell was originally explained as mutool lacking a second glyph on
a ligature-only line to prove the line was RTL. **That explanation was wrong —
see P4.** The table above is accurate for the macOS build it was measured on,
but the variable is how MuPDF was compiled, not what the line contains: Ubuntu's
`mupdf-tools` reports the same 1.28.2 and reverses nothing at all. The mutool
column is therefore build-specific and is no longer asserted; the poppler and
PDFKit columns stand.

Note the two orders are now deliberately opposite in the same file — `ToUnicode`
logical (`<06B50627>`), `/ActualText` visual (`<FEFF062706B5>`). "Fixing" that
apparent inconsistency by reversing the CMap breaks every reader that has no
span to read.

### O5 — `pdfFormatNumber` emitted scientific notation on the web
`lib/src/pdf/object.dart:29`

Keeps its number: `tool/web_number_parity.dart` cites it by name.

`if (value is int)` is TRUE for every *integral double* on dart2js and
dart2wasm, where one JavaScript number backs both types — so the double path and
the BigInt guard below it were dead code on the web. `1e21` serialised as
`1e+21`, which is a PDF syntax error, and `-0.0` as `-0.0` against the VM's `0`,
so the same document produced different bytes and a different `/ID` per target.

Fixed by asking for `value is int && value is! double`, the one test that means
the same thing on both targets: on the VM only a real int passes, on the web
nothing does and every number takes the double path, which handles integers
exactly anyway. Proved by `dart run tool/web_number_parity.dart` diffed against
`dart compile js -O2` through node — 28 lines, identical.

### O6 — ASCII85 decoder silently wrapped an over-range group
`lib/src/util/ascii85.dart`, `_emitGroup`

`& 0xFF` after `~/` masked a group above 2³²−1 into plausible bytes:
`ascii85Decode('uuuuu~>')` → `[8, 120, 14, 196]`. PDF §7.4.3 makes that an
error, and the function's own doc comment promised to throw.

Fixed by throwing a `FormatException` on `value > 0xFFFFFFFF` before the shift.
Legal input cannot reach it: a partial group padded with `u` stays under the
limit, because the digits the padding replaces were at most 84 anyway.
`test/util/ascii85_range_test.dart` covers the reproduction, the exact boundary
(`s8W-!`), a mid-stream group, and the padded-partial false positive.

### O7 — `PdfStream` dropped a caller's `/Filter` and then re-filtered the payload
`lib/src/pdf/object.dart`

`write` recomputes `/Filter` from the parallel `filters` list and skips the
dict's own entry, so a declared filter was silently removed — and
`PdfWriter._deflateStream` reads only `filters`, so it then saw an unfiltered
stream and deflated it. A `/DCTDecode` JPEG was written as `/FlateDecode`: a
reader inflates it and hands raw JPEG bytes to an XObject declared as
uncompressed samples. Corrupt image, no error anywhere.

Fixed by seeding `filters` from the dict's `/Filter` (name or array) in the
constructor rather than throwing — `/Filter` in the dict is how the rest of the
PDF world spells this, and a caller who writes it means it. The defect was
losing the intent, not receiving it. Covered in `test/pdf/object_test.dart`.

### F6 — a single isolate character poisoned every space in the document
`lib/src/layout/text_engine.dart` (`_clusterSources`)

`Shaper._hideJoiners` hides a surviving default-ignorable by pointing it at the
SPACE glyph and zeroing its metrics — HarfBuzz does the same, and it is correct.
But `ToUnicode` is keyed by GLYPH ID, so one glyph then stood for two things. A
U+2066 that registered first claimed the space glyph **font-wide**, and the CMap
came out with `<0010> <2066>` and no `<0020>` entry at all. Every space in the
document then extracted as U+2066 — including on lines containing no isolate:
`Paid in full` came back as `Paid<U+2066>in<U+2066>full`, `Acme Gateway` as
`Acme<U+2066>Gateway`.

Found in review, which also noted it was recorded nowhere — the engine shipped
a landmine documented only in a caller's comment.

Fixed by stripping default-ignorables from a cluster's ToUnicode sources. That
is independently correct: a joiner is a shaping instruction, not text, and has
no business in what a reader copies out of a receipt. Pinned by
`test/pdf/end_to_end_test.dart` — "one isolate character does not poison every
space in the document".

### F7 — `PayvDocument` had no way to tolerate a missing glyph
`lib/src/api/document.dart`

`onMissingGlyph` existed on the internal `TextEngine` but was unreachable from
the public API, so the only available behaviour was the throw. That default is
right for a library — a silently drawn `.notdef` puts a hole in someone's name
and nobody finds out — but it left a caller with no way to choose otherwise,
and the consequence was measured: a payment method of `中文 카드 😀` produced
**no receipt at all**, which for someone's proof of payment is the worse
failure. Exposed as `PayvDocument.onMissingGlyph`.

### O1 — a mid-paragraph `B` (a plain `\n`) corrupted bidi levels — FIXED
`lib/src/text/bidi.dart`, API at `Bidi.resolve`

`_buildIsolatingRunSequences` skips a level run beginning with a matched PDI,
expecting the run holding the initiator to append it. X8 zeroes `validIsolate`
at a `B`, so the initiator stops being the last character of its run, the append
never fires, and the PDI's run keeps its raw explicit level. Repro:
`LRI B RLE L PDF PDI R` at paragraph level 0 gives
`levels = [0, 0, 0, 2, 2, 0, 0]` — index 6 is a strong R at an **even** level,
which I1/I2 make unreachable. 300k random samples produced 86 such states; with
`B` removed from the alphabet, zero.

UAX #9 P1 says the *caller* splits paragraphs at `B`, which is why the spec never
meets this. But `Bidi.resolve` takes a `List<int>` with no split, no assert and
no splitter anywhere in the package — and `\n` is the commonest character in laid
out text after the space. Even without an isolate, every line after the first
silently inherits paragraph 1's auto-detected direction:
`'Hello\n123 سلام'` resolves paragraph 2 as LTR.

**This one bit any multi-line body text**, which is what `textBox` takes.

Fixed inside `Bidi.resolve` rather than in the text engine, which was the choice
between the two candidates: splitting in the caller would have left the trap
armed for the next caller, and this class takes a flat `List<int>` with nowhere
to express a boundary. `resolve` now runs P1 itself — `_paragraphEnds` splits at
every `B`, each paragraph resolves with its own P2/P3, and run indices are mapped
back into global coordinates so a caller's slices still line up. `CR LF` counts
as one separator. `BidiResult.paragraphs` exposes the split, because
`'Hello\n سلام'` has no single base direction and a caller that aligns text needs
to know that. Pinned by `test/text/bidi_paragraph_test.dart`, including the
original `LRI B RLE L PDF PDI R` reproduction and a 300k-sample sweep for the
strong-R-at-even / strong-L-at-odd invariant.

### O2 — BD13 was tested against post-override types — FIXED
`lib/src/text/bidi.dart`, `_buildIsolatingRunSequences`

`isIsolateInitiator(types[last])` and `types[first] == pdi` read the array X6
already rewrote, so an initiator inside an LRO/RLO scope never linked to its
matching PDI's run, and the two halves of the isolate then resolved against
different sos/eos. Only reachable together with O1, which masked it.

Fixed by reading `initialTypes` at both sites. BD13 is structural — it links a
character to the one that matches it, which is a property of what the character
IS, not of what an enclosing RLO resolved it to.

### O3 — `OS/2` version-tail guard bounded against the file, not the table — FIXED
`lib/src/font/tables/os2.dart`, `lib/src/font/open_type_font.dart`

`ByteReader.canRead` bounds against the whole font, and `OS/2` is never the last
table, so the `hasV1`/`hasV2`/`hasV5` guards always passed — doing exactly what
the code's own comment says it exists to prevent. Demonstrated by flipping
Vazirmatn's version word to 5: `usLowerOpticalPointSize` decoded to **908** from
bytes belonging to `post`. The same path fabricates `sCapHeight` and `sxHeight`
for a v2+ header over an 86-byte body, and those two go straight into the PDF
`/CapHeight` and `/XHeight`.

Closed in two halves, and **the second half is the whole lesson**.
`Os2Table.parse` gained a `tableLength` and `os2_test.dart` proved it worked —
while `OpenTypeFont.os2` went on calling `_lazy(Tag.os2, Os2Table.parse)` without
it. The parameter existed, its doc comment said "PASS IT", it was tested, and it
was never passed, so the fabricated value still reached the descriptor. **Taking
a bound is not the same as being given one**, and a test that constructs the
parser by hand cannot tell the difference.

The facade now owns it: `_sized()` looks the length up from the directory record,
so no caller can forget. `PostTable` and `MaxpTable` had the same defect — `post`
even carried a comment explaining the workaround it needed *because* the table
end "is not knowable from this reader" — and both now take the bound. A 2.0
`post` over a short body read its name index and then its name strings out of the
following table; a 1.0 `maxp` over a 6-byte body read its twelve outline limits
the same way.

Pinned by `test/font/table_bounds_test.dart`, which goes **through
`OpenTypeFont`** and keeps the unbounded call beside each case as the
reproduction. Mutation-checked: reverting the `os2` wiring turns it red.

### O4 — `gvar` deltas were applied to point-matched composite components — FIXED
`lib/src/font/tables/glyf.dart`

A component positioned by point matching must stay pinned to its anchor.
FreeType guards with `if (flags & ARGS_ARE_XY_VALUES)`; HarfBuzz applies the
translation first so the anchor cancels it; fontTools drops it. payv added
`varDx`/`varDy` unconditionally, so an anchored component moved — synthetic repro
showed `xMax` going to 250 where it must stay 200. Accents drifted off their
attachment point as weight moved, worsening with axis distance.

Fixed with FreeType's guard: the delta is added only in the `argsAreXy` branch.
Vazirmatn has no point-matched composites, which is why the parity run was clean
and why the pin needed a font built for it —
`test/font/composite_variation_test.dart` constructs a synthetic variable
composite with one offset component and one point-matched component sharing a
delta, and asserts the first moves and the second stays put, at several points
along the axis.

---

## OPEN

Nothing. Every defect found so far is in FIXED above, with what closed it.

That is not a claim the engine is defect-free — it is a claim that this FILE is
current. What remains genuinely undone is scope rather than defects, and it is
stated in the two places that own it: the gate coverage gaps G1/G2 below, and the
unimplemented surface named in the README — no CFF/CFF2 outlines, no
Indic/Khmer/Myanmar shapers, no PDF/UA structure tree.

---

## Process findings

### P1 — the `glyf` suite cannot fail
`test/font/glyf_test.dart`

Three severe mutations all passed 32/32: removing IUP interpolation entirely
(`_inferDelta` → `return prevDelta`), dropping the tuple scalar's axis
interpolation, and removing the implied on-curve midpoint in `_emitContour` —
the last being the exact failure the file's own comment calls "where most
reimplementations break". The variation tests assert only topology and
inequality. The real evidence — a 5332-outline byte-parity run against
fontTools — was produced by a throwaway harness that was then **deleted**, so
nothing in the repo pins a single varied coordinate.

Fix: rebuild that harness as a checked-in test with a small committed fixture of
expected coordinates, and re-run the three mutations to prove it now fails.

### P2 — `SfntBuilder` has no test
`lib/src/font/table_builder.dart`

Reviewed clean against the spec, but it is the container every subsetted and
instanced font is emitted through and nothing asserts it. Its own header names
the three failure modes — directory sort, padding inside the checksum,
`checkSumAdjustment` ordering — that produce a font which opens on a developer's
Mac and is rejected by a validator.

### P3 — a red test shipped with an invented expectation
`test/font/core_tables_test.dart:61`

`head keeps fontRevision as its raw Fixed word` expects a value that was guessed
rather than read from the font. Needs the real word read out of Vazirmatn.

### P4 — three tests encoded one machine's behaviour as universal — FIXED
`test/pdf/actual_text_test.dart`, `test/pdf/end_to_end_test.dart`

The first CI run this package ever had went red on three `mutool` assertions.
None was a defect in payv: macOS homebrew's MuPDF reverses RTL lines in its text
device, Ubuntu's `mupdf-tools` does not, and **both report version 1.28.2**. The
`/ActualText` measurement table was taken entirely on one machine and its
conclusions about "the one cell we lose" attributed to line content what was
really a build flag.

Fixed by making the mutool assertions direction-agnostic and asserting exact
order only through poppler, which implements UAX #9 properly. The table in
`actual_text_test.dart` now carries the correction rather than the original
claim.

Two things worth keeping from this:

- **An external tool's version string does not identify its behaviour.** Any
  test shelling out to a third-party binary is testing that binary's build as
  much as our output.
- **A green local suite is not a green suite.** 486 tests passed on the dev
  machine for days; the defect existed the whole time and only a second
  environment could see it. This is the argument for CI existing at all, and it
  paid for itself on its first run.

---

## Gate coverage gaps (found by mutation-testing the parity suite)

The HarfBuzz gate was mutation-tested to check it can actually fail. It caught
the transparent-mark mutation immediately (`shadda — shadda between joiners must
not break the join` went red). Two mutations survived, and in both cases the
reason is the **test font**, not the gate:

### G1 — lookup application order is unverified
Reverting `stagedLookups`' `..sort()` (i.e. reintroducing defect F4) leaves the
suite green. Vazirmatn's `arab` feature set happens to be order-insensitive; the
review's reproduction needed a **Urdu** language tag, where `locl` moves relative
to `rlig`/`calt`. Nothing in the corpus uses a non-default LangSys.

### G2 — multi-glyph backtrack matching is unverified
Inverting the index in `matchBacktrack` leaves the suite green. Measured with
fontTools: every chaining-context backtrack array in Vazirmatn has length **0 or
1** (`{0: 10, 1: 2}`), which makes `count - 1 - i` identical to `i`. The mutant
is mathematically equivalent on this font, so this is not an escaped bug — but
the ordering it protects is genuinely untested.

Closing both needs a second test font, or a synthetic one built with fontTools
that has a ≥2-glyph backtrack and a non-default LangSys. Until then, the package
should not claim GSUB type 6 is verified — only that it is verified *as far as
Vazirmatn exercises it*.
