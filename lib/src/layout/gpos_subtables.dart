/// The nine `GPOS` lookup types, and the apply context they share.
///
/// Every class here is a THIN view over the font bytes: a subtable holds its
/// absolute base offset and reads fields on demand. That is not premature
/// optimisation — a mark-to-base subtable in a large Arabic family is an anchor
/// matrix of thousands of entries, of which shaping one line touches two, and
/// materialising it would cost more than the whole rest of the parse.
///
/// The behaviour is HarfBuzz's, deliberately down to the details that look like
/// bugs and are not: a horizontal run IGNORES a ValueRecord's `yAdvance`, a
/// PairPos advances the cursor PAST the second glyph only when `valueFormat2`
/// is non-empty, and mark attachment records a relative [GlyphPosition.attachChain]
/// instead of baking the base's offset in. Those three are the difference
/// between byte-exact parity and "close".
library;

import '../shaping/glyph_buffer.dart';
import '../util/byte_reader.dart';
import 'common.dart';

/// "At input position [sequenceIndex], run lookup [lookupListIndex]."
///
/// The unit of every contextual rule. The records are applied in the order the
/// font lists them, which is NOT sorted by [sequenceIndex] — a font may legally
/// position glyph 2 before glyph 0.
class LookupRecord {
  const LookupRecord(this.sequenceIndex, this.lookupListIndex);

  final int sequenceIndex;
  final int lookupListIndex;
}

/// Matches one buffer glyph against one entry of a rule's input array.
///
/// The `data` is whatever the rule format stores per position: a glyph id
/// (format 1), a class (format 2), or an offset to a Coverage table (format 3).
typedef GposMatcher = bool Function(GlyphInfo info, int data);

/// What [GposApplyContext] needs from the table that owns it, so that a
/// contextual subtable can recurse into another lookup without this file
/// importing `gpos.dart` back.
abstract interface class GposLookupSource {
  /// Applies lookup [lookupIndex] at [GposApplyContext.index] only — the first
  /// subtable that succeeds wins, exactly as `Lookup::dispatch` does.
  bool applyLookupAt(int lookupIndex, GposApplyContext c);

  int lookupFlag(int lookupIndex);

  int markFilteringSet(int lookupIndex);
}

/// The mutable state one GPOS pass carries: where it is, what it is blind to,
/// and how deep it has recursed.
class GposApplyContext {
  GposApplyContext(
    this.buffer,
    this.source, {
    required this.lookupMask,
    this.gdef,
    this.coords,
    this.xPpem = 0,
    this.yPpem = 0,
  });

  /// HarfBuzz's `HB_MAX_NESTING_LEVEL`. A font can chain contextual lookups
  /// into each other, and a hostile (or merely broken) one can make that a
  /// cycle; the depth cap is the only thing standing between a document export
  /// and a stack overflow.
  static const int maxNestingLevel = 64;

  final GlyphBuffer buffer;
  final GposLookupSource source;

  /// Feature mask of the pass. A glyph participates only where
  /// `info.mask & lookupMask != 0`, which is how one GPOS run applies features
  /// that were switched on for different spans of the text.
  final int lookupMask;

  final GdefTable? gdef;

  /// Normalised variation coordinates, for VariationIndex device resolution.
  final List<double>? coords;

  /// Device-table resolution ppem. Zero — the default — means "unscaled", and
  /// then hinting Device deltas contribute nothing, which is what HarfBuzz
  /// does at `x_ppem == 0` and what makes our design-unit output comparable
  /// with its own.
  final int xPpem;
  final int yPpem;

  /// Cursor. Subtables advance it themselves; the driver only advances it when
  /// nothing applied.
  int index = 0;

  int _lookupFlag = 0;
  int _markFilteringSet = 0;
  int _nestingLeft = maxNestingLevel;
  SkippyIterator? _iter;

  int get lookupFlag => _lookupFlag;

  int get markFilteringSet => _markFilteringSet;

  /// True when the run is laid out along x. [TextDirection] has no vertical
  /// member, so this is constant — but the ValueRecord and cursive code below
  /// branches on it anyway, because that branch is exactly where a future
  /// vertical mode would land and silently getting it wrong is how `yAdvance`
  /// bugs are born.
  bool get isHorizontal => true;

  bool get isBackward => buffer.direction == TextDirection.rtl;

  void setLookupProps(int flag, int filteringSet) {
    _lookupFlag = flag;
    _markFilteringSet = filteringSet;
    _iter = null;
  }

  /// The iterator for the CURRENT lookup's flags.
  SkippyIterator get iterator => _iter ??= iteratorFor(_lookupFlag);

  /// An iterator for a modified flag word. Mark-to-base and mark-to-ligature
  /// search backwards with `IgnoreMarks` forced on regardless of what the
  /// lookup declared, and mark-to-mark with every `Ignore*` bit forced off; both
  /// need an iterator that is not the lookup's own.
  SkippyIterator iteratorFor(int flag) => SkippyIterator(
    buffer,
    lookupFlag: flag,
    markFilteringSet: _markFilteringSet,
    gdef: gdef,
  );

  /// Runs another lookup at [index], with that lookup's own flags in force.
  ///
  /// The flags are saved and restored around the call: a contextual lookup that
  /// ignores marks may perfectly well invoke one that does not, and leaking the
  /// caller's flags into the callee misplaces every mark the callee touches.
  bool recurse(int lookupIndex) {
    if (_nestingLeft == 0) return false;
    final savedFlag = _lookupFlag;
    final savedSet = _markFilteringSet;
    _nestingLeft--;
    setLookupProps(
      source.lookupFlag(lookupIndex),
      source.markFilteringSet(lookupIndex),
    );
    final ret = source.applyLookupAt(lookupIndex, this);
    setLookupProps(savedFlag, savedSet);
    _nestingLeft++;
    return ret;
  }

  // ── matching ────────────────────────────────────────────────────────────────
  //
  // HarfBuzz's skipping iterator answers three things, not two: MATCH,
  // NOT_MATCH, and SKIP. The third state is what makes ZWJ transparent — a
  // default-ignorable that fails the match is stepped over rather than failing
  // the rule. Collapse it to a boolean and every kern pair separated by a ZWJ
  // silently stops kerning.

  static const int _matchYes = 0;
  static const int _matchNo = 1;
  static const int _matchMaybe = 2;

  /// True for the characters HarfBuzz calls default-ignorable. `Cf` is the
  /// class that matters here (ZWJ, ZWNJ, the bidi controls); GPOS ignores all
  /// of them, because `table_index == 1` forces both `ignore_zwnj` and
  /// `ignore_zwj` on.
  static bool _isDefaultIgnorable(GlyphInfo info) =>
      info.generalCategory == GeneralCategory.format;

  int _matchOf(GlyphInfo info, bool useMask, GposMatcher? match, int data) {
    // The mask is part of MATCHING, not of skipping: a glyph the feature was
    // not enabled for BREAKS the rule rather than being stepped over.
    if (useMask && info.mask & lookupMask == 0) return _matchNo;
    if (match == null) return _matchMaybe;
    return match(info, data) ? _matchYes : _matchNo;
  }

  /// Next index after [from] that matches, or -1.
  ///
  /// [useMask] is false for backtrack and lookahead: HarfBuzz builds its
  /// context iterator with `mask = -1`, so surrounding glyphs qualify whether or
  /// not the feature was enabled on them.
  int nextMatch(
    SkippyIterator it,
    int from, {
    bool useMask = true,
    GposMatcher? match,
    int data = 0,
  }) {
    var i = from;
    while (true) {
      i = it.next(i);
      if (i < 0) return -1;
      final info = buffer.infos[i];
      final m = _matchOf(info, useMask, match, data);
      final maybeSkip = _isDefaultIgnorable(info);
      if (m == _matchYes || (m == _matchMaybe && !maybeSkip)) return i;
      if (!maybeSkip) return -1;
    }
  }

  /// Previous index before [from] that matches, or -1.
  int prevMatch(
    SkippyIterator it,
    int from, {
    bool useMask = true,
    GposMatcher? match,
    int data = 0,
  }) {
    var i = from;
    while (true) {
      i = it.prev(i);
      if (i < 0) return -1;
      final info = buffer.infos[i];
      final m = _matchOf(info, useMask, match, data);
      final maybeSkip = _isDefaultIgnorable(info);
      if (m == _matchYes || (m == _matchMaybe && !maybeSkip)) return i;
      if (!maybeSkip) return -1;
    }
  }

  // ── device and anchor resolution ────────────────────────────────────────────

  /// A Device or VariationIndex delta, in design units.
  int deviceDelta(Device d, {required bool vertical}) {
    if (d.isVariationIndex) {
      // A VariationIndex carries no deltas of its own — it is a pointer into
      // GDEF's ItemVariationStore, and without coordinates there is nothing to
      // evaluate it at.
      final store = gdef?.varStore;
      final co = coords;
      if (store == null || co == null || co.isEmpty) return 0;
      return store.delta(d.deltaSetOuter, d.deltaSetInner, co).round();
    }
    final ppem = vertical ? yPpem : xPpem;
    return ppem == 0 ? 0 : d.valueAt(ppem);
  }

  /// An anchor's coordinates with its device adjustments applied.
  ///
  /// A format 2 anchor's `contourPoint` is deliberately not resolved: HarfBuzz
  /// only consults the outline when a ppem is set, and at ppem 0 it returns the
  /// bare coordinates — which is exactly what happens here.
  (int, int) anchorPoint(Anchor a) {
    var x = a.x;
    var y = a.y;
    final xd = a.xDevice;
    if (xd != null) x += deviceDelta(xd, vertical: false);
    final yd = a.yDevice;
    if (yd != null) y += deviceDelta(yd, vertical: true);
    return (x, y);
  }
}

/// One parsed GPOS subtable.
abstract class GposSubtable {
  const GposSubtable();

  /// Applies at `c.index`. Returns true — and leaves `c.index` advanced — when
  /// it did something.
  bool apply(GposApplyContext c);

  /// Parses the subtable of [type] at [r]'s position. Extension subtables have
  /// already been resolved by the caller.
  static GposSubtable parse(int type, ByteReader r) {
    final base = r.position;
    final format = r.uint16At(base);
    switch (type) {
      case 1:
        return SinglePos.parse(r, base, format);
      case 2:
        return PairPos.parse(r, base, format);
      case 3:
        return CursivePos.parse(r, base, format);
      case 4:
        return MarkBasePos.parse(r, base, format);
      case 5:
        return MarkLigPos.parse(r, base, format);
      case 6:
        return MarkMarkPos.parse(r, base, format);
      case 7:
        return ContextPos.parse(r, base, format);
      case 8:
        return ChainContextPos.parse(r, base, format);
      default:
        throw FontFormatException('unknown GPOS lookup type $type');
    }
  }
}

// ── ValueRecord application ───────────────────────────────────────────────────

/// Adds the ValueRecord at [at] (under [format]) to [pos].
///
/// [deviceBase] is what the record's Device offsets are measured from, and it
/// is NOT always the subtable: in a PairPos format 1 it is the PairSet, which is
/// what HarfBuzz uses and therefore what a font tested against HarfBuzz encodes.
///
/// The `yAdvance` field is read and DISCARDED in a horizontal run. That is the
/// spec's rule and HarfBuzz's code, and it is the single easiest place to
/// produce a plausible, wrong number: a font that ships `yAdvance` for its
/// vertical mode would tilt every line if the value were honoured here.
void applyValueRecord(
  GposApplyContext c,
  ByteReader r,
  int deviceBase,
  int at,
  int format,
  GlyphPosition pos,
) {
  if (format == 0) return;
  var p = at;

  int nextShort() {
    final v = r.int16At(p);
    p += 2;
    return v;
  }

  if (format & ValueFormat.xPlacement != 0) pos.xOffset += nextShort();
  if (format & ValueFormat.yPlacement != 0) pos.yOffset += nextShort();
  if (format & ValueFormat.xAdvance != 0) {
    if (c.isHorizontal) {
      pos.xAdvance += r.int16At(p);
    }
    p += 2;
  }
  if (format & ValueFormat.yAdvance != 0) {
    // Vertical only, and negated when it applies: y advances grow downward in
    // layout and upward in font space.
    if (!c.isHorizontal) pos.yAdvance -= r.int16At(p);
    p += 2;
  }

  if (format & ValueFormat.deviceMask == 0) return;

  // HarfBuzz skips the device pass entirely when there is neither a ppem nor a
  // variation instance to resolve against, and so do we — parsing four Device
  // tables per glyph to add zero is the kind of cost that only shows up on a
  // 40-page document.
  final varying = c.coords?.isNotEmpty ?? false;
  final useX = c.xPpem != 0 || varying;
  final useY = c.yPpem != 0 || varying;
  if (!useX && !useY) return;

  int nextOffset() {
    final v = r.uint16At(p);
    p += 2;
    return v;
  }

  if (format & ValueFormat.xPlacementDevice != 0) {
    final o = nextOffset();
    if (useX && o != 0) {
      pos.xOffset += c.deviceDelta(
        Device.parse(r.at(deviceBase + o)),
        vertical: false,
      );
    }
  }
  if (format & ValueFormat.yPlacementDevice != 0) {
    final o = nextOffset();
    if (useY && o != 0) {
      pos.yOffset += c.deviceDelta(
        Device.parse(r.at(deviceBase + o)),
        vertical: true,
      );
    }
  }
  if (format & ValueFormat.xAdvanceDevice != 0) {
    final o = nextOffset();
    if (c.isHorizontal && useX && o != 0) {
      pos.xAdvance += c.deviceDelta(
        Device.parse(r.at(deviceBase + o)),
        vertical: false,
      );
    }
  }
  if (format & ValueFormat.yAdvanceDevice != 0) {
    final o = nextOffset();
    if (!c.isHorizontal && useY && o != 0) {
      pos.yAdvance -= c.deviceDelta(
        Device.parse(r.at(deviceBase + o)),
        vertical: true,
      );
    }
  }
}

// ── type 1: single adjustment ─────────────────────────────────────────────────

/// Lookup type 1 — one ValueRecord applied to every covered glyph (format 1),
/// or one per coverage index (format 2).
class SinglePos extends GposSubtable {
  SinglePos._(
    this._r,
    this._base,
    this._coverage,
    this._valueFormat,
    this._one,
  );

  static SinglePos parse(ByteReader r, int base, int format) {
    final coverage = Coverage.parse(r.at(base + r.uint16At(base + 2)));
    final valueFormat = r.uint16At(base + 4);
    switch (format) {
      case 1:
        return SinglePos._(r, base, coverage, valueFormat, true);
      case 2:
        return SinglePos._(r, base, coverage, valueFormat, false);
      default:
        throw FontFormatException('unknown SinglePos format $format');
    }
  }

  final ByteReader _r;
  final int _base;
  final Coverage _coverage;
  final int _valueFormat;

  /// Format 1 shares one record; format 2 indexes an array by coverage index.
  final bool _one;

  @override
  bool apply(GposApplyContext c) {
    final index = _coverage.index(c.buffer.infos[c.index].glyphId);
    if (index < 0) return false;

    final int at;
    if (_one) {
      at = _base + 6;
    } else {
      if (index >= _r.uint16At(_base + 6)) return false;
      at = _base + 8 + index * ValueRecord.sizeOf(_valueFormat);
    }
    applyValueRecord(
      c,
      _r,
      _base,
      at,
      _valueFormat,
      c.buffer.positions[c.index],
    );
    c.index++;
    return true;
  }
}

// ── type 2: pair adjustment (kerning) ─────────────────────────────────────────

/// Lookup type 2 — the pair adjustment that carries almost all kerning.
///
/// Both ValueRecords are variable-length, and their sizes come from
/// `valueFormat1`/`valueFormat2` via a popcount. Assuming a stride is the
/// classic way to read this table wrong: a font with `xAdvance` only has a
/// 2-byte record, one with placement and advance has 8, and there is nothing in
/// the array itself to tell them apart.
class PairPos extends GposSubtable {
  PairPos._(
    this._r,
    this._base,
    this._coverage,
    this._format1,
    this._format2,
    this._format,
    this._classDef1,
    this._classDef2,
    this._class1Count,
    this._class2Count,
  );

  static PairPos parse(ByteReader r, int base, int format) {
    final coverage = Coverage.parse(r.at(base + r.uint16At(base + 2)));
    final format1 = r.uint16At(base + 4);
    final format2 = r.uint16At(base + 6);
    switch (format) {
      case 1:
        return PairPos._(
          r,
          base,
          coverage,
          format1,
          format2,
          1,
          null,
          null,
          0,
          0,
        );
      case 2:
        final c1 = r.uint16At(base + 8);
        final c2 = r.uint16At(base + 10);
        return PairPos._(
          r,
          base,
          coverage,
          format1,
          format2,
          2,
          c1 == 0 ? ClassDef.empty : ClassDef.parse(r.at(base + c1)),
          c2 == 0 ? ClassDef.empty : ClassDef.parse(r.at(base + c2)),
          r.uint16At(base + 12),
          r.uint16At(base + 14),
        );
      default:
        throw FontFormatException('unknown PairPos format $format');
    }
  }

  final ByteReader _r;
  final int _base;
  final Coverage _coverage;
  final int _format1;
  final int _format2;
  final int _format;
  final ClassDef? _classDef1;
  final ClassDef? _classDef2;
  final int _class1Count;
  final int _class2Count;

  @override
  bool apply(GposApplyContext c) {
    final first = c.index;
    if (_coverage.index(c.buffer.infos[first].glyphId) < 0) return false;

    final second = c.nextMatch(c.iterator, first);
    if (second < 0) return false;

    final len1 = ValueRecord.sizeOf(_format1);
    final len2 = ValueRecord.sizeOf(_format2);

    final int at;
    final int deviceBase;
    if (_format == 1) {
      final index = _coverage.index(c.buffer.infos[first].glyphId);
      final pairSet = _base + _r.uint16At(_base + 10 + index * 2);
      final record = _findPair(
        pairSet,
        c.buffer.infos[second].glyphId,
        len1 + len2,
      );
      if (record < 0) return false;
      at = record + 2;
      // The PairSet, not the PairPos: HarfBuzz resolves a PairPos format 1
      // device offset against the PairSet it was found in, and a font tuned
      // against HarfBuzz encodes it that way.
      deviceBase = pairSet;
    } else {
      final class1 = _classDef1!.classOf(c.buffer.infos[first].glyphId);
      final class2 = _classDef2!.classOf(c.buffer.infos[second].glyphId);
      if (class1 >= _class1Count || class2 >= _class2Count) return false;
      at = _base + 16 + (class1 * _class2Count + class2) * (len1 + len2);
      deviceBase = _base;
    }

    applyValueRecord(
      c,
      _r,
      deviceBase,
      at,
      _format1,
      c.buffer.positions[first],
    );
    applyValueRecord(
      c,
      _r,
      deviceBase,
      at + len1,
      _format2,
      c.buffer.positions[second],
    );

    // The cursor lands ON the second glyph when only the first was adjusted, and
    // PAST it when the second was too. Both are deliberate: a font that kerns
    // A→B and B→C wants B considered again as a first glyph, unless B has
    // already been adjusted as a second one.
    c.index = len2 != 0 ? second + 1 : second;
    return true;
  }

  /// Binary-searches a PairSet's PairValueRecords for [glyphId], returning the
  /// record's absolute offset or -1.
  int _findPair(int pairSet, int glyphId, int valuesSize) {
    final count = _r.uint16At(pairSet);
    final stride = 2 + valuesSize;
    var lo = 0;
    var hi = count - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final at = pairSet + 2 + mid * stride;
      final g = _r.uint16At(at);
      if (glyphId < g) {
        hi = mid - 1;
      } else if (glyphId > g) {
        lo = mid + 1;
      } else {
        return at;
      }
    }
    return -1;
  }
}

// ── type 3: cursive attachment ────────────────────────────────────────────────

/// Lookup type 3 — cursive attachment: this glyph's exit anchor meets the next
/// glyph's entry anchor.
///
/// [LookupFlag.rightToLeft] decides which of the two keeps its advance, and it
/// is NOT the same question as the run's direction. Getting it backwards makes
/// a Nastaliq-style font's letters slide along the baseline in the wrong
/// direction — visually obvious, and impossible to debug from the glyph ids
/// alone, since they are all correct.
class CursivePos extends GposSubtable {
  CursivePos._(this._r, this._base, this._coverage);

  static CursivePos parse(ByteReader r, int base, int format) {
    if (format != 1) {
      throw FontFormatException('unknown CursivePos format $format');
    }
    return CursivePos._(
      r,
      base,
      Coverage.parse(r.at(base + r.uint16At(base + 2))),
    );
  }

  final ByteReader _r;
  final int _base;
  final Coverage _coverage;

  int _entryAnchorOffset(int index) => _r.uint16At(_base + 6 + index * 4);

  int _exitAnchorOffset(int index) => _r.uint16At(_base + 6 + index * 4 + 2);

  @override
  bool apply(GposApplyContext c) {
    final i = c.index;
    final thisIndex = _coverage.index(c.buffer.infos[i].glyphId);
    if (thisIndex < 0) return false;
    final exitOffset = _exitAnchorOffset(thisIndex);
    if (exitOffset == 0) return false;

    final j = c.nextMatch(c.iterator, i);
    if (j < 0) return false;
    final nextIndex = _coverage.index(c.buffer.infos[j].glyphId);
    if (nextIndex < 0) return false;
    final entryOffset = _entryAnchorOffset(nextIndex);
    if (entryOffset == 0) return false;

    final (exitX, exitY) = c.anchorPoint(
      Anchor.parse(_r.at(_base + exitOffset)),
    );
    final (entryX, entryY) = c.anchorPoint(
      Anchor.parse(_r.at(_base + entryOffset)),
    );

    final pos = c.buffer.positions;

    // Main-direction adjustment: whichever glyph is "behind" in the reading
    // order surrenders the space between the two anchors.
    if (c.isBackward) {
      final d = exitX + pos[i].xOffset;
      pos[i].xAdvance -= d;
      pos[i].xOffset -= d;
      pos[j].xAdvance = entryX + pos[j].xOffset;
    } else {
      pos[i].xAdvance = exitX + pos[i].xOffset;
      final d = entryX + pos[j].xOffset;
      pos[j].xAdvance -= d;
      pos[j].xOffset -= d;
    }

    // Cross-direction: a rooted tree, where the root stays on the baseline and
    // each node aligns against its parent. RightToLeft flips which end of the
    // pair is the root.
    var child = i;
    var parent = j;
    var yOffset = entryY - exitY;
    if (c.lookupFlag & LookupFlag.rightToLeft == 0) {
      child = j;
      parent = i;
      yOffset = -yOffset;
    }

    // If the child was already hanging off someone else, that whole chain has
    // to be re-rooted at the new parent — otherwise two cursive lookups in
    // sequence leave a cycle, and offset propagation never terminates.
    _reverseMinorOffset(pos, child, parent);

    pos[child].attachType = GlyphPosition.attachTypeCursive;
    pos[child].attachChain = parent - child;
    pos[child].yOffset = yOffset;

    // And if the parent was attached to the child, they are now each other's
    // parent. Break the shorter link.
    if (pos[parent].attachChain == -pos[child].attachChain) {
      pos[parent].attachChain = 0;
    }

    c.index++;
    return true;
  }

  static void _reverseMinorOffset(
    List<GlyphPosition> pos,
    int i,
    int newParent,
  ) {
    final chain = pos[i].attachChain;
    final type = pos[i].attachType;
    if (chain == 0 || type & GlyphPosition.attachTypeCursive == 0) return;

    pos[i].attachChain = 0;
    final j = i + chain;
    if (j == newParent) return;
    if (j < 0 || j >= pos.length) return;

    _reverseMinorOffset(pos, j, newParent);
    pos[j].yOffset = -pos[i].yOffset;
    pos[j].attachChain = -chain;
    pos[j].attachType = type;
  }
}

// ── mark arrays ───────────────────────────────────────────────────────────────

/// A `MarkArray`: per covered mark, its class and its attachment anchor.
class _MarkArray {
  const _MarkArray(this._r, this._base);

  final ByteReader _r;
  final int _base;

  int classOf(int markIndex) => _r.uint16At(_base + 2 + markIndex * 4);

  /// The mark's own anchor. A NULL offset means the origin, which is what
  /// HarfBuzz's null-object dereference yields.
  Anchor anchorOf(int markIndex) {
    final o = _r.uint16At(_base + 2 + markIndex * 4 + 2);
    return o == 0 ? Anchor(x: 0, y: 0) : Anchor.parse(_r.at(_base + o));
  }
}

/// A `BaseArray` / `Mark2Array` / `LigatureAttach` — all three are the same
/// structure: a row count followed by `rows × markClassCount` anchor offsets.
class _AnchorMatrix {
  const _AnchorMatrix(this._r, this._base);

  final ByteReader _r;
  final int _base;

  int get rows => _r.uint16At(_base);

  /// Null when the row/column is out of range OR the offset is NULL. The
  /// distinction matters: a NULL anchor makes the whole subtable decline, so
  /// that a later subtable in the same lookup still gets its chance.
  Anchor? anchor(int row, int col, int cols) {
    if (row < 0 || col < 0 || col >= cols || row >= rows) return null;
    final o = _r.uint16At(_base + 2 + (row * cols + col) * 2);
    return o == 0 ? null : Anchor.parse(_r.at(_base + o));
  }
}

/// Places the mark at `c.index` against [target], recording the attachment as a
/// RELATIVE chain rather than a baked-in offset.
///
/// The relative chain is the whole trick behind stacked diacritics: a mark
/// attached to a mark attached to a base is resolved once, at the end, by
/// walking the chain — so the second mark inherits the first one's final
/// position instead of the base's.
bool _attachMark(
  GposApplyContext c,
  _MarkArray marks,
  int markIndex,
  Anchor? target,
  int targetPos,
) {
  if (target == null) return false;

  final (markX, markY) = c.anchorPoint(marks.anchorOf(markIndex));
  final (baseX, baseY) = c.anchorPoint(target);

  final pos = c.buffer.positions[c.index];
  pos.xOffset = baseX - markX;
  pos.yOffset = baseY - markY;
  pos.attachType = GlyphPosition.attachTypeMark;
  pos.attachChain = targetPos - c.index;

  c.index++;
  return true;
}

// ── type 4: mark-to-base ──────────────────────────────────────────────────────

/// Lookup type 4 — a mark attached to the preceding base glyph.
class MarkBasePos extends GposSubtable {
  MarkBasePos._(
    this._markCoverage,
    this._baseCoverage,
    this._classCount,
    this._marks,
    this._bases,
  );

  static MarkBasePos parse(ByteReader r, int base, int format) {
    if (format != 1) {
      throw FontFormatException('unknown MarkBasePos format $format');
    }
    return MarkBasePos._(
      Coverage.parse(r.at(base + r.uint16At(base + 2))),
      Coverage.parse(r.at(base + r.uint16At(base + 4))),
      r.uint16At(base + 6),
      _MarkArray(r, base + r.uint16At(base + 8)),
      _AnchorMatrix(r, base + r.uint16At(base + 10)),
    );
  }

  final Coverage _markCoverage;
  final Coverage _baseCoverage;
  final int _classCount;
  final _MarkArray _marks;
  final _AnchorMatrix _bases;

  @override
  bool apply(GposApplyContext c) {
    final markIndex = _markCoverage.index(c.buffer.infos[c.index].glyphId);
    if (markIndex < 0) return false;

    // The search back for the base ALWAYS ignores marks, whatever the lookup's
    // own flags say. Otherwise the second diacritic of a stack would attach to
    // the first one through a mark-to-BASE lookup and land in the wrong place.
    final it = c.iteratorFor(LookupFlag.ignoreMarks);
    var j = c.index;
    while (true) {
      j = c.prevMatch(it, j);
      if (j < 0) return false;
      final info = c.buffer.infos[j];
      // Only the FIRST glyph of a multiple-substitution sequence is a legal
      // attachment point — unless the font explicitly covers the later one.
      if (!info.multipliedAdvance ||
          info.ligatureComponent == 0 ||
          _baseCoverage.covers(info.glyphId)) {
        break;
      }
    }

    final baseIndex = _baseCoverage.index(c.buffer.infos[j].glyphId);
    if (baseIndex < 0) return false;

    return _attachMark(
      c,
      _marks,
      markIndex,
      _bases.anchor(baseIndex, _marks.classOf(markIndex), _classCount),
      j,
    );
  }
}

// ── type 5: mark-to-ligature ──────────────────────────────────────────────────

/// Lookup type 5 — a mark attached to one COMPONENT of a ligature.
///
/// Which component comes from the mark's own [GlyphInfo.ligatureComponent],
/// which GSUB type 4 stamped on it when it built the ligature. That is why the
/// two engines share a buffer model: throw the component away in GSUB and this
/// lookup can only ever attach to the last component, which for `لله` puts the
/// shadda over the wrong letter.
class MarkLigPos extends GposSubtable {
  MarkLigPos._(
    this._r,
    this._markCoverage,
    this._ligCoverage,
    this._classCount,
    this._marks,
    this._ligArray,
  );

  static MarkLigPos parse(ByteReader r, int base, int format) {
    if (format != 1) {
      throw FontFormatException('unknown MarkLigPos format $format');
    }
    return MarkLigPos._(
      r,
      Coverage.parse(r.at(base + r.uint16At(base + 2))),
      Coverage.parse(r.at(base + r.uint16At(base + 4))),
      r.uint16At(base + 6),
      _MarkArray(r, base + r.uint16At(base + 8)),
      base + r.uint16At(base + 10),
    );
  }

  final ByteReader _r;
  final Coverage _markCoverage;
  final Coverage _ligCoverage;
  final int _classCount;
  final _MarkArray _marks;

  /// Absolute offset of the LigatureArray.
  final int _ligArray;

  @override
  bool apply(GposApplyContext c) {
    final markIndex = _markCoverage.index(c.buffer.infos[c.index].glyphId);
    if (markIndex < 0) return false;

    final it = c.iteratorFor(LookupFlag.ignoreMarks);
    final j = c.prevMatch(it, c.index);
    if (j < 0) return false;

    final ligIndex = _ligCoverage.index(c.buffer.infos[j].glyphId);
    if (ligIndex < 0) return false;
    if (ligIndex >= _r.uint16At(_ligArray)) return false;

    final attach = _AnchorMatrix(
      _r,
      _ligArray + _r.uint16At(_ligArray + 2 + ligIndex * 2),
    );
    final componentCount = attach.rows;
    if (componentCount == 0) return false;

    final mark = c.buffer.infos[c.index];
    final lig = c.buffer.infos[j];
    final int component;
    if (lig.ligatureId != 0 &&
        lig.ligatureId == mark.ligatureId &&
        mark.ligatureComponent > 0) {
      final n = mark.ligatureComponent;
      component = (n < componentCount ? n : componentCount) - 1;
    } else {
      // A mark that is not part of this ligature hangs off its last component —
      // the spec's fallback, and the only one that keeps a stray diacritic
      // inside the ligature's ink.
      component = componentCount - 1;
    }

    return _attachMark(
      c,
      _marks,
      markIndex,
      attach.anchor(component, _marks.classOf(markIndex), _classCount),
      j,
    );
  }
}

// ── type 6: mark-to-mark ──────────────────────────────────────────────────────

/// Lookup type 6 — a mark attached to another mark. This is what stacks two
/// Arabic diacritics instead of drawing them on top of each other.
class MarkMarkPos extends GposSubtable {
  MarkMarkPos._(
    this._mark1Coverage,
    this._mark2Coverage,
    this._classCount,
    this._mark1s,
    this._mark2s,
  );

  static MarkMarkPos parse(ByteReader r, int base, int format) {
    if (format != 1) {
      throw FontFormatException('unknown MarkMarkPos format $format');
    }
    return MarkMarkPos._(
      Coverage.parse(r.at(base + r.uint16At(base + 2))),
      Coverage.parse(r.at(base + r.uint16At(base + 4))),
      r.uint16At(base + 6),
      _MarkArray(r, base + r.uint16At(base + 8)),
      _AnchorMatrix(r, base + r.uint16At(base + 10)),
    );
  }

  final Coverage _mark1Coverage;
  final Coverage _mark2Coverage;
  final int _classCount;
  final _MarkArray _mark1s;
  final _AnchorMatrix _mark2s;

  @override
  bool apply(GposApplyContext c) {
    final mark1Index = _mark1Coverage.index(c.buffer.infos[c.index].glyphId);
    if (mark1Index < 0) return false;

    // Every Ignore* bit is cleared: a mark-to-mark lookup that ignored marks
    // could never find its target. The mark-attachment-class and filtering-set
    // bits are kept, because those DO select which marks are eligible.
    final it = c.iteratorFor(c.lookupFlag & ~_ignoreFlags);
    final j = c.prevMatch(it, c.index);
    if (j < 0) return false;

    final other = c.buffer.infos[j];
    if (other.glyphClass != GlyphClass.mark) return false;

    final mark = c.buffer.infos[c.index];
    if (!_sameCluster(mark, other)) return false;

    final mark2Index = _mark2Coverage.index(other.glyphId);
    if (mark2Index < 0) return false;

    return _attachMark(
      c,
      _mark1s,
      mark1Index,
      _mark2s.anchor(mark2Index, _mark1s.classOf(mark1Index), _classCount),
      j,
    );
  }

  static const int _ignoreFlags =
      LookupFlag.ignoreBaseGlyphs |
      LookupFlag.ignoreLigatures |
      LookupFlag.ignoreMarks;

  /// Two marks may only stack when they belong to the same thing.
  ///
  /// Same ligature id AND same component, or neither in a ligature at all. The
  /// escape hatch is a mark that is ITSELF a ligature (component 0 of a
  /// non-zero id) — `ccmp` produces those, and they must still accept a mark.
  static bool _sameCluster(GlyphInfo a, GlyphInfo b) {
    if (a.ligatureId == b.ligatureId) {
      return a.ligatureId == 0 || a.ligatureComponent == b.ligatureComponent;
    }
    return (a.ligatureId > 0 && a.ligatureComponent == 0) ||
        (b.ligatureId > 0 && b.ligatureComponent == 0);
  }
}

// ── the contextual machinery ──────────────────────────────────────────────────

/// Applies a rule's nested lookups, then parks the cursor past the match.
///
/// A GPOS lookup never inserts or deletes a glyph, so — unlike GSUB — the match
/// positions cannot shift under us and no re-indexing is needed. The cursor
/// still has to land on [matchEnd] at the end: leave it on the last nested
/// lookup's position and the driver re-enters the same rule forever.
void _applyNested(
  GposApplyContext c,
  List<int> positions,
  List<LookupRecord> records,
  int matchEnd,
) {
  for (final record in records) {
    if (record.sequenceIndex >= positions.length) continue;
    c.index = positions[record.sequenceIndex];
    c.recurse(record.lookupListIndex);
  }
  c.index = matchEnd;
}

/// Matches the input sequence starting at `c.index`, returning the matched
/// positions (including the first, unmatched glyph) or null.
List<int>? _matchInput(
  GposApplyContext c,
  int count,
  int dataAt,
  ByteReader r,
  GposMatcher match,
) {
  if (count == 0) return const <int>[];
  final out = List<int>.filled(count, 0);
  out[0] = c.index;
  var at = c.index;
  for (var i = 1; i < count; i++) {
    at = c.nextMatch(
      c.iterator,
      at,
      match: match,
      data: r.uint16At(dataAt + (i - 1) * 2),
    );
    if (at < 0) return null;
    out[i] = at;
  }
  return out;
}

/// Matches [count] glyphs before `c.index`, nearest first.
bool _matchBacktrack(
  GposApplyContext c,
  int count,
  int dataAt,
  ByteReader r,
  GposMatcher match,
) {
  var at = c.index;
  for (var i = 0; i < count; i++) {
    at = c.prevMatch(
      c.iterator,
      at,
      useMask: false,
      match: match,
      data: r.uint16At(dataAt + i * 2),
    );
    if (at < 0) return false;
  }
  return true;
}

/// Matches [count] glyphs from [start] forward.
bool _matchLookahead(
  GposApplyContext c,
  int count,
  int dataAt,
  ByteReader r,
  GposMatcher match,
  int start,
) {
  var at = start - 1;
  for (var i = 0; i < count; i++) {
    at = c.nextMatch(
      c.iterator,
      at,
      useMask: false,
      match: match,
      data: r.uint16At(dataAt + i * 2),
    );
    if (at < 0) return false;
  }
  return true;
}

List<LookupRecord> _readRecords(ByteReader r, int at, int count) =>
    List<LookupRecord>.generate(
      count,
      (i) => LookupRecord(r.uint16At(at + i * 4), r.uint16At(at + i * 4 + 2)),
      growable: false,
    );

bool _matchGlyph(GlyphInfo info, int data) => info.glyphId == data;

// ── type 7: contextual positioning ────────────────────────────────────────────

/// Lookup type 7 — "when these glyphs / classes / coverages appear in a row,
/// run these other lookups at these positions".
class ContextPos extends GposSubtable {
  ContextPos._(
    this._r,
    this._base,
    this._format,
    this._coverage,
    this._classDef,
  );

  static ContextPos parse(ByteReader r, int base, int format) {
    switch (format) {
      case 1:
        return ContextPos._(
          r,
          base,
          1,
          Coverage.parse(r.at(base + r.uint16At(base + 2))),
          null,
        );
      case 2:
        final cd = r.uint16At(base + 4);
        return ContextPos._(
          r,
          base,
          2,
          Coverage.parse(r.at(base + r.uint16At(base + 2))),
          cd == 0 ? ClassDef.empty : ClassDef.parse(r.at(base + cd)),
        );
      case 3:
        return ContextPos._(r, base, 3, null, null);
      default:
        throw FontFormatException('unknown ContextPos format $format');
    }
  }

  final ByteReader _r;
  final int _base;
  final int _format;
  final Coverage? _coverage;
  final ClassDef? _classDef;

  @override
  bool apply(GposApplyContext c) {
    final glyph = c.buffer.infos[c.index].glyphId;
    switch (_format) {
      case 1:
        final index = _coverage!.index(glyph);
        if (index < 0) return false;
        return _applyRuleSet(c, index, _matchGlyph, classRule: false);
      case 2:
        if (!_coverage!.covers(glyph)) return false;
        final klass = _classDef!.classOf(glyph);
        final cd = _classDef;
        return _applyRuleSet(
          c,
          klass,
          (info, data) => cd.classOf(info.glyphId) == data,
          classRule: true,
        );
      default:
        return _applyFormat3(c);
    }
  }

  /// Formats 1 and 2 share a shape: a set of rule sets indexed by coverage
  /// index or by class, each holding rules tried in order until one matches.
  bool _applyRuleSet(
    GposApplyContext c,
    int index,
    GposMatcher match, {
    required bool classRule,
  }) {
    final setCount = _r.uint16At(_base + (classRule ? 6 : 4));
    if (index < 0 || index >= setCount) return false;
    final setOffset = _r.uint16At(_base + (classRule ? 8 : 6) + index * 2);
    if (setOffset == 0) return false;
    final set = _base + setOffset;

    final ruleCount = _r.uint16At(set);
    for (var i = 0; i < ruleCount; i++) {
      final ruleOffset = _r.uint16At(set + 2 + i * 2);
      if (ruleOffset == 0) continue;
      final rule = set + ruleOffset;
      final inputCount = _r.uint16At(rule);
      final lookupCount = _r.uint16At(rule + 2);
      final inputAt = rule + 4;

      final positions = _matchInput(c, inputCount, inputAt, _r, match);
      if (positions == null) continue;

      final records = _readRecords(
        _r,
        inputAt + (inputCount == 0 ? 0 : inputCount - 1) * 2,
        lookupCount,
      );
      _applyNested(
        c,
        positions,
        records,
        positions.isEmpty ? c.index + 1 : positions.last + 1,
      );
      return true;
    }
    return false;
  }

  bool _applyFormat3(GposApplyContext c) {
    final glyphCount = _r.uint16At(_base + 2);
    if (glyphCount == 0) return false;
    final lookupCount = _r.uint16At(_base + 4);
    final coverageAt = _base + 6;

    // Position 0's coverage is the "does this lookup apply here at all" test.
    final first = Coverage.parse(_r.at(_base + _r.uint16At(coverageAt)));
    if (!first.covers(c.buffer.infos[c.index].glyphId)) return false;

    final positions = _matchInput(
      c,
      glyphCount,
      coverageAt + 2,
      _r,
      _coverageMatcher(_r, _base),
    );
    if (positions == null) return false;

    final records = _readRecords(_r, coverageAt + glyphCount * 2, lookupCount);
    _applyNested(c, positions, records, positions.last + 1);
    return true;
  }
}

/// A matcher whose per-position `data` is an offset to a Coverage table,
/// relative to [base].
///
/// The parsed tables are memoised per call: a format 3 rule asks the SAME
/// coverage the same question once per candidate position, and `Coverage.parse`
/// copies the table's glyph array. Re-parsing it inside the match loop turned a
/// chaining kern lookup into the most expensive thing in the shaper.
GposMatcher _coverageMatcher(ByteReader r, int base) {
  final cache = <int, Coverage>{};
  return (info, data) =>
      (cache[data] ??= Coverage.parse(r.at(base + data))).covers(info.glyphId);
}

// ── type 8: chaining contextual positioning ───────────────────────────────────

/// Lookup type 8 — contextual positioning with backtrack and lookahead.
///
/// The backtrack array is stored REVERSED: entry 0 is the glyph immediately
/// before the input, entry 1 the one before that. Read it forwards and every
/// rule with two or more backtrack glyphs matches the wrong context — which
/// shows up as a handful of correctly-shaped words positioned wrongly, the
/// hardest kind of layout bug to see.
class ChainContextPos extends GposSubtable {
  ChainContextPos._(
    this._r,
    this._base,
    this._format,
    this._coverage,
    this._backtrackClassDef,
    this._inputClassDef,
    this._lookaheadClassDef,
  );

  static ChainContextPos parse(ByteReader r, int base, int format) {
    switch (format) {
      case 1:
        return ChainContextPos._(
          r,
          base,
          1,
          Coverage.parse(r.at(base + r.uint16At(base + 2))),
          null,
          null,
          null,
        );
      case 2:
        ClassDef cd(int at) {
          final o = r.uint16At(at);
          return o == 0 ? ClassDef.empty : ClassDef.parse(r.at(base + o));
        }

        return ChainContextPos._(
          r,
          base,
          2,
          Coverage.parse(r.at(base + r.uint16At(base + 2))),
          cd(base + 4),
          cd(base + 6),
          cd(base + 8),
        );
      case 3:
        return ChainContextPos._(r, base, 3, null, null, null, null);
      default:
        throw FontFormatException('unknown ChainContextPos format $format');
    }
  }

  final ByteReader _r;
  final int _base;
  final int _format;
  final Coverage? _coverage;
  final ClassDef? _backtrackClassDef;
  final ClassDef? _inputClassDef;
  final ClassDef? _lookaheadClassDef;

  @override
  bool apply(GposApplyContext c) {
    final glyph = c.buffer.infos[c.index].glyphId;
    switch (_format) {
      case 1:
        final index = _coverage!.index(glyph);
        if (index < 0) return false;
        return _applyRuleSet(
          c,
          index,
          4,
          _matchGlyph,
          _matchGlyph,
          _matchGlyph,
        );
      case 2:
        if (!_coverage!.covers(glyph)) return false;
        // The rule set is chosen by the INPUT class, not by the coverage index
        // — coverage only gates whether the subtable is consulted at all.
        final back = _backtrackClassDef!;
        final input = _inputClassDef!;
        final ahead = _lookaheadClassDef!;
        return _applyRuleSet(
          c,
          input.classOf(glyph),
          10,
          (info, data) => back.classOf(info.glyphId) == data,
          (info, data) => input.classOf(info.glyphId) == data,
          (info, data) => ahead.classOf(info.glyphId) == data,
        );
      default:
        return _applyFormat3(c);
    }
  }

  bool _applyRuleSet(
    GposApplyContext c,
    int index,
    int countAt,
    GposMatcher backtrack,
    GposMatcher input,
    GposMatcher lookahead,
  ) {
    final setCount = _r.uint16At(_base + countAt);
    if (index < 0 || index >= setCount) return false;
    final setOffset = _r.uint16At(_base + countAt + 2 + index * 2);
    if (setOffset == 0) return false;
    final set = _base + setOffset;

    final ruleCount = _r.uint16At(set);
    for (var i = 0; i < ruleCount; i++) {
      final ruleOffset = _r.uint16At(set + 2 + i * 2);
      if (ruleOffset == 0) continue;
      if (_applyRule(c, set + ruleOffset, backtrack, input, lookahead)) {
        return true;
      }
    }
    return false;
  }

  bool _applyRule(
    GposApplyContext c,
    int rule,
    GposMatcher backtrack,
    GposMatcher input,
    GposMatcher lookahead,
  ) {
    var at = rule;
    final backtrackCount = _r.uint16At(at);
    final backtrackAt = at + 2;
    at = backtrackAt + backtrackCount * 2;

    final inputCount = _r.uint16At(at);
    final inputAt = at + 2;
    at = inputAt + (inputCount == 0 ? 0 : inputCount - 1) * 2;

    final lookaheadCount = _r.uint16At(at);
    final lookaheadAt = at + 2;
    at = lookaheadAt + lookaheadCount * 2;

    final lookupCount = _r.uint16At(at);
    final recordsAt = at + 2;

    // Input first, then lookahead, then backtrack — HarfBuzz's order, and the
    // cheap one: the input sequence rejects most rules on its second glyph.
    final positions = _matchInput(c, inputCount, inputAt, _r, input);
    if (positions == null) return false;
    final matchEnd = positions.isEmpty ? c.index + 1 : positions.last + 1;

    if (!_matchLookahead(
      c,
      lookaheadCount,
      lookaheadAt,
      _r,
      lookahead,
      matchEnd,
    )) {
      return false;
    }
    if (!_matchBacktrack(c, backtrackCount, backtrackAt, _r, backtrack)) {
      return false;
    }

    _applyNested(
      c,
      positions,
      _readRecords(_r, recordsAt, lookupCount),
      matchEnd,
    );
    return true;
  }

  bool _applyFormat3(GposApplyContext c) {
    var at = _base + 2;
    final backtrackCount = _r.uint16At(at);
    final backtrackAt = at + 2;
    at = backtrackAt + backtrackCount * 2;

    final inputCount = _r.uint16At(at);
    final inputAt = at + 2;
    at = inputAt + inputCount * 2;

    final lookaheadCount = _r.uint16At(at);
    final lookaheadAt = at + 2;
    at = lookaheadAt + lookaheadCount * 2;

    final lookupCount = _r.uint16At(at);
    final recordsAt = at + 2;

    if (inputCount == 0) return false;
    final first = Coverage.parse(_r.at(_base + _r.uint16At(inputAt)));
    if (!first.covers(c.buffer.infos[c.index].glyphId)) return false;

    final match = _coverageMatcher(_r, _base);
    final positions = _matchInput(c, inputCount, inputAt + 2, _r, match);
    if (positions == null) return false;
    final matchEnd = positions.last + 1;

    if (!_matchLookahead(c, lookaheadCount, lookaheadAt, _r, match, matchEnd)) {
      return false;
    }
    if (!_matchBacktrack(c, backtrackCount, backtrackAt, _r, match)) {
      return false;
    }

    _applyNested(
      c,
      positions,
      _readRecords(_r, recordsAt, lookupCount),
      matchEnd,
    );
    return true;
  }
}
