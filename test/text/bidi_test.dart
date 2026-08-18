// Every expected level array here was derived by hand from UAX #9's rules —
// not captured from this implementation's output. A test written the other way
// round only proves the code has not changed, which is exactly the property
// that does not matter.
//
// Uppercase in the case names means RTL, following the annex's own convention.
import 'package:payv/src/shaping/glyph_buffer.dart' show TextDirection;
import 'package:payv/src/text/bidi.dart';
import 'package:payv/src/text/unicode.dart';
import 'package:test/test.dart';

/// Unicode scalars of [s] — the input every bidi entry point takes.
List<int> cps(String s) => toScalars(s).$1;

// Hebrew and Arabic literals are spelled out as escapes so a reviewer can see
// which bidi class each character carries without trusting the editor's
// bidi rendering of the source file itself.
const String heb = 'אב'; // אב  — R
const String hebLong = 'אבג'; // אבג — R
const String arab = 'اب'; // اب  — AL
const String arabIndic = '٢٠٢٦'; // ٢٠٢٦ — AN
const String rli = '\u2067'; // RIGHT-TO-LEFT ISOLATE
const String lri = '\u2066'; // LEFT-TO-RIGHT ISOLATE
const String pdi = '\u2069'; // POP DIRECTIONAL ISOLATE
const String rle = '\u202B'; // RIGHT-TO-LEFT EMBEDDING
const String pdf = '\u202C'; // POP DIRECTIONAL FORMATTING

void main() {
  group('generated table contract', () {
    test('BidiClass values match the generated class-name order', () {
      expect(bidiClassNames[BidiClass.l], 'L');
      expect(bidiClassNames[BidiClass.r], 'R');
      expect(bidiClassNames[BidiClass.al], 'AL');
      expect(bidiClassNames[BidiClass.en], 'EN');
      expect(bidiClassNames[BidiClass.an], 'AN');
      expect(bidiClassNames[BidiClass.nsm], 'NSM');
      expect(bidiClassNames[BidiClass.bn], 'BN');
      expect(bidiClassNames[BidiClass.ws], 'WS');
      expect(bidiClassNames[BidiClass.on], 'ON');
      expect(bidiClassNames[BidiClass.pdi], 'PDI');
      expect(bidiClassNames.length, BidiClass.pdi + 1);
    });

    test('the four Sorani letters classify as Arabic letters', () {
      for (final cp in [0x0695, 0x06B5, 0x06D5, 0x06CE]) {
        expect(
          bidiClassOf(cp),
          BidiClass.al,
          reason: 'U+${cp.toRadixString(16)}',
        );
      }
    });
  });

  group('P2/P3 paragraph direction', () {
    test('first strong L gives an LTR paragraph', () {
      expect(Bidi.resolve(cps('car $heb')).paragraphLevel, 0);
    });

    test('first strong R or AL gives an RTL paragraph', () {
      expect(Bidi.resolve(cps('$heb car')).paragraphLevel, 1);
      expect(Bidi.resolve(cps('$arab car')).paragraphLevel, 1);
    });

    test('digits and punctuation alone do not decide direction', () {
      expect(Bidi.resolve(cps('125,000 — ')).paragraphLevel, 0);
    });

    test('P2 skips over an isolate when detecting direction', () {
      // The RTL text is inside an isolate, so it must NOT make the paragraph
      // RTL; the 'x' after the PDI is the first strong character P2 sees.
      expect(Bidi.resolve(cps('$rli$heb${pdi}x')).paragraphLevel, 0);
      // Without the closing PDI the isolate runs to the end and P2 finds
      // nothing strong at all.
      expect(Bidi.resolve(cps('$rli$heb')).paragraphLevel, 0);
    });

    test('an explicit paragraph level overrides detection', () {
      expect(Bidi.resolve(cps('car'), paragraphLevel: 1).paragraphLevel, 1);
      expect(Bidi.resolve(cps('car'), paragraphLevel: 1).levels, [2, 2, 2]);
    });
  });

  group('uniform text', () {
    test('pure LTR is all level 0 in one run', () {
      final r = Bidi.resolve(cps('hello'));
      expect(r.levels, [0, 0, 0, 0, 0]);
      expect(r.logicalRuns.length, 1);
      expect(r.logicalRuns.single.direction, TextDirection.ltr);
      expect(r.visualRuns.single.start, 0);
    });

    test('pure RTL is all level 1 in one run', () {
      final r = Bidi.resolve(cps(hebLong));
      expect(r.paragraphLevel, 1);
      expect(r.levels, [1, 1, 1]);
      expect(r.logicalRuns.single.level, 1);
      expect(r.logicalRuns.single.direction, TextDirection.rtl);
    });

    test('empty input is handled', () {
      final r = Bidi.resolve(const <int>[]);
      expect(r.levels, isEmpty);
      expect(r.logicalRuns, isEmpty);
      expect(r.visualRuns, isEmpty);
    });
  });

  group('mixed direction', () {
    test('"car means HEB." — the textbook case', () {
      // c a r _ m e a n s _   HEB   .
      // 0 0 0 0 0 0 0 0 0 0  1 1 1  0
      // The trailing full stop is CS → ON, and N2 gives it the paragraph
      // direction because it sits between an R and the end of the line.
      final r = Bidi.resolve(cps('car means $hebLong.'));
      expect(r.paragraphLevel, 0);
      expect(r.levels, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0]);
    });

    test('an Arabic sentence with an embedded Latin word', () {
      // ا ب _ a b c _ ا ب
      // 1 1 1 2 2 2 1 1 1
      final r = Bidi.resolve(cps('$arab abc $arab'));
      expect(r.paragraphLevel, 1);
      expect(r.levels, [1, 1, 1, 2, 2, 2, 1, 1, 1]);
      expect(r.logicalRuns.map((x) => '${x.start}-${x.end}@${x.level}'), [
        '0-3@1',
        '3-6@2',
        '6-9@1',
      ]);
      // L2: the highest run is reversed inside the RTL sweep, so the last
      // Arabic word is drawn leftmost.
      expect(r.visualRuns.map((x) => x.start), [6, 3, 0]);
    });
  });

  group('digits (W2, W4, W5, W7)', () {
    test('Arabic-Indic digits stay upright inside an Arabic run', () {
      // ا ب _ ٢ ٠ ٢ ٦
      // 1 1 1 2 2 2 2   — AN goes up TWO levels from an odd level, which is
      // what makes the group read left-to-right inside the RTL line.
      final r = Bidi.resolve(cps('$arab $arabIndic'));
      expect(r.levels, [1, 1, 1, 2, 2, 2, 2]);
    });

    test(
      'W2: European digits after Arabic context behave as Arabic digits',
      () {
        final r = Bidi.resolve(cps('$arab 2026'));
        expect(r.levels, [1, 1, 1, 2, 2, 2, 2]);
      },
    );

    test('W4: a thousands separator does not split a number', () {
      // If W4 missed the comma it would fall to W6 → ON and then N2 would give
      // it level 1, tearing "125,000" into two visual pieces.
      final r = Bidi.resolve(cps('$arab 125,000'));
      expect(r.levels, [1, 1, 1, 2, 2, 2, 2, 2, 2, 2]);
    });

    test('W5: a currency symbol joins the digits it terminates', () {
      // HEB $25 in an LTR paragraph. Hebrew is R, not AL, so W2 leaves the
      // digits European and W5 can pull the '$' into them — level 2 with the
      // number. Left as ON it would resolve to level 1 with the Hebrew.
      //
      // Deliberately NOT written with Arabic: an AL context makes W2 turn the
      // digits into AN first, and then W5 has nothing to join. That ordering is
      // the rule W5 tests usually get wrong.
      final r = Bidi.resolve(cps('$heb \$25'), paragraphLevel: 0);
      expect(r.levels, [1, 1, 1, 2, 2, 2]);
    });

    test('W2 outranks W5: an AL context leaves the terminator behind', () {
      // Same text under Arabic context — the digits become AN, the '$' is a
      // plain neutral, and it stays at the RTL level.
      final r = Bidi.resolve(cps('$arab \$25'));
      expect(r.levels, [1, 1, 1, 1, 2, 2]);
    });

    test('W7: Latin digits after a Latin word do not flip', () {
      // Forced RTL paragraph. With W7 the digits become L, so the space
      // between word and number sits at level 2 with them and the whole thing
      // is ONE left-to-right run. Without W7 the digits stay EN, the space
      // resolves to the RTL embedding direction, and the run splits at 3.
      final r = Bidi.resolve(cps('abc 123'), paragraphLevel: 1);
      expect(r.levels, [2, 2, 2, 2, 2, 2, 2]);
      expect(r.logicalRuns.length, 1);
    });
  });

  group('N0 paired brackets', () {
    test('brackets follow the established RTL context, not the line', () {
      // Forced LTR paragraph: "HEB (HEB)".
      // With N0 the pair takes the opposite (R) direction because the context
      // before the opening bracket is R — every character ends at level 1.
      // Without N0 the closing bracket would fall to N2 and drop to level 0.
      final r = Bidi.resolve(cps('$heb ($heb)'), paragraphLevel: 0);
      expect(r.levels, [1, 1, 1, 1, 1, 1, 1]);
      expect(r.logicalRuns.length, 1);
    });

    test('brackets round LTR content inside an LTR line stay LTR', () {
      // No strong RTL context before the bracket, so N0 clause (d)(2) snaps
      // the pair back to the embedding direction.
      final r = Bidi.resolve(cps('($heb)'), paragraphLevel: 0);
      expect(r.levels, [0, 1, 1, 0]);
    });

    test('a pair enclosing embedding-direction text takes that direction', () {
      // N0 clause (c): "abc" matches the embedding direction, so the brackets
      // become L even though an RTL word precedes them.
      final r = Bidi.resolve(cps('$heb (abc)'), paragraphLevel: 0);
      expect(r.levels, [1, 1, 0, 0, 0, 0, 0, 0]);
    });

    test('an unmatched bracket resolves as an ordinary neutral', () {
      final r = Bidi.resolve(cps('$heb ($heb'), paragraphLevel: 0);
      expect(r.levels, [1, 1, 1, 1, 1, 1]);
    });
  });

  group('isolates (X5a-X6a, X10)', () {
    test('an isolate hides its content from the digits that follow it', () {
      // hi _ RLI ا ب ا PDI _ 1 2 3
      // The Arabic is invisible to the outer sequence, so W2 never sees an AL
      // and W7 turns the digits into L: everything outside the isolate stays
      // at level 0. Treat RLI/PDI as plain neutrals instead and the digits
      // become AN at level 2.
      final r = Bidi.resolve(cps('hi $rli$arab$pdi 123'));
      expect(r.paragraphLevel, 0);
      expect(r.levels, [0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0]);
    });

    test('an isolate raises the level of its own content', () {
      final r = Bidi.resolve(cps('x $rli$heb${pdi}y'));
      expect(r.levels, [0, 0, 0, 1, 1, 0, 0]);
    });

    test('an LRI inside RTL text carries Latin at an even level', () {
      final r = Bidi.resolve(cps('$arab $lri$heb$pdi'));
      // The isolate is LTR (level 2), the Hebrew inside it R (level 3).
      expect(r.levels, [1, 1, 1, 1, 3, 3, 1]);
    });

    test('an unmatched PDI is inert', () {
      final r = Bidi.resolve(cps('x${pdi}y'));
      expect(r.levels, [0, 0, 0]);
    });
  });

  group('X9 removal keeps indices aligned', () {
    test(
      'embedding controls occupy their index and take a neighbour level',
      () {
        // RLE abc PDF — the controls are removed from the algorithm but must
        // still hold a slot, or every index the caller passed in shifts.
        final r = Bidi.resolve(cps('${rle}abc$pdf'));
        expect(r.levels.length, 5);
        expect(r.levels.sublist(1, 4), [2, 2, 2]);
      },
    );

    test('an embedding raises the level of the text it wraps', () {
      final r = Bidi.resolve(cps('x${rle}ab${pdf}y'));
      expect(r.levels[0], 0);
      expect(r.levels[2], 2);
      expect(r.levels[3], 2);
      expect(r.levels[5], 0);
    });
  });

  group('L1 resets', () {
    test('a segment separator returns to the paragraph level', () {
      // Forced RTL paragraph, "abc\tabc": N1 alone would leave the tab at
      // level 2 between two Latin words. L1 pulls it back to 1.
      final r = Bidi.resolve(cps('abc\tabc'), paragraphLevel: 1);
      expect(r.levels, [2, 2, 2, 1, 2, 2, 2]);
    });

    test('trailing whitespace returns to the paragraph level', () {
      final r = Bidi.resolve(cps('abc  '), paragraphLevel: 1);
      expect(r.levels, [2, 2, 2, 1, 1]);
    });

    test('whitespace before a separator is reset with it', () {
      final r = Bidi.resolve(cps('abc \t'), paragraphLevel: 1);
      expect(r.levels, [2, 2, 2, 1, 1]);
    });
  });

  group('L2 visual order', () {
    test('nested levels reverse from the highest down', () {
      // Arabic, Latin word, Arabic → runs 1, 2, 1. The level-1 sweep reverses
      // all three; the level-2 sweep leaves the single inner run alone.
      final r = Bidi.resolve(cps('$arab abc $arab'));
      expect(r.visualRuns.map((x) => x.level), [1, 2, 1]);
      expect(r.visualRuns.map((x) => x.start), [6, 3, 0]);
      expect(r.logicalRuns.map((x) => x.start), [0, 3, 6]);
    });

    test('an LTR paragraph with one RTL word keeps run order', () {
      final r = Bidi.resolve(cps('a $heb b'));
      expect(r.visualRuns.map((x) => x.start), [0, 2, 4]);
    });
  });

  group('toScalars', () {
    test('pairs surrogates and reports UTF-16 offsets', () {
      final (scalars, offsets) = toScalars('a\u{1F600}b');
      expect(scalars, [0x61, 0x1F600, 0x62]);
      expect(offsets, [0, 1, 3]);
      expect('a\u{1F600}b'.length, 4); // the offsets are NOT scalar indices
    });

    test('handles a string that is only an emoji', () {
      final (scalars, offsets) = toScalars('\u{1F1EE}\u{1F1F6}');
      expect(scalars, [0x1F1EE, 0x1F1F6]);
      expect(offsets, [0, 2]);
    });

    test('an unpaired surrogate becomes U+FFFD rather than throwing', () {
      final (scalars, offsets) = toScalars('a\uD800b');
      expect(scalars, [0x61, 0xFFFD, 0x62]);
      expect(offsets, [0, 1, 2]);
    });

    test('Kurdish text decodes one scalar per code unit', () {
      final (scalars, offsets) = toScalars('ڕڵەێ');
      expect(scalars, [0x0695, 0x06B5, 0x06D5, 0x06CE]);
      expect(offsets, [0, 1, 2, 3]);
    });
  });
}
