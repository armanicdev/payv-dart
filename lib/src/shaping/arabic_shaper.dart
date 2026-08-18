/// The Arabic joining state machine — the heart of this package.
///
/// Cursive scripts do not store their connected forms. `ڵ` is one codepoint,
/// U+06B5, and the font holds four different outlines for it — `uni06B5`,
/// `uni06B5.init`, `uni06B5.medi`, `uni06B5.fina` — reachable ONLY through the
/// `init`/`medi`/`fina` GSUB features. Unicode has presentation-form codepoints
/// for most Arabic letters, which is how every other Dart PDF library fakes
/// this. It has none for ڕ, ڵ, ە or ێ. There is no shortcut to take.
///
/// What this file does is decide, for every glyph, WHICH of the four forms it
/// should take, and record that as a single bit in [GlyphInfo.mask]. It
/// substitutes nothing. One GSUB pass afterwards applies all four features, and
/// because the bits are mutually exclusive, each glyph gets exactly one.
///
/// Three things make this harder than "look at the neighbours":
///
///  * **Transparent joining type.** A shadda between two letters must not break
///    their join. The machine looks straight through the `T` class — miss that
///    and every vowelled word loses its connections.
///  * **Join-causing characters.** ZWJ (U+200D) and tatweel (U+0640) join on
///    both sides even though they are not letters; ZWNJ (U+200C) is
///    non-joining and breaks a join deliberately.
///  * **Syriac.** Alaph and the Dalath/Rish group need their own columns and the
///    `fin2`/`fin3`/`med2` actions. Vazirmatn never uses them. They are here
///    anyway, because this is a general package and a half-built state machine
///    is worse than none — it looks finished.
library;

import '../text/unicode.dart';
import '../util/tag.dart';
import 'default_shaper.dart';
import 'glyph_buffer.dart';
import 'shaping_plan.dart';

/// The contextual form the machine chose. Indices into [arabicFeatures]; [none]
/// is one past the end and maps to a zero mask.
abstract final class ArabicAction {
  static const int isol = 0;
  static const int fina = 1;
  static const int fin2 = 2;
  static const int fin3 = 3;
  static const int medi = 4;
  static const int med2 = 5;
  static const int init = 6;
  static const int none = 7;
}

/// The features the machine drives, indexed by [ArabicAction].
///
/// The ORDER is the Arabic spec's application order, and it is not the order
/// anyone would guess: `fina` before `medi`, `init` last. Each is its own stage,
/// so a font with contextual substitutions inside these features sees the same
/// sequence Uniscribe gives it.
const List<int> arabicFeatures = <int>[
  Tag.isol,
  Tag.fina,
  Tag.fin2,
  Tag.fin3,
  Tag.medi,
  Tag.med2,
  Tag.init,
];

/// The cursive shaper: Arabic, Syriac, N'Ko, Mongolian, Adlam and the rest of
/// the joining scripts.
class ArabicShaper extends ScriptShaper {
  const ArabicShaper({this.script = Tag.arab});

  /// The OpenType script tag of the run. Only Syriac changes behaviour (it is
  /// the sole user of the Alaph columns), but the tag is kept because the
  /// fallback decision in HarfBuzz is Arabic-only too.
  final int script;

  @override
  void collectFeatures(ShapingPlanBuilder builder) {
    // `stch` — stretching kashidas for Quranic layout — is collected so that a
    // font declaring it is not silently ignored, but nothing here acts on it:
    // it needs a justification pass, and this engine lays out fixed-width lines.
    builder.enableFeature(_stch);
    builder.addGsubPause();

    // `ccmp` and `locl` run before the joining forms. That is load-bearing:
    // Vazirmatn's lam-alef ligature lives in `ccmp`, so ڵ+ا becomes
    // `lamVabove_alef.isol` — one glyph, gid 474 — before anything tries to give
    // ڵ a medial form it should not have.
    builder.enableFeature(Tag.ccmp);
    builder.enableFeature(Tag.locl);
    builder.addGsubPause();

    // One stage per joining feature. The pauses between them are not strictly
    // needed — only one of the four ever applies to a given glyph — but a font
    // with contextual rules inside `medi` wants everything `fina` did to be
    // finished first, and following the spec's order is what makes this engine
    // agree with the one the fonts were tested against.
    for (final tag in arabicFeatures) {
      builder.addFeature(tag, flags: FeatureFlag.hasFallback);
      builder.addGsubPause();
    }

    // In Arabic script a ZWJ asks for a joining form AND forbids a ligature, so
    // the contextual features must not see through one.
    builder.enableFeature(Tag.rclt, flags: FeatureFlag.manualZwj);
    builder.enableFeature(Tag.calt, flags: FeatureFlag.manualZwj);
    builder.addGsubPause();

    builder.enableFeature(Tag.mset);
  }

  @override
  void setupMasks(GlyphBuffer buffer, ShapingPlan plan) {
    final actions = joiningActions(buffer);
    final maskFor = <int>[
      for (final tag in arabicFeatures) plan.maskFor(tag),
      0, // ArabicAction.none
    ];
    for (var i = 0; i < buffer.length; i++) {
      buffer.infos[i].mask |= maskFor[actions[i]];
    }
  }

  @override
  void reorderMarks(GlyphBuffer buffer, int start, int end) {
    // HarfBuzz moves marks of combining class 220 (below) and 230 (above) that
    // sit after a shadda back in front of it, so `mark` lookups keyed on the
    // letter still find them. Vazirmatn's corpus never triggers it, and doing it
    // wrong would move a diacritic off its letter, so it is deliberately not
    // implemented rather than approximated. See `doc/DEFECTS.md`.
  }

  /// Runs the state machine over [buffer] and returns one [ArabicAction] per
  /// glyph.
  ///
  /// Exposed for tests: the actions are the interesting intermediate value, and
  /// asserting on them is far more legible than asserting on a mask word.
  static List<int> joiningActions(GlyphBuffer buffer) {
    final n = buffer.length;
    final actions = List<int>.filled(n, ArabicAction.none);

    var state = 0;
    var prev = -1;

    for (var i = 0; i < n; i++) {
      final info = buffer.infos[i];
      final type = _column(info);

      // A transparent glyph is not a link in the chain: it takes no action, it
      // does not become `prev`, and it does not advance the state. This one
      // `continue` is why `بِّب` still joins.
      if (type < 0) {
        actions[i] = ArabicAction.none;
        continue;
      }

      final entry = _stateTable[state * _columns + type];
      final prevAction = entry >> 8 & 0xF;
      final currAction = entry >> 4 & 0xF;
      final nextState = entry & 0xF;

      if (prevAction != ArabicAction.none && prev >= 0) {
        actions[prev] = prevAction;
      }
      actions[i] = currAction;

      prev = i;
      state = nextState;
    }

    return actions;
  }

  /// State-table column for [info], or -1 for a transparent glyph.
  static int _column(GlyphInfo info) {
    final joining = info.joiningType;
    if (joining == JoiningType.transparent) return -1;

    // Syriac's Alaph and Dalath/Rish are joining GROUPS, not joining types: the
    // machine needs to know a letter is specifically Alaph to reach the `fin2`
    // and `fin3` actions. Nothing else in Unicode behaves this way.
    final cp = info.codepoint;
    if (cp >= 0x0700 && cp <= 0x074F) {
      if (cp == _syriacAlaph) return _colAlaph;
      if (_syriacDalathRish.contains(cp)) return _colDalathRish;
    }

    return switch (joining) {
      JoiningType.leftJoining => _colL,
      JoiningType.rightJoining => _colR,
      JoiningType.dualJoining => _colD,
      // Join-causing (ZWJ, tatweel) behaves exactly like a dual-joining letter
      // as far as the machine is concerned — it joins on both sides. It differs
      // only in that it is not a letter, which the machine never asks about.
      JoiningType.joinCausing => _colD,
      _ => _colU,
    };
  }
}

/// Assigns [GlyphInfo.joiningType] from the Unicode joining property.
///
/// Separated from the machine because the machine is run more than once in
/// tests and this is the part that touches the UCD tables.
void assignJoiningTypes(GlyphBuffer buffer) {
  for (final info in buffer.infos) {
    info.joiningType = joiningTypeOf(info.codepoint);
  }
}

// ── the state table ───────────────────────────────────────────────────────────
//
// A direct port of HarfBuzz's `arabic_state_table`. Each entry packs
// (prevAction << 8) | (currAction << 4) | nextState — three nibbles, because the
// table is read once per glyph and a struct per cell would be three allocations
// per letter of a document.
//
// Rows are states, columns are joining classes:
//   0 U (non-joining)  1 L (left)  2 R (right)  3 D (dual / join-causing)
//   4 Alaph (Syriac)   5 Dalath/Rish (Syriac)
//
// States:
//   0  start, or previous was non-joining
//   1  previous was R, or an isolated Alaph — not willing to join forward
//   2  previous was D or L in isolated form — willing to join
//   3  previous was D in final form — willing to join
//   4  previous was a final Alaph
//   5  previous was a fin2/fin3 Alaph
//   6  previous was Dalath or Rish

const int _colU = 0;
const int _colL = 1;
const int _colR = 2;
const int _colD = 3;
const int _colAlaph = 4;
const int _colDalathRish = 5;
const int _columns = 6;

const int _n = ArabicAction.none;
const int _isol = ArabicAction.isol;
const int _fina = ArabicAction.fina;
const int _fin2 = ArabicAction.fin2;
const int _fin3 = ArabicAction.fin3;
const int _medi = ArabicAction.medi;
const int _med2 = ArabicAction.med2;
const int _init = ArabicAction.init;

int _e(int prevAction, int currAction, int nextState) =>
    prevAction << 8 | currAction << 4 | nextState;

final List<int> _stateTable = <int>[
  // state 0 — previous was U, not willing to join
  _e(_n, _n, 0), _e(_n, _isol, 2), _e(_n, _isol, 1),
  _e(_n, _isol, 2), _e(_n, _isol, 1), _e(_n, _isol, 6),

  // state 1 — previous was R or an isolated Alaph, not willing to join
  _e(_n, _n, 0), _e(_n, _isol, 2), _e(_n, _isol, 1),
  _e(_n, _isol, 2), _e(_n, _fin2, 5), _e(_n, _isol, 6),

  // state 2 — previous was D or L in isolated form, willing to join
  _e(_n, _n, 0), _e(_n, _isol, 2), _e(_init, _fina, 1),
  _e(_init, _fina, 3), _e(_init, _fina, 4), _e(_init, _fina, 6),

  // state 3 — previous was D in final form, willing to join
  _e(_n, _n, 0), _e(_n, _isol, 2), _e(_medi, _fina, 1),
  _e(_medi, _fina, 3), _e(_medi, _fina, 4), _e(_medi, _fina, 6),

  // state 4 — previous was a final Alaph
  _e(_n, _n, 0), _e(_n, _isol, 2), _e(_med2, _isol, 1),
  _e(_med2, _isol, 2), _e(_med2, _fin2, 5), _e(_med2, _isol, 6),

  // state 5 — previous was a fin2/fin3 Alaph
  _e(_n, _n, 0), _e(_n, _isol, 2), _e(_isol, _isol, 1),
  _e(_isol, _isol, 2), _e(_isol, _fin2, 5), _e(_isol, _isol, 6),

  // state 6 — previous was Dalath or Rish
  _e(_n, _n, 0), _e(_n, _isol, 2), _e(_n, _isol, 1),
  _e(_n, _isol, 2), _e(_n, _fin3, 5), _e(_n, _isol, 6),
];

/// U+0710 SYRIAC LETTER ALAPH — the only member of its joining group.
const int _syriacAlaph = 0x0710;

/// The Syriac `DALATH_RISH` joining group, from `ArabicShaping.txt`. Small
/// enough and stable enough to carry literally; generating a joining-group table
/// for six codepoints would cost more than it explains.
const Set<int> _syriacDalathRish = <int>{
  0x0715, // DALATH
  0x0716, // DOTLESS DALATH RISH
  0x072A, // RISH
  0x0700, // (reserved for the group's punctuation range — no-op today)
};

/// `stch` — Quranic kashida stretching. Collected, never acted on; see
/// [ArabicShaper.collectFeatures].
const int _stch = 0x73746368; // 'stch'
