// GPOS, graded against Vazirmatn's real positioning tables.
//
// The shaper-level gate (`test/shaping/harfbuzz_parity_test.dart`) proves the
// whole pipeline against HarfBuzz. This file proves the GPOS half ALONE, by
// building a glyph buffer by hand and running named lookups over it — so that
// when the gate goes red there is an answer to "is it GSUB or is it GPOS".
//
// The expected numbers are not this engine's own output. They were read out of
// the font's anchor and pair tables with fontTools, independently, and the
// mark-to-base pair below (28, −183) is also what HarfBuzz reports in the
// checked-in corpus for `بَب`. Two implementations and a golden file agree.
library;

import 'dart:io';

import 'package:payv/src/font/open_type_font.dart';
import 'package:payv/src/layout/gpos.dart';
import 'package:payv/src/shaping/glyph_buffer.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

// Glyph ids, from the HarfBuzz corpus and the font's own glyph order.
const int gidA = 2; // 'A'
const int gidW = 1310; // 'w'
const int gidBehInit = 1176; // uniFE91 — a base letter
const int gidFatha = 728; // uni064E — an above-base mark
const int gidShadda = 732; // uni0651 — a second above-base mark

/// Every glyph carries this bit, and every lookup is run with it. The real
/// masks come from the shaper's feature plan; here the point is only that the
/// mask gate does not accidentally exclude everything.
const int kMask = 0x1;

void main() {
  final fontFile = File(
    Platform.environment['PAYV_TEST_FONT'] ?? 'test/fonts/Vazirmatn.ttf',
  );
  if (!fontFile.existsSync()) {
    throw StateError('test font not found at ${fontFile.path}');
  }
  final font = OpenTypeFont.parse(fontFile.readAsBytesSync());
  final gpos = font.gpos;
  if (gpos == null) {
    throw StateError('Vazirmatn must have a GPOS table');
  }
  final gdef = font.gdef;

  /// A buffer seeded the way the shaper hands one to GPOS: glyph ids already
  /// substituted, advances already taken from `hmtx`, GDEF classes resolved.
  GlyphBuffer bufferOf(List<int> gids, {required TextDirection direction}) {
    final buffer = GlyphBuffer()..direction = direction;
    for (var i = 0; i < gids.length; i++) {
      buffer.infos.add(
        GlyphInfo(
          glyphId: gids[i],
          codepoint: -1,
          cluster: i,
          mask: kMask,
          glyphClass: gdef?.glyphClass(gids[i]) ?? GlyphClass.unclassified,
          markAttachClass: gdef?.markAttachClass(gids[i]) ?? 0,
        ),
      );
      buffer.positions.add(GlyphPosition(xAdvance: font.advanceWidth(gids[i])));
    }
    return buffer;
  }

  /// Runs every lookup the font schedules for [features] under [script].
  void runFeatures(
    GlyphBuffer buffer,
    Set<int> features, {
    required int script,
  }) {
    final lookups = gpos.layout.lookupsFor(
      script: script,
      language: Tag.dflt,
      features: features,
    );
    expect(
      lookups,
      isNotEmpty,
      reason: 'the font must schedule lookups for $features under $script',
    );
    for (final lookup in lookups) {
      gpos.applyLookup(lookup, buffer, mask: kMask, gdef: gdef);
    }
  }

  group('parsing', () {
    test('every lookup resolves, extensions included', () {
      // Vazirmatn wraps almost all of its GPOS in type 9 extension subtables.
      // If that indirection were broken, the table would look empty rather than
      // throw — so this asserts the resolved types, not merely that it parsed.
      final resolved = <int>{};
      for (var i = 0; i < gpos.lookupCount; i++) {
        for (final subtable in gpos.subtablesOf(i)) {
          resolved.add(subtable.runtimeType.hashCode);
        }
      }
      expect(gpos.lookupCount, greaterThan(0));
      expect(resolved, isNotEmpty);

      // The font declares type 9 on most lookups; none may still READ as 9.
      expect(
        List.generate(gpos.lookupCount, gpos.declaredLookupType),
        contains(9),
        reason: 'this font is expected to use extension lookups',
      );
      expect(
        List.generate(gpos.lookupCount, gpos.lookupType),
        isNot(contains(9)),
        reason: 'an extension must report the type it wraps',
      );
      expect(
        List.generate(gpos.lookupCount, gpos.lookupType).toSet(),
        containsAll(<int>[1, 2, 4, 5, 6, 8]),
        reason:
            'Vazirmatn exercises single, pair, all three mark types and '
            'chaining context',
      );
    });
  });

  group('type 2 — pair adjustment (kerning)', () {
    test('a known Latin kern pair closes the gap', () {
      // 'A' followed by 'w': PairPos format 1 carries −33 on the FIRST glyph.
      final kerned = bufferOf([gidA, gidW], direction: TextDirection.ltr);
      final loose = font.advanceWidth(gidA);
      runFeatures(kerned, {Tag.kern}, script: Tag.latn);

      expect(kerned.positions[0].xAdvance, loose - 33);
      expect(
        kerned.positions[1].xAdvance,
        font.advanceWidth(gidW),
        reason: 'valueFormat2 is empty here, so the second glyph is untouched',
      );
    });

    test('an unkerned pair is left exactly alone', () {
      final plain = bufferOf([gidA, gidA], direction: TextDirection.ltr);
      runFeatures(plain, {Tag.kern}, script: Tag.latn);
      expect(plain.positions[0].xAdvance, font.advanceWidth(gidA));
      expect(plain.positions[1].xAdvance, font.advanceWidth(gidA));
    });
  });

  group('type 4 — mark-to-base', () {
    test('a mark over a base gets a real offset and a zero advance', () {
      final buffer = bufferOf([
        gidBehInit,
        gidFatha,
      ], direction: TextDirection.rtl);
      runFeatures(buffer, {Tag.mark}, script: Tag.arab);

      // Recorded as a chain, not yet as a finished offset.
      expect(buffer.positions[1].attachType, GlyphPosition.attachTypeMark);
      expect(buffer.positions[1].attachChain, -1);

      GposTable.positionFinish(buffer, reverseForRtl: false);

      // baseAnchor(326,1000) − markAnchor(298,1183). HarfBuzz reports the same
      // pair for `بَب` in test/fixtures/harfbuzz_golden.json.
      expect(buffer.positions[1].xOffset, 28);
      expect(buffer.positions[1].yOffset, -183);
      expect(
        buffer.positions[1].yOffset,
        isNot(0),
        reason: 'a mark that did not move was never positioned',
      );

      // The mark must not advance the pen — it sits ON the base, it does not
      // follow it.
      expect(buffer.positions[1].xAdvance, 0);
      expect(
        buffer.positions[0].xAdvance,
        font.advanceWidth(gidBehInit),
        reason: 'the base keeps its own advance',
      );

      // And the chain is spent: propagation must not be re-runnable.
      expect(buffer.positions[1].attachChain, 0);
    });

    test('the base search ignores intervening marks', () {
      // The second mark must still find the BASE through the first mark, not
      // attach to the first mark via a mark-to-base lookup.
      final buffer = bufferOf([
        gidBehInit,
        gidFatha,
        gidShadda,
      ], direction: TextDirection.rtl);
      runFeatures(buffer, {Tag.mark}, script: Tag.arab);
      expect(buffer.positions[2].attachChain, -2, reason: 'attached to gid 0');
    });
  });

  group('type 6 — mark-to-mark', () {
    test('two stacked marks do not land on top of each other', () {
      final buffer = bufferOf([
        gidBehInit,
        gidFatha,
        gidShadda,
      ], direction: TextDirection.rtl);

      runFeatures(buffer, {Tag.mark}, script: Tag.arab);
      runFeatures(buffer, {Tag.mkmk}, script: Tag.arab);

      // mkmk re-parents the second mark onto the first.
      expect(buffer.positions[2].attachChain, -1);

      GposTable.positionFinish(buffer, reverseForRtl: false);

      final low = buffer.positions[1];
      final high = buffer.positions[2];

      // First mark: base(326,1000) − fatha(298,1183).
      expect([low.xOffset, low.yOffset], [28, -183]);
      // Second mark: mark2Anchor(293,1430) − mark1Anchor(333,998) = (−40,432),
      // then inheriting the first mark's resolved offset.
      expect([high.xOffset, high.yOffset], [-12, 249]);

      expect(
        high.yOffset - low.yOffset,
        432,
        reason:
            'the upper mark must clear the lower one by the mkmk anchor '
            'delta; equal offsets mean the two glyphs are drawn on top of '
            'each other',
      );
      expect(high.xAdvance, 0);
      expect(low.xAdvance, 0);
    });

    test('without mkmk both marks sit on the base and collide', () {
      // The control for the test above: this is exactly the broken rendering
      // that mark-to-mark exists to prevent, and it must be reachable — if the
      // `mark` pass alone already separated them, the assertion above would be
      // proving nothing.
      final buffer = bufferOf([
        gidBehInit,
        gidFatha,
        gidShadda,
      ], direction: TextDirection.rtl);
      runFeatures(buffer, {Tag.mark}, script: Tag.arab);
      GposTable.positionFinish(buffer, reverseForRtl: false);

      expect(buffer.positions[1].yOffset, -183);
      expect(buffer.positions[2].yOffset, 2);
      expect(
        (buffer.positions[2].yOffset - buffer.positions[1].yOffset).abs(),
        lessThan(432),
      );
    });
  });

  group('the final passes', () {
    test('propagation is recursive — a mark on a mark on a base', () {
      // Built by hand so the chain is unambiguous: glyph 2 hangs off glyph 1,
      // which hangs off glyph 0.
      final buffer = bufferOf([
        gidBehInit,
        gidFatha,
        gidShadda,
      ], direction: TextDirection.ltr);
      buffer.positions[1]
        ..xOffset = 10
        ..yOffset = 100
        ..attachType = GlyphPosition.attachTypeMark
        ..attachChain = -1;
      buffer.positions[2]
        ..xOffset = 5
        ..yOffset = 50
        ..attachType = GlyphPosition.attachTypeMark
        ..attachChain = -1;

      GposTable.positionFinish(buffer, reverseForRtl: false);

      // LTR: each mark subtracts the advances the pen already spent between it
      // and its parent. Both marks are zero-width by now, so glyph 1 pays only
      // the base's advance and glyph 2 inherits glyph 1's resolved offset.
      final baseAdvance = font.advanceWidth(gidBehInit);
      expect(buffer.positions[1].xOffset, 10 - baseAdvance);
      expect(buffer.positions[1].yOffset, 100);
      expect(buffer.positions[2].xOffset, 5 + 10 - baseAdvance);
      expect(
        buffer.positions[2].yOffset,
        150,
        reason:
            'the upper mark must see the lower one FINAL position, which '
            'is what makes propagation recursive rather than one-level',
      );
    });

    test('an RTL buffer comes back in visual order', () {
      final buffer = bufferOf([
        gidBehInit,
        gidFatha,
      ], direction: TextDirection.rtl);
      runFeatures(buffer, {Tag.mark}, script: Tag.arab);
      GposTable.positionFinish(buffer);
      expect(buffer.infos.map((i) => i.glyphId), [gidFatha, gidBehInit]);
    });

    test('a cyclic attachment chain terminates', () {
      // No real font does this. A corrupt one must not be able to hang a
      // document export, so the guard is asserted rather than assumed.
      final buffer = bufferOf([
        gidBehInit,
        gidFatha,
      ], direction: TextDirection.ltr);
      buffer.positions[0]
        ..attachType = GlyphPosition.attachTypeMark
        ..attachChain = 1;
      buffer.positions[1]
        ..attachType = GlyphPosition.attachTypeMark
        ..attachChain = -1;
      expect(() => GposTable.propagateAttachments(buffer), returnsNormally);
    });
  });
}
