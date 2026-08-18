/// The variable-to-static instancer, graded against fontTools.
///
/// Instancing is the step where a wrong answer is least visible: the font still
/// parses, still draws, and is simply the wrong weight — or the right weight
/// one design unit off, everywhere, which no eye catches and every diff does.
/// So the expectations below are not "close to the default" or "heavier than
/// before". They are the exact integers fontTools 4.62.1 produces, pinned from:
///
///   from fontTools.ttLib import TTFont
///   from fontTools.varLib import instancer
///   inst = instancer.instantiateVariableFont(
///       TTFont('Vazirmatn.ttf'), {'wght': 900}, inplace=False)
///
/// which is the same computation HarfBuzz does at draw time. Agreement to the
/// unit means `payv`'s `gvar` evaluation, its IUP pass, its rounding mode and
/// its `glyf` re-encoder are all right at once.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:payv/src/font/glyph_path.dart';
import 'package:payv/src/font/instancer.dart';
import 'package:payv/src/font/open_type_font.dart';
import 'package:payv/src/font/subset.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

final String fontPath =
    Platform.environment['PAYV_TEST_FONT'] ?? 'test/fonts/Vazirmatn.ttf';

const int gidA = 2; // simple, three contours, every point on-curve
const int gidAacute = 9; // composite: 'A' + 'acute'
const int gidAcute = 313;
const int gidSpace = 592; // no outline, but its advance still varies
const int gidLamVAboveAlef = 474; // ڵ + ا
const int gidUni06B5Init = 839; // ڵ initial
const int gidUni06D5Fina = 896; // ە final
const int gidUniFbdc = 1121; // the one glyph whose HVAR and gvar disagree

/// `A` at wght 900, in point order: contour 0, then 1, then 2. Every point is
/// on-curve, so the outline's `MoveTo`/`LineTo` sequence IS the coordinate
/// array and can be compared to it directly.
const List<List<int>> aAtWght900 = [
  [728, 1150],
  [373, 0],
  [-4, 0],
  [531, 1456],
  [770, 1456],
  [1022, 0],
  [666, 1150],
  [620, 1456],
  [862, 1456],
  [1400, 0],
  [1008, 543],
  [1008, 272],
  [261, 272],
  [261, 543],
];

/// Glyph bounding boxes at wght 900, as fontTools recalculates them.
const Map<int, List<int>> boundsAtWght900 = {
  gidA: [-4, 0, 1400, 1456],
  gidAacute: [-4, 0, 1400, 1846],
  gidLamVAboveAlef: [86, 0, 1196, 1891],
  gidUni06B5Init: [-20, 0, 576, 1891],
  gidUni06D5Fina: [79, 0, 1122, 1094],
};

/// Advance widths at wght 900 for the closure of a Kurdish word set.
const Map<int, int> advancesAtWght900 = {
  0: 908,
  2: 1395,
  9: 1395,
  313: 692,
  330: 517,
  333: 197,
  334: 787,
  474: 1234,
  592: 500,
  681: 556,
  684: 1852,
  689: 1040,
  691: 762,
  693: 2480,
  717: 1381,
  718: 1278,
  719: 1445,
  720: 1015,
  721: 970,
  722: 1495,
  746: 0,
  748: 781,
  752: 1132,
  760: 1063,
  772: 1852,
  804: 762,
  822: 1853,
  836: 1853,
  837: 1381,
  839: 630,
  841: 1445,
  868: 1495,
  871: 1495,
  895: 1015,
  896: 1102,
  1262: 630,
  1275: 1102,
  1301: 1234,
};

/// Left sidebearings at wght 900 for the same set.
///
/// fontTools derives these from phantom point 1 and the recalculated `xMin`,
/// and they are the half of `hmtx` a naive instancer forgets — leaving every
/// glyph drawn at the right width in the wrong place inside it.
const Map<int, int> lsbsAtWght900 = {
  0: 100,
  2: -4,
  9: -4,
  313: 90,
  330: -88,
  333: -90,
  334: -60,
  474: 86,
  592: 0,
  681: 134,
  684: 79,
  689: 79,
  691: -62,
  693: 82,
  717: 79,
  718: 68,
  719: 82,
  720: 78,
  721: 68,
  722: 82,
  746: 355,
  748: 115,
  752: 45,
  760: 76,
  772: 79,
  804: -62,
  822: 79,
  836: 79,
  837: 79,
  839: -20,
  841: 82,
  868: 82,
  871: 82,
  895: 78,
  896: 79,
  1262: -20,
  1275: 79,
  1301: 86,
};

void main() {
  late Uint8List bytes;
  late OpenTypeFont font;

  setUpAll(() {
    bytes = File(fontPath).readAsBytesSync();
    font = OpenTypeFont.parse(bytes);
    expect(font.numGlyphs, 1333, reason: 'fixture font changed');
    expect(font.isVariable, isTrue);
    expect(font.fvar!.axes.single.tagString, 'wght');
  });

  group('at the default instance (wght 400)', () {
    late OpenTypeFont instanced;

    setUpAll(() {
      instanced = OpenTypeFont.parse(
        Instancer.instanceAxes(font, {'wght': 400}),
      );
    });

    test('every outline in the font is unchanged, point for point', () {
      // 1333 glyphs, and all of them: this is the round trip of the `glyf`
      // encoder over every flag-run, every implied on-curve point and every
      // composite the designer drew. A single mis-encoded repeat count shows up
      // here and almost nowhere else.
      for (var gid = 0; gid < font.numGlyphs; gid++) {
        expect(
          _describe(instanced.outline(gid)),
          equals(_describe(font.outline(gid))),
          reason: 'glyph $gid changed at its own default instance',
        );
      }
    });

    test('advances are unchanged', () {
      for (var gid = 0; gid < font.numGlyphs; gid++) {
        expect(
          instanced.advanceWidth(gid),
          font.advanceWidth(gid),
          reason: 'advance of glyph $gid',
        );
      }
    });

    test('is no longer variable', () {
      expect(instanced.isVariable, isFalse);
      expect(instanced.needsInstancing, isFalse);
    });
  });

  group('at wght 900', () {
    late Uint8List instancedBytes;
    late OpenTypeFont instanced;

    setUpAll(() {
      instancedBytes = Instancer.instanceAxes(font, {'wght': 900});
      instanced = OpenTypeFont.parse(instancedBytes);
    });

    test('has no fvar, and no other variation table either', () {
      expect(instanced.sfnt.has(Tag.fvar), isFalse);
      expect(instanced.isVariable, isFalse);
      for (final tag in [
        Tag.gvar,
        Tag.avar,
        Tag.hvar,
        Tag.mvar,
        Tag.stat,
        Tag.parse('VVAR'),
      ]) {
        expect(
          instanced.sfnt.has(tag),
          isFalse,
          reason:
              '${Tag(tag).asString} describes variations that are now baked',
        );
      }
      // Everything a shaper needs is still here: instancing is not subsetting.
      for (final tag in [Tag.cmap, Tag.gsub, Tag.gpos, Tag.gdef, Tag.name]) {
        expect(instanced.sfnt.has(tag), isTrue);
      }
    });

    test('outlines actually moved', () {
      for (final gid in [gidA, gidLamVAboveAlef, gidUni06B5Init]) {
        expect(
          _describe(instanced.outline(gid)),
          isNot(equals(_describe(font.outline(gid)))),
          reason: 'glyph $gid did not change between wght 400 and 900',
        );
      }
    });

    test("'A' lands on fontTools' exact coordinates", () {
      final path = instanced.outline(gidA)!;
      expect(_corners(path), equals(aAtWght900));
    });

    test('glyph bounding boxes match fontTools', () {
      boundsAtWght900.forEach((gid, box) {
        final r = instanced.glyf!.boundingBox(gid)!;
        expect(
          [r.xMin.toInt(), r.yMin.toInt(), r.xMax.toInt(), r.yMax.toInt()],
          equals(box),
          reason: 'bounding box of glyph $gid',
        );
      });
    });

    test('composite component offsets moved with the design', () {
      final composite = CompositeGlyph.parse(
        instanced.glyf!.glyphBytes(gidAacute)!,
      )!;
      expect(
        [
          for (final c in composite.components) [c.glyphId, c.arg1, c.arg2],
        ],
        equals([
          [gidA, 0, 0],
          // 447, 311 at the default: the accent slides as the letter widens.
          [gidAcute, 455, 310],
        ]),
      );
    });

    test('advances match fontTools', () {
      advancesAtWght900.forEach((gid, advance) {
        expect(
          instanced.advanceWidth(gid),
          advance,
          reason: 'advance of glyph $gid',
        );
      });
      // `space` has no outline at all and still varies — proof the advances
      // come from the metrics tables and not from the ink.
      expect(
        instanced.advanceWidth(gidSpace),
        isNot(font.advanceWidth(gidSpace)),
      );
    });

    test('prefers HVAR where the font contradicts itself', () {
      // Vazirmatn contains exactly one glyph — of 1333 — whose `HVAR` advance
      // delta disagrees with its `gvar` phantom points: uniFBDC. `HVAR` grows
      // it 911 → 925 → 932 across the axis; the phantom points say it never
      // moves, and fontTools reports 911 at every weight because it rebuilds
      // metrics from the phantoms.
      //
      // `HVAR` wins here, deliberately and twice over: the OpenType spec makes
      // it authoritative when present, and it is what `payv`'s own shaper
      // measured with — so an embedded font built off the phantoms would
      // disagree with the glyph positions already written into the page.
      expect(font.advanceWidth(gidUniFbdc), 911);
      expect(instanced.advanceWidth(gidUniFbdc), 932);
    });

    test('left sidebearings match fontTools', () {
      lsbsAtWght900.forEach((gid, lsb) {
        expect(
          instanced.leftSideBearing(gid),
          lsb,
          reason: 'lsb of glyph $gid',
        );
      });
    });

    test('agrees with the variable face it came from, to within rounding', () {
      // The instanced font is integers; the variable face at the same
      // coordinates is not. Anything worse than half a unit per axis means the
      // deltas themselves diverged, not the rounding.
      final varied = font.withVariationCoords(
        font.normalizeAxisValues({'wght': 900}),
      );
      for (final gid in [gidA, gidAacute, gidLamVAboveAlef, gidUni06D5Fina]) {
        final a = _coordinates(instanced.outline(gid)!);
        final b = _coordinates(varied.outline(gid)!);
        expect(a.length, b.length, reason: 'command count of glyph $gid');
        for (var i = 0; i < a.length; i++) {
          expect(
            (a[i] - b[i]).abs(),
            lessThanOrEqualTo(1.0),
            reason: 'glyph $gid coordinate $i drifted',
          );
        }
      }
    });

    test('is smaller than the variable font it came from', () {
      // `gvar` alone is 101 KB of Vazirmatn's 236 KB.
      expect(instancedBytes.length, lessThan(bytes.length));
    });
  });

  group('the embedding pipeline', () {
    test('instance, then subset, and the outlines still hold', () {
      // The real path a PDF takes: pin the weight, then keep only the glyphs
      // the document draws.
      final instanced = OpenTypeFont.parse(
        Instancer.instanceAxes(font, {'wght': 900}),
      );
      final wanted = {
        gidA,
        gidAacute,
        gidLamVAboveAlef,
        gidUni06B5Init,
        gidUni06D5Fina,
      };
      final result = Subsetter.subset(instanced, wanted);
      final subset = OpenTypeFont.parse(result.bytes);

      expect(subset.isVariable, isFalse);
      for (final old in Subsetter.closure(instanced, wanted)) {
        final fresh = result.oldToNewGid[old]!;
        expect(
          _describe(subset.outline(fresh)),
          equals(_describe(instanced.outline(old))),
          reason: 'glyph $old → $fresh differs after the round trip',
        );
        expect(subset.advanceWidth(fresh), instanced.advanceWidth(old));
      }
      expect(result.bytes.length, lessThan(bytes.length ~/ 4));
    });
  });
}

/// The outline as comparable text — the only representation that fails when a
/// contour is lost rather than merely moved.
List<String> _describe(GlyphPath? path) =>
    path == null ? const <String>[] : [for (final c in path.commands) '$c'];

/// Every coordinate the path names, in order. Used for the tolerance
/// comparison, where the SHAPE of the command list is already known to match.
List<double> _coordinates(GlyphPath path) {
  final out = <double>[];
  for (final c in path.commands) {
    switch (c) {
      case MoveTo():
        out.addAll([c.x, c.y]);
      case LineTo():
        out.addAll([c.x, c.y]);
      case QuadTo():
        out.addAll([c.cx, c.cy, c.x, c.y]);
      case CubicTo():
        out.addAll([c.c1x, c.c1y, c.c2x, c.c2y, c.x, c.y]);
      case ClosePath():
        break;
    }
  }
  return out;
}

/// The on-curve points of an all-straight-line glyph, as integer pairs.
///
/// Only meaningful for a glyph with no curves — `A` — where the emitted
/// `MoveTo`/`LineTo` sequence is exactly the stored coordinate array and can be
/// compared to fontTools' output without interpreting anything.
List<List<int>> _corners(GlyphPath path) {
  final out = <List<int>>[];
  for (final c in path.commands) {
    switch (c) {
      case MoveTo():
        out.add([c.x.toInt(), c.y.toInt()]);
      case LineTo():
        out.add([c.x.toInt(), c.y.toInt()]);
      default:
        break;
    }
  }
  return out;
}
