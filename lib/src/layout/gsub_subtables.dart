/// The eight `GSUB` lookup types, and the matching machinery they share.
///
/// Everything here is written against HarfBuzz's model rather than against a
/// plain reading of the spec, because the spec does not describe half of what a
/// correct shaper has to do. Three things in particular are invisible in the
/// OpenType text and load-bearing here:
///
///  1. A lookup does not walk the buffer by index; it walks it through a
///     [SkippyIterator], so a `calt` rule with `IgnoreMarks` sees `ب` and `ب`
///     as adjacent across a shadda. Every match in this file goes through the
///     iterator.
///  2. A ligature does not just delete its components. It has to keep the marks
///     that sat between them, stamp each one with the component it belongs to,
///     and merge the clusters — otherwise mark positioning lands on the wrong
///     half of the ligature and text extraction reports the wrong characters.
///  3. A `SequenceLookupRecord`'s `sequenceIndex` counts NON-SKIPPED positions
///     from the match start. Counting raw buffer positions gives a shaper that
///     works on undecorated text and silently mangles decorated text.
///
/// Backtrack arrays are stored NEAREST-FIRST (`backtrack[0]` is the glyph
/// immediately before the input). Reading them left-to-right like the input
/// array is the classic GSUB bug and it fails silently — the rule simply never
/// fires, and the word renders in its plain forms, which looks plausible.
library;

import '../shaping/glyph_buffer.dart';
import '../util/byte_reader.dart';
import 'common.dart';

/// Recursion cap for nested lookups. HarfBuzz's number; a font that needs more
/// is either pathological or hostile.
const int kGsubMaxNestingLevel = 64;

/// Longest input sequence a context rule may match, and therefore the size of
/// the match-position array [applySequenceLookups] rewrites in place.
const int kGsubMaxContextLength = 64;

/// Applies lookup [lookupIndex] once, at `ctx.index`, with that lookup's own
/// flags. Supplied by `GsubTable`; kept as a callback so subtables never have
/// to import the table that owns them.
typedef GsubRecurseCallback = bool Function(GsubContext ctx, int lookupIndex);

/// One `SequenceLookupRecord`: "when this rule matches, run lookup
/// [lookupListIndex] at input position [sequenceIndex]".
class SequenceLookupRecord {
  const SequenceLookupRecord(this.sequenceIndex, this.lookupListIndex);

  /// Position within the rule's INPUT sequence — counted in non-skipped
  /// glyphs, not buffer indices.
  final int sequenceIndex;

  final int lookupListIndex;

  @override
  String toString() =>
      'SequenceLookupRecord($sequenceIndex → $lookupListIndex)';
}

/// The mutable state one GSUB pass carries: where we are, what the current
/// lookup is allowed to see, and how to recurse.
///
/// One of these is built per `applyLookup` call and threaded through every
/// subtable, which is why the iterator lives here — rebuilding a
/// [SkippyIterator] per glyph per subtable would be the single hottest
/// allocation in the engine.
class GsubContext {
  GsubContext(
    this.buffer, {
    required this.lookupMask,
    required this.recurse,
    this.gdef,
    this.alternateIndex = 0,
  });

  final GlyphBuffer buffer;

  /// Feature mask of the lookup being applied. A glyph is only substituted when
  /// `info.mask & lookupMask != 0`, which is how one GSUB pass can apply four
  /// mutually exclusive Arabic joining features to one buffer.
  final int lookupMask;

  final GdefTable? gdef;

  /// Which alternate an `AlternateSubst` picks. HarfBuzz packs this into the
  /// high bits of the feature mask; payv keeps it as a plain number because the
  /// shaping plan, not the lookup, is what knows the user asked for `salt 2`.
  final int alternateIndex;

  final GsubRecurseCallback recurse;

  /// Current position in [buffer]. A subtable that applies MUST leave this past
  /// the input it consumed, exactly as HarfBuzz's `buffer->idx` ends up.
  int index = 0;

  /// Nesting depth, against [kGsubMaxNestingLevel].
  int depth = 0;

  int _lookupFlag = 0;
  int _markFilteringSet = 0;
  SkippyIterator? _iterator;

  int get lookupFlag => _lookupFlag;

  int get markFilteringSet => _markFilteringSet;

  /// Switches to the flags of the lookup now being applied. Cheap when nothing
  /// changed, which is the common case — only recursion changes them.
  void setLookup(int lookupFlag, int markFilteringSet) {
    if (lookupFlag == _lookupFlag && markFilteringSet == _markFilteringSet) {
      return;
    }
    _lookupFlag = lookupFlag;
    _markFilteringSet = markFilteringSet;
    _iterator = null;
  }

  SkippyIterator get iterator => _iterator ??= SkippyIterator(
    buffer,
    lookupFlag: _lookupFlag,
    markFilteringSet: _markFilteringSet,
    gdef: gdef,
  );

  GlyphInfo get current => buffer.infos[index];

  /// Rewrites the glyph at [at] and re-derives its GDEF properties.
  ///
  /// Re-deriving is not optional. `uni06B5` is a base and `uni06B5.medi` is a
  /// base, but a ccmp lookup that turns a letter into a mark changes what every
  /// LATER lookup is allowed to see. Forgetting this is why marks sometimes
  /// stop being skipped halfway through a word.
  void substituteGlyph(int at, int glyphId, {int classGuess = 0}) {
    final info = buffer.infos[at];
    info.glyphId = glyphId;

    final gdef = this.gdef;
    if (gdef != null && gdef.hasGlyphClasses) {
      info.glyphClass = gdef.glyphClass(glyphId);
      info.markAttachClass = gdef.markAttachClass(glyphId);
    } else if (classGuess != GlyphClass.unclassified) {
      // Without a GlyphClassDef the font has told us nothing, so the subtable's
      // guess ("this is a ligature now") is the only signal there is.
      info.glyphClass = classGuess;
    }
  }
}

// ── shared matching helpers ───────────────────────────────────────────────────

/// Matches [count] input glyphs starting at `ctx.index`, returning their buffer
/// positions (position 0 is `ctx.index` itself) or null.
///
/// [matches] is called with the 1-based input position and the glyph found
/// there, so callers index their own `input[i - 1]` array without an offset
/// dance.
///
/// The ligature-component bookkeeping in the middle is not defensive
/// programming: it stops a second ligature from re-ligating glyphs that already
/// belong to different components of an earlier one, which would attach marks
/// to a component that no longer exists.
List<int>? matchInput(
  GsubContext ctx,
  int count,
  bool Function(int position, int glyphId) matches,
) {
  final buffer = ctx.buffer;
  final iterator = ctx.iterator;
  final positions = List<int>.filled(count, 0)..[0] = ctx.index;
  if (count == 1) return positions;

  final first = buffer.infos[ctx.index];
  final firstLigId = first.ligatureId;
  final firstLigComponent = first.ligatureComponent;

  // Tri-state, resolved at most once per match: null = not yet checked.
  bool? ligBaseMaySkip;

  var at = ctx.index;
  for (var i = 1; i < count; i++) {
    at = iterator.next(at);
    if (at < 0) return null;

    final info = buffer.infos[at];
    if (!matches(i, info.glyphId)) return null;
    positions[i] = at;

    if (firstLigId != 0 && firstLigComponent != 0) {
      // The first glyph is itself a component of an earlier ligature, so every
      // other glyph must belong to the SAME component of the SAME ligature…
      if (firstLigId != info.ligatureId ||
          firstLigComponent != info.ligatureComponent) {
        // …unless the ligature they hang off is one this lookup cannot see, in
        // which case they are adjacent as far as this lookup is concerned.
        ligBaseMaySkip ??= _ligatureBaseMaySkip(ctx, firstLigId);
        if (!ligBaseMaySkip) return null;
      }
    } else if (info.ligatureId != 0 &&
        info.ligatureComponent != 0 &&
        info.ligatureId != firstLigId) {
      // The first glyph is free but this one is bound into another ligature.
      return null;
    }
  }
  return positions;
}

/// True when the ligature that `firstLigId`'s components hang off is invisible
/// to the current lookup.
bool _ligatureBaseMaySkip(GsubContext ctx, int firstLigId) {
  final infos = ctx.buffer.infos;
  var j = ctx.index;
  var found = false;
  while (j > 0 && infos[j - 1].ligatureId == firstLigId) {
    if (infos[j - 1].ligatureComponent == 0) {
      j--;
      found = true;
      break;
    }
    j--;
  }
  return found && ctx.iterator.shouldSkip(infos[j]);
}

/// Matches [count] backtrack entries before `ctx.index`.
///
/// The array is nearest-first, and so is [SkippyIterator.prev], so this is a
/// straight walk with NO reversal anywhere. If you find yourself adding one,
/// the bug is elsewhere.
bool matchBacktrack(
  GsubContext ctx,
  int count,
  bool Function(int position, int glyphId) matches,
) {
  final iterator = ctx.iterator;
  var at = ctx.index;
  for (var i = 0; i < count; i++) {
    at = iterator.prev(at);
    if (at < 0) return false;
    if (!matches(i, ctx.buffer.infos[at].glyphId)) return false;
  }
  return true;
}

/// Matches [count] lookahead entries starting at [from] (the position just past
/// the matched input).
bool matchLookahead(
  GsubContext ctx,
  int count,
  int from,
  bool Function(int position, int glyphId) matches,
) {
  final iterator = ctx.iterator;
  var at = from - 1;
  for (var i = 0; i < count; i++) {
    at = iterator.next(at);
    if (at < 0) return false;
    if (!matches(i, ctx.buffer.infos[at].glyphId)) return false;
  }
  return true;
}

/// Runs a matched rule's nested lookups, then leaves `ctx.index` past the whole
/// match.
///
/// The bookkeeping exists because a nested lookup may itself insert or delete
/// glyphs, which moves every match position after it. HarfBuzz's approximation
/// — assume the length change happened immediately after the recursed position
/// — is reproduced exactly, deliberately: a "better" guess here would be a
/// different shaper, and the gate compares against HarfBuzz.
///
/// Always returns true: the rule matched, and whether its nested lookups did
/// anything is not the caller's business.
bool applySequenceLookups(
  GsubContext ctx,
  List<int> matchPositions,
  int matchEnd,
  List<SequenceLookupRecord> records,
) {
  final buffer = ctx.buffer;
  var count = matchPositions.length;
  var end = matchEnd;

  // Copied into a fixed-width scratch array because the shift below writes
  // past `count` when a nested lookup grows the buffer.
  final positions = List<int>.filled(kGsubMaxContextLength, 0);
  if (count > kGsubMaxContextLength) return true;
  positions.setRange(0, count, matchPositions);

  for (final record in records) {
    final target = record.sequenceIndex;
    if (target >= count) continue;
    // An earlier recursed lookup may have deleted enough glyphs that this
    // position no longer exists.
    if (positions[target] >= buffer.length) continue;

    ctx.index = positions[target];
    final before = buffer.length;
    if (!ctx.recurse(ctx, record.lookupListIndex)) continue;
    var delta = buffer.length - before;
    if (delta == 0) continue;

    end += delta;
    if (end < positions[target]) {
      // A recursed lookup removed more than the rule ever matched. Never rewind
      // `end` behind the position we are standing on; just stop.
      end = positions[target];
      break;
    }

    var next = target + 1;
    if (delta > 0) {
      if (delta + count > kGsubMaxContextLength) break;
    } else {
      // delta is negative; clamp so the shift below cannot underflow.
      final floor = next - count;
      if (delta < floor) delta = floor;
      next -= delta;
    }

    final moving = count - next;
    if (delta > 0) {
      for (var j = moving - 1; j >= 0; j--) {
        positions[next + delta + j] = positions[next + j];
      }
    } else {
      for (var j = 0; j < moving; j++) {
        positions[next + delta + j] = positions[next + j];
      }
    }
    next += delta;
    count += delta;

    // Glyphs the recursed lookup inserted sit immediately after it.
    for (var j = target + 1; j < next; j++) {
      positions[j] = positions[j - 1] + 1;
    }
    for (; next < count; next++) {
      positions[next] += delta;
    }
  }

  ctx.index = end;
  return true;
}

// ── the subtables ─────────────────────────────────────────────────────────────

/// One parsed GSUB subtable.
sealed class GsubSubtable {
  const GsubSubtable();

  /// Lookup type this subtable implements, AFTER extension resolution — a type
  /// 7 subtable never survives parsing.
  int get type;

  /// Tries to apply at `ctx.index`. On true, `ctx.index` has moved past the
  /// consumed input.
  bool apply(GsubContext ctx);

  /// Adds every glyph this subtable can emit to [into], recursing into nested
  /// lookups through [recurseInto].
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  );
}

/// Parses one subtable of a lookup of type [lookupType], resolving extensions.
GsubSubtable parseGsubSubtable(int lookupType, ByteReader r) {
  final (type, subtable) = resolveExtension(lookupType, r, extensionType: 7);
  final base = subtable.position;
  final format = subtable.uint16At(base);
  switch (type) {
    case 1:
      return SingleSubst.parse(subtable, format);
    case 2:
      return MultipleSubst.parse(subtable, format);
    case 3:
      return AlternateSubst.parse(subtable, format);
    case 4:
      return LigatureSubst.parse(subtable, format);
    case 5:
      return switch (format) {
        1 => ContextSubstFormat1.parse(subtable),
        2 => ContextSubstFormat2.parse(subtable),
        3 => ContextSubstFormat3.parse(subtable),
        _ => throw FontFormatException('unknown Context subst format $format'),
      };
    case 6:
      return switch (format) {
        1 => ChainContextSubstFormat1.parse(subtable),
        2 => ChainContextSubstFormat2.parse(subtable),
        3 => ChainContextSubstFormat3.parse(subtable),
        _ => throw FontFormatException(
          'unknown ChainContext subst format $format',
        ),
      };
    case 8:
      return ReverseChainSingleSubst.parse(subtable, format);
    default:
      throw FontFormatException('unknown GSUB lookup type $type');
  }
}

// ── type 1: single ────────────────────────────────────────────────────────────

/// Type 1 — one glyph for one glyph. The whole Arabic joining feature set
/// (`init`/`medi`/`fina`) is this and nothing else in Vazirmatn: gid 837 `ڵ`
/// becomes gid 839 `uni06B5.init`, a glyph with no codepoint anywhere.
final class SingleSubst extends GsubSubtable {
  SingleSubst._(this.coverage, this._delta, this._substitutes);

  static SingleSubst parse(ByteReader r, int format) {
    final base = r.position;
    final coverage = Coverage.parse(r.at(base + r.uint16At(base + 2)));
    switch (format) {
      case 1:
        return SingleSubst._(coverage, r.int16At(base + 4), null);
      case 2:
        final count = r.uint16At(base + 4);
        return SingleSubst._(coverage, 0, r.at(base + 6).readUint16List(count));
      default:
        throw FontFormatException('unknown SingleSubst format $format');
    }
  }

  final Coverage coverage;
  final int _delta;
  final List<int>? _substitutes;

  @override
  int get type => 1;

  int? _substituteFor(int glyphId) {
    final index = coverage.index(glyphId);
    if (index < 0) return null;
    final substitutes = _substitutes;
    if (substitutes == null) {
      // Format 1's delta wraps at 16 bits by spec, and real fonts rely on it.
      return (glyphId + _delta) & 0xFFFF;
    }
    return index < substitutes.length ? substitutes[index] : null;
  }

  @override
  bool apply(GsubContext ctx) {
    final substitute = _substituteFor(ctx.current.glyphId);
    if (substitute == null) return false;
    ctx.substituteGlyph(ctx.index, substitute);
    ctx.index++;
    return true;
  }

  @override
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  ) {
    for (final glyph in coverage.glyphs) {
      final substitute = _substituteFor(glyph);
      if (substitute != null) into.add(substitute);
    }
  }
}

// ── type 2: multiple ──────────────────────────────────────────────────────────

/// Type 2 — one glyph becomes several (decomposition).
///
/// Every output keeps the SOURCE glyph's cluster and codepoint. That is not a
/// nicety: the `ToUnicode` CMap is built from clusters, so an output that
/// invents its own cluster makes a PDF whose text cannot be copied back.
final class MultipleSubst extends GsubSubtable {
  MultipleSubst._(this.coverage, this._reader, this._sequenceOffsets)
    : _sequences = List<List<int>?>.filled(_sequenceOffsets.length, null);

  static MultipleSubst parse(ByteReader r, int format) {
    if (format != 1) {
      throw FontFormatException('unknown MultipleSubst format $format');
    }
    final base = r.position;
    final coverage = Coverage.parse(r.at(base + r.uint16At(base + 2)));
    final count = r.uint16At(base + 4);
    final offsets = List<int>.generate(
      count,
      (i) => base + r.uint16At(base + 6 + i * 2),
      growable: false,
    );
    return MultipleSubst._(coverage, r, offsets);
  }

  final Coverage coverage;
  final ByteReader _reader;
  final List<int> _sequenceOffsets;
  final List<List<int>?> _sequences;

  @override
  int get type => 2;

  List<int> _sequence(int index) => _sequences[index] ??= _reader
      .at(_sequenceOffsets[index] + 2)
      .readUint16List(_reader.uint16At(_sequenceOffsets[index]));

  @override
  bool apply(GsubContext ctx) {
    final index = coverage.index(ctx.current.glyphId);
    if (index < 0 || index >= _sequenceOffsets.length) return false;
    final glyphs = _sequence(index);

    if (glyphs.length == 1) {
      // Deliberately NOT treated as a multiplication — HarfBuzz special-cases
      // it so a one-glyph "sequence" does not mark the glyph as multiplied and
      // change what later lookups think it is.
      ctx.substituteGlyph(ctx.index, glyphs[0]);
      ctx.index++;
      return true;
    }
    if (glyphs.isEmpty) {
      // The spec forbids an empty sequence; Uniscribe accepts it as a delete,
      // so fonts ship it, so we honour it.
      ctx.buffer.infos.removeAt(ctx.index);
      ctx.buffer.positions.removeAt(ctx.index);
      return true;
    }

    final buffer = ctx.buffer;
    final at = ctx.index;
    final source = buffer.infos[at];
    // A ligature that decomposes leaves base glyphs behind, not ligatures.
    final classGuess = source.glyphClass == GlyphClass.ligature
        ? GlyphClass.base
        : GlyphClass.unclassified;
    final ligatureId = source.ligatureId;

    final outputs = <GlyphInfo>[];
    for (var i = 0; i < glyphs.length; i++) {
      final info = source.copy();
      if (ligatureId == 0) {
        // Free glyph: number the pieces so a later ligature can tell them
        // apart. Already bound to a ligature: leave that binding alone.
        info.ligatureId = 0;
        info.ligatureComponent = i;
      }
      outputs.add(info);
    }

    buffer.infos.removeAt(at);
    buffer.positions.removeAt(at);
    buffer.infos.insertAll(at, outputs);
    buffer.positions.insertAll(at, [
      for (var i = 0; i < glyphs.length; i++) GlyphPosition(),
    ]);
    for (var i = 0; i < glyphs.length; i++) {
      ctx.substituteGlyph(at + i, glyphs[i], classGuess: classGuess);
    }
    ctx.index = at + glyphs.length;
    return true;
  }

  @override
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  ) {
    for (var i = 0; i < _sequenceOffsets.length; i++) {
      into.addAll(_sequence(i));
    }
  }
}

// ── type 3: alternate ─────────────────────────────────────────────────────────

/// Type 3 — a menu of glyphs, one of which the feature picks
/// ([GsubContext.alternateIndex]).
final class AlternateSubst extends GsubSubtable {
  AlternateSubst._(this.coverage, this._reader, this._setOffsets)
    : _sets = List<List<int>?>.filled(_setOffsets.length, null);

  static AlternateSubst parse(ByteReader r, int format) {
    if (format != 1) {
      throw FontFormatException('unknown AlternateSubst format $format');
    }
    final base = r.position;
    final coverage = Coverage.parse(r.at(base + r.uint16At(base + 2)));
    final count = r.uint16At(base + 4);
    final offsets = List<int>.generate(
      count,
      (i) => base + r.uint16At(base + 6 + i * 2),
      growable: false,
    );
    return AlternateSubst._(coverage, r, offsets);
  }

  final Coverage coverage;
  final ByteReader _reader;
  final List<int> _setOffsets;
  final List<List<int>?> _sets;

  @override
  int get type => 3;

  List<int> _alternates(int index) => _sets[index] ??= _reader
      .at(_setOffsets[index] + 2)
      .readUint16List(_reader.uint16At(_setOffsets[index]));

  @override
  bool apply(GsubContext ctx) {
    final index = coverage.index(ctx.current.glyphId);
    if (index < 0 || index >= _setOffsets.length) return false;
    final alternates = _alternates(index);
    if (ctx.alternateIndex >= alternates.length) return false;
    ctx.substituteGlyph(ctx.index, alternates[ctx.alternateIndex]);
    ctx.index++;
    return true;
  }

  @override
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  ) {
    // Every alternate, not just the selected one — a subsetter that keeps only
    // alternate 0 makes `salt`/`ss01` silently unavailable in the exported PDF.
    for (var i = 0; i < _setOffsets.length; i++) {
      into.addAll(_alternates(i));
    }
  }
}

// ── type 4: ligature ──────────────────────────────────────────────────────────

/// One Ligature record: the glyph it produces and the components after the
/// first (the first is what the coverage matched).
class _Ligature {
  const _Ligature(this.glyph, this.components);

  final int glyph;
  final List<int> components;
}

/// Type 4 — several glyphs become one. This is the lookup that produces gid
/// 474 `lamVabove_alef.isol` from `ڵ` + `ا`, a shape Unicode has no codepoint
/// for and therefore no presentation-form library can reach.
final class LigatureSubst extends GsubSubtable {
  LigatureSubst._(this.coverage, this._reader, this._setOffsets)
    : _sets = List<List<_Ligature>?>.filled(_setOffsets.length, null);

  static LigatureSubst parse(ByteReader r, int format) {
    if (format != 1) {
      throw FontFormatException('unknown LigatureSubst format $format');
    }
    final base = r.position;
    final coverage = Coverage.parse(r.at(base + r.uint16At(base + 2)));
    final count = r.uint16At(base + 4);
    final offsets = List<int>.generate(
      count,
      (i) => base + r.uint16At(base + 6 + i * 2),
      growable: false,
    );
    return LigatureSubst._(coverage, r, offsets);
  }

  final Coverage coverage;
  final ByteReader _reader;
  final List<int> _setOffsets;
  final List<List<_Ligature>?> _sets;

  @override
  int get type => 4;

  List<_Ligature> _ligatureSet(int index) {
    final cached = _sets[index];
    if (cached != null) return cached;
    final setBase = _setOffsets[index];
    final count = _reader.uint16At(setBase);
    final out = List<_Ligature>.generate(count, (i) {
      final at = setBase + _reader.uint16At(setBase + 2 + i * 2);
      final componentCount = _reader.uint16At(at + 2);
      return _Ligature(
        _reader.uint16At(at),
        // componentCount counts the first glyph, which is not stored.
        _reader
            .at(at + 4)
            .readUint16List(componentCount == 0 ? 0 : componentCount - 1),
      );
    }, growable: false);
    return _sets[index] = out;
  }

  @override
  bool apply(GsubContext ctx) {
    final index = coverage.index(ctx.current.glyphId);
    if (index < 0 || index >= _setOffsets.length) return false;

    for (final ligature in _ligatureSet(index)) {
      final components = ligature.components;
      final positions = matchInput(
        ctx,
        components.length + 1,
        (position, glyphId) => components[position - 1] == glyphId,
      );
      if (positions == null) continue;
      _ligate(ctx, positions, ligature.glyph);
      return true;
    }
    return false;
  }

  @override
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  ) {
    for (var i = 0; i < _setOffsets.length; i++) {
      for (final ligature in _ligatureSet(i)) {
        into.add(ligature.glyph);
      }
    }
  }
}

/// Collapses [positions] into [ligatureGlyph], keeping every glyph that sat
/// between the components.
///
/// The kept glyphs are the marks the lookup was blind to, and each one is
/// re-stamped with the ligature id plus the component it now belongs to. That
/// stamp is the ONLY thing that lets `GPOS` mark-to-ligature attachment put a
/// shadda over the right half of a two-letter ligature afterwards; drop it and
/// every mark piles onto component one.
void _ligate(GsubContext ctx, List<int> positions, int ligatureGlyph) {
  final buffer = ctx.buffer;
  final infos = buffer.infos;
  final count = positions.length;
  final matchEnd = positions[count - 1] + 1;

  _mergeClusters(buffer, ctx.index, matchEnd);

  // Classification, straight from HarfBuzz:
  //  - base + marks  → still a base, so following marks can keep attaching;
  //  - marks + marks → a mark ligature (a stacked-diacritic glyph);
  //  - anything else → a real ligature, which gets an id and a component map.
  var isBaseLigature = infos[positions[0]].glyphClass == GlyphClass.base;
  var isMarkLigature = infos[positions[0]].glyphClass == GlyphClass.mark;
  for (var i = 1; i < count; i++) {
    if (infos[positions[i]].glyphClass != GlyphClass.mark) {
      isBaseLigature = false;
      isMarkLigature = false;
      break;
    }
  }
  final isLigature = !isBaseLigature && !isMarkLigature;
  final classGuess = isLigature ? GlyphClass.ligature : GlyphClass.unclassified;
  final ligatureId = isLigature ? _allocateLigatureId(buffer) : 0;

  var lastLigatureId = infos[ctx.index].ligatureId;
  var lastComponentCount = _componentCount(infos[ctx.index]);
  var componentsSoFar = lastComponentCount;

  if (isLigature) {
    infos[ctx.index].ligatureId = ligatureId;
    infos[ctx.index].ligatureComponent = 0;
    if (infos[ctx.index].generalCategory == GeneralCategory.nonSpacingMark) {
      // A ligature is a letter even when it was built out of marks, and the
      // Arabic shaper's later passes branch on this.
      infos[ctx.index].generalCategory = GeneralCategory.other;
    }
  }
  ctx.substituteGlyph(ctx.index, ligatureGlyph, classGuess: classGuess);

  var survivors = 0;
  for (var i = 1; i < count; i++) {
    for (var j = positions[i - 1] + 1; j < positions[i]; j++) {
      if (isLigature) {
        var component = infos[j].ligatureComponent;
        if (component == 0) component = lastComponentCount;
        infos[j].ligatureId = ligatureId;
        infos[j].ligatureComponent =
            componentsSoFar -
            lastComponentCount +
            (component < lastComponentCount ? component : lastComponentCount);
      }
      survivors++;
    }
    lastLigatureId = infos[positions[i]].ligatureId;
    lastComponentCount = _componentCount(infos[positions[i]]);
    componentsSoFar += lastComponentCount;
  }

  // Descending, so each removal leaves the earlier positions valid.
  for (var i = count - 1; i >= 1; i--) {
    infos.removeAt(positions[i]);
    buffer.positions.removeAt(positions[i]);
  }

  final after = ctx.index + 1 + survivors;

  // Marks that trailed the LAST component belong to this ligature too, and
  // they are past the match, so the loop above never saw them.
  if (!isMarkLigature && lastLigatureId != 0) {
    for (var i = after; i < infos.length; i++) {
      if (infos[i].ligatureId != lastLigatureId) break;
      final component = infos[i].ligatureComponent;
      if (component == 0) break;
      infos[i].ligatureId = ligatureId;
      infos[i].ligatureComponent =
          componentsSoFar -
          lastComponentCount +
          (component < lastComponentCount ? component : lastComponentCount);
    }
  }

  ctx.index = after;
}

/// How many original characters a glyph stands for.
///
/// HarfBuzz keeps this packed alongside the ligature id; [GlyphInfo] has no
/// field for it, so a ligature of ligatures distributes interleaved marks
/// across components as if each component were one character. Vazirmatn never
/// ligates a ligature, so this costs nothing here — it is the one place a
/// second field on [GlyphInfo] would buy full generality.
int _componentCount(GlyphInfo info) => 1;

/// Ligature ids only have to distinguish a ligature from its NEIGHBOURS, so
/// three bits is enough — HarfBuzz uses exactly three. Picking the lowest id
/// not currently in the buffer keeps this stateless, which matters because a
/// `GsubTable` is cached on the font and shared across every run on the page.
int _allocateLigatureId(GlyphBuffer buffer) {
  var used = 0;
  for (final info in buffer.infos) {
    final id = info.ligatureId;
    if (id > 0 && id < 8) used |= 1 << id;
  }
  for (var id = 1; id < 8; id++) {
    if (used & (1 << id) == 0) return id;
  }
  return 1;
}

/// Collapses the clusters of `[start, end)` onto their minimum.
///
/// Clusters only ever merge downward, which is what keeps them usable as
/// `/ActualText` span boundaries. The backwards walk catches glyphs BEFORE
/// [start] that already shared the old cluster value — without it, a ligature
/// following a decomposed mark leaves an orphan cluster that no longer maps to
/// any character.
void _mergeClusters(GlyphBuffer buffer, int start, int end) {
  if (end - start < 2) return;
  final infos = buffer.infos;

  var cluster = infos[start].cluster;
  for (var i = start + 1; i < end; i++) {
    if (infos[i].cluster < cluster) cluster = infos[i].cluster;
  }

  final startCluster = infos[start].cluster;
  for (var i = start; i > 0 && infos[i - 1].cluster == startCluster; i--) {
    infos[i - 1].cluster = cluster;
  }
  for (var i = start; i < end; i++) {
    infos[i].cluster = cluster;
  }
}

// ── types 5 and 6: context and chaining context ───────────────────────────────

/// A Context or ChainContext rule in glyph or class form. Backtrack and
/// lookahead are empty for the plain Context types.
class _ContextRule {
  const _ContextRule({
    required this.backtrack,
    required this.input,
    required this.lookahead,
    required this.records,
  });

  /// NEAREST-FIRST. `backtrack[0]` is the glyph immediately before the input.
  final List<int> backtrack;

  /// Input positions 1..n-1; position 0 is the coverage match itself.
  final List<int> input;

  final List<int> lookahead;
  final List<SequenceLookupRecord> records;
}

List<SequenceLookupRecord> _readRecords(ByteReader r, int at, int count) =>
    List<SequenceLookupRecord>.generate(
      count,
      (i) => SequenceLookupRecord(
        r.uint16At(at + i * 4),
        r.uint16At(at + i * 4 + 2),
      ),
      growable: false,
    );

/// Reads a SequenceRule / ClassSequenceRule at [at].
_ContextRule _readSequenceRule(ByteReader r, int at) {
  final glyphCount = r.uint16At(at);
  final recordCount = r.uint16At(at + 2);
  final input = r
      .at(at + 4)
      .readUint16List(glyphCount == 0 ? 0 : glyphCount - 1);
  return _ContextRule(
    backtrack: const <int>[],
    input: input,
    lookahead: const <int>[],
    records: _readRecords(r, at + 4 + input.length * 2, recordCount),
  );
}

/// Reads a ChainedSequenceRule / ChainedClassSequenceRule at [at].
_ContextRule _readChainRule(ByteReader r, int at) {
  var p = at;
  final backtrackCount = r.uint16At(p);
  final backtrack = r.at(p + 2).readUint16List(backtrackCount);
  p += 2 + backtrackCount * 2;

  final inputCount = r.uint16At(p);
  final input = r
      .at(p + 2)
      .readUint16List(inputCount == 0 ? 0 : inputCount - 1);
  p += 2 + input.length * 2;

  final lookaheadCount = r.uint16At(p);
  final lookahead = r.at(p + 2).readUint16List(lookaheadCount);
  p += 2 + lookaheadCount * 2;

  final recordCount = r.uint16At(p);
  return _ContextRule(
    backtrack: backtrack,
    input: input,
    lookahead: lookahead,
    records: _readRecords(r, p + 2, recordCount),
  );
}

/// Rule sets shared by Context formats 1 and 2 and ChainContext formats 1 and 2.
///
/// Read lazily per coverage index: a large Arabic font ships thousands of rules
/// and a given run touches a handful, so parsing them all up front would cost
/// more than shaping the page.
class _RuleSets {
  _RuleSets(this._reader, this._offsets, this._read)
    : _cache = List<List<_ContextRule>?>.filled(_offsets.length, null);

  final ByteReader _reader;

  /// Absolute offsets; 0 means the font shipped a NULL set for that class.
  final List<int> _offsets;
  final _ContextRule Function(ByteReader r, int at) _read;
  final List<List<_ContextRule>?> _cache;

  int get length => _offsets.length;

  List<_ContextRule> operator [](int index) {
    if (index < 0 || index >= _offsets.length) return const <_ContextRule>[];
    final cached = _cache[index];
    if (cached != null) return cached;
    final base = _offsets[index];
    if (base == 0) return _cache[index] = const <_ContextRule>[];
    final count = _reader.uint16At(base);
    return _cache[index] = List<_ContextRule>.generate(
      count,
      (i) => _read(_reader, base + _reader.uint16At(base + 2 + i * 2)),
      growable: false,
    );
  }
}

List<int> _offsetList(ByteReader r, int base, int at, int count) =>
    List<int>.generate(count, (i) {
      final offset = r.uint16At(at + i * 2);
      return offset == 0 ? 0 : base + offset;
    }, growable: false);

/// Runs one matched context/chaining rule.
bool _applyRule(GsubContext ctx, _ContextRule rule, List<int> positions) {
  return applySequenceLookups(
    ctx,
    positions,
    positions[positions.length - 1] + 1,
    rule.records,
  );
}

/// Shared body of every context and chaining-context subtable: match input,
/// then lookahead, then backtrack, then recurse.
///
/// Order matters for cost, not correctness — input fails fastest.
bool _matchAndApply(
  GsubContext ctx,
  _ContextRule rule, {
  required bool Function(int position, int glyphId) input,
  required bool Function(int position, int glyphId) backtrack,
  required bool Function(int position, int glyphId) lookahead,
}) {
  final positions = matchInput(ctx, rule.input.length + 1, input);
  if (positions == null) return false;
  final matchEnd = positions[positions.length - 1] + 1;
  if (!matchLookahead(ctx, rule.lookahead.length, matchEnd, lookahead)) {
    return false;
  }
  if (!matchBacktrack(ctx, rule.backtrack.length, backtrack)) return false;
  return _applyRule(ctx, rule, positions);
}

/// Type 5 format 1 — context by literal glyph id.
final class ContextSubstFormat1 extends GsubSubtable {
  ContextSubstFormat1._(this.coverage, this._ruleSets);

  static ContextSubstFormat1 parse(ByteReader r) {
    final base = r.position;
    final coverage = Coverage.parse(r.at(base + r.uint16At(base + 2)));
    final count = r.uint16At(base + 4);
    return ContextSubstFormat1._(
      coverage,
      _RuleSets(r, _offsetList(r, base, base + 6, count), _readSequenceRule),
    );
  }

  final Coverage coverage;
  final _RuleSets _ruleSets;

  @override
  int get type => 5;

  @override
  bool apply(GsubContext ctx) {
    final index = coverage.index(ctx.current.glyphId);
    if (index < 0) return false;
    for (final rule in _ruleSets[index]) {
      if (_matchAndApply(
        ctx,
        rule,
        input: (position, glyphId) => rule.input[position - 1] == glyphId,
        backtrack: _never,
        lookahead: _never,
      )) {
        return true;
      }
    }
    return false;
  }

  @override
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  ) => _collectRuleOutputs(_ruleSets, recurseInto);
}

/// Type 5 format 2 — context by glyph class.
final class ContextSubstFormat2 extends GsubSubtable {
  ContextSubstFormat2._(this.coverage, this.classDef, this._ruleSets);

  static ContextSubstFormat2 parse(ByteReader r) {
    final base = r.position;
    final coverage = Coverage.parse(r.at(base + r.uint16At(base + 2)));
    final classOffset = r.uint16At(base + 4);
    final count = r.uint16At(base + 6);
    return ContextSubstFormat2._(
      coverage,
      classOffset == 0
          ? ClassDef.empty
          : ClassDef.parse(r.at(base + classOffset)),
      _RuleSets(r, _offsetList(r, base, base + 8, count), _readSequenceRule),
    );
  }

  final Coverage coverage;
  final ClassDef classDef;
  final _RuleSets _ruleSets;

  @override
  int get type => 5;

  @override
  bool apply(GsubContext ctx) {
    if (!coverage.covers(ctx.current.glyphId)) return false;
    final index = classDef.classOf(ctx.current.glyphId);
    for (final rule in _ruleSets[index]) {
      if (_matchAndApply(
        ctx,
        rule,
        input: (position, glyphId) =>
            rule.input[position - 1] == classDef.classOf(glyphId),
        backtrack: _never,
        lookahead: _never,
      )) {
        return true;
      }
    }
    return false;
  }

  @override
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  ) => _collectRuleOutputs(_ruleSets, recurseInto);
}

/// Type 5 format 3 — one coverage table per input position.
final class ContextSubstFormat3 extends GsubSubtable {
  ContextSubstFormat3._(this._coverages, this._records);

  static ContextSubstFormat3 parse(ByteReader r) {
    final base = r.position;
    final glyphCount = r.uint16At(base + 2);
    final recordCount = r.uint16At(base + 4);
    final coverages = List<Coverage>.generate(
      glyphCount,
      (i) => Coverage.parse(r.at(base + r.uint16At(base + 6 + i * 2))),
      growable: false,
    );
    return ContextSubstFormat3._(
      coverages,
      _readRecords(r, base + 6 + glyphCount * 2, recordCount),
    );
  }

  final List<Coverage> _coverages;
  final List<SequenceLookupRecord> _records;

  @override
  int get type => 5;

  @override
  bool apply(GsubContext ctx) {
    if (_coverages.isEmpty) return false;
    if (!_coverages[0].covers(ctx.current.glyphId)) return false;
    final positions = matchInput(
      ctx,
      _coverages.length,
      (position, glyphId) => _coverages[position].covers(glyphId),
    );
    if (positions == null) return false;
    return applySequenceLookups(
      ctx,
      positions,
      positions[positions.length - 1] + 1,
      _records,
    );
  }

  @override
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  ) {
    for (final record in _records) {
      recurseInto(record.lookupListIndex);
    }
  }
}

/// Type 6 format 1 — chaining context by literal glyph id.
final class ChainContextSubstFormat1 extends GsubSubtable {
  ChainContextSubstFormat1._(this.coverage, this._ruleSets);

  static ChainContextSubstFormat1 parse(ByteReader r) {
    final base = r.position;
    final coverage = Coverage.parse(r.at(base + r.uint16At(base + 2)));
    final count = r.uint16At(base + 4);
    return ChainContextSubstFormat1._(
      coverage,
      _RuleSets(r, _offsetList(r, base, base + 6, count), _readChainRule),
    );
  }

  final Coverage coverage;
  final _RuleSets _ruleSets;

  @override
  int get type => 6;

  @override
  bool apply(GsubContext ctx) {
    final index = coverage.index(ctx.current.glyphId);
    if (index < 0) return false;
    for (final rule in _ruleSets[index]) {
      if (_matchAndApply(
        ctx,
        rule,
        input: (position, glyphId) => rule.input[position - 1] == glyphId,
        backtrack: (position, glyphId) => rule.backtrack[position] == glyphId,
        lookahead: (position, glyphId) => rule.lookahead[position] == glyphId,
      )) {
        return true;
      }
    }
    return false;
  }

  @override
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  ) => _collectRuleOutputs(_ruleSets, recurseInto);
}

/// Type 6 format 2 — chaining context by glyph class, with a SEPARATE ClassDef
/// for backtrack, input and lookahead. Using the input ClassDef for all three
/// is a real and common bug; the three tables genuinely differ.
final class ChainContextSubstFormat2 extends GsubSubtable {
  ChainContextSubstFormat2._(
    this.coverage,
    this.backtrackClassDef,
    this.inputClassDef,
    this.lookaheadClassDef,
    this._ruleSets,
  );

  static ChainContextSubstFormat2 parse(ByteReader r) {
    final base = r.position;
    final coverage = Coverage.parse(r.at(base + r.uint16At(base + 2)));

    ClassDef classAt(int offsetPosition) {
      final offset = r.uint16At(offsetPosition);
      return offset == 0 ? ClassDef.empty : ClassDef.parse(r.at(base + offset));
    }

    final count = r.uint16At(base + 10);
    return ChainContextSubstFormat2._(
      coverage,
      classAt(base + 4),
      classAt(base + 6),
      classAt(base + 8),
      _RuleSets(r, _offsetList(r, base, base + 12, count), _readChainRule),
    );
  }

  final Coverage coverage;
  final ClassDef backtrackClassDef;
  final ClassDef inputClassDef;
  final ClassDef lookaheadClassDef;
  final _RuleSets _ruleSets;

  @override
  int get type => 6;

  @override
  bool apply(GsubContext ctx) {
    if (!coverage.covers(ctx.current.glyphId)) return false;
    final index = inputClassDef.classOf(ctx.current.glyphId);
    for (final rule in _ruleSets[index]) {
      if (_matchAndApply(
        ctx,
        rule,
        input: (position, glyphId) =>
            rule.input[position - 1] == inputClassDef.classOf(glyphId),
        backtrack: (position, glyphId) =>
            rule.backtrack[position] == backtrackClassDef.classOf(glyphId),
        lookahead: (position, glyphId) =>
            rule.lookahead[position] == lookaheadClassDef.classOf(glyphId),
      )) {
        return true;
      }
    }
    return false;
  }

  @override
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  ) => _collectRuleOutputs(_ruleSets, recurseInto);
}

/// Type 6 format 3 — a coverage table per position in all three arrays.
///
/// This is the one Vazirmatn leans on hardest: `uniFE98` becomes
/// `uniFE98.long` in `کوردستان` only because a format 3 rule saw an
/// alef-final in the lookahead. Every `.long` / `.long1` / `.long2` alternate
/// in the corpus arrives this way.
final class ChainContextSubstFormat3 extends GsubSubtable {
  ChainContextSubstFormat3._(
    this._backtrack,
    this._input,
    this._lookahead,
    this._records,
  );

  static ChainContextSubstFormat3 parse(ByteReader r) {
    final base = r.position;

    var p = base + 2;
    List<Coverage> coverages() {
      final count = r.uint16At(p);
      final out = List<Coverage>.generate(
        count,
        (i) => Coverage.parse(r.at(base + r.uint16At(p + 2 + i * 2))),
        growable: false,
      );
      p += 2 + count * 2;
      return out;
    }

    final backtrack = coverages();
    final input = coverages();
    final lookahead = coverages();
    final recordCount = r.uint16At(p);
    return ChainContextSubstFormat3._(
      backtrack,
      input,
      lookahead,
      _readRecords(r, p + 2, recordCount),
    );
  }

  final List<Coverage> _backtrack;
  final List<Coverage> _input;
  final List<Coverage> _lookahead;
  final List<SequenceLookupRecord> _records;

  @override
  int get type => 6;

  @override
  bool apply(GsubContext ctx) {
    if (_input.isEmpty) return false;
    if (!_input[0].covers(ctx.current.glyphId)) return false;

    final positions = matchInput(
      ctx,
      _input.length,
      (position, glyphId) => _input[position].covers(glyphId),
    );
    if (positions == null) return false;

    final matchEnd = positions[positions.length - 1] + 1;
    if (!matchLookahead(
      ctx,
      _lookahead.length,
      matchEnd,
      (position, glyphId) => _lookahead[position].covers(glyphId),
    )) {
      return false;
    }
    if (!matchBacktrack(
      ctx,
      _backtrack.length,
      (position, glyphId) => _backtrack[position].covers(glyphId),
    )) {
      return false;
    }
    return applySequenceLookups(ctx, positions, matchEnd, _records);
  }

  @override
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  ) {
    for (final record in _records) {
      recurseInto(record.lookupListIndex);
    }
  }
}

void _collectRuleOutputs(
  _RuleSets ruleSets,
  void Function(int lookupIndex) recurseInto,
) {
  for (var i = 0; i < ruleSets.length; i++) {
    for (final rule in ruleSets[i]) {
      for (final record in rule.records) {
        recurseInto(record.lookupListIndex);
      }
    }
  }
}

bool _never(int position, int glyphId) => false;

// ── type 8: reverse chaining single ───────────────────────────────────────────

/// Type 8 — a single substitution with a chaining context, applied RIGHT TO
/// LEFT.
///
/// It is its own pass and it cannot be recursed into, both by spec. The reason
/// is that its lookahead is meant to see glyphs this same lookup has ALREADY
/// rewritten, which only holds if the whole buffer is walked backwards in one
/// go — running it inside a forward pass would give it a lookahead of
/// un-substituted glyphs and quietly change the result.
final class ReverseChainSingleSubst extends GsubSubtable {
  ReverseChainSingleSubst._(
    this.coverage,
    this._backtrack,
    this._lookahead,
    this._substitutes,
  );

  static ReverseChainSingleSubst parse(ByteReader r, int format) {
    if (format != 1) {
      throw FontFormatException(
        'unknown ReverseChainSingleSubst format $format',
      );
    }
    final base = r.position;
    final coverage = Coverage.parse(r.at(base + r.uint16At(base + 2)));

    var p = base + 4;
    List<Coverage> coverages() {
      final count = r.uint16At(p);
      final out = List<Coverage>.generate(
        count,
        (i) => Coverage.parse(r.at(base + r.uint16At(p + 2 + i * 2))),
        growable: false,
      );
      p += 2 + count * 2;
      return out;
    }

    final backtrack = coverages();
    final lookahead = coverages();
    final count = r.uint16At(p);
    return ReverseChainSingleSubst._(
      coverage,
      backtrack,
      lookahead,
      r.at(p + 2).readUint16List(count),
    );
  }

  final Coverage coverage;
  final List<Coverage> _backtrack;
  final List<Coverage> _lookahead;
  final List<int> _substitutes;

  @override
  int get type => 8;

  @override
  bool apply(GsubContext ctx) {
    // Never valid as a nested lookup; see the class comment.
    if (ctx.depth != 0) return false;

    final index = coverage.index(ctx.current.glyphId);
    if (index < 0 || index >= _substitutes.length) return false;

    if (!matchBacktrack(
      ctx,
      _backtrack.length,
      (position, glyphId) => _backtrack[position].covers(glyphId),
    )) {
      return false;
    }
    // Lookahead starts one past the single input glyph.
    if (!matchLookahead(
      ctx,
      _lookahead.length,
      ctx.index + 1,
      (position, glyphId) => _lookahead[position].covers(glyphId),
    )) {
      return false;
    }

    ctx.substituteGlyph(ctx.index, _substitutes[index]);
    // Deliberately does NOT move `ctx.index`: the backward driver owns the
    // cursor, and a reverse lookup consumes exactly the glyph it stands on.
    return true;
  }

  @override
  void collectOutputGlyphs(
    Set<int> into,
    void Function(int lookupIndex) recurseInto,
  ) => into.addAll(_substitutes);
}
