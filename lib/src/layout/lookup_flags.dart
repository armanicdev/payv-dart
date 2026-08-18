/// Lookup flags, and the iterator that makes them mean something.
///
/// A lookup's flags say which glyphs it is blind to. Nothing else in OpenType
/// depends on getting this right as completely as Arabic does: `ڵ` followed by
/// a shadda followed by `ا` is, to a `calt` lookup with `IgnoreMarks`, two
/// adjacent letters — and if the engine walks the buffer by raw index instead
/// of through [SkippyIterator], the shadda blocks the match, the ligature never
/// forms, and the word is silently wrong. Every context match in GSUB and GPOS
/// goes through this file.
library;

import '../shaping/glyph_buffer.dart';
import 'gdef.dart';

/// Bits of a Lookup table's `lookupFlag` field.
abstract final class LookupFlag {
  static const int rightToLeft = 0x0001;
  static const int ignoreBaseGlyphs = 0x0002;
  static const int ignoreLigatures = 0x0004;
  static const int ignoreMarks = 0x0008;
  static const int useMarkFilteringSet = 0x0010;

  /// High byte: when non-zero, marks of a *different* GDEF mark attachment
  /// class are skipped.
  static const int markAttachmentType = 0xFF00;
}

/// Walks a [GlyphBuffer] as a lookup sees it, skipping the glyph classes the
/// lookup's flags exclude.
///
/// Stateless with respect to the buffer — [next] and [prev] take the position
/// to move from — so one iterator can be reused across every match attempt of a
/// subtable without a reset. [index] is a convenience cursor for callers that
/// want one; the movers update it when they find something, and leave it alone
/// when they do not.
class SkippyIterator {
  SkippyIterator(
    this.buffer, {
    required this.lookupFlag,
    required this.markFilteringSet,
    this.gdef,
  });

  final GlyphBuffer buffer;
  final int lookupFlag;

  /// MarkGlyphSets index, meaningful only when
  /// [LookupFlag.useMarkFilteringSet] is set.
  final int markFilteringSet;

  final GdefTable? gdef;

  /// Caller-owned cursor. Set by [next]/[prev] on a hit.
  int index = 0;

  /// True when this lookup cannot see [info].
  bool shouldSkip(GlyphInfo info) {
    final glyphClass = info.glyphClass;

    // The GDEF class values (base 1, ligature 2, mark 3) were chosen so that
    // `1 << class` IS the matching ignore bit. One shift and one test covers
    // all three, which matters: this runs per glyph per match attempt.
    if (glyphClass >= GlyphClass.base &&
        glyphClass <= GlyphClass.mark &&
        lookupFlag & (1 << glyphClass) != 0) {
      return true;
    }

    // The remaining two filters narrow *which* marks are visible, so a
    // non-mark is already done.
    if (glyphClass != GlyphClass.mark) return false;

    if (lookupFlag & LookupFlag.useMarkFilteringSet != 0) {
      // A font that asks for a filtering set without shipping a GDEF to hold
      // one has excluded every mark, which is what HarfBuzz concludes too.
      final set = gdef;
      if (set == null) return true;
      return !set.isInMarkFilteringSet(markFilteringSet, info.glyphId);
    }

    // Deliberately `else`: the spec lets a lookup set both bits, and the
    // filtering set wins outright rather than intersecting with the class.
    final attachType = lookupFlag & LookupFlag.markAttachmentType;
    if (attachType != 0) {
      return info.markAttachClass != attachType >> 8;
    }
    return false;
  }

  /// Next visible index strictly after [from], or -1. Pass -1 to start at the
  /// beginning of the buffer.
  int next(int from) {
    for (var i = from + 1; i < buffer.length; i++) {
      if (!shouldSkip(buffer.infos[i])) {
        index = i;
        return i;
      }
    }
    return -1;
  }

  /// Previous visible index strictly before [from], or -1.
  int prev(int from) {
    var i = from - 1;
    if (i >= buffer.length) i = buffer.length - 1;
    for (; i >= 0; i--) {
      if (!shouldSkip(buffer.infos[i])) {
        index = i;
        return i;
      }
    }
    return -1;
  }

  /// The next [count] visible indices after [from], or null if the buffer runs
  /// out before that many are found.
  ///
  /// This is how a Sequence or LookAhead array is matched: the input glyphs of
  /// a chaining rule are consecutive *to the lookup*, never necessarily
  /// consecutive in the buffer.
  List<int>? forward(int from, int count) => _walk(from, count, forwards: true);

  /// The previous [count] visible indices before [from], nearest first, or null
  /// if the buffer runs out. Backtrack arrays are stored in exactly this order
  /// — closest to the input glyph first — so no reversal is needed.
  List<int>? backward(int from, int count) =>
      _walk(from, count, forwards: false);

  List<int>? _walk(int from, int count, {required bool forwards}) {
    if (count <= 0) return const <int>[];
    final saved = index;
    final out = List<int>.filled(count, 0);
    var at = from;
    for (var i = 0; i < count; i++) {
      at = forwards ? next(at) : prev(at);
      if (at < 0) {
        // A failed walk leaves no trace: the caller will try the next rule from
        // the same starting cursor.
        index = saved;
        return null;
      }
      out[i] = at;
    }
    return out;
  }
}
