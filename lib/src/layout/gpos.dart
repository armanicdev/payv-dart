/// `GPOS` — the table that decides where each glyph actually sits.
///
/// GSUB picks the glyphs; GPOS is what stops them from colliding. On the
/// Kurdish text this package exists for, that means three things: `kern` closes
/// the gaps between letters, `mark` drops a fatha or a shadda onto the right
/// part of a base glyph, and `mkmk` stacks a second diacritic ON the first
/// instead of on top of it. None of that is reachable by mapping codepoints.
///
/// The engine is HarfBuzz's, and so is the ORDER of the final passes. GPOS
/// records mark attachment as a relative chain rather than as a finished
/// offset, and the chain is resolved once, at the end, after mark advances have
/// been zeroed. Swap those two and every mark drifts by exactly one glyph's
/// advance — a bug that reads as a broken font and is not.
library;

import '../shaping/glyph_buffer.dart';
import '../util/byte_reader.dart';
import 'common.dart';
import 'gpos_subtables.dart';

export 'gpos_subtables.dart'
    show GposApplyContext, GposLookupSource, GposSubtable, LookupRecord;

/// A parsed `GPOS` table.
class GposTable implements GposLookupSource {
  GposTable._(this.layout)
    : _reader = layout.base,
      _subtables = List<List<GposSubtable>?>.filled(
        layout.lookupOffsets.length,
        null,
      );

  /// Parses the `GPOS` table at [r]'s current position.
  ///
  /// Only the ScriptList / FeatureList / LookupList directory is read. Subtables
  /// are parsed the first time a lookup runs, because a font ships kerning for
  /// every script it supports and a Kurdish invoice touches two of them.
  static GposTable parse(ByteReader r) => GposTable._(LayoutTable.parse(r));

  /// The shared script / feature / lookup directory.
  final LayoutTable layout;

  final ByteReader _reader;
  final List<List<GposSubtable>?> _subtables;

  int get lookupCount => layout.lookupOffsets.length;

  /// Effective lookup type of [lookupIndex] — 1..8, never 9.
  ///
  /// An extension lookup reports what it WRAPS, matching [GsubTable]: callers
  /// ask this question to find out what a lookup does, and "9" is not an answer
  /// to that. The type is read out of the first subtable's extension header
  /// rather than by parsing the subtable, so asking is free.
  int lookupType(int lookupIndex) {
    final at = layout.lookupOffsets[lookupIndex];
    final declared = _reader.uint16At(at);
    if (declared != 9 || _reader.uint16At(at + 4) == 0) return declared;
    return _reader.uint16At(at + _reader.uint16At(at + 6) + 2);
  }

  /// The lookup's raw `lookupType` field, extension indirection intact.
  int declaredLookupType(int lookupIndex) =>
      _reader.uint16At(layout.lookupOffsets[lookupIndex]);

  @override
  int lookupFlag(int lookupIndex) =>
      _reader.uint16At(layout.lookupOffsets[lookupIndex] + 2);

  /// The MarkGlyphSets index this lookup filters marks through, or 0.
  ///
  /// It is stored AFTER the subtable offset array, so reading it means reading
  /// the count first — which is why it is a method and not a field.
  @override
  int markFilteringSet(int lookupIndex) {
    final at = layout.lookupOffsets[lookupIndex];
    if (_reader.uint16At(at + 2) & LookupFlag.useMarkFilteringSet == 0) {
      return 0;
    }
    return _reader.uint16At(at + 6 + _reader.uint16At(at + 4) * 2);
  }

  /// The parsed subtables of [lookupIndex], extension indirection resolved.
  List<GposSubtable> subtablesOf(int lookupIndex) {
    final cached = _subtables[lookupIndex];
    if (cached != null) return cached;

    final at = layout.lookupOffsets[lookupIndex];
    final declaredType = _reader.uint16At(at);
    final count = _reader.uint16At(at + 4);

    final out = <GposSubtable>[];
    for (var i = 0; i < count; i++) {
      final subtable = _reader.at(at + _reader.uint16At(at + 6 + i * 2));
      final (type, real) = resolveExtension(
        declaredType,
        subtable,
        extensionType: 9,
      );
      out.add(GposSubtable.parse(type, real));
    }
    return _subtables[lookupIndex] = out;
  }

  // ── application ─────────────────────────────────────────────────────────────

  /// Runs [lookupIndex] over the whole [buffer], left to right.
  ///
  /// [mask] is the feature mask of the pass: a glyph participates only where
  /// `info.mask & mask != 0`. That is how one GPOS run applies a feature that
  /// the shaper enabled for part of the text and not the rest.
  ///
  /// [coords] are normalised variation coordinates; they are needed only to
  /// resolve VariationIndex device tables through [GdefTable.varStore]. [xPpem]
  /// and [yPpem] default to 0 — "unscaled" — which is what makes the output
  /// comparable with HarfBuzz's own unscaled positions, and which also disables
  /// hinting Device deltas exactly as HarfBuzz does at ppem 0.
  ///
  /// Returns true when anything was adjusted.
  bool applyLookup(
    int lookupIndex,
    GlyphBuffer buffer, {
    required int mask,
    GdefTable? gdef,
    List<double>? coords,
    int xPpem = 0,
    int yPpem = 0,
  }) {
    if (lookupIndex < 0 || lookupIndex >= lookupCount) return false;
    final subtables = subtablesOf(lookupIndex);
    if (subtables.isEmpty || buffer.isEmpty) return false;

    final c = GposApplyContext(
      buffer,
      this,
      lookupMask: mask,
      gdef: gdef,
      coords: coords,
      xPpem: xPpem,
      yPpem: yPpem,
    )..setLookupProps(lookupFlag(lookupIndex), markFilteringSet(lookupIndex));

    var applied = false;
    c.index = 0;
    while (c.index < buffer.length) {
      final info = buffer.infos[c.index];
      final before = c.index;
      var didApply = false;
      if (info.mask & mask != 0 && !c.iterator.shouldSkip(info)) {
        didApply = _applyAt(subtables, c);
      }
      if (!didApply) {
        c.index++;
      } else {
        applied = true;
        // A subtable that reports success without moving would spin here
        // forever. No well-formed font does it; a corrupt one must not be able
        // to hang a document export.
        if (c.index <= before) c.index = before + 1;
      }
    }
    return applied;
  }

  /// Applies [lookupIndex] at `c.index` only. First subtable that succeeds wins
  /// — the rest of the lookup is not consulted, which is what makes a lookup's
  /// subtables alternatives rather than a pipeline.
  @override
  bool applyLookupAt(int lookupIndex, GposApplyContext c) {
    if (lookupIndex < 0 || lookupIndex >= lookupCount) return false;
    return _applyAt(subtablesOf(lookupIndex), c);
  }

  static bool _applyAt(List<GposSubtable> subtables, GposApplyContext c) {
    for (final subtable in subtables) {
      if (subtable.apply(c)) return true;
    }
    return false;
  }

  // ── the final passes ────────────────────────────────────────────────────────

  /// Everything that has to happen after the last GPOS lookup, in the one order
  /// that produces HarfBuzz's numbers.
  ///
  /// 1. Zero the advances of GDEF marks.
  /// 2. Zero default-ignorables (ZWJ, ZWNJ, the bidi controls) entirely.
  /// 3. Resolve the attachment chains into absolute offsets.
  /// 4. Reverse an RTL buffer into visual order.
  ///
  /// Steps 1 and 3 are the pair that must not be swapped. Propagation walks the
  /// chain adding up the advances BETWEEN a mark and its base; if a mark still
  /// carries an advance at that point it contributes to its own offset and the
  /// whole stack shifts. HarfBuzz zeroes first, and so does this.
  ///
  /// [adjustOffsetsWhenZeroing] is HarfBuzz's forward-direction-only
  /// compensation: with no GPOS to place it, a zero-width mark should hang back
  /// over the glyph it follows. It is off by default because a font WITH a
  /// working `mark` feature — which is every case this package cares about —
  /// has already placed the mark, and applying it twice moves it.
  static void positionFinish(
    GlyphBuffer buffer, {
    bool zeroMarkAdvances = true,
    bool adjustOffsetsWhenZeroing = false,
    bool zeroDefaultIgnorables = true,
    bool reverseForRtl = true,
  }) {
    if (zeroMarkAdvances) {
      zeroMarkWidths(buffer, adjustOffsets: adjustOffsetsWhenZeroing);
    }
    if (zeroDefaultIgnorables) zeroDefaultIgnorableWidths(buffer);
    propagateAttachments(buffer);
    if (reverseForRtl && buffer.direction == TextDirection.rtl) {
      buffer.reverse();
    }
  }

  /// Zeroes the advance of every glyph GDEF calls a mark.
  ///
  /// By GDEF class, not by "did a lookup attach it": a mark the font failed to
  /// position is still a mark, and letting it carry an advance opens a gap in
  /// the word rather than leaving a misplaced diacritic. That is HarfBuzz's
  /// `zero_mark_widths_by_gdef`, which the Arabic shaper runs late — after GPOS,
  /// so a `mark` lookup that wanted to read the advance still could.
  static void zeroMarkWidths(GlyphBuffer buffer, {bool adjustOffsets = false}) {
    for (var i = 0; i < buffer.length; i++) {
      if (buffer.infos[i].glyphClass != GlyphClass.mark) continue;
      final pos = buffer.positions[i];
      if (adjustOffsets) {
        pos.xOffset -= pos.xAdvance;
        pos.yOffset -= pos.yAdvance;
      }
      pos.xAdvance = 0;
      pos.yAdvance = 0;
    }
  }

  /// Zeroes advance AND offset of the default-ignorable glyphs (ZWJ, ZWNJ, the
  /// bidi controls) that survived shaping.
  ///
  /// They did their job in the joining state machine and in GSUB; they must not
  /// take up space on the page.
  static void zeroDefaultIgnorableWidths(GlyphBuffer buffer) {
    for (var i = 0; i < buffer.length; i++) {
      if (buffer.infos[i].generalCategory != GeneralCategory.format) continue;
      final pos = buffer.positions[i];
      pos.xAdvance = 0;
      pos.yAdvance = 0;
      pos.xOffset = 0;
      pos.yOffset = 0;
    }
  }

  /// Resolves every [GlyphPosition.attachChain] into an absolute offset.
  ///
  /// A mark records where it sits relative to the glyph it attached to, not
  /// relative to the pen. Turning that into a pen-relative offset means adding
  /// the parent's own (already resolved) offset and then cancelling the
  /// advances the pen travelled between them — which is why this is recursive:
  /// a mark on a mark on a base has to see the FINAL position of the mark below
  /// it, not that mark's raw one.
  static void propagateAttachments(GlyphBuffer buffer) {
    for (var i = 0; i < buffer.length; i++) {
      _propagate(buffer, i, GposApplyContext.maxNestingLevel);
    }
  }

  static void _propagate(GlyphBuffer buffer, int i, int nestingLeft) {
    final pos = buffer.positions;
    final chain = pos[i].attachChain;
    final type = pos[i].attachType;
    if (chain == 0) return;

    // Cleared before recursing, so a font whose chains form a cycle terminates
    // instead of overflowing the stack.
    pos[i].attachChain = 0;

    final j = i + chain;
    if (j < 0 || j >= buffer.length) return;
    if (nestingLeft == 0) return;

    _propagate(buffer, j, nestingLeft - 1);

    if (type & GlyphPosition.attachTypeCursive != 0) {
      // Cursive attachment only ever moves a glyph across the baseline; its
      // main-axis position was already settled by adjusting the advances.
      pos[i].yOffset += pos[j].yOffset;
      return;
    }

    pos[i].xOffset += pos[j].xOffset;
    pos[i].yOffset += pos[j].yOffset;

    // The parent is always EARLIER in the buffer, which is still in logical
    // order here — the reverse for RTL has not happened yet. What differs by
    // direction is which advances the pen has already spent when it reaches
    // this glyph.
    if (buffer.direction == TextDirection.rtl) {
      for (var k = j + 1; k <= i; k++) {
        pos[i].xOffset += pos[k].xAdvance;
        pos[i].yOffset += pos[k].yAdvance;
      }
    } else {
      for (var k = j; k < i; k++) {
        pos[i].xOffset -= pos[k].xAdvance;
        pos[i].yOffset -= pos[k].yAdvance;
      }
    }
  }

  @override
  String toString() => 'GposTable($layout)';
}
