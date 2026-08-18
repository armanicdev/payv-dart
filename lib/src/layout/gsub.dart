/// `GSUB` — the table this whole package exists to execute.
///
/// Four Kurdish Sorani letters (ڕ U+0695 · ڵ U+06B5 · ە U+06D5 · ێ U+06CE) have
/// no Unicode presentation forms, and `ڵ`+`ا` has no ligature codepoint at all.
/// Their contextual shapes exist in the font ONLY as the OUTPUT of a `GSUB`
/// lookup — gid 839 `uni06B5.init`, gid 896 `uni06D5.fina`, gid 474
/// `lamVabove_alef.isol`. No cmap reaches them, in any font, ever. Running the
/// font's own lookups is not an optimisation here; it is the only door.
///
/// This file is the DRIVER. It owns lookup parsing, the forward and backward
/// passes over the buffer, the per-glyph feature mask, and nested-lookup
/// recursion. The lookup types themselves live in `gsub_subtables.dart`.
library;

import '../shaping/glyph_buffer.dart';
import '../util/byte_reader.dart';
import 'common.dart';
import 'gsub_subtables.dart';

export 'gsub_subtables.dart'
    show GsubContext, SequenceLookupRecord, kGsubMaxNestingLevel;

/// One Lookup table: its type, its flags, and its parsed subtables.
class _GsubLookup {
  _GsubLookup({
    required this.type,
    required this.flag,
    required this.markFilteringSet,
    required this.subtables,
  });

  /// Effective type, after extension resolution — a caller asking "is this
  /// reverse?" must get the right answer even when the font wrapped a type 8
  /// lookup in a type 7 extension.
  final int type;

  final int flag;
  final int markFilteringSet;
  final List<GsubSubtable> subtables;

  /// Type 8 runs right-to-left, as its own pass over the whole buffer.
  bool get isReverse => type == 8;
}

/// A parsed `GSUB` table, ready to apply.
class GsubTable {
  GsubTable._(this.layout)
    : _lookups = List<_GsubLookup?>.filled(layout.lookupOffsets.length, null);

  /// Parses the `GSUB` table at [r]'s current position.
  ///
  /// Only the header is read. Lookups parse on first use, because a font with
  /// Latin, Cyrillic, Greek and Arabic coverage ships 37 lookups and a Kurdish
  /// line touches six of them.
  static GsubTable parse(ByteReader r) => GsubTable._(LayoutTable.parse(r));

  /// The script/feature/lookup directory. Ask it which lookups a run needs.
  final LayoutTable layout;

  final List<_GsubLookup?> _lookups;

  int get lookupCount => _lookups.length;

  /// Effective lookup type of [lookupIndex] — 1..6 or 8, never 7.
  int lookupType(int lookupIndex) => _lookup(lookupIndex).type;

  int lookupFlag(int lookupIndex) => _lookup(lookupIndex).flag;

  /// True when [lookupIndex] must be run as its own right-to-left pass.
  bool isReverseLookup(int lookupIndex) => _lookup(lookupIndex).isReverse;

  /// Applies one lookup across the whole buffer, honouring per-glyph feature
  /// masks. Returns true if anything changed.
  ///
  /// [mask] is the feature's bit. A glyph is only considered when
  /// `info.mask & mask != 0`, which is what lets a single pass apply `init` to
  /// one letter of a word and `fina` to another — the Arabic joining state
  /// machine sets one bit per glyph and the four features then cost four
  /// passes, not four buffers.
  ///
  /// [alternateIndex] selects which alternate a type 3 lookup takes; it is
  /// ignored by every other type.
  bool applyLookup(
    int lookupIndex,
    GlyphBuffer buffer, {
    required int mask,
    GdefTable? gdef,
    int alternateIndex = 0,
  }) {
    if (buffer.isEmpty) return false;
    final lookup = _lookup(lookupIndex);
    if (lookup.subtables.isEmpty) return false;

    final ctx = GsubContext(
      buffer,
      lookupMask: mask,
      gdef: gdef,
      alternateIndex: alternateIndex,
      recurse: _recurse,
    )..setLookup(lookup.flag, lookup.markFilteringSet);

    return lookup.isReverse
        ? _applyBackward(lookup, ctx)
        : _applyForward(lookup, ctx);
  }

  /// Every glyph this lookup could ever produce, including through the lookups
  /// a contextual rule recurses into.
  ///
  /// The subsetter needs the CLOSURE, not the direct outputs. Keep only what
  /// the cmap reached and an exported PDF is missing exactly the contextual
  /// forms this package exists to produce — the document renders, in tofu,
  /// which is the failure mode nobody catches before it ships.
  void collectOutputGlyphs(int lookupIndex, Set<int> into) =>
      _collect(lookupIndex, into, <int>{});

  void _collect(int lookupIndex, Set<int> into, Set<int> seen) {
    if (lookupIndex < 0 || lookupIndex >= _lookups.length) return;
    // A font may point two lookups at each other; the seen set makes that
    // finite rather than fatal.
    if (!seen.add(lookupIndex)) return;
    for (final subtable in _lookup(lookupIndex).subtables) {
      subtable.collectOutputGlyphs(
        into,
        (nested) => _collect(nested, into, seen),
      );
    }
  }

  // ── passes ──────────────────────────────────────────────────────────────────

  /// The normal pass: left to right, one glyph at a time.
  ///
  /// A subtable that applies leaves `ctx.index` past whatever it consumed, so
  /// the cursor is only advanced here when NOTHING applied. That is HarfBuzz's
  /// loop shape and it is load-bearing — a ligature that swallowed three glyphs
  /// must not then be re-examined at its second component.
  bool _applyForward(_GsubLookup lookup, GsubContext ctx) {
    final buffer = ctx.buffer;
    var changed = false;
    ctx.index = 0;

    while (ctx.index < buffer.length) {
      final at = ctx.index;
      final info = buffer.infos[at];
      var applied = false;

      if (info.mask & ctx.lookupMask != 0 && !ctx.iterator.shouldSkip(info)) {
        for (final subtable in lookup.subtables) {
          if (subtable.apply(ctx)) {
            applied = true;
            break;
          }
        }
      }

      if (!applied) {
        ctx.index = at + 1;
        continue;
      }
      changed = true;
      // Liveness guard, not spec: a well-formed subtable always advances. A
      // malformed one that does not would spin here forever on a font we did
      // not write.
      if (ctx.index <= at) ctx.index = at + 1;
    }
    return changed;
  }

  /// The type 8 pass: right to left, and the cursor moves by exactly one glyph
  /// whether or not the lookup applied.
  ///
  /// Walking backwards is the entire point of a reverse lookup: its lookahead
  /// is supposed to see glyphs this same lookup has already rewritten.
  bool _applyBackward(_GsubLookup lookup, GsubContext ctx) {
    final buffer = ctx.buffer;
    var changed = false;

    for (ctx.index = buffer.length - 1; ctx.index >= 0; ctx.index--) {
      final info = buffer.infos[ctx.index];
      if (info.mask & ctx.lookupMask == 0) continue;
      if (ctx.iterator.shouldSkip(info)) continue;
      for (final subtable in lookup.subtables) {
        if (subtable.apply(ctx)) {
          changed = true;
          break;
        }
      }
    }
    return changed;
  }

  /// Applies [lookupIndex] once, at `ctx.index`, under that lookup's own flags.
  ///
  /// The flags swap matters: a nested lookup may ignore marks when its parent
  /// did not, or the reverse. Restoring them afterwards matters just as much,
  /// because the parent is mid-match and about to keep walking.
  bool _recurse(GsubContext ctx, int lookupIndex) {
    if (ctx.depth >= kGsubMaxNestingLevel) return false;
    if (lookupIndex < 0 || lookupIndex >= _lookups.length) return false;
    if (ctx.index < 0 || ctx.index >= ctx.buffer.length) return false;

    final lookup = _lookup(lookupIndex);
    final savedFlag = ctx.lookupFlag;
    final savedFilteringSet = ctx.markFilteringSet;
    ctx.setLookup(lookup.flag, lookup.markFilteringSet);
    ctx.depth++;

    var applied = false;
    for (final subtable in lookup.subtables) {
      if (subtable.apply(ctx)) {
        applied = true;
        break;
      }
    }

    ctx.depth--;
    ctx.setLookup(savedFlag, savedFilteringSet);
    return applied;
  }

  // ── lookup parsing ──────────────────────────────────────────────────────────

  _GsubLookup _lookup(int index) {
    if (index < 0 || index >= _lookups.length) {
      throw FontFormatException('GSUB lookup index $index out of range');
    }
    final cached = _lookups[index];
    if (cached != null) return cached;

    final r = layout.base;
    final base = layout.lookupOffsets[index];
    final declaredType = r.uint16At(base);
    final flag = r.uint16At(base + 2);
    final subtableCount = r.uint16At(base + 4);

    // The MarkFilteringSet field sits AFTER the subtable offset array, not in
    // the header — reading it from a fixed offset is a silent off-by-N that
    // only shows up on fonts that use mark filtering sets.
    final markFilteringSet = flag & LookupFlag.useMarkFilteringSet != 0
        ? r.uint16At(base + 6 + subtableCount * 2)
        : 0;

    final subtables = <GsubSubtable>[];
    for (var i = 0; i < subtableCount; i++) {
      final offset = r.uint16At(base + 6 + i * 2);
      subtables.add(parseGsubSubtable(declaredType, r.at(base + offset)));
    }

    return _lookups[index] = _GsubLookup(
      type: subtables.isEmpty ? declaredType : subtables.first.type,
      flag: flag,
      markFilteringSet: markFilteringSet,
      subtables: subtables,
    );
  }

  @override
  String toString() => 'GsubTable(${_lookups.length} lookups, $layout)';
}
