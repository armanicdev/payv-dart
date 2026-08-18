/// Where a line MAY break — UAX #14, the pragmatic subset.
///
/// The full algorithm is a 40-class pair table. This is not that, and says so:
/// it implements the rules that decide a real document — mandatory breaks,
/// breaks after a space run, after a hyphen, after ZWSP, and the *prohibitions*
/// that go wrong most visibly (never inside a grapheme cluster, never between a
/// base and its marks, never at an NBSP, never between CR and LF).
///
/// The prohibitions are the half that matters here. A missed break opportunity
/// costs a slightly short line; a break taken between `ڵ` and the fatha sitting
/// on it puts the diacritic alone at the head of the next line, which on a
/// a printed invoice reads as a different word. So the omissions below are all on
/// the "did not break" side, never on the "broke somewhere illegal" side.
///
/// Deliberately absent: line-break classes for CJK (which breaks almost
/// anywhere), the numeric-context rules LB25 beyond the one hyphen case, and
/// tailoring by language. All three are additive; none of them can make an
/// existing opportunity illegal.
library;

import '../text/unicode.dart';

/// One place a line may end.
///
/// Two indices, not one, because a hard break consumes characters: the `\n`
/// belongs to neither the line before it nor the line after it. For a soft
/// break they are equal — the spaces stay on the line that ends and are simply
/// not measured.
class BreakOpportunity {
  const BreakOpportunity({
    required this.contentEnd,
    required this.nextStart,
    required this.mandatory,
  });

  /// Exclusive UTF-16 index where the text on THIS line stops.
  final int contentEnd;

  /// UTF-16 index where the following line starts.
  final int nextStart;

  /// True for a hard break (`\n`, `\r\n`, U+2028…) and for the end of the
  /// text. Justification skips these lines — stretching the last line of a
  /// paragraph to the full measure is the single most recognisable sign of a
  /// layout engine that was not finished.
  final bool mandatory;

  @override
  String toString() =>
      'BreakOpportunity($contentEnd→$nextStart'
      '${mandatory ? ", mandatory" : ""})';
}

abstract final class LineBreaker {
  /// Every break opportunity in [text], in order, ending with a mandatory one
  /// at `text.length` (UAX #14 LB3 — the end of text is always a break).
  ///
  /// Indices are UTF-16, the caller's own coordinates, so a returned range can
  /// be handed straight back to `String.substring`.
  static List<BreakOpportunity> opportunities(String text) {
    final out = <BreakOpportunity>[];
    if (text.isEmpty) {
      return <BreakOpportunity>[
        const BreakOpportunity(contentEnd: 0, nextStart: 0, mandatory: true),
      ];
    }

    final n = text.length;
    var i = 0;
    var previous = -1; // scalar before the current position, -1 at the start
    while (i < n) {
      final (scalar, width) = _scalarAt(text, i);

      if (_isMandatory(scalar)) {
        // LB5. CRLF is ONE break, not two — split it and every Windows-authored
        // paragraph grows a blank line.
        var after = i + width;
        if (scalar == 0x000D && after < n && text.codeUnitAt(after) == 0x000A) {
          after++;
        }
        out.add(
          BreakOpportunity(contentEnd: i, nextStart: after, mandatory: true),
        );
        previous = scalar;
        i = after;
        continue;
      }

      if (previous >= 0 && _mayBreakBetween(previous, scalar)) {
        out.add(
          BreakOpportunity(contentEnd: i, nextStart: i, mandatory: false),
        );
      }

      previous = scalar;
      i += width;
    }

    out.add(BreakOpportunity(contentEnd: n, nextStart: n, mandatory: true));
    return out;
  }

  /// Grapheme-cluster starts in `[start, end)`, for emergency breaking.
  ///
  /// Used only when a single unbreakable chunk is wider than the box. Letting
  /// it overflow silently is the worse failure: an IBAN or a 12-digit meter
  /// number would run off the edge of a receipt with nothing in the output to
  /// say it had.
  ///
  /// Approximate against UAX #29 — it handles marks, ZWJ sequences and CRLF,
  /// and does not handle regional-indicator pairs or the Indic conjunct rules.
  /// Both of those only ever cause a break to be taken one cluster later than
  /// it should be, never inside a letter.
  static List<int> graphemeStarts(String text, int start, int end) {
    final out = <int>[];
    var i = start;
    var previous = -1;
    while (i < end) {
      final (scalar, width) = _scalarAt(text, i);
      if (previous >= 0 && !_isGraphemeExtender(previous, scalar)) out.add(i);
      previous = scalar;
      i += width;
    }
    return out;
  }

  /// `end` with trailing breakable whitespace removed.
  ///
  /// Trailing spaces sit on the line but are not measured (UAX #14 LB18, and
  /// every typesetter since Gutenberg): a right-aligned line whose width
  /// includes its trailing space is visibly short of the margin, and a
  /// justified one distributes space it should have thrown away.
  static int trimTrailing(String text, int start, int end) {
    var i = end;
    while (i > start) {
      final before = _scalarBefore(text, i, start);
      if (before == null || !_isBreakableSpace(before.$1)) break;
      i -= before.$2;
    }
    return i;
  }

  /// True where word spacing and justification apply — U+0020 only.
  ///
  /// Not NBSP, whose whole job is to not be a break, and not the fixed-width
  /// spaces, which are fixed on purpose. Stretching either of those is how a
  /// column of figures ends up misaligned by a justification pass.
  static bool isJustifiableSpace(int scalar) => scalar == 0x0020;

  // ── the rules ───────────────────────────────────────────────────────────────

  /// May a line break between [before] and [after]?
  ///
  /// Ordered as UAX #14 orders its rules: the prohibitions run first and win,
  /// and only what survives all of them is an opportunity.
  static bool _mayBreakBetween(int before, int after) {
    // LB6 — never break before a hard break character; the break belongs to
    // the character itself and is emitted above.
    if (_isMandatory(after)) return false;

    // LB9/LB10 — a combining mark is part of the character it sits on. This is
    // the rule that keeps a Kurdish diacritic with its letter.
    if (isMark(after) || after == _zwj) return false;

    // LB8a — no break after ZWJ, which exists precisely to forbid one.
    if (before == _zwj) return false;

    // LB12/LB12a — glue (NBSP, figure space, narrow NBSP) welds both sides.
    if (_isGlue(before) || _isGlue(after)) return false;

    // LB7 — no break BEFORE a space or a ZWSP; the opportunity is after the
    // whole run of them, which falls out of testing `before` instead.
    if (_isBreakableSpace(after) || after == _zwsp) return false;

    // LB8 — break after ZWSP, the invisible "you may break here" character.
    if (before == _zwsp) return true;

    // LB18 — break after a space run.
    if (_isBreakableSpace(before)) return true;

    // LB21/LB23 — break after a hyphen, EXCEPT before a digit. `-5` is a
    // signed number and `2026-08` is a date; breaking either leaves a line
    // that starts with a bare figure and reads as a different value.
    if (_isBreakAfter(before)) {
      if (before == 0x002D && after >= 0x0030 && after <= 0x0039) return false;
      return true;
    }

    return false;
  }

  /// UAX #14 classes BK, CR, LF and NL — the breaks a document author wrote.
  static bool _isMandatory(int c) =>
      c == 0x000A ||
      c == 0x000B ||
      c == 0x000C ||
      c == 0x000D ||
      c == 0x0085 ||
      c == 0x2028 ||
      c == 0x2029;

  /// Class SP, plus the Unicode spaces that behave like it.
  static bool _isBreakableSpace(int c) =>
      c == 0x0020 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x2006) ||
      (c >= 0x2008 && c <= 0x200A) ||
      c == 0x205F ||
      c == 0x3000;

  /// Class GL — spaces that forbid a break on either side.
  static bool _isGlue(int c) =>
      c == 0x00A0 || c == 0x2007 || c == 0x202F || c == 0x180E;

  /// Class BA/HY — break opportunity after.
  ///
  /// The tab is here rather than with the spaces because it is not trimmed at
  /// the end of a line: a tab carries width in the columns some callers lay
  /// out with it, and silently dropping it would move their figures.
  static bool _isBreakAfter(int c) =>
      c == 0x0009 ||
      c == 0x002D ||
      c == 0x00AD ||
      c == 0x2010 ||
      c == 0x2012 ||
      c == 0x2013 ||
      c == 0x2014 ||
      c == 0x058A ||
      c == 0x2027;

  static bool _isGraphemeExtender(int before, int after) =>
      isMark(after) ||
      after == _zwj ||
      before == _zwj ||
      (before == 0x000D && after == 0x000A);

  /// The scalar starting at [i], and how many UTF-16 units it occupies.
  static (int, int) _scalarAt(String text, int i) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xD800 && unit < 0xDC00 && i + 1 < text.length) {
      final low = text.codeUnitAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        return (0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00), 2);
      }
    }
    return (unit, 1);
  }

  /// The scalar ending at [i], walking backwards, or null at [floor].
  static (int, int)? _scalarBefore(String text, int i, int floor) {
    if (i <= floor) return null;
    final unit = text.codeUnitAt(i - 1);
    if (unit >= 0xDC00 && unit <= 0xDFFF && i - 2 >= floor) {
      final high = text.codeUnitAt(i - 2);
      if (high >= 0xD800 && high < 0xDC00) {
        return (0x10000 + ((high - 0xD800) << 10) + (unit - 0xDC00), 2);
      }
    }
    return (unit, 1);
  }

  static const int _zwsp = 0x200B;
  static const int _zwj = 0x200D;
}
