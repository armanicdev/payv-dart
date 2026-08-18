// Rule P1 — the paragraph split — and the invariant it exists to protect.
//
// The Unicode conformance suites cannot reach any of this. Both data files say
// so in their own headers: BidiCharacterTest.txt contains no Paragraph_Separator
// at all, and BidiTest.txt allows one only as the LAST character, adding
// "implementations may need extra testing for rule P1 of the UBA". This file is
// that extra testing, because payv's own invoice hands `Bidi.resolve` a
// multi-line string.
library;

import 'dart:math';

import 'package:payv/src/text/bidi.dart';
import 'package:payv/src/text/unicode.dart';
import 'package:test/test.dart';

/// One representative codepoint per bidi class. LRO and RLO are deliberately
/// absent — see the invariant test for why.
const Map<String, int> _cp = <String, int>{
  'L': 0x006C,
  'R': 0x05D0,
  'AL': 0x0627,
  'EN': 0x0030,
  'ES': 0x002B,
  'ET': 0x0023,
  'AN': 0x0660,
  'CS': 0x002C,
  'NSM': 0x0300,
  'BN': 0x00AD,
  'B': 0x2029,
  'S': 0x0009,
  'WS': 0x0020,
  'ON': 0x0021,
  'LRE': 0x202A,
  'RLE': 0x202B,
  'PDF': 0x202C,
  'LRI': 0x2066,
  'RLI': 0x2067,
  'FSI': 0x2068,
  'PDI': 0x2069,
};

List<int> _text(String classes) => <int>[
  for (final name in classes.split(' ')) _cp[name]!,
];

void main() {
  group('P1 — paragraph splitting', () {
    test('the representatives still stand for the classes named', () {
      // A stale representative would silently test the wrong class everywhere
      // below, which is exactly how a bidi suite stops being able to fail.
      _cp.forEach((name, cp) {
        expect(bidiClassNames[bidiClassOf(cp)], name);
      });
    });

    test('a mid-text B no longer strands a strong R at an even level', () {
      // The reviewer's reproduction. X8 zeroes the isolate counter at the B, so
      // the LRI stopped being the last character of its level run, BD13 never
      // appended the matching PDI's run, and the PDI kept its raw explicit
      // level — carrying the R after it to level 0. I1/I2 make a strong R at an
      // even level unreachable, so the old answer was not merely different, it
      // was outside the algorithm's range.
      final levels = Bidi.resolve(
        _text('LRI B RLE L PDF PDI R'),
        paragraphLevel: 0,
      ).levels;
      expect(levels, <int>[0, 0, 0, 2, 2, 1, 1]);
      expect(levels[6].isOdd, isTrue);
    });

    test('each paragraph auto-detects its own direction', () {
      // Without the split every line after the first inherits paragraph 1's
      // direction, so a Kurdish line under an English heading lays out LTR.
      final scalars = toScalars('Hello\n123 سلام').$1;
      final r = Bidi.resolve(scalars);

      expect(r.paragraphs, hasLength(2));
      expect(r.paragraphs[0].level, 0);
      expect(r.paragraphs[1].level, 1, reason: 'the Kurdish line is RTL');
      expect(r.paragraphLevel, 0, reason: 'still the first paragraph');

      // The Arabic-script letters must sit at an odd level, and the Latin
      // digits that precede them at an even one two above it (I1/I2).
      final alef = scalars.indexOf(0x0633); // س
      expect(r.levels[alef].isOdd, isTrue);
      expect(r.levels[scalars.indexOf(0x0031)], 2); // '1'
    });

    test('CR LF is one separator, not two paragraphs', () {
      final r = Bidi.resolve(toScalars('a\r\nب').$1);
      expect(r.paragraphs.map((p) => p.end), <int>[3, 4]);
      expect(r.paragraphs[1].level, 1);
    });

    test('a trailing separator does not open an empty paragraph', () {
      expect(Bidi.resolve(_text('L B')).paragraphs, hasLength(1));
      expect(Bidi.resolve(_text('L B R B')).paragraphs, hasLength(2));
    });

    test('an explicit level applies to every paragraph', () {
      final r = Bidi.resolve(toScalars('Hello\nسلام').$1, paragraphLevel: 1);
      expect(r.paragraphs.map((p) => p.level), <int>[1, 1]);
      expect(r.levels.first, 2, reason: 'Latin inside an RTL paragraph');
    });

    test('runs stay in global coordinates across the split', () {
      final scalars = toScalars('ab\nسلام').$1;
      final r = Bidi.resolve(scalars);
      expect(r.levels, hasLength(scalars.length));
      expect(r.logicalRuns.first.start, 0);
      expect(r.logicalRuns.last.end, scalars.length);
      // L2 reorders WITHIN a paragraph. Concatenating the paragraphs' visual
      // runs must therefore still cover every index exactly once.
      final covered = <int>[];
      for (final run in r.visualRuns) {
        for (var i = run.start; i < run.end; i++) {
          covered.add(i);
        }
      }
      covered.sort();
      expect(covered, List<int>.generate(scalars.length, (i) => i));
    });

    test('autoParagraphLevel answers for the first paragraph only', () {
      expect(Bidi.autoParagraphLevel(toScalars('Hello\nسلام').$1), 0);
      expect(Bidi.autoParagraphLevel(toScalars('سلام\nHello').$1), 1);
      expect(Bidi.autoParagraphLevel(const <int>[]), 0);
    });
  });

  group('I1/I2 range invariant', () {
    test('no strong R at an even level, no strong L at an odd one — 300k', () {
      // The check that found the P1 defect. I1 raises a strong R sitting at an
      // even level and I2 raises a strong L at an odd one, so after resolution
      // the two states below cannot exist. Nothing else in the suite asserts
      // that, which is why a corrupt level array read as merely "different".
      //
      // LRO and RLO are out of the alphabet on purpose: X6 rewrites the type of
      // every character inside an override scope, so "this input character is a
      // strong R" stops being a property of the input and the invariant is no
      // longer expressible from outside the resolver.
      final alphabet = _cp.values.toList(growable: false);
      final random = Random(0x5AB1D1); // fixed: a failure must be replayable
      final levelChoices = <int?>[null, 0, 1];

      var checked = 0;
      for (var sample = 0; sample < 300000; sample++) {
        final length = 1 + random.nextInt(8);
        final scalars = List<int>.generate(
          length,
          (_) => alphabet[random.nextInt(alphabet.length)],
          growable: false,
        );
        final paragraphLevel = levelChoices[random.nextInt(3)];
        final levels = Bidi.resolve(
          scalars,
          paragraphLevel: paragraphLevel,
        ).levels;

        for (var i = 0; i < length; i++) {
          final t = bidiClassOf(scalars[i]);
          final bool bad;
          if (t == BidiClass.l) {
            bad = levels[i].isOdd;
          } else if (t == BidiClass.r || t == BidiClass.al) {
            bad = levels[i].isEven;
          } else {
            continue;
          }
          checked++;
          if (bad) {
            final names = scalars
                .map((c) => bidiClassNames[bidiClassOf(c)])
                .join(' ');
            fail(
              'index $i of $names [para=${paragraphLevel ?? "auto"}] '
              'resolved to level ${levels[i]}: ${levels.join(" ")}',
            );
          }
        }
      }
      // Three of the twenty-one classes are strong and the mean sample is 4.5
      // characters long, so ~190k of the 300k samples' characters are checked.
      // The floor guards against a future edit that quietly stops sampling.
      expect(checked, greaterThan(150000), reason: 'sweep looks degenerate');
    });
  });
}
