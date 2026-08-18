/// The subsetter, against the real face.
///
/// Every assertion here is about something that fails SILENTLY in production:
/// a dropped composite component prints an accent-less letter, a stale
/// component glyph id prints the wrong letter entirely, and a `loca` format
/// that disagrees with `head` prints garbage. None of them throw, so the test
/// has to look at the output rather than at the absence of an exception.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:payv/src/font/glyph_path.dart';
import 'package:payv/src/font/open_type_font.dart';
import 'package:payv/src/font/subset.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

/// Same override every other test in the package uses, so one env var repoints
/// the whole suite at a different face.
final String fontPath =
    Platform.environment['PAYV_TEST_FONT'] ?? 'test/fonts/Vazirmatn.ttf';

/// Sorani, and chosen for what is in it: ڕ ێ ڵ ە are the four letters with no
/// Unicode presentation form, which is the reason this package exists.
const String kurdishText = 'ڕێگای وڵاتەکە لە هەرێمی کوردستان ٢٠٢٦';

/// Glyphs reachable ONLY through `GSUB`, plus one Latin composite.
///
/// A subsetter that walks the cmap would never see the first three, and they
/// are exactly the glyphs a Kurdish document cannot be rendered without.
const int gidLamVAboveAlef = 474; // ڵ + ا, a ligature with no codepoint
const int gidUni06B5Init = 839; // ڵ initial
const int gidUni06D5Fina = 896; // ە final
const int gidAacute = 9; // 'A' + 'acute'
const int gidA = 2;
const int gidAcute = 313;

void main() {
  late Uint8List bytes;
  late OpenTypeFont font;

  setUpAll(() {
    bytes = File(fontPath).readAsBytesSync();
    font = OpenTypeFont.parse(bytes);
    // Pin the fixture. Every glyph id below is Vazirmatn's; against another
    // face they would silently address different letters.
    expect(font.numGlyphs, 1333, reason: 'fixture font changed');
    expect(font.unitsPerEm, 2048);
  });

  /// The glyph set a Kurdish document actually draws, plus the three GSUB-only
  /// forms and one Latin composite.
  Set<int> requestedGlyphs() => {
    for (final scalar in kurdishText.runes)
      if (font.glyphForCodepoint(scalar) != 0) font.glyphForCodepoint(scalar),
    gidLamVAboveAlef,
    gidUni06B5Init,
    gidUni06D5Fina,
    gidAacute,
  };

  group('composite closure', () {
    test('pulls in components no text asked for', () {
      final requested = requestedGlyphs();
      final closed = Subsetter.closure(font, requested);

      // The seed set contains neither 'A' nor 'acute' — only the composite
      // that is built from them.
      expect(requested.contains(gidA), isFalse);
      expect(requested.contains(gidAcute), isFalse);
      expect(closed, containsAll([gidA, gidAcute]));

      // …and the Arabic ligature's own components.
      for (final gid in [gidLamVAboveAlef, gidUni06B5Init, gidUni06D5Fina]) {
        expect(
          Subsetter.componentGlyphs(font.glyf!, gid),
          isNotEmpty,
          reason: 'glyph $gid should be a composite in this font',
        );
        expect(closed, containsAll(Subsetter.componentGlyphs(font.glyf!, gid)));
      }
    });

    test('always keeps .notdef, even when nothing asked for it', () {
      expect(Subsetter.closure(font, const <int>{}), equals({0}));
      expect(Subsetter.closure(font, {gidA}), containsAll([0, gidA]));
    });

    test('runs to a fixed point, not one level deep', () {
      // Vazirmatn's ڵ-initial is a composite whose components are themselves
      // real glyphs; the closure must be stable under a second pass.
      final once = Subsetter.closure(font, requestedGlyphs());
      final twice = Subsetter.closure(font, once);
      expect(twice, equals(once));
    });
  });

  group('subset of a Kurdish word set', () {
    late FontSubset result;
    late OpenTypeFont subset;
    late Set<int> kept;

    setUpAll(() {
      kept = Subsetter.closure(font, requestedGlyphs());
      result = Subsetter.subset(font, requestedGlyphs());
      subset = OpenTypeFont.parse(result.bytes);
    });

    test('re-parses as a font with the right glyph count', () {
      expect(kept.length, 38, reason: 'closure size for this fixture');
      expect(result.numGlyphs, kept.length);
      expect(subset.numGlyphs, kept.length);
      expect(subset.unitsPerEm, font.unitsPerEm);
      expect(result.oldToNewGid.length, kept.length);
      expect(result.newToOldGid.length, kept.length);
    });

    test('.notdef stays at glyph 0', () {
      expect(result.oldToNewGid[0], 0);
      expect(result.newToOldGid[0], 0);
    });

    test('the maps are inverses', () {
      result.oldToNewGid.forEach((old, fresh) {
        expect(result.newToOldGid[fresh], old);
      });
    });

    test('every retained outline survives point for point', () {
      for (final old in kept) {
        final fresh = result.oldToNewGid[old]!;
        expect(
          _describe(subset.outline(fresh)),
          equals(_describe(font.outline(old))),
          reason: 'glyph $old → $fresh differs after subsetting',
        );
      }
    });

    test('composite components survived and were renumbered', () {
      final fresh = result.oldToNewGid[gidAacute]!;
      final composite = CompositeGlyph.parse(subset.glyf!.glyphBytes(fresh)!);
      expect(composite, isNotNull);
      expect([
        for (final c in composite!.components) c.glyphId,
      ], equals([result.oldToNewGid[gidA], result.oldToNewGid[gidAcute]]));

      // The Kurdish ligature matters more than the Latin one: its components
      // are the glyphs that carry the ڵ hook and the ا stem.
      final ligature = result.oldToNewGid[gidLamVAboveAlef]!;
      final parts = CompositeGlyph.parse(subset.glyf!.glyphBytes(ligature)!)!;
      final expected = [
        for (final c in Subsetter.componentGlyphs(font.glyf!, gidLamVAboveAlef))
          result.oldToNewGid[c],
      ];
      expect([for (final c in parts.components) c.glyphId], equals(expected));
      expect(parts.components, isNotEmpty);
    });

    test('advances and sidebearings follow the renumbering', () {
      for (final old in kept) {
        final fresh = result.oldToNewGid[old]!;
        expect(
          subset.advanceWidth(fresh),
          font.advanceWidth(old),
          reason: 'advance of glyph $old',
        );
        expect(
          subset.leftSideBearing(fresh),
          font.leftSideBearing(old),
          reason: 'lsb of glyph $old',
        );
      }
    });

    test('is under a quarter of the original', () {
      expect(
        result.bytes.length,
        lessThan(bytes.length ~/ 4),
        reason:
            '${result.bytes.length} of ${bytes.length} bytes '
            '(${(100 * result.bytes.length / bytes.length).toStringAsFixed(1)}%)',
      );
    });

    test('carries only what a rasteriser needs to draw by index', () {
      // The surprising half of subsetting: an Identity-H CIDFontType2 addresses
      // glyphs by number, and shaping already happened. So there is nothing for
      // a cmap to map and nothing for GSUB to do.
      for (final tag in [
        Tag.cmap,
        Tag.name,
        Tag.post,
        Tag.os2,
        Tag.gsub,
        Tag.gpos,
        Tag.gdef,
        Tag.fvar,
        Tag.gvar,
        Tag.avar,
        Tag.hvar,
        Tag.stat,
      ]) {
        expect(
          subset.sfnt.has(tag),
          isFalse,
          reason: '${Tag(tag).asString} should not survive subsetting',
        );
      }
      for (final tag in [
        Tag.glyf,
        Tag.loca,
        Tag.head,
        Tag.hhea,
        Tag.hmtx,
        Tag.maxp,
      ]) {
        expect(
          subset.sfnt.has(tag),
          isTrue,
          reason: '${Tag(tag).asString} is required to draw a glyph',
        );
      }
      // Hinting tables ride along when the source has them; Vazirmatn ships
      // `prep` and `gasp` but no `cvt `/`fpgm`.
      for (final tag in [Tag.cvt, Tag.fpgm, Tag.prep, Tag.gasp]) {
        expect(subset.sfnt.has(tag), font.sfnt.has(tag));
      }
    });

    test('the loca format head declares is the one that was written', () {
      // A short `loca` at this size, which is the whole reason a subset is
      // small — and it only works because every glyph is padded to an even
      // offset.
      expect(subset.head.indexToLocFormat, 0);
      final loca = subset.sfnt.tableBytes(Tag.loca)!;
      expect(loca.length, (result.numGlyphs + 1) * 2);
    });
  });

  group('retainGids', () {
    test('keeps the original numbering and ends at the highest id', () {
      final requested = {gidA, gidAacute};
      final result = Subsetter.subset(font, requested, retainGids: true);
      final subset = OpenTypeFont.parse(result.bytes);

      expect(result.numGlyphs, gidAcute + 1);
      expect(subset.numGlyphs, gidAcute + 1);
      for (final gid in [0, gidA, gidAacute, gidAcute]) {
        expect(result.oldToNewGid[gid], gid);
        expect(
          _describe(subset.outline(gid)),
          equals(_describe(font.outline(gid))),
          reason: 'glyph $gid moved',
        );
      }
      // A glyph nobody asked for is a hole, not a renumbering.
      expect(subset.glyf!.glyphBytes(gidA + 1), isNull);
      expect(result.oldToNewGid.containsKey(gidA + 1), isFalse);
    });
  });
}

/// A glyph outline as comparable text.
///
/// Comparing [GlyphPath] objects directly would compare identity; comparing
/// bounding boxes would pass a subset that lost an interior contour. The
/// command list is the only representation that fails when it should.
List<String> _describe(GlyphPath? path) =>
    path == null ? const <String>[] : [for (final c in path.commands) '$c'];
