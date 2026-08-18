/// Outline extraction and the variable-font machinery, against the real face.
///
/// Everything here runs on Vazirmatn rather than on a synthetic fixture,
/// because the encodings that break reimplementations — implied on-curve
/// points, composites, IUP — only appear in a font a type designer actually
/// drew. The glyph ids are pinned as constants and each is guarded by an
/// assertion on the font's own bounding box, so swapping the fixture font fails
/// loudly instead of silently testing the wrong glyph.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:payv/src/font/glyph_path.dart';
import 'package:payv/src/font/sfnt.dart';
import 'package:payv/src/font/tables/glyf.dart';
import 'package:payv/src/font/variations/avar.dart';
import 'package:payv/src/font/variations/fvar.dart';
import 'package:payv/src/font/variations/gvar.dart';
import 'package:payv/src/font/variations/variation_store.dart';
import 'package:payv/src/util/byte_reader.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

/// Same override the HarfBuzz corpus generator uses, so one env var repoints
/// every test in the package at a different face.
final String fontPath =
    Platform.environment['PAYV_TEST_FONT'] ?? 'test/fonts/Vazirmatn.ttf';

// Glyph ids in Vazirmatn's glyph order.
const int gidA = 2; // 'A' — simple, three contours
const int gidAacute = 9; // composite: 'A' + 'acute'
const int gidSpace = 592; // no outline at all
const int gidLamVAboveAlef = 474; // the ڵ+ا ligature: NO codepoint anywhere
const int gidUni06B5Init = 839; // ڵ initial: no presentation form exists
const int gidUni06D5Fina = 896; // ە final: no presentation form exists

void main() {
  late Uint8List bytes;
  late SfntFile sfnt;
  late GlyfTable glyf;
  late FvarTable fvar;
  late GvarTable gvar;
  late int numGlyphs;

  setUpAll(() {
    bytes = File(fontPath).readAsBytesSync();
    sfnt = SfntFile.parse(bytes);

    // maxp.numGlyphs and head.indexToLocFormat are read here rather than
    // through OpenTypeFont so that this suite does not depend on tables owned
    // by other modules.
    final maxp = sfnt.requireTable(Tag.maxp);
    numGlyphs = maxp.uint16At(maxp.position + 4);
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
  });

  group('glyf — simple glyphs', () {
    test('the fixture is the font these ids were pinned against', () {
      expect(numGlyphs, 1333);
      expect(glyf.boundingBox(gidA), const Rect(29, 0, 1310, 1456));
      expect(glyf.boundingBox(gidAacute), const Rect(29, 0, 1310, 1847));
    });

    test("'A' resolves to a plausible outline", () {
      final path = glyf.outline(gidA)!;
      expect(path.commands, isNotEmpty);

      // Three contours: the two stems and the crossbar's counter.
      expect(path.commands.whereType<MoveTo>(), hasLength(3));
      expect(path.commands.whereType<ClosePath>(), hasLength(3));

      final b = path.bounds;
      expect(b.xMin, closeTo(29, 0.5));
      expect(b.yMin, closeTo(0, 0.5));
      expect(b.xMax, closeTo(1310, 0.5));
      expect(b.yMax, closeTo(1456, 0.5));
      // Sanity against the em rather than against itself: a capital should be
      // most of the ascender and comfortably under one em wide.
      expect(b.height, greaterThan(1000));
      expect(b.width, lessThan(2048));
    });

    test('an empty glyph has a null outline, not an empty path', () {
      expect(glyf.outline(gidSpace), isNull);
      expect(glyf.glyphBytes(gidSpace), isNull);
      final (start, end) = glyf.locaRange(gidSpace);
      expect(start, end);
    });

    test('the GSUB-only Sorani glyphs have real outlines', () {
      // The whole reason this package exists: these three carry Kurdish shapes
      // that no codepoint in Unicode can reach.
      for (final gid in <int>[
        gidLamVAboveAlef,
        gidUni06B5Init,
        gidUni06D5Fina,
      ]) {
        final path = glyf.outline(gid);
        expect(path, isNotNull, reason: 'glyph $gid has no outline');
        expect(path!.commands, isNotEmpty);
        expect(path.bounds.isEmpty, isFalse);
      }
    });

    test('every glyph in the font parses', () {
      var withOutlines = 0;
      for (var gid = 0; gid < numGlyphs; gid++) {
        final path = glyf.outline(gid);
        if (path != null) {
          withOutlines++;
          expect(path.commands.first, isA<MoveTo>());
        }
      }
      expect(withOutlines, greaterThan(1000));
    });

    test('an out-of-range glyph id is a range error, not a bad read', () {
      expect(() => glyf.locaRange(numGlyphs), throwsRangeError);
      expect(glyf.outline(numGlyphs), isNull);
      expect(glyf.boundingBox(-1), isNull);
    });
  });

  group('glyf — composites', () {
    test('a composite resolves into its components', () {
      final base = glyf.outline(gidA)!;
      final composite = glyf.outline(gidAacute)!;

      // 'Aacute' is 'A' plus one accent contour, translated — so it has one
      // more contour and reaches higher, but is no wider.
      expect(
        composite.commands.whereType<MoveTo>().length,
        base.commands.whereType<MoveTo>().length + 1,
      );
      expect(composite.bounds.yMax, greaterThan(base.bounds.yMax));
      expect(composite.bounds.xMin, closeTo(base.bounds.xMin, 0.5));
      expect(composite.bounds.yMax, closeTo(1847, 0.5));
    });

    test('a composite the shaper reaches only through GSUB resolves', () {
      final path = glyf.outline(gidLamVAboveAlef)!;
      expect(path.commands.whereType<MoveTo>().length, greaterThan(1));
      expect(path.bounds.yMax, closeTo(1871, 1));
    });
  });

  group('fvar', () {
    test('reports one wght axis, 100/400/900', () {
      expect(fvar.axes, hasLength(1));
      final wght = fvar.axes.single;
      expect(wght.tagString, 'wght');
      expect(wght.minValue, 100);
      expect(wght.defaultValue, 400);
      expect(wght.maxValue, 900);
      expect(wght.isHidden, isFalse);
      expect(fvar.axisIndex('wght'), 0);
      expect(fvar.axisIndex('wdth'), -1);
    });

    test('named instances carry user-space coordinates', () {
      expect(fvar.instances, hasLength(9));
      expect(fvar.instances.first.coordinates, <double>[100]);
      expect(fvar.instances.last.coordinates, <double>[900]);
      for (final i in fvar.instances) {
        expect(i.subfamilyNameId, greaterThan(0));
      }
    });

    test('the default instance normalises to exactly zero', () {
      expect(fvar.normalize(const <String, double>{'wght': 400}), <double>[0]);
      expect(fvar.normalize(const <String, double>{}), <double>[0]);
      // An axis the caller does not mention must also land on its default.
      expect(fvar.normalize(const <String, double>{'wdth': 75}), <double>[0]);
    });

    test('700 normalises into (0, 1]', () {
      final n = fvar.normalize(const <String, double>{'wght': 700}).single;
      expect(n, greaterThan(0));
      expect(n, lessThanOrEqualTo(1));
    });

    test('the extremes clamp to ±1', () {
      expect(fvar.normalize(const <String, double>{'wght': 900}), <double>[1]);
      expect(fvar.normalize(const <String, double>{'wght': 100}), <double>[-1]);
      // Out-of-range user values clamp rather than extrapolating.
      expect(fvar.normalize(const <String, double>{'wght': 5000}), <double>[1]);
    });

    test('avar bends the axis, and 700 lands on the knot the font pinned', () {
      final linear = fvar.normalize(const <String, double>{'wght': 700}).single;
      final mapped = fvar.normalize(const <String, double>{
        'wght': 700,
      }, avar: sfnt.table(Tag.avar)).single;

      expect(linear, closeTo(0.6, 1 / 16384));
      // Vazirmatn's avar pins 0.5999755859375 → 0.67755126953125. Landing on it
      // EXACTLY is the point of quantising to F2Dot14 before the map: a float
      // 0.6 would interpolate across the next segment and draw a weight nobody
      // designed.
      expect(mapped, 0.67755126953125);
    });
  });

  group('avar', () {
    test('parses version 1 and maps the identity knots', () {
      final avar = AvarTable.parse(sfnt.requireTable(Tag.avar));
      expect(avar.majorVersion, 1);
      expect(avar.hasVersion2Mapping, isFalse);
      expect(avar.axisCount, 1);
      expect(avar.map(0, 0), 0);
      expect(avar.map(0, 1), 1);
      expect(avar.map(0, -1), -1);
      // Out-of-range axes pass the coordinate through untouched.
      expect(avar.map(7, 0.5), 0.5);
    });

    test('interpolates between knots and clamps outside them', () {
      final avar = AvarTable.parse(sfnt.requireTable(Tag.avar));
      final knots = avar.segmentMap(0);
      expect(knots.length, greaterThan(2));
      expect(avar.map(0, 2), knots.last.toCoordinate);
      expect(avar.map(0, -2), knots.first.toCoordinate);

      // Monotonic: a heavier request never maps lighter.
      var previous = -1.0;
      for (var i = -16384; i <= 16384; i += 137) {
        final v = avar.map(0, i / 16384);
        expect(v, greaterThanOrEqualTo(previous));
        previous = v;
      }
    });
  });

  group('gvar', () {
    List<double> normalized(double weight) => fvar.normalize(<String, double>{
      'wght': weight,
    }, avar: sfnt.table(Tag.avar));

    test('the default instance is the untouched outline', () {
      final plain = glyf.outline(gidA)!;
      final atDefault = glyf.outline(
        gidA,
        coords: normalized(400),
        gvar: gvar,
      )!;
      expect(atDefault.commands.length, plain.commands.length);
      expect(atDefault.bounds, plain.bounds);
    });

    test('a heavier instance thickens the glyph', () {
      final light = glyf.outline(gidA, coords: normalized(100), gvar: gvar)!;
      final regular = glyf.outline(gidA)!;
      final bold = glyf.outline(gidA, coords: normalized(900), gvar: gvar)!;

      // Same topology at every weight — a variation that adds or drops a
      // contour would mean the deltas landed on the wrong points.
      expect(
        bold.commands.whereType<MoveTo>().length,
        regular.commands.whereType<MoveTo>().length,
      );
      // 'A' is drawn to a fixed cap height, so weight moves the stems, not the
      // extremes: the interior must move even though the box barely does.
      expect(bold.commands, isNot(equals(regular.commands)));
      expect(light.commands, isNot(equals(regular.commands)));
      expect(bold.bounds.yMax, closeTo(regular.bounds.yMax, 1));

      // The left stem's inner edge is the point IUP most often gets wrong.
      expect(bold.bounds.xMin, lessThan(regular.bounds.xMin));
    });

    test('composites vary by moving their components', () {
      final regular = glyf.outline(gidAacute)!;
      final bold = glyf.outline(
        gidAacute,
        coords: normalized(900),
        gvar: gvar,
      )!;
      expect(
        bold.commands.whereType<MoveTo>().length,
        regular.commands.whereType<MoveTo>().length,
      );
      expect(bold.commands, isNot(equals(regular.commands)));
    });

    test('every varying glyph stays well formed at the extremes', () {
      final heavy = normalized(900);
      for (var gid = 0; gid < numGlyphs; gid++) {
        final base = glyf.outline(gid);
        final varied = glyf.outline(gid, coords: heavy, gvar: gvar);
        expect(
          varied == null,
          base == null,
          reason: 'glyph $gid changed emptiness under variation',
        );
        if (base == null) continue;
        expect(
          varied!.commands.length,
          base.commands.length,
          reason: 'glyph $gid changed topology under variation',
        );
      }
    });

    test('a glyph outside the table simply does not vary', () {
      expect(gvar.deltas(numGlyphs + 10, normalized(900), 4), isNull);
    });
  });

  group('HVAR / ItemVariationStore', () {
    test('resolves an advance delta through the delta-set index map', () {
      final hvar = sfnt.requireTable(Tag.hvar);
      final store = ItemVariationStore.parseHvar(hvar);
      expect(store.deltaSetIndexMap, isNotNull);
      expect(store.deltaSetIndexMap!.length, numGlyphs);
      expect(store.subtableCount, greaterThan(0));

      final coords = fvar.normalize(const <String, double>{
        'wght': 900,
      }, avar: sfnt.table(Tag.avar));
      // 'A' is 1339 units at Regular and 1450 at Black in this face; the exact
      // number belongs to the hmtx test, so assert only that the store moves it
      // the right way and by a sane amount.
      final delta = store.deltaForGlyph(gidA, coords);
      expect(delta, greaterThan(0));
      expect(delta, lessThan(500));
      // The default instance must be an exact zero, not a rounding of one.
      expect(store.deltaForGlyph(gidA, const <double>[0]), 0);
    });

    test('the region scalar peaks at the master and falls to zero', () {
      final hvar = sfnt.requireTable(Tag.hvar);
      final store = ItemVariationStore.parseHvar(hvar);
      final full = store.deltaForGlyph(gidA, const <double>[1]);
      final half = store.deltaForGlyph(gidA, const <double>[0.5]);
      expect(half.abs(), lessThan(full.abs()));
      expect(half.abs(), greaterThan(0));
    });
  });

  group('GlyphPath', () {
    test('quadratics promote to cubics exactly', () {
      final path = GlyphPath()
        ..moveTo(0, 0)
        ..quadraticTo(30, 60, 60, 0)
        ..close();

      final cubic = path.cubicCommands[1] as CubicTo;
      // c1 = p0 + 2/3·(q − p0), c2 = p2 + 2/3·(q − p2).
      expect(cubic.c1x, closeTo(20, 1e-9));
      expect(cubic.c1y, closeTo(40, 1e-9));
      expect(cubic.c2x, closeTo(40, 1e-9));
      expect(cubic.c2y, closeTo(40, 1e-9));
      expect(cubic.x, 60);
      expect(cubic.y, 0);
    });

    test('bounds are tight, not the control hull', () {
      final path = GlyphPath()
        ..moveTo(0, 0)
        ..quadraticTo(50, 100, 100, 0)
        ..close();
      // The control point sits at y=100 but the curve only reaches y=50.
      expect(path.bounds.yMax, closeTo(50, 1e-9));
      expect(path.bounds, const Rect(0, 0, 100, 50));
    });

    test('emits PDF operators with no exponent notation', () {
      final path = GlyphPath()
        ..moveTo(100, 0)
        ..lineTo(200, 0)
        ..quadraticTo(250, 50, 200, 100)
        ..close();

      final pdf = path.toPdfPath();
      expect(pdf.split('\n'), hasLength(4));
      expect(pdf.split('\n').first, '100 0 m');
      expect(pdf.split('\n')[1], '200 0 l');
      expect(pdf.split('\n')[2], startsWith('233.333333 33.333333 '));
      expect(pdf.split('\n').last, 'h');

      // Scaled into text space, the values go small — and must stay decimal,
      // because PDF has no exponent syntax and a viewer would reject `1e-4`.
      final scaled = path.toPdfPath(scale: 1 / 2048);
      expect(scaled, isNot(contains('e')));
      expect(scaled, isNot(contains('E')));
      expect(scaled.split('\n').first, '0.048828 0 m');
    });

    test('a real glyph round-trips through the PDF writer', () {
      final pdf = glyf.outline(gidA)!.toPdfPath(scale: 1 / 2048);
      expect(RegExp('^h\$', multiLine: true).allMatches(pdf), hasLength(3));
      expect(RegExp('m\$', multiLine: true).allMatches(pdf), hasLength(3));
      expect(pdf, isNot(contains('NaN')));
      expect(pdf, isNot(contains('Infinity')));
    });
  });

  group('malformed input', () {
    test('a truncated loca is rejected, not read past', () {
      // A reader that really does end early — as it would if the file were cut
      // short — rather than one that merely points into a short table.
      final record = sfnt.record(Tag.loca)!;
      final shortLoca = ByteReader.fromBytes(
        Uint8List.sublistView(bytes, record.offset, record.offset + 16),
      );
      expect(
        () => GlyfTable.parse(
          sfnt.requireTable(Tag.glyf),
          loca: shortLoca,
          indexToLocFormat: 0,
          numGlyphs: numGlyphs,
        ),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('the wrong loca format is caught before a glyph is decoded', () {
      // Reading a short `loca` as long does not overrun the FILE — every table
      // reader shares one buffer — so the guard that has to catch it is the
      // per-glyph range check against the end of `glyf`.
      final wrong = GlyfTable.parse(
        sfnt.requireTable(Tag.glyf),
        loca: sfnt.requireTable(Tag.loca),
        indexToLocFormat: 1,
        numGlyphs: numGlyphs,
      );
      var threw = 0;
      for (var gid = 0; gid < 64; gid++) {
        try {
          wrong.outline(gid);
        } on FontFormatException {
          threw++;
        }
      }
      expect(threw, greaterThan(0));
    });

    test('a nonsense indexToLocFormat is rejected', () {
      expect(
        () => GlyfTable.parse(
          sfnt.requireTable(Tag.glyf),
          loca: sfnt.requireTable(Tag.loca),
          indexToLocFormat: 2,
          numGlyphs: numGlyphs,
        ),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('a gvar whose axis count disagrees with fvar is rejected', () {
      expect(
        () => GvarTable.parse(
          sfnt.requireTable(Tag.gvar),
          numGlyphs: numGlyphs,
          axisCount: 3,
        ),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('a table read past the end of the file throws', () {
      final truncated = ByteReader.fromBytes(
        Uint8List.sublistView(bytes, 0, 64),
      );
      expect(() => FvarTable.parse(truncated), throwsA(isA<Exception>()));
    });
  });
}
