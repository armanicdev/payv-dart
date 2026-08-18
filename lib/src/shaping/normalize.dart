/// Unicode normalisation, done for shaping rather than for storage.
///
/// A font's `GSUB` rules are written against ONE spelling of a word. Unicode
/// allows several: `بِّ` can be typed shadda-then-kasra or kasra-then-shadda, and
/// `é` can arrive as one codepoint or as two. Feed the font the spelling it was
/// not written for and the rule silently does not match — no error, no fallback,
/// just a diacritic sitting in the wrong place on a printed form.
///
/// So this runs three rounds, which are HarfBuzz's:
///
///  1. **Decompose** any character the font has no glyph for, in the hope that it
///     has glyphs for the pieces. A character the font DOES have is left alone —
///     that short circuit is what keeps a fully-composed Latin document from
///     being taken apart and put back together for nothing.
///  2. **Sort** each run of combining marks by combining class, so the two
///     spellings above become one.
///  3. **Recompose** what the font can draw as a unit, because a font's
///     mark-positioning is usually better than a font's mark-stacking.
///
/// What it deliberately does NOT do is compatibility normalisation. NFKC would
/// fold ﷼ into ر ي ا ل and a superscript ² into a plain 2 — that is rewriting
/// the document, not laying it out.
library;

import 'dart:typed_data';

import '../font/open_type_font.dart';
import '../text/unicode.dart';
import '../text/unicode_data.g.dart';
import 'default_shaper.dart';
import 'glyph_buffer.dart';

/// How aggressively to normalise.
enum NormalizationMode {
  /// Resolve glyphs and sort marks; never decompose or recompose. Correct only
  /// for a font known to cover the exact text.
  none,

  /// Decompose everything and leave it decomposed. Some Indic and Khmer fonts
  /// are built this way.
  decomposed,

  /// Decompose what the font cannot draw, then recompose what it can. The
  /// default, and what every OpenType font since the 1990s expects.
  composedDiacritics,
}

/// The maximum length of a mark run this will bother to sort.
///
/// The sort is insertion sort — O(n²) — because a real mark run is two or three
/// marks and insertion sort wins there. A pathological string of a thousand
/// combining characters (a "Zalgo" payload, which is a real thing to receive
/// from a web form) would make that a denial of service, so runs longer than
/// this are left in their typed order. HarfBuzz caps at the same place.
const int maxCombiningMarks = 32;

/// Canonical_Combining_Class of [codepoint].
int combiningClassOf(int codepoint) =>
    lookupRange(combiningClassRanges, codepoint);

/// The combining class HarfBuzz sorts by, which is not always Unicode's.
///
/// Unicode's Hebrew classes put the points in an order no Hebrew font is built
/// for — sheva, dagesh and the shin dot come out interleaved wrongly — and the
/// Arabic classes are shifted up by one so that a mark reordering pass has a
/// value to insert between them. UAX #15 explicitly permits a shaper to use its
/// own order internally as long as the result is canonically equivalent, and
/// every OpenType shaper does.
int modifiedCombiningClassOf(int codepoint) {
  final ccc = combiningClassOf(codepoint);
  return ccc < _modifiedCombiningClass.length
      ? _modifiedCombiningClass[ccc]
      : ccc;
}

/// Normalises [buffer] in place and resolves every glyph id.
///
/// On return, `infos[i].glyphId` is set for every glyph — this is the only place
/// the `cmap` is consulted, because it is the only place that knows whether a
/// character survived as itself or was taken apart.
class Normalizer {
  Normalizer(this.font, {this.mode = NormalizationMode.composedDiacritics});

  final OpenTypeFont font;
  final NormalizationMode mode;

  void normalize(GlyphBuffer buffer, ScriptShaper shaper) {
    if (buffer.isEmpty) return;
    _decomposeRound(buffer);
    _sortMarks(buffer, shaper);
    if (mode == NormalizationMode.composedDiacritics) _recompose(buffer);
  }

  // ── round 1 ────────────────────────────────────────────────────────────────

  void _decomposeRound(GlyphBuffer buffer) {
    final shortest = mode != NormalizationMode.decomposed;
    final out = <GlyphInfo>[];

    for (final info in buffer.infos) {
      // The short circuit. A character the font draws directly is emitted as
      // itself, and this is by far the common path: for `Payment Receipt` it is
      // every glyph, and for Kurdish it is every glyph too.
      if (shortest) {
        final gid = font.glyphForCodepoint(info.codepoint);
        if (gid != 0) {
          info.glyphId = gid;
          out.add(info);
          continue;
        }
      }
      if (!_decompose(out, info, info.codepoint, shortest)) {
        // Nothing worked: emit whatever the cmap gave us, which may well be
        // .notdef. A missing glyph is the font's problem to show, not ours to
        // hide — silently dropping the character would make a truncated name on
        // a form look like the data someone actually entered.
        info.glyphId = font.glyphForCodepoint(info.codepoint);
        out.add(info);
      }
    }

    _replace(buffer, out);
  }

  /// Emits the canonical decomposition of [ab] into [out], recursing until it
  /// reaches characters the font can draw. Returns false when it cannot.
  bool _decompose(
    List<GlyphInfo> out,
    GlyphInfo source,
    int ab,
    bool shortest,
  ) {
    final (a, b) = _canonicalDecompose(ab);
    if (a < 0) return false;

    // Both halves have to be drawable or the split buys nothing — half a
    // character on the page is worse than a .notdef box, because it reads as
    // real text.
    final bGlyph = b < 0 ? 0 : font.glyphForCodepoint(b);
    if (b >= 0 && bGlyph == 0) return false;

    final aGlyph = font.glyphForCodepoint(a);

    if (shortest && aGlyph != 0) {
      out.add(_derive(source, a, aGlyph));
      if (b >= 0) out.add(_derive(source, b, bGlyph));
      return true;
    }

    if (_decompose(out, source, a, shortest)) {
      if (b >= 0) out.add(_derive(source, b, bGlyph));
      return true;
    }

    if (aGlyph != 0) {
      out.add(_derive(source, a, aGlyph));
      if (b >= 0) out.add(_derive(source, b, bGlyph));
      return true;
    }

    return false;
  }

  // ── round 2 ────────────────────────────────────────────────────────────────

  /// Sorts each run of combining marks by combining class.
  ///
  /// Insertion sort, and stable on purpose: two marks of the SAME class are
  /// canonically ordered by how they were typed, and reordering them would
  /// change the meaning.
  void _sortMarks(GlyphBuffer buffer, ScriptShaper shaper) {
    final infos = buffer.infos;
    final n = infos.length;

    for (var i = 0; i < n; i++) {
      if (modifiedCombiningClassOf(infos[i].codepoint) == 0) continue;

      var end = i + 1;
      while (end < n && modifiedCombiningClassOf(infos[end].codepoint) != 0) {
        end++;
      }

      if (end - i <= maxCombiningMarks) {
        for (var j = i + 1; j < end; j++) {
          final item = infos[j];
          final cc = modifiedCombiningClassOf(item.codepoint);
          var k = j;
          while (k > i &&
              modifiedCombiningClassOf(infos[k - 1].codepoint) > cc) {
            infos[k] = infos[k - 1];
            k--;
          }
          if (k != j) {
            infos[k] = item;
            // Moving a mark past its neighbours makes them one indivisible unit
            // for anything downstream that maps glyphs back to text.
            _mergeClusters(buffer, k, j + 1);
          }
        }
        shaper.reorderMarks(buffer, i, end);
      }
      i = end - 1;
    }
  }

  // ── round 3 ────────────────────────────────────────────────────────────────

  void _recompose(GlyphBuffer buffer) {
    final infos = buffer.infos;
    if (infos.length < 2) return;

    final out = <GlyphInfo>[infos.first];
    var starter = 0;

    for (var i = 1; i < infos.length; i++) {
      final cur = infos[i];
      final prev = out.last;

      // Only a mark is ever composed onto its starter. Composing two base
      // characters is both pointless for almost every script and actively wrong
      // for Hangul, whose fonts are not built to mix and match syllables.
      final isMark = GeneralCategory.isMark(cur.generalCategory);
      final blocked =
          starter != out.length - 1 &&
          modifiedCombiningClassOf(prev.codepoint) >=
              modifiedCombiningClassOf(cur.codepoint);

      if (isMark && !blocked) {
        final composed = _canonicalCompose(
          out[starter].codepoint,
          cur.codepoint,
        );
        if (composed >= 0) {
          final glyph = font.glyphForCodepoint(composed);
          if (glyph != 0) {
            // The starter and everything between it and the mark just absorbed
            // become one cluster: they are now drawn by a single glyph, so text
            // extraction has to hand all of them back together.
            var min = cur.cluster;
            for (var k = starter; k < out.length; k++) {
              if (out[k].cluster < min) min = out[k].cluster;
            }
            for (var k = starter; k < out.length; k++) {
              out[k].cluster = min;
            }
            out[starter]
              ..codepoint = composed
              ..glyphId = glyph
              ..generalCategory = generalCategoryOf(composed)
              ..joiningType = joiningTypeOf(composed);
            continue;
          }
        }
      }

      out.add(cur);
      if (combiningClassOf(cur.codepoint) == 0) starter = out.length - 1;
    }

    _replace(buffer, out);
  }

  // ── plumbing ───────────────────────────────────────────────────────────────

  GlyphInfo _derive(GlyphInfo source, int codepoint, int glyphId) => GlyphInfo(
    glyphId: glyphId,
    codepoint: codepoint,
    cluster: source.cluster,
    generalCategory: generalCategoryOf(codepoint),
    joiningType: joiningTypeOf(codepoint),
    mask: source.mask,
  );

  static void _replace(GlyphBuffer buffer, List<GlyphInfo> infos) {
    if (identical(infos, buffer.infos)) return;
    buffer.infos
      ..clear()
      ..addAll(infos);
    buffer.positions
      ..clear()
      ..addAll(
        List<GlyphPosition>.generate(infos.length, (_) => GlyphPosition()),
      );
  }

  /// Collapses `[start, end)` onto the lowest cluster in the range.
  ///
  /// Downward only. Cluster values are the contract with `ActualText` and with
  /// hit testing, and both break the moment a cluster can grow.
  static void _mergeClusters(GlyphBuffer buffer, int start, int end) {
    var min = buffer.infos[start].cluster;
    for (var i = start + 1; i < end; i++) {
      if (buffer.infos[i].cluster < min) min = buffer.infos[i].cluster;
    }
    for (var i = start; i < end; i++) {
      buffer.infos[i].cluster = min;
    }
  }
}

/// Canonical decomposition of [ab] into (first, second); second is -1 for a
/// singleton and first is -1 when there is no decomposition.
(int, int) _canonicalDecompose(int ab) {
  // Hangul syllables decompose arithmetically — 11 172 of them, which is why
  // Unicode does not list them. See UAX #15 §16.
  if (ab >= _hangulSBase && ab < _hangulSBase + _hangulSCount) {
    final index = ab - _hangulSBase;
    final t = index % _hangulTCount;
    if (t != 0) {
      // LV + T. The LV half is itself a syllable, so a second pass takes it
      // apart further if anyone needs it decomposed all the way.
      return (_hangulSBase + index - t, _hangulTBase + t);
    }
    return (
      _hangulLBase + index ~/ _hangulNCount,
      _hangulVBase + index % _hangulNCount ~/ _hangulTCount,
    );
  }

  var lo = 0;
  var hi = canonicalDecompositions.length ~/ 3 - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final i = mid * 3;
    final cp = canonicalDecompositions[i];
    if (ab < cp) {
      hi = mid - 1;
    } else if (ab > cp) {
      lo = mid + 1;
    } else {
      return (canonicalDecompositions[i + 1], canonicalDecompositions[i + 2]);
    }
  }
  return (-1, -1);
}

/// Canonical composition of [a] + [b], or -1 when the pair does not compose.
int _canonicalCompose(int a, int b) {
  if (a >= _hangulLBase && a < _hangulLBase + _hangulLCount) {
    if (b >= _hangulVBase && b < _hangulVBase + _hangulVCount) {
      return _hangulSBase +
          ((a - _hangulLBase) * _hangulVCount + (b - _hangulVBase)) *
              _hangulTCount;
    }
  }
  if (a >= _hangulSBase && a < _hangulSBase + _hangulSCount) {
    if ((a - _hangulSBase) % _hangulTCount == 0 &&
        b > _hangulTBase &&
        b < _hangulTBase + _hangulTCount) {
      return a + (b - _hangulTBase);
    }
  }

  var lo = 0;
  var hi = canonicalCompositionPairs.length ~/ 3 - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final i = mid * 3;
    final pa = canonicalCompositionPairs[i];
    final pb = canonicalCompositionPairs[i + 1];
    if (a < pa || (a == pa && b < pb)) {
      hi = mid - 1;
    } else if (a > pa || (a == pa && b > pb)) {
      lo = mid + 1;
    } else {
      return canonicalCompositionPairs[i + 2];
    }
  }
  return -1;
}

const int _hangulSBase = 0xAC00;
const int _hangulLBase = 0x1100;
const int _hangulVBase = 0x1161;
const int _hangulTBase = 0x11A7;
const int _hangulLCount = 19;
const int _hangulVCount = 21;
const int _hangulTCount = 28;
const int _hangulNCount = _hangulVCount * _hangulTCount;
const int _hangulSCount = _hangulLCount * _hangulNCount;

/// Unicode combining class → the class this engine sorts by.
///
/// Identity except where a font's expectations and Unicode's numbering disagree:
///
///  * **Hebrew (10–26).** Unicode's order interleaves the vowel points and the
///    dagesh in a way no Hebrew font is cut for; this is the order Uniscribe,
///    CoreText and HarfBuzz all use instead.
///  * **Arabic (27–35).** Shifted up by one, leaving class 27 free so a
///    script-specific reordering pass has somewhere to put a mark.
///  * **Telugu, Thai, Lao, Tibetan.** Length and vowel marks that Unicode ranks
///    after the consonant the font wants them before.
final Uint8List _modifiedCombiningClass = () {
  final t = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    t[i] = i;
  }

  // Hebrew.
  t[10] = 22; // sheva
  t[11] = 15; // hataf segol
  t[12] = 21; // hataf patah
  t[13] = 17; // hataf qamats
  t[14] = 14; // hiriq
  t[15] = 25; // tsere
  t[16] = 18; // segol
  t[17] = 19; // patah
  t[18] = 20; // qamats
  t[19] = 24; // holam
  t[20] = 12; // qubuts
  t[21] = 13; // dagesh
  t[22] = 23; // meteg
  t[23] = 16; // rafe
  t[24] = 11; // shin dot
  t[25] = 10; // sin dot
  t[26] = 26; // point varika

  // Arabic and Syriac.
  for (var i = 27; i <= 35; i++) {
    t[i] = i + 1;
  }
  t[36] = 36; // Syriac superscript alaph

  // Telugu.
  t[84] = 4;
  t[91] = 5;

  // Thai.
  t[103] = 3;
  t[107] = 107;

  // Lao.
  t[118] = 118;
  t[122] = 122;

  // Tibetan.
  t[129] = 129;
  t[130] = 132;
  t[132] = 131;

  return t;
}();
