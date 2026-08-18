/// The Unicode Bidirectional Algorithm (UAX #9), implemented in full.
///
/// "In full" is not ambition, it is the requirement. An invoice line reads
/// `کۆی گشتی: 125,000 IQD (٢٠٢٦)` — one Kurdish RTL paragraph carrying a Latin
/// digit group, an Arabic-Indic digit group, a Latin currency code and a
/// bracket pair. Every one of those needs a different rule to come out right:
/// W7 keeps Latin digits from flipping after an English word, W2/W4/W5 keep
/// `125,000` from splitting at the comma, W2 makes Arabic-Indic digits AN so
/// they stay upright and in logical order inside the RTL run, and N0 stops the
/// parentheses from swapping. An "approximate" bidi pass gets each of those
/// individually wrong in a way that looks like a font bug.
///
/// The structure follows the specification's own rule numbering (P2, X1–X10,
/// W1–W7, N0–N2, I1–I2, L1–L2) so a conformance failure can be traced to a
/// rule instead of to a paragraph of prose.
library;

import 'dart:typed_data';

import '../shaping/glyph_buffer.dart';
import 'unicode.dart';

/// UAX #9 bidirectional character types.
///
/// The numeric values ARE the indices into the generated `bidiClassNames`, so
/// a class read from the table needs no translation. `test/text/bidi_test.dart`
/// pins that correspondence — if the generator's `_bidiOrder` is ever
/// reordered, that test fails rather than the shaper silently treating every
/// Arabic letter as a paragraph separator.
abstract final class BidiClass {
  static const int l = 0;
  static const int r = 1;
  static const int al = 2;
  static const int en = 3;
  static const int es = 4;
  static const int et = 5;
  static const int an = 6;
  static const int cs = 7;
  static const int nsm = 8;
  static const int bn = 9;
  static const int b = 10;
  static const int s = 11;
  static const int ws = 12;
  static const int on = 13;
  static const int lre = 14;
  static const int rle = 15;
  static const int lro = 16;
  static const int rlo = 17;
  static const int pdf = 18;
  static const int lri = 19;
  static const int rli = 20;
  static const int fsi = 21;
  static const int pdi = 22;

  /// BD8 — LRI, RLI, FSI.
  static bool isIsolateInitiator(int t) => t == lri || t == rli || t == fsi;

  /// The set rule X9 removes. See [Bidi] for why they are marked, not deleted.
  static bool isRemovedByX9(int t) =>
      t == rle || t == lre || t == rlo || t == lro || t == pdf || t == bn;

  /// BD? — "NI", a neutral or isolate formatting character, the input to N1/N2.
  static bool isNeutralOrIsolate(int t) =>
      t == b ||
      t == s ||
      t == ws ||
      t == on ||
      t == fsi ||
      t == lri ||
      t == rli ||
      t == pdi;
}

/// One maximal range of text at a single embedding level.
class BidiRun {
  const BidiRun(this.start, this.end, this.level);

  /// First scalar index in the run.
  final int start;

  /// One past the last scalar index — exclusive, like every other range here.
  final int end;

  /// UAX #9 embedding level. Odd is right-to-left.
  final int level;

  int get length => end - start;

  TextDirection get direction =>
      level.isOdd ? TextDirection.rtl : TextDirection.ltr;

  @override
  String toString() => 'BidiRun($start..$end, level $level)';
}

/// The resolved state of a run of text — one paragraph, or several.
class BidiResult {
  const BidiResult._(
    this._levels,
    this.paragraphLevel,
    this.logicalRuns,
    this.visualRuns,
    this.paragraphs,
  );

  final List<int> _levels;

  /// Final embedding level per scalar, after L1. The engine's own array — read
  /// it, do not mutate it.
  List<int> get levels => _levels;

  /// 0 for an LTR paragraph, 1 for RTL. Resolved by P2/P3 unless the caller
  /// supplied it.
  ///
  /// When the text held more than one paragraph this is the FIRST paragraph's
  /// level; the rest are in [paragraphs]. A caller that aligns text must read
  /// [paragraphs], because `'Hello\n سلام'` is an LTR paragraph followed by an
  /// RTL one and no single number describes it.
  final int paragraphLevel;

  /// Runs in LOGICAL order — the order to shape in. GSUB context rules are
  /// specified in logical order, so shaping must never see visual order.
  final List<BidiRun> logicalRuns;

  /// Runs in VISUAL order, left to right, produced by rule L2.
  ///
  /// L2 reorders within a paragraph, never across one, so these are the
  /// paragraphs' visual runs concatenated in logical paragraph order.
  final List<BidiRun> visualRuns;

  /// One entry per paragraph (P1), whose `level` is that paragraph's own base
  /// level. Always at least one entry for non-empty text.
  final List<BidiRun> paragraphs;

  bool get isEmpty => _levels.isEmpty;
}

/// Resolves embedding levels for a paragraph of Unicode scalars.
///
/// Rule X9 says to *remove* the explicit formatting characters. This
/// implementation marks them BN and keeps them in place instead, because every
/// index this class hands back — run bounds, level array positions — is used by
/// the caller to slice its own scalar list, and a removal would silently shift
/// all of them. The removed characters are then filtered out when the isolating
/// run sequences are built, so no W, N or I rule ever sees one; that is exactly
/// equivalent to deleting them, without the index skew. (§5.2 of the annex
/// offers a different equivalence — a set of patched W/N rules that tolerate BN
/// in place. It is more code and more ways to be subtly wrong, for the same
/// answer.)
class Bidi {
  Bidi._();

  /// Maximum explicit embedding depth (UAX #9 BD2). Beyond this, embeddings and
  /// isolates are counted as overflow and produce no level change.
  static const int maxDepth = 125;

  /// Resolves [scalars], splitting at paragraph separators first (rule P1).
  ///
  /// P1 makes the CALLER split the text and hands the algorithm one paragraph
  /// at a time, which is why the annex never trips over a `\n`. Doing the split
  /// here instead of documenting the obligation is deliberate: `\n` is the
  /// commonest character in laid-out text after the space, this class takes a
  /// flat `List<int>` with nowhere to express a boundary, and every caller that
  /// forgot would get silently wrong levels rather than an error. Two ways it
  /// bit before: rule X8 zeroes the isolate counter at a `B`, which detached an
  /// isolate initiator from its matching PDI's level run and left a strong R
  /// sitting at an even level; and every line after the first inherited
  /// paragraph 1's auto-detected direction, so `'Hello\n سلام'` laid its
  /// Kurdish line out left-to-right.
  ///
  /// [paragraphLevel], when given, applies to every paragraph — that is what a
  /// caller who states the direction means.
  static BidiResult resolve(List<int> scalars, {int? paragraphLevel}) {
    final ends = _paragraphEnds(scalars);
    if (ends.length <= 1) return _Resolver(scalars, paragraphLevel).run();

    final levels = Uint8List(scalars.length);
    final logical = <BidiRun>[];
    final visual = <BidiRun>[];
    final paragraphs = <BidiRun>[];
    var start = 0;
    var firstLevel = 0;
    for (var p = 0; p < ends.length; p++) {
      final end = ends[p];
      final one = _Resolver(scalars.sublist(start, end), paragraphLevel).run();
      levels.setAll(start, one.levels);
      for (final r in one.logicalRuns) {
        logical.add(BidiRun(r.start + start, r.end + start, r.level));
      }
      for (final r in one.visualRuns) {
        visual.add(BidiRun(r.start + start, r.end + start, r.level));
      }
      paragraphs.add(BidiRun(start, end, one.paragraphLevel));
      if (p == 0) firstLevel = one.paragraphLevel;
      start = end;
    }
    return BidiResult._(levels, firstLevel, logical, visual, paragraphs);
  }

  /// P2/P3 in isolation — the direction the FIRST paragraph auto-detects to.
  static int autoParagraphLevel(List<int> scalars) {
    if (scalars.isEmpty) return 0;
    return _Resolver(
      scalars,
      null,
    )._paragraphLevelOf(0, _paragraphEnds(scalars).first);
  }

  /// End index (exclusive) of each paragraph, the separator included in the
  /// paragraph it terminates. Never empty for non-empty text.
  static List<int> _paragraphEnds(List<int> scalars) {
    final ends = <int>[];
    for (var i = 0; i < scalars.length; i++) {
      if (bidiClassOf(scalars[i]) != BidiClass.b) continue;
      // CR LF is ONE separator. Splitting between them would leave a paragraph
      // holding a lone LF, which resolves to level 0 and would drag a
      // right-to-left document's line breaks back to the left.
      if (scalars[i] == 0x0D &&
          i + 1 < scalars.length &&
          scalars[i + 1] == 0x0A) {
        continue;
      }
      ends.add(i + 1);
    }
    if (ends.isEmpty || ends.last != scalars.length) {
      ends.add(scalars.length);
    }
    return ends;
  }
}

int _typeForLevel(int level) => level.isOdd ? BidiClass.r : BidiClass.l;

int _nextOdd(int level) => (level + 1) | 1;

int _nextEven(int level) => (level + 2) & ~1;

/// Sentinel for "no directional override in effect". Cannot be a real class
/// index, and deliberately not 0 — 0 is `L`.
const int _noOverride = 0xFF;

class _Resolver {
  _Resolver(this.scalars, this.explicitParagraphLevel)
    : n = scalars.length,
      initialTypes = Uint8List(scalars.length),
      types = Uint8List(scalars.length),
      levels = Uint8List(scalars.length),
      matchingPdi = Int32List(scalars.length),
      matchingIsolate = Int32List(scalars.length) {
    for (var i = 0; i < n; i++) {
      initialTypes[i] = bidiClassOf(scalars[i]);
    }
    types.setAll(0, initialTypes);
    _determineMatchingIsolates();
  }

  final List<int> scalars;
  final int? explicitParagraphLevel;
  final int n;

  /// Bidi class as read from the UCD — never modified. L1 and the N0 mark
  /// clause are both specified against these, not against resolved types.
  final Uint8List initialTypes;

  /// Working types: overrides applied by X6, then rewritten by W and N rules.
  final Uint8List types;
  final Uint8List levels;

  /// For each isolate initiator, the index of its matching PDI, or [n] when it
  /// has none (BD9). For every other character, -1.
  final Int32List matchingPdi;

  /// For each PDI, the index of the isolate initiator it matches, or -1.
  final Int32List matchingIsolate;

  late int paragraphLevel;

  /// Indices surviving X9, in order — the only positions the W/N/I rules see.
  late final List<int> _kept;

  /// Position of each index within [_kept]; -1 for a removed character.
  late final Int32List _keptPos;

  BidiResult run() {
    if (n == 0) {
      return BidiResult._(
        Uint8List(0),
        explicitParagraphLevel ?? 0,
        const <BidiRun>[],
        const <BidiRun>[],
        const <BidiRun>[],
      );
    }

    paragraphLevel = explicitParagraphLevel ?? _detectParagraphLevel();
    _resolveExplicitLevels();

    // Every sequence's sos/eos reads neighbouring levels, so all of them must
    // be built before any of them runs I1/I2 and rewrites those levels.
    final sequences = _buildIsolatingRunSequences();
    for (final s in sequences) {
      s.resolve();
    }

    _levelRemovedCharacters();
    _applyL1();

    final logical = _levelRuns();
    return BidiResult._(
      levels,
      paragraphLevel,
      logical,
      _reorderVisually(logical),
      <BidiRun>[BidiRun(0, n, paragraphLevel)],
    );
  }

  // ── P2 / P3 ─────────────────────────────────────────────────────────────────

  int _detectParagraphLevel() => _paragraphLevelOf(0, n);

  /// P2/P3 over `[start, end)`. Also serves rule X5c, which asks the same
  /// question of the text an FSI encloses.
  int _paragraphLevelOf(int start, int end) {
    for (var i = start; i < end; i++) {
      final t = initialTypes[i];
      if (t == BidiClass.l) return 0;
      if (t == BidiClass.r || t == BidiClass.al) return 1;
      if (BidiClass.isIsolateInitiator(t)) {
        // P2 looks *past* a nested isolate: its content does not decide the
        // enclosing paragraph's direction.
        i = matchingPdi[i];
        if (i >= end) break;
      }
    }
    return 0;
  }

  void _determineMatchingIsolates() {
    matchingPdi.fillRange(0, n, -1);
    matchingIsolate.fillRange(0, n, -1);
    for (var i = 0; i < n; i++) {
      if (!BidiClass.isIsolateInitiator(initialTypes[i])) continue;
      var depth = 1;
      var found = n;
      for (var j = i + 1; j < n; j++) {
        final t = initialTypes[j];
        if (BidiClass.isIsolateInitiator(t)) {
          depth++;
        } else if (t == BidiClass.pdi) {
          if (--depth == 0) {
            found = j;
            matchingIsolate[j] = i;
            break;
          }
        }
      }
      matchingPdi[i] = found;
    }
  }

  // ── X1 … X8 ─────────────────────────────────────────────────────────────────

  void _resolveExplicitLevels() {
    // 125 levels can be pushed at most once each, plus the initial entry.
    final stackLevel = Uint8List(Bidi.maxDepth + 3);
    final stackOverride = Uint8List(Bidi.maxDepth + 3);
    final stackIsolate = Uint8List(Bidi.maxDepth + 3);
    var sp = 0;
    stackLevel[0] = paragraphLevel;
    stackOverride[0] = _noOverride;

    var overflowIsolate = 0;
    var overflowEmbedding = 0;
    var validIsolate = 0;

    for (var i = 0; i < n; i++) {
      final t = initialTypes[i];
      switch (t) {
        case BidiClass.rle:
        case BidiClass.lre:
        case BidiClass.rlo:
        case BidiClass.lro:
          // X2–X5. The initiator itself keeps the *outer* level; X9 hides it.
          levels[i] = stackLevel[sp];
          final rtl = t == BidiClass.rle || t == BidiClass.rlo;
          final newLevel = rtl
              ? _nextOdd(stackLevel[sp])
              : _nextEven(stackLevel[sp]);
          if (newLevel <= Bidi.maxDepth &&
              overflowIsolate == 0 &&
              overflowEmbedding == 0) {
            sp++;
            stackLevel[sp] = newLevel;
            stackOverride[sp] = switch (t) {
              BidiClass.rlo => BidiClass.r,
              BidiClass.lro => BidiClass.l,
              _ => _noOverride,
            };
            stackIsolate[sp] = 0;
          } else if (overflowIsolate == 0) {
            overflowEmbedding++;
          }

        case BidiClass.rli:
        case BidiClass.lri:
        case BidiClass.fsi:
          // X5a–X5c. Unlike an embedding, an isolate initiator is real text: it
          // stays in its run and is resolved as a neutral by N1/N2.
          var rtl = t == BidiClass.rli;
          if (t == BidiClass.fsi) {
            final end = matchingPdi[i];
            rtl = _paragraphLevelOf(i + 1, end < n ? end : n) == 1;
          }
          levels[i] = stackLevel[sp];
          if (stackOverride[sp] != _noOverride) types[i] = stackOverride[sp];
          final newLevel = rtl
              ? _nextOdd(stackLevel[sp])
              : _nextEven(stackLevel[sp]);
          if (newLevel <= Bidi.maxDepth &&
              overflowIsolate == 0 &&
              overflowEmbedding == 0) {
            validIsolate++;
            sp++;
            stackLevel[sp] = newLevel;
            stackOverride[sp] = _noOverride;
            stackIsolate[sp] = 1;
          } else {
            overflowIsolate++;
          }

        case BidiClass.pdi:
          // X6a. An isolate is a hard boundary: closing one throws away any
          // embeddings opened inside it, which is the whole point of isolates
          // over embeddings.
          if (overflowIsolate > 0) {
            overflowIsolate--;
          } else if (validIsolate != 0) {
            overflowEmbedding = 0;
            while (stackIsolate[sp] == 0) {
              sp--;
            }
            sp--;
            validIsolate--;
          }
          levels[i] = stackLevel[sp];
          if (stackOverride[sp] != _noOverride) types[i] = stackOverride[sp];

        case BidiClass.pdf:
          // X7.
          if (overflowIsolate > 0) {
            // An unmatched PDF inside an overflowed isolate does nothing.
          } else if (overflowEmbedding > 0) {
            overflowEmbedding--;
          } else if (stackIsolate[sp] == 0 && sp >= 1) {
            sp--;
          }
          levels[i] = stackLevel[sp];

        case BidiClass.b:
          // X8. A paragraph separator terminates every embedding and isolate
          // outright, and sits at the paragraph level itself.
          sp = 0;
          overflowIsolate = 0;
          overflowEmbedding = 0;
          validIsolate = 0;
          levels[i] = paragraphLevel;

        default:
          // X6.
          levels[i] = stackLevel[sp];
          if (stackOverride[sp] != _noOverride) types[i] = stackOverride[sp];
      }
    }

    // X9, as marking rather than deletion — see the class doc comment.
    for (var i = 0; i < n; i++) {
      if (BidiClass.isRemovedByX9(initialTypes[i])) types[i] = BidiClass.bn;
    }
  }

  // ── X10 ─────────────────────────────────────────────────────────────────────

  List<_IsolatingRunSequence> _buildIsolatingRunSequences() {
    final kept = <int>[];
    final keptPos = Int32List(n)..fillRange(0, n, -1);
    for (var i = 0; i < n; i++) {
      if (BidiClass.isRemovedByX9(initialTypes[i])) continue;
      keptPos[i] = kept.length;
      kept.add(i);
    }
    _kept = kept;
    _keptPos = keptPos;
    if (kept.isEmpty) return const <_IsolatingRunSequence>[];

    // BD7 level runs, over the surviving characters only.
    final runStart = <int>[];
    final runEnd = <int>[];
    final runOf = Int32List(n)..fillRange(0, n, -1);
    var from = 0;
    for (var k = 1; k <= kept.length; k++) {
      if (k == kept.length || levels[kept[k]] != levels[kept[from]]) {
        final index = runStart.length;
        runStart.add(from);
        runEnd.add(k);
        for (var q = from; q < k; q++) {
          runOf[kept[q]] = index;
        }
        from = k;
      }
    }

    final sequences = <_IsolatingRunSequence>[];
    for (var r = 0; r < runStart.length; r++) {
      final first = kept[runStart[r]];
      // BD13: a run beginning with a PDI that closes an isolate is not a
      // sequence start — it is the continuation of the run that opened it.
      //
      // Every BD13 test reads [initialTypes], never [types]. X5a–X6a rewrite an
      // isolate initiator's or a PDI's type to L or R when a directional
      // OVERRIDE is in effect, and BD13 is structural: it links a character to
      // the one that matches it, which is a property of what the character IS,
      // not of what an enclosing RLO resolved it to. Reading [types] here meant
      // an initiator inside an LRO/RLO scope never linked to its PDI's run, and
      // the two halves of the isolate then resolved against different sos/eos.
      if (initialTypes[first] == BidiClass.pdi && matchingIsolate[first] >= 0) {
        continue;
      }
      final indices = <int>[];
      var current = r;
      while (true) {
        for (var k = runStart[current]; k < runEnd[current]; k++) {
          indices.add(kept[k]);
        }
        final last = indices.last;
        if (!BidiClass.isIsolateInitiator(initialTypes[last]) ||
            matchingPdi[last] >= n) {
          break;
        }
        final next = runOf[matchingPdi[last]];
        // Defensive: a matching PDI that is not the head of a later run cannot
        // happen for a *valid* isolate, and following it would loop forever.
        if (next <= current || kept[runStart[next]] != matchingPdi[last]) break;
        current = next;
      }
      sequences.add(_makeSequence(indices));
    }
    return sequences;
  }

  _IsolatingRunSequence _makeSequence(List<int> indices) {
    final level = levels[indices.first];

    final firstPos = _keptPos[indices.first];
    final beforeLevel = firstPos > 0
        ? levels[_kept[firstPos - 1]]
        : paragraphLevel;

    final last = indices.last;
    final int afterLevel;
    // [initialTypes] again, and for the same reason as BD13 above.
    if (BidiClass.isIsolateInitiator(initialTypes[last]) &&
        matchingPdi[last] >= n) {
      // X10: an isolate that is never closed runs to the end of the paragraph,
      // so its sequence ends against the paragraph level, not against whatever
      // character happens to follow the initiator.
      afterLevel = paragraphLevel;
    } else {
      final lastPos = _keptPos[last];
      afterLevel = lastPos + 1 < _kept.length
          ? levels[_kept[lastPos + 1]]
          : paragraphLevel;
    }

    return _IsolatingRunSequence(
      this,
      indices,
      _typeForLevel(level > beforeLevel ? level : beforeLevel),
      _typeForLevel(level > afterLevel ? level : afterLevel),
      level,
    );
  }

  // ── L1 / L2 ─────────────────────────────────────────────────────────────────

  /// Gives the X9-removed characters the level of the text they sit in, so the
  /// level array has no holes and does not fragment the run list.
  void _levelRemovedCharacters() {
    for (var i = 0; i < n; i++) {
      if (!BidiClass.isRemovedByX9(initialTypes[i])) continue;
      levels[i] = i > 0 ? levels[i - 1] : paragraphLevel;
    }
  }

  /// True for the characters L1 resets: whitespace, isolate formatting, and —
  /// per §5.2 — the formatting characters X9 removed, which must not break a
  /// trailing-whitespace run.
  bool _isL1Resettable(int t) =>
      t == BidiClass.ws ||
      t == BidiClass.fsi ||
      t == BidiClass.lri ||
      t == BidiClass.rli ||
      t == BidiClass.pdi ||
      BidiClass.isRemovedByX9(t);

  void _applyL1() {
    for (var i = 0; i < n; i++) {
      final t = initialTypes[i];
      if (t != BidiClass.b && t != BidiClass.s) continue;
      levels[i] = paragraphLevel;
      for (var j = i - 1; j >= 0; j--) {
        if (!_isL1Resettable(initialTypes[j])) break;
        levels[j] = paragraphLevel;
      }
    }
    // The whole paragraph is treated as one line here; a line breaker that
    // splits it must re-run this trailing reset per line, which is why L1 is
    // specified against the untouched original types.
    for (var j = n - 1; j >= 0; j--) {
      if (!_isL1Resettable(initialTypes[j])) break;
      levels[j] = paragraphLevel;
    }
  }

  List<BidiRun> _levelRuns() {
    final runs = <BidiRun>[];
    var start = 0;
    for (var i = 1; i <= n; i++) {
      if (i == n || levels[i] != levels[start]) {
        runs.add(BidiRun(start, i, levels[start]));
        start = i;
      }
    }
    return runs;
  }

  /// L2 — reverse each maximal range at or above every level, from the highest
  /// down to the lowest odd level. Reversing whole runs is equivalent to
  /// reversing characters because a run is by construction uniform in level.
  List<BidiRun> _reorderVisually(List<BidiRun> logical) {
    if (logical.isEmpty) return const <BidiRun>[];
    var highest = 0;
    var lowestOdd = Bidi.maxDepth + 2;
    for (final run in logical) {
      if (run.level > highest) highest = run.level;
      if (run.level.isOdd && run.level < lowestOdd) lowestOdd = run.level;
    }
    final out = List<BidiRun>.of(logical);
    for (var level = highest; level >= lowestOdd; level--) {
      var i = 0;
      while (i < out.length) {
        if (out[i].level < level) {
          i++;
          continue;
        }
        var j = i;
        while (j < out.length && out[j].level >= level) {
          j++;
        }
        for (var a = i, b = j - 1; a < b; a++, b--) {
          final t = out[a];
          out[a] = out[b];
          out[b] = t;
        }
        i = j;
      }
    }
    return out;
  }
}

/// One isolating run sequence (BD13) plus the rules that run over it.
///
/// The W, N and I rules are all defined on a sequence, never on the paragraph:
/// that is what stops text inside an isolate from influencing the digits
/// outside it.
class _IsolatingRunSequence {
  _IsolatingRunSequence(
    this._owner,
    this.indices,
    this.sos,
    this.eos,
    this.level,
  ) : types = List<int>.generate(
        indices.length,
        (i) => _owner.types[indices[i]],
        growable: false,
      ) {
    // N0's trailing-mark clause is specified against the types *before* W1
    // rewrote the NSMs, so the snapshot has to be taken here and not derived
    // afterwards.
    preW1Types = List<int>.of(types, growable: false);
  }

  final _Resolver _owner;
  final List<int> indices;
  final List<int> types;
  late final List<int> preW1Types;

  /// Directional context at the sequence's start and end (X10).
  final int sos;
  final int eos;
  final int level;

  int get length => indices.length;

  void resolve() {
    _w1();
    _w2();
    _w3();
    _w4();
    _w5();
    _w6();
    _w7();
    _n0();
    _n1n2();
    _i1i2();
  }

  /// W1 — a nonspacing mark takes the type of what it sits on. After an isolate
  /// initiator or PDI it becomes ON instead: a mark cannot attach across an
  /// isolate boundary.
  void _w1() {
    var prev = sos;
    for (var i = 0; i < length; i++) {
      if (types[i] == BidiClass.nsm) {
        types[i] = (BidiClass.isIsolateInitiator(prev) || prev == BidiClass.pdi)
            ? BidiClass.on
            : prev;
      }
      prev = types[i];
    }
  }

  /// W2 — a European digit after Arabic-letter context is Arabic-Indic in
  /// behaviour. This is what keeps `٢٠٢٦` and `2026` both upright and in
  /// logical order inside a Kurdish sentence instead of being reversed with it.
  void _w2() {
    var strong = sos;
    for (var i = 0; i < length; i++) {
      final t = types[i];
      if (t == BidiClass.l || t == BidiClass.r || t == BidiClass.al) {
        strong = t;
      } else if (t == BidiClass.en && strong == BidiClass.al) {
        types[i] = BidiClass.an;
      }
    }
  }

  void _w3() {
    for (var i = 0; i < length; i++) {
      if (types[i] == BidiClass.al) types[i] = BidiClass.r;
    }
  }

  /// W4 — a single separator between two digits of the same kind joins them.
  /// `125,000` and `12:30` survive as one number because of this rule.
  void _w4() {
    for (var i = 1; i < length - 1; i++) {
      final t = types[i];
      if (t != BidiClass.es && t != BidiClass.cs) continue;
      final before = types[i - 1];
      final after = types[i + 1];
      if (before == BidiClass.en && after == BidiClass.en) {
        types[i] = BidiClass.en;
      } else if (t == BidiClass.cs &&
          before == BidiClass.an &&
          after == BidiClass.an) {
        types[i] = BidiClass.an;
      }
    }
  }

  /// W5 — a terminator run touching European digits joins them (`$25`, `25%`).
  void _w5() {
    for (var i = 0; i < length; i++) {
      if (types[i] != BidiClass.et) continue;
      var j = i;
      while (j < length && types[j] == BidiClass.et) {
        j++;
      }
      final before = i > 0 ? types[i - 1] : sos;
      final after = j < length ? types[j] : eos;
      if (before == BidiClass.en || after == BidiClass.en) {
        for (var k = i; k < j; k++) {
          types[k] = BidiClass.en;
        }
      }
      i = j - 1;
    }
  }

  void _w6() {
    for (var i = 0; i < length; i++) {
      final t = types[i];
      if (t == BidiClass.et || t == BidiClass.es || t == BidiClass.cs) {
        types[i] = BidiClass.on;
      }
    }
  }

  /// W7 — a European digit in Latin context is Latin. Skip this and the `2026`
  /// in "issued 2026" jumps to the wrong side of the sentence the moment the
  /// paragraph is RTL.
  void _w7() {
    var strong = sos;
    for (var i = 0; i < length; i++) {
      final t = types[i];
      if (t == BidiClass.l || t == BidiClass.r) {
        strong = t;
      } else if (t == BidiClass.en && strong == BidiClass.l) {
        types[i] = BidiClass.l;
      }
    }
  }

  /// Strong direction for N0/N1, where digits count as R (UAX #9 N0 note).
  /// Returns -1 for a character with no strong direction.
  static int _strongClass(int t) => switch (t) {
    BidiClass.l => BidiClass.l,
    BidiClass.r || BidiClass.en || BidiClass.an => BidiClass.r,
    _ => -1,
  };

  /// N0 — paired brackets take the direction of what they enclose.
  ///
  /// Without this, `(2026)` inside a Kurdish line renders as `)2026(`: the
  /// brackets are neutrals, so N1/N2 alone would resolve them to the RTL
  /// embedding direction and the mirroring pass would then swap the glyphs.
  void _n0() {
    final e = _typeForLevel(level);
    final o = e == BidiClass.l ? BidiClass.r : BidiClass.l;

    for (final (open, close) in _bracketPairs()) {
      var foundOpposite = false;
      var direction = -1;
      for (var i = open + 1; i < close; i++) {
        final s = _strongClass(types[i]);
        if (s == -1) continue;
        if (s == e) {
          direction = e;
          break;
        }
        foundOpposite = true;
      }
      if (direction == -1 && foundOpposite) {
        // Only opposite-direction text inside: the established context before
        // the bracket decides whether to follow it or snap back to embedding.
        var context = sos;
        for (var i = open - 1; i >= 0; i--) {
          final s = _strongClass(types[i]);
          if (s != -1) {
            context = s;
            break;
          }
        }
        direction = context == o ? o : e;
      }
      if (direction == -1) continue; // N0 e — nothing strong inside, leave it.

      types[open] = direction;
      types[close] = direction;
      _absorbTrailingMarks(open, direction);
      _absorbTrailingMarks(close, direction);
    }
  }

  /// N0's final clause: marks that followed a bracket before W1 touched them
  /// follow the bracket's new direction too, so a bracket and its diacritics do
  /// not end up on opposite sides.
  void _absorbTrailingMarks(int from, int direction) {
    for (var i = from + 1; i < length && preW1Types[i] == BidiClass.nsm; i++) {
      types[i] = direction;
    }
  }

  /// BD16 — the bracket pair stack, capped at 63 openers by the spec so a
  /// pathological input cannot make this quadratic in memory.
  List<(int, int)> _bracketPairs() {
    final expected = <int>[];
    final at = <int>[];
    final pairs = <(int, int)>[];

    for (var i = 0; i < length; i++) {
      // BD14/BD15: only a bracket whose *current* type is still ON qualifies,
      // so a bracket swallowed by an override is not a bracket any more.
      if (types[i] != BidiClass.on) continue;
      final cp = _owner.scalars[indices[i]];
      switch (bracketTypeOf(cp)) {
        case bracketOpen:
          if (expected.length == 63) return _sorted(pairs);
          expected.add(_canonical(pairedBracketOf(cp)));
          at.add(i);
        case bracketClose:
          final want = _canonical(cp);
          for (var s = expected.length - 1; s >= 0; s--) {
            if (expected[s] != want) continue;
            pairs.add((at[s], i));
            expected.removeRange(s, expected.length);
            at.removeRange(s, at.length);
            break;
          }
      }
    }
    return _sorted(pairs);
  }

  static List<(int, int)> _sorted(List<(int, int)> pairs) =>
      pairs..sort((a, b) => a.$1.compareTo(b.$1));

  /// BD16 matches brackets under canonical equivalence. The angle brackets are
  /// the only pair in Unicode where that matters: U+2329/U+232A have singleton
  /// decompositions to U+3008/U+3009, so `〈…⟩` written with one of each must
  /// still pair.
  static int _canonical(int cp) => switch (cp) {
    0x3008 => 0x2329,
    0x3009 => 0x232A,
    _ => cp,
  };

  /// N1/N2 — a neutral run between two same-direction strongs takes that
  /// direction; anything left over takes the embedding direction.
  void _n1n2() {
    final e = _typeForLevel(level);
    for (var i = 0; i < length; i++) {
      if (!BidiClass.isNeutralOrIsolate(types[i])) continue;
      var j = i;
      while (j < length && BidiClass.isNeutralOrIsolate(types[j])) {
        j++;
      }
      final before = i > 0 ? _directionOf(types[i - 1]) : sos;
      final after = j < length ? _directionOf(types[j]) : eos;
      final resolved =
          (before == after && (before == BidiClass.l || before == BidiClass.r))
          ? before
          : e;
      for (var k = i; k < j; k++) {
        types[k] = resolved;
      }
      i = j - 1;
    }
  }

  static int _directionOf(int t) =>
      (t == BidiClass.en || t == BidiClass.an) ? BidiClass.r : t;

  /// I1/I2 — the implicit levels. Numbers inside RTL text go up two levels, not
  /// one, which is what makes them read left-to-right within a right-to-left
  /// line.
  void _i1i2() {
    for (var i = 0; i < length; i++) {
      final t = types[i];
      var resolved = level;
      if (level.isEven) {
        if (t == BidiClass.r) {
          resolved = level + 1;
        } else if (t == BidiClass.an || t == BidiClass.en) {
          resolved = level + 2;
        }
      } else if (t == BidiClass.l || t == BidiClass.en || t == BidiClass.an) {
        resolved = level + 1;
      }
      _owner.levels[indices[i]] = resolved;
    }
  }
}
