/// Splits text into runs of a single OpenType script.
///
/// Shaping is per-script: the Arabic joining state machine, the Indic reorder
/// and the plain Latin path are different pipelines, and a font's `GSUB`
/// features are registered under a script tag. So the text has to be cut into
/// runs first — and cut in the right places, which is the whole difficulty.
/// The space in `سەرۆک وەزیران` and the comma in `کۆیە، هەولێر` carry the
/// Unicode script `Common`; treat them as their own run and the Arabic run
/// splits in two, the joining state machine restarts, and both words render
/// with final/initial forms where they should have medial ones.
library;

import 'dart:typed_data';

import '../util/tag.dart';
import 'unicode.dart';

/// A maximal range of scalars that shapes under one OpenType script tag.
class ScriptRun {
  const ScriptRun(this.start, this.end, this.scriptTag);

  /// First scalar index in the run.
  final int start;

  /// One past the last scalar index.
  final int end;

  /// Packed OpenType script tag — [Tag.arab], [Tag.latn], `DFLT`, …
  final int scriptTag;

  int get length => end - start;

  @override
  String toString() => 'ScriptRun($start..$end, ${Tag(scriptTag).asString})';
}

class ScriptItemizer {
  ScriptItemizer._();

  /// Cuts [scalars] into runs of one script.
  ///
  /// `Common` and `Inherited` characters — spaces, punctuation, digits,
  /// combining marks — never start a run. They extend whichever script run they
  /// follow, and a leading group of them joins the first real script that
  /// appears. Text that is entirely `Common` (a bare `"125,000"`) is tagged
  /// `DFLT`, which is what HarfBuzz does and what makes a font's default
  /// language system the one that shapes it.
  ///
  /// Not implemented: UAX #24's extended pairing, which would give a closing
  /// bracket the script of its *opener* rather than of the text just before it
  /// (`عربی (latin)` — the final `)` becomes Latin here, Arabic there). No font
  /// shapes a parenthesis differently between the two, so it buys nothing but a
  /// stack.
  static List<ScriptRun> itemize(List<int> scalars) {
    final n = scalars.length;
    if (n == 0) return const <ScriptRun>[];

    final runs = <ScriptRun>[];
    var runStart = 0;
    var currentTag = -1; // no real script seen yet

    for (var i = 0; i < n; i++) {
      final script = scriptOf(scalars[i]);
      if (script == _commonId ||
          script == _inheritedId ||
          script == _unknownId) {
        continue;
      }
      // Runs are cut on the TAG, not on the Unicode script: Hiragana and
      // Katakana are two scripts under one `kana` tag, and splitting between
      // them would break a `GSUB` rule that spans the boundary for no gain.
      final tag = tagForScript(script);
      if (currentTag == -1) {
        currentTag = tag;
      } else if (tag != currentTag) {
        runs.add(ScriptRun(runStart, i, currentTag));
        runStart = i;
        currentTag = tag;
      }
    }

    runs.add(ScriptRun(runStart, n, currentTag == -1 ? Tag.dflt : currentTag));
    return runs;
  }

  /// OpenType script tag for a Unicode script id (an index into `scriptNames`).
  /// Scripts with no entry resolve to `DFLT`, so an unmapped script still finds
  /// the font's default language system instead of finding nothing.
  static int tagForScript(int scriptId) =>
      scriptId >= 0 && scriptId < _tagByScriptId.length
      ? _tagByScriptId[scriptId]
      : Tag.dflt;
}

final int _commonId = scriptNames.indexOf('Common');
final int _inheritedId = scriptNames.indexOf('Inherited');
const int _unknownId = 0;

/// Unicode script name → OpenType script tag.
///
/// Two places where this is not a transliteration of the ISO 15924 code, and
/// both matter:
///
///  * Hiragana and Katakana share `kana`. The registry has no separate tag, and
///    Japanese fonts register their kana features under the one.
///  * The Indic scripts use their *v2* tags (`dev2`, `bng2`, …). The v1 tags
///    (`deva`) select a lookup order that expects the shaper to do the Indic
///    reordering the old way; every font built this century registers v2, and
///    HarfBuzz tries v2 first for the same reason.
const Map<String, String> _openTypeScriptTags = <String, String>{
  // ── cursive-joining scripts (the ones the Arabic shaper claims) ────────────
  'Arabic': 'arab',
  'Syriac': 'syrc',
  'Nko': 'nko',
  'Thaana': 'thaa',
  'Mongolian': 'mong',
  'Adlam': 'adlm',
  'Mandaic': 'mand',
  'Manichaean': 'mani',
  'Psalter_Pahlavi': 'phlp',
  'Hanifi_Rohingya': 'rohg',
  'Sogdian': 'sogd',
  'Old_Sogdian': 'sogo',
  'Old_Uyghur': 'ougr',
  'Chorasmian': 'chrs',
  'Phags_Pa': 'phag',

  // ── alphabets ─────────────────────────────────────────────────────────────
  'Latin': 'latn',
  'Cyrillic': 'cyrl',
  'Greek': 'grek',
  'Hebrew': 'hebr',
  'Armenian': 'armn',
  'Georgian': 'geor',
  'Coptic': 'copt',
  'Glagolitic': 'glag',
  'Gothic': 'goth',
  'Runic': 'runr',
  'Ogham': 'ogam',
  'Cherokee': 'cher',
  'Deseret': 'dsrt',
  'Osage': 'osge',
  'Shavian': 'shaw',
  'Vai': 'vai',
  'Tifinagh': 'tfng',
  'Ethiopic': 'ethi',
  'Canadian_Aboriginal': 'cans',
  'Braille': 'brai',

  // ── CJK ───────────────────────────────────────────────────────────────────
  'Han': 'hani',
  'Hiragana': 'kana',
  'Katakana': 'kana',
  'Hangul': 'hang',
  'Bopomofo': 'bopo',
  'Yi': 'yi',
  'Nushu': 'nshu',
  'Tangut': 'tang',

  // ── Brahmic ───────────────────────────────────────────────────────────────
  'Devanagari': 'dev2',
  'Bengali': 'bng2',
  'Gurmukhi': 'gur2',
  'Gujarati': 'gjr2',
  'Oriya': 'ory2',
  'Tamil': 'tml2',
  'Telugu': 'tel2',
  'Kannada': 'knd2',
  'Malayalam': 'mlm2',
  'Sinhala': 'sinh',
  'Myanmar': 'mym2',
  'Khmer': 'khmr',
  'Thai': 'thai',
  'Lao': 'lao',
  'Tibetan': 'tibt',
  'Tai_Tham': 'lana',
  'Tai_Le': 'tale',
  'New_Tai_Lue': 'talu',
  'Tai_Viet': 'tavt',
  'Balinese': 'bali',
  'Javanese': 'java',
  'Sundanese': 'sund',
  'Batak': 'batk',
  'Buginese': 'bugi',
  'Rejang': 'rjng',
  'Cham': 'cham',
  'Kayah_Li': 'kali',
  'Lepcha': 'lepc',
  'Limbu': 'limb',
  'Meetei_Mayek': 'mtei',
  'Syloti_Nagri': 'sylo',
  'Chakma': 'cakm',
  'Sharada': 'shrd',
  'Takri': 'takr',
  'Khojki': 'khoj',
  'Khudawadi': 'sind',
  'Multani': 'mult',
  'Modi': 'modi',
  'Grantha': 'gran',
  'Tirhuta': 'tirh',
  'Newa': 'newa',
  'Ahom': 'ahom',
  'Brahmi': 'brah',
  'Kaithi': 'kthi',
  'Kharoshthi': 'khar',
  'Saurashtra': 'saur',
  'Mahajani': 'mahj',
};

/// Script id → packed tag, resolved once. Built as a flat [Int32List] because
/// itemization asks this question per run and a map lookup on a string would be
/// the most expensive thing in an otherwise integer pipeline.
final Int32List _tagByScriptId = () {
  final out = Int32List(scriptNames.length);
  for (var i = 0; i < scriptNames.length; i++) {
    final tag = _openTypeScriptTags[scriptNames[i]];
    out[i] = tag == null ? Tag.dflt : Tag.parse(tag);
  }
  return out;
}();
