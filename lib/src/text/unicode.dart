/// Typed accessors over the generated Unicode Character Database tables.
///
/// Everything here is a one-line binary search into [unicode_data.g.dart]. The
/// indirection earns its keep by being the only place that knows the generated
/// tables' encoding: the bidi pass, the script itemizer and the Arabic joining
/// state machine all ask questions in the vocabulary of [JoiningType],
/// [GeneralCategory] and UAX #9 class indices, and never touch an `Int32List`.
library;

import '../shaping/glyph_buffer.dart';
import 'unicode_data.g.dart';

export 'unicode_data.g.dart' show bidiClassNames, scriptNames, unicodeVersion;

/// Arabic joining type — one of the [JoiningType] constants.
int joiningTypeOf(int codepoint) => lookupRange(joiningTypeRanges, codepoint);

/// Unicode general category, narrowed to the [GeneralCategory] constants.
int generalCategoryOf(int codepoint) =>
    lookupRange(generalCategoryRanges, codepoint);

/// UAX #9 bidirectional character type, as an index into [bidiClassNames].
int bidiClassOf(int codepoint) => lookupRange(bidiClassRanges, codepoint);

/// True for Mn, Mc and Me.
///
/// This is the test that decides whether a glyph may be reordered away from the
/// base it belongs to, so it deliberately includes Mc (spacing marks): a
/// spacing mark still belongs to its cluster even though it carries width.
bool isMark(int codepoint) =>
    GeneralCategory.isMark(generalCategoryOf(codepoint));

/// Unicode Script property, as an index into [scriptNames]. 0 is `Unknown`.
int scriptOf(int codepoint) => lookupRange(scriptRanges, codepoint);

/// Bidi_Paired_Bracket_Type: [bracketNone], [bracketOpen] or [bracketClose].
int bracketTypeOf(int codepoint) =>
    lookupRange(bidiBracketRanges, codepoint) & 3;

/// The codepoint that closes (or opens) [codepoint], or -1 when it is not a
/// paired bracket.
int pairedBracketOf(int codepoint) {
  final packed = lookupRange(bidiBracketRanges, codepoint);
  return packed == 0 ? -1 : packed >> 2;
}

const int bracketNone = 0;
const int bracketOpen = 1;
const int bracketClose = 2;

/// Decodes a Dart [String] (UTF-16) into Unicode scalars.
///
/// Returns the scalars plus a parallel list giving each scalar's index in the
/// original string. The second list is not a convenience: a cluster produced by
/// shaping has to be reportable in the *caller's* coordinates so that a PDF
/// `ActualText` span or a hit test lands on the right characters, and a scalar
/// index silently disagrees with a UTF-16 index the moment an emoji, a rare CJK
/// ideograph or an Adlam letter appears.
///
/// An unpaired surrogate — which a Dart `String` can legally hold — is replaced
/// with U+FFFD rather than thrown on. Text arrives from files and network
/// payloads; refusing to lay out a document because one byte pair is malformed
/// is worse than drawing a replacement character where the damage is.
(List<int> scalars, List<int> utf16Offsets) toScalars(String s) {
  final scalars = <int>[];
  final offsets = <int>[];
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF && i + 1 < units.length) {
      final low = units[i + 1];
      if (low >= 0xDC00 && low <= 0xDFFF) {
        scalars.add(0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00));
        offsets.add(i);
        i++;
        continue;
      }
    }
    scalars.add(u >= 0xD800 && u <= 0xDFFF ? 0xFFFD : u);
    offsets.add(i);
  }
  return (scalars, offsets);
}
