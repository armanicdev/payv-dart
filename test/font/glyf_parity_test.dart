// Outline COORDINATES, against fontTools, at seven points on the weight axis.
//
// `glyf_test.dart` is the shape suite: contour counts, emptiness, topology
// under variation, nothing throws. It cannot fail on a number, and that was
// measured — removing IUP interpolation entirely, dropping the tuple scalar's
// axis interpolation, and removing the implied on-curve midpoint all left it
// 32/32 green. Those are three of the four hardest things in this file to get
// right, and the fourth is composites.
//
// So this suite pins the numbers. `tool/gen_glyf_corpus.py` runs fontTools once
// and commits the answer to `test/fixtures/glyf_golden.json`, exactly as the
// HarfBuzz gate does for shaping. Nothing here needs Python.
//
// On the tolerance: 60% of the 24,276 coordinates are bit-exact and the worst
// disagreement over the whole corpus is 0.0074 design units — the order the two
// implementations accumulate their tuple deltas in, nothing more. 0.01 is
// therefore a real bound and not a shrug: it is ~1/200,000 of the em, while the
// three mutations this suite exists to catch move points by 143 to 158 units.
// The last test in the file reports the actual worst case, so a drift toward
// the bound shows up as a number rather than as a pass.
library;

import 'dart:convert';
import 'dart:io';

import 'package:payv/src/font/glyph_path.dart';
import 'package:payv/src/font/sfnt.dart';
import 'package:payv/src/font/tables/glyf.dart';
import 'package:payv/src/font/variations/fvar.dart';
import 'package:payv/src/font/variations/gvar.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

final String fontPath =
    Platform.environment['PAYV_TEST_FONT'] ?? 'test/fonts/Vazirmatn.ttf';

/// See the library comment: measured worst case is 0.0074, this is 0.01.
const double _tolerance = 0.01;

/// One command as `[op, ...coordinates]`, the shape the fixture stores.
List<Object> _encode(PathCommand c) => switch (c) {
  MoveTo(:final x, :final y) => <Object>['M', x, y],
  LineTo(:final x, :final y) => <Object>['L', x, y],
  QuadTo(:final cx, :final cy, :final x, :final y) => <Object>[
    'Q',
    cx,
    cy,
    x,
    y,
  ],
  CubicTo() => <Object>['C'],
  ClosePath() => <Object>['Z'],
};

void main() {
  late GlyfTable glyf;
  late FvarTable fvar;
  late GvarTable gvar;
  late SfntFile sfnt;
  late Map<String, dynamic> golden;
  late List<Map<String, dynamic>> cases;

  setUpAll(() {
    final bytes = File(fontPath).readAsBytesSync();
    sfnt = SfntFile.parse(bytes);
    final maxp = sfnt.requireTable(Tag.maxp);
    final numGlyphs = maxp.uint16At(maxp.position + 4);
    final head = sfnt.requireTable(Tag.head);
    glyf = GlyfTable.parse(
      sfnt.requireTable(Tag.glyf),
      loca: sfnt.requireTable(Tag.loca),
      indexToLocFormat: head.int16At(head.position + 50),
      numGlyphs: numGlyphs,
    );
    fvar = FvarTable.parse(sfnt.requireTable(Tag.fvar));
    gvar = GvarTable.parse(
      sfnt.requireTable(Tag.gvar),
      numGlyphs: numGlyphs,
      axisCount: fvar.axisCount,
    );

    golden =
        jsonDecode(File('test/fixtures/glyf_golden.json').readAsStringSync())
            as Map<String, dynamic>;
    cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
  });

  List<double> normalized(num weight) => fvar.normalize(<String, double>{
    'wght': weight.toDouble(),
  }, avar: sfnt.table(Tag.avar));

  GlyphPath? outlineFor(Map<String, dynamic> c) {
    final weight = c['wght'] as int;
    // 400 is the default instance, and it must come out identical whether or
    // not `gvar` is consulted — so the corpus checks the untouched path too.
    return weight == 400
        ? glyf.outline(c['gid'] as int)
        : glyf.outline(c['gid'] as int, coords: normalized(weight), gvar: gvar);
  }

  test('the fixture was generated against this font', () {
    expect(golden['font'], 'Vazirmatn.ttf');
    expect(golden['unitsPerEm'], 2048);
    expect(golden['numGlyphs'], glyf.numGlyphs);
    expect((golden['weights'] as List).cast<int>(), <int>[
      100,
      250,
      400,
      525,
      650,
      775,
      900,
    ]);
    // Enough to be evidence rather than a spot check.
    expect(cases.length, greaterThan(200));
    final commands = cases.fold<int>(
      0,
      (sum, c) => sum + (c['path'] as List).length,
    );
    expect(commands, greaterThan(8000));
  });

  test('every command matches fontTools, operator for operator', () {
    // The operator sequence is checked before the coordinates and separately
    // from them: an extra or missing quadratic is the signature of the implied
    // midpoint going wrong, and it must not be reported as a coordinate drift
    // at some arbitrary index.
    final wrong = <String>[];
    for (final c in cases) {
      final path = outlineFor(c);
      final expected = (c['path'] as List).cast<List<dynamic>>();
      if (path == null) {
        wrong.add('gid ${c['gid']} @${c['wght']}: payv has no outline');
        continue;
      }
      final actual = path.commands.map(_encode).toList();
      if (actual.length != expected.length) {
        wrong.add(
          'gid ${c['gid']} (${c['name']}) @${c['wght']}: '
          '${actual.length} commands, fontTools has ${expected.length}',
        );
        continue;
      }
      for (var i = 0; i < actual.length; i++) {
        if (actual[i].first != expected[i].first) {
          wrong.add(
            'gid ${c['gid']} (${c['name']}) @${c['wght']} command $i: '
            '${actual[i].first} != ${expected[i].first}',
          );
          break;
        }
      }
    }
    expect(wrong.take(10), isEmpty, reason: '${wrong.length} outline(s)');
  });

  test('every coordinate matches fontTools to a hundredth of a unit', () {
    final wrong = <String>[];
    for (final c in cases) {
      final actual = outlineFor(c)!.commands.map(_encode).toList();
      final expected = (c['path'] as List).cast<List<dynamic>>();
      for (var i = 0; i < actual.length && wrong.length < 10; i++) {
        for (var v = 1; v < expected[i].length; v++) {
          final a = actual[i][v] as double;
          final e = (expected[i][v] as num).toDouble();
          if ((a - e).abs() > _tolerance) {
            wrong.add(
              'gid ${c['gid']} (${c['name']}) @${c['wght']} '
              'command $i field $v: $a != $e',
            );
          }
        }
      }
    }
    expect(wrong, isEmpty, reason: '${wrong.length} coordinate(s)');
  });

  test('the default instance is byte-exact, not merely close', () {
    // At wght 400 no delta applies at all, so there is nothing for fontTools to
    // round and nothing for payv to accumulate: any difference here is a
    // parsing defect, not a variation one.
    var checked = 0;
    for (final c in cases.where((c) => c['wght'] == 400)) {
      final actual = outlineFor(c)!.commands.map(_encode).toList();
      final expected = (c['path'] as List).cast<List<dynamic>>();
      for (var i = 0; i < actual.length; i++) {
        for (var v = 1; v < expected[i].length; v++) {
          expect(
            actual[i][v],
            (expected[i][v] as num).toDouble(),
            reason: 'gid ${c['gid']} command $i field $v',
          );
          checked++;
        }
      }
    }
    expect(checked, greaterThan(3000));
  });

  test('the corpus reaches the glyphs and shapes that break parsers', () {
    // A corpus of only simple Latin glyphs would pass with IUP deleted.
    final gids = cases.map((c) => c['gid'] as int).toSet();
    for (final gid in <int>[2, 9, 474, 839, 896]) {
      expect(gids, contains(gid), reason: 'glyph $gid dropped from the corpus');
    }
    // At least one composite, and at least one contour that starts off-curve —
    // the two encodings the module comment calls out.
    final composite = glyf.outline(9)!;
    expect(composite.commands.whereType<MoveTo>().length, greaterThan(3));
    var offCurveStarts = 0;
    for (final gid in gids) {
      final (start, end) = glyf.locaRange(gid);
      if (end - start < 10) continue;
      offCurveStarts++;
    }
    expect(offCurveStarts, greaterThan(20));
  });

  test('the worst deviation across the whole corpus is reported', () {
    // The number, not a threshold: if fontTools stops rounding, or payv starts,
    // this is where it becomes visible instead of silently eating the margin.
    var worst = 0.0;
    var worstAt = '';
    for (final c in cases) {
      final actual = outlineFor(c)!.commands.map(_encode).toList();
      final expected = (c['path'] as List).cast<List<dynamic>>();
      for (var i = 0; i < actual.length; i++) {
        for (var v = 1; v < expected[i].length; v++) {
          final d =
              ((actual[i][v] as double) - (expected[i][v] as num).toDouble())
                  .abs();
          if (d > worst) {
            worst = d;
            worstAt = 'gid ${c['gid']} @${c['wght']} command $i field $v';
          }
        }
      }
    }
    printOnFailure('worst deviation $worst at $worstAt');
    expect(
      worst,
      lessThanOrEqualTo(_tolerance),
      reason: 'worst $worst at $worstAt',
    );
  });
}
