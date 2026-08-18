# Why `payv` exists, and why it is shaped this way

> `payv` (پەیڤ) — "word", in Kurdish. Its second letter, ە U+06D5, is one of
> the four this document is about: the ones Unicode never gave a presentation
> form, and which therefore no presentation-form library can place correctly.
> The package is named after its own hardest test case.

This document is the argument for the package. If you are wondering why anyone
would write an OpenType layout engine in Dart in 2026, the short answer is: for
Kurdish, nothing else works, and we measured that rather than assumed it.

---

## 1. The problem, stated precisely

Every pure-Dart PDF library renders Arabic-script text the same way. It walks
the string, decides for each letter whether it is isolated, initial, medial or
final, and swaps in the corresponding **Unicode presentation form** — a
codepoint from the `U+FB50–FDFF` (Arabic Presentation Forms-A) or `U+FE70–FEFF`
(Forms-B) blocks. The font's `cmap` then maps that codepoint to a glyph, and the
glyph is drawn.

This works for Arabic. It works for Persian. For **Kurdish Sorani it cannot
work**, and the reason is architectural, not a missing patch.

The presentation-form blocks were encoded for compatibility with legacy Arabic
and Persian character sets. Four letters that Sorani needs were never in those
character sets, so they have **no presentation forms at all**:

| Letter | Codepoint | Joining type | Forms needed | Forms that exist in Unicode |
|---|---|---|---|---|
| ڕ | `U+0695` | Right-joining | 2 | **0** |
| ڵ | `U+06B5` | Dual-joining | 4 | **0** |
| ە | `U+06D5` | Right-joining | 2 | **0** |
| ێ | `U+06CE` | Dual-joining | 4 | **0** |

`ە` is the most frequent vowel in written Sorani. `ڵ` and `ێ` are dual-joining,
so each needs all four contextual shapes. And there is no `ڵ`+`ا` ligature
codepoint either, though the ligature is required — every Sorani reader expects
`ڵا` to be one connected mark.

A well-made Kurdish font supplies all of these. Vazirmatn, for example, has:

```
gid 474  lamVabove_alef.isol
gid 839  uni06B5.init
gid 896  uni06D5.fina
gid 873  uni06CE.init
```

Those glyphs are in the font. They are simply **not reachable through `cmap`**,
because they have no codepoint to be reached by. They exist only as the *output*
of a `GSUB` lookup. A library that resolves text to glyphs via codepoints is
standing on the wrong side of a wall.

### 1.1 What the failure looks like

Not a missing glyph box. That would be honest. Instead:

- **`syncfusion_flutter_pdf`** drops the letters or renders `.notdef`.
- **`pdf` (the `dart_pdf` package)** falls back to unshaped isolated forms, so
  the word disconnects.
- **`kurdish_sorani_pdf`** — a pub.dev package written specifically to fix
  this — invents mappings onto codepoints that belong to *other letters*:
  `ڕ → U+FB8A`, which is **ژ (jeh)**; `ێ → U+FBE8`, alef maksura;
  `ڵ → U+FBF0`, `.notdef`.

  So `گۆڕینی ڕووکار` ("changing the appearance") renders as
  `گۆژینی ژووکار` — different words, silently, with no error and no warning.

That last one is the dangerous case, and it is the reason this package exists.
On a document someone relies on — an invoice, a contract, a receipt, a
certificate — a substituted letter is not a rendering artifact. It is wrong
information, issued under someone's name and looking entirely correct.

### 1.2 Why "just use a HarfBuzz binding"

It is the right instinct, and we built one: a working `dart:ffi` binding over
15 HarfBuzz symbols, byte-identical to `hb-shape`. It was rejected for
deployment reasons, not correctness:

- **+1.15 MB** for the two Android ABIs alone, before iOS and desktop.
- No web target at all.
- A native build step in every consumer's toolchain, which for a package meant
  to be *adopted* is the difference between "I'll try it" and "no".

A pure-Dart engine has none of those costs and runs everywhere Dart runs —
including a server generating documents with no display, and Flutter Web.

### 1.3 Why not render the text as an image

This is what most Flutter apps do today, and it is defensible: lay the page out
with Flutter's real widgets (Flutter embeds HarfBuzz, so its shaping is
correct), rasterise at 300 dpi, and overlay the logical Unicode in invisible
text-rendering mode (`3 Tr`) so the document is still searchable. We shipped a
pipeline shaped like that before writing this one.

It works. It is also:

- **~230 KB per page** instead of ~10 KB.
- Not scalable — a reader zooming to check a serial number sees pixels.
- Not printable at press resolution without re-rendering.
- Dependent on a live Flutter engine, so no server-side generation.
- Text that *extracts* correctly but is not really *there*. And extraction can
  never prove shaping: an `/ActualText` span can be perfect while the glyphs
  underneath are garbage. It is a claim, not a proof.

Real vector text is the correct artifact. This package produces it.

---

## 2. The architecture

```
  String
    │
    ├─ toScalars ──────────────  UTF-16 → scalars + offset map
    │
    ├─ Bidi (UAX #9) ──────────  embedding levels, isolating run sequences
    │
    ├─ ScriptItemizer ─────────  runs of one script, Common/Inherited resolved
    │
    ├─ ShapingPlan ────────────  script → ordered feature list + per-glyph masks
    │      │
    │      ├─ ArabicShaper ────  joining state machine → isol/init/medi/fina
    │      │
    │      ├─ GSUB ────────────  types 1–8, executed against the font's own
    │      │                     lookups. THIS is what reaches gid 474.
    │      │
    │      └─ GPOS ────────────  types 1–9: kerning, mark-to-base, mark-to-mark,
    │                            cursive attachment
    │
    ├─ Line breaking / alignment
    │
    ├─ Subsetter + Instancer ──  used glyphs only; variable → static
    │
    └─ PDF writer ─────────────  CIDFontType2 / Identity-H, glyph ids in the
                                 content stream, ToUnicode CMap for extraction
```

Three decisions are worth defending.

**Shaping happens in logical order; reversal happens once, at the end.**
`GSUB` context rules are written in logical order. Reversing first matches the
wrong contexts. Both HarfBuzz and this engine shape logically and reverse the
buffer as the final step.

**Everything upstream of the PDF boundary is in font design units.** Integers,
`unitsPerEm`-relative. Scaling once, at the content-stream boundary, keeps
shaping exactly comparable with HarfBuzz's unscaled output — which is what makes
the correctness gate in §3 possible at all.

**RTL text is stored VISUAL in the PDF, not logical.** This one cost us a full
round of measurement to learn. Every PDF text extractor — `pdftotext`, `mutool`,
`pypdf`, Acrobat — assumes a PDF stores glyphs in visual order and runs its own
bidi pass over what it finds. Store logical order and whoever copies the text
gets their Kurdish backwards. All four extractors agreed, which is what
proved the bug was ours.

---

## 3. The correctness gate

An engine like this is easy to write plausibly and hard to write correctly, and
"our Kurdish looks right" is not a claim a reviewer can check. So the package is
graded against **HarfBuzz**, the reference implementation of OpenType shaping.

`tool/gen_harfbuzz_corpus.py` shapes a corpus of probe strings with HarfBuzz and
records the exact glyph ids, clusters and positions into
`test/fixtures/harfbuzz_golden.json`. `test/shaping/harfbuzz_parity_test.dart`
demands byte-exact agreement. Where we differ, we are wrong — there is no second
opinion to appeal to.

The corpus deliberately over-weights the cases that defeat presentation-form
libraries: all four form-less Sorani letters in every joining position, the
`ڵ`+`ا` ligature with no codepoint, the contextual `.long` alternates that need
chaining-context substitution (`GSUB` type 6), transparent-class diacritics
between joiners, ZWJ-forced forms, and mixed-direction strings with both
Arabic-Indic and Western digits.

Current corpus: **53 cases, 371 glyphs, 16 distinct GSUB-only glyphs.**

Two things this gate deliberately does *not* rely on:

- **Text extraction.** It proves the `ToUnicode` CMap, nothing about shaping.
- **Visual inspection.** A human cannot tell `uni06B5.medi` from
  `uni06B5.init` at 10 pt, and that is exactly the class of error that ships.

---

## 4. Scope, and what is deliberately absent

**In scope.** OpenType `GSUB` 1–8 and `GPOS` 1–9; the Arabic joining shaper;
UAX #9 bidi; TrueType (`glyf`) outlines; variable-font instancing; subsetting;
PDF 1.7 output with embedded CIDFontType2 fonts.

**Not implemented, on purpose.**

- **CFF/CFF2 outlines.** Vazirmatn and most libre Arabic faces are `glyf`.
  A CFF charstring interpreter is a self-contained addition; the seams are
  there for it (`GlyfTable` is reached only through `OpenTypeFont.glyf`).
- **Indic, Khmer, Myanmar, Hangul shapers.** These need their own reordering
  engines. The default and Arabic shapers are implemented; the plan structure
  accepts more.
- **`stch` stretching**, which needs a justification pass.
- **Tagged PDF / PDF/UA.** The document is searchable and selectable but has no
  structure tree, so a screen reader gets unordered text. This is the largest
  known gap and the most likely next piece of work.
- **Encryption, forms, annotations beyond links.**

---

## 5. Prior art, and why each was not enough

| Project | Language | Kurdish Sorani | Why not |
|---|---|---|---|
| HarfBuzz | C++ | ✅ correct | Native binary; no web; +1.15 MB per ABI pair |
| `pdf` / `dart_pdf` | Dart | ❌ | Presentation-form mapping |
| `syncfusion_flutter_pdf` | Dart | ❌ | Presentation-form mapping; licence excludes us |
| `kurdish_sorani_pdf` | Dart | ❌ **wrong letters** | Maps ڕ onto ژ's codepoint |
| `arabic_reshaper` ports | Dart/Py | ❌ | Presentation-form mapping by definition |
| `printing` (platform) | Dart+native | ⚠️ | Quartz emits presentation forms in `ToUnicode`; ڵ+ا extracts as ASCII `5` |
| fontTools/ReportLab | Python | ✅ | Not Dart; not embeddable in a Flutter app |

To the best of our knowledge, `payv` is the first OpenType layout implementation
in Dart, and the first PDF generator in any language that treats Kurdish Sorani
as a first-class script rather than as Arabic with extra letters.

If you know of prior art we missed, please open an issue — we would rather be
second and correct than first and wrong.
