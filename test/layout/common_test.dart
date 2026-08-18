// The layout-common plumbing, graded against a real font.
//
// Coverage, ClassDef and GDEF have no visible output of their own — they are
// the layer everything else asks questions of, so a wrong answer here does not
// crash, it quietly shapes the wrong glyph. The font-driven tests below walk
// Vazirmatn's actual GSUB and assert against glyph ids taken from the HarfBuzz
// corpus, and the synthetic ones cover the packed structures (Device deltas,
// variable-length ValueRecords) that Vazirmatn happens not to exercise.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:payv/src/font/sfnt.dart';
import 'package:payv/src/layout/common.dart';
import 'package:payv/src/shaping/glyph_buffer.dart';
import 'package:payv/src/util/byte_reader.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

/// Glyph ids lifted from `test/fixtures/harfbuzz_golden.json`, so they are
/// HarfBuzz's answers for this exact font rather than anything this engine
/// derived.
const int gidRe = 804; // uni0695 — ڕ, a base letter
const int gidBehFinal = 1175; // uniFE90 — a base letter
const int gidShadda = 732; // uni0651 — a combining mark
const int gidFatha = 728; // uni064E — a combining mark
const int gidDotBelow = 379; // the only glyph in GDEF mark set 0

void main() {
  final fontFile = File(
    Platform.environment['PAYV_TEST_FONT'] ?? 'test/fonts/Vazirmatn.ttf',
  );
  if (!fontFile.existsSync()) {
    throw StateError('test font not found at ${fontFile.path}');
  }
  final sfnt = SfntFile.parse(fontFile.readAsBytesSync());
  final gsub = LayoutTable.parse(sfnt.requireTable(Tag.gsub));
  final gdef = GdefTable.parse(sfnt.requireTable(Tag.gdef));

  group('Coverage (Vazirmatn GSUB)', () {
    test('index round-trips for every glyph in every coverage table', () {
      final coverages = _gsubCoverages(sfnt, gsub);
      expect(
        coverages,
        isNotEmpty,
        reason:
            'no GSUB coverage tables were reached — the walk is broken, '
            'not the parser',
      );

      for (final coverage in coverages) {
        var expected = 0;
        for (final glyph in coverage.glyphs) {
          expect(
            coverage.index(glyph),
            expected,
            reason: 'glyph $glyph should sit at coverage index $expected',
          );
          expect(coverage.covers(glyph), isTrue);
          expected++;
        }
        expect(coverage.glyphCount, expected);
      }
    });

    test('an uncovered glyph reports -1, not a neighbouring index', () {
      final coverages = _gsubCoverages(sfnt, gsub);
      // 0xFFFF is past the end of any 1333-glyph font, and glyph 0 (.notdef)
      // is never in a substitution coverage.
      for (final coverage in coverages) {
        expect(coverage.index(0xFFFF), -1);
        expect(coverage.covers(0xFFFF), isFalse);
      }

      final covered = coverages.first.glyphs.toSet();
      final absent = Iterable<int>.generate(
        1333,
      ).firstWhere((g) => !covered.contains(g));
      expect(coverages.first.index(absent), -1);
    });

    test('both formats parse, and format 2 is the interesting one', () {
      // Not a correctness claim — a canary. If a font revision ever drops to a
      // single coverage format the round-trip test above gets much weaker, and
      // this is where that shows up.
      expect(_gsubCoverages(sfnt, gsub).length, greaterThan(4));
    });
  });

  group('ClassDef', () {
    test('returns 0 for a glyph the table does not list', () {
      // Past the last glyph of the font, so no format can legitimately claim
      // it, whichever ClassDef GDEF happens to ship.
      expect(gdef.glyphClass(0xFFFE), 0);
      expect(gdef.markAttachClass(0xFFFE), 0);
    });

    test('the empty ClassDef puts everything in class 0', () {
      expect(ClassDef.empty.classOf(0), 0);
      expect(ClassDef.empty.classOf(gidRe), 0);
      expect(ClassDef.empty.classOf(0xFFFF), 0);
    });

    test('format 1 covers exactly its declared range', () {
      // startGlyphID 10, three glyphs, classes 7 8 9.
      final def = ClassDef.parse(_reader([1, 10, 3, 7, 8, 9]));
      expect(def.classOf(9), 0);
      expect(def.classOf(10), 7);
      expect(def.classOf(12), 9);
      expect(def.classOf(13), 0);
    });

    test('format 2 range records resolve, including between the ranges', () {
      // Two ranges: 10..12 → class 4, 20..20 → class 5.
      final def = ClassDef.parse(_reader([2, 2, 10, 12, 4, 20, 20, 5]));
      expect(def.classOf(9), 0);
      expect(def.classOf(11), 4);
      expect(def.classOf(13), 0);
      expect(def.classOf(20), 5);
      expect(def.classOf(21), 0);
    });
  });

  group('GDEF (Vazirmatn)', () {
    test('an Arabic combining mark is class 3', () {
      expect(gdef.glyphClass(gidShadda), GlyphClass.mark);
      expect(gdef.glyphClass(gidFatha), GlyphClass.mark);
    });

    test('an Arabic letter is class 1', () {
      expect(gdef.glyphClass(gidRe), GlyphClass.base);
      expect(gdef.glyphClass(gidBehFinal), GlyphClass.base);
    });

    test('the mark filtering sets parse and answer', () {
      // Vazirmatn ships three mark sets; fontTools reports set 0 as the single
      // glyph `dotbelow`, gid 379. A set that answers false to everything would
      // pass every other test in this file while silently disabling the
      // lookups that use it.
      expect(gdef.isInMarkFilteringSet(0, gidDotBelow), isTrue);
      expect(gdef.isInMarkFilteringSet(0, gidShadda), isFalse);

      // An out-of-range set index must be a quiet false rather than a throw:
      // the index comes from a lookup flag we do not control.
      expect(gdef.isInMarkFilteringSet(9999, gidShadda), isFalse);
      expect(gdef.isInMarkFilteringSet(-1, gidDotBelow), isFalse);
      expect(gdef.isInMarkFilteringSet(0, 0xFFFE), isFalse);
    });

    test('ligature carets parse, including the ones we cannot resolve', () {
      // Vazirmatn ships no LigCaretList at all, so the only way to test this
      // path is a synthetic GDEF: one covered glyph (5) with two carets, the
      // first a format 1 coordinate and the second a format 2 contour point
      // that this layer has no outlines to resolve and reports as 0.
      final synthetic = GdefTable.parse(
        _reader([
          1, 0, 0, 0, 12, 0, // header: only ligCaretListOffset is set
          8, 1, 14, 0, //       LigCaretList + padding
          1, 1, 5, //           Coverage format 1: glyph 5
          2, 6, 10, //          LigGlyph: two caret offsets
          1, 250, //            CaretValue format 1
          2, 3, //              CaretValue format 2 (contour point)
        ]),
      );
      expect(synthetic.ligatureCarets(5), [250, 0]);
      expect(synthetic.ligatureCarets(6), isNull);
      expect(synthetic.varStore, isNull);
      expect(synthetic.hasGlyphClasses, isFalse);

      expect(gdef.ligatureCarets(gidRe), isNull);
    });

    test('the version 1.3 ItemVariationStore is reachable', () {
      // GPOS device offsets in this font are VariationIndex records, so a null
      // store here means every variable-instance mark position is unresolvable.
      expect(gdef.minorVersion, 3);
      expect(gdef.varStore, isNotNull);
      expect(gdef.hasGlyphClasses, isTrue);
    });
  });

  group('LayoutTable (Vazirmatn GSUB)', () {
    test('the Arabic joining features resolve to lookups', () {
      final lookups = gsub.lookupsFor(
        script: Tag.arab,
        language: Tag.dflt,
        features: {Tag.isol, Tag.init, Tag.medi, Tag.fina},
      );
      expect(
        lookups,
        isNotEmpty,
        reason: 'without these four features no Arabic script joins at all',
      );
      for (final index in lookups) {
        expect(index, lessThan(gsub.lookupOffsets.length));
      }
    });

    test('the Arabic joining lookups are exactly the ones fontTools names', () {
      // Ground truth read out of Vazirmatn with fontTools, independently of
      // this parser: the `arab` default LangSys names feature indices
      // [1,3,7,9,11,19,22,25,26], of which isol/init/medi/fina contribute
      // lookups 22, 23 and 24. Pinning the ORDER is the point — it is the one
      // thing a self-consistent parser can still get wrong.
      //
      // ASCENDING LOOKUP ORDER, not FeatureList order. This expectation used to
      // read [22, 24, 23], matching an implementation that returned lookups in
      // the order their features appear. The LookupList table is normative the
      // other way: the font developer defines the lookup sequence there to
      // control the order a client applies them, and HarfBuzz sorts its stage
      // map by lookup index for that reason. See doc/DEFECTS.md F4.
      expect(
        gsub.lookupsFor(
          script: Tag.arab,
          language: Tag.dflt,
          features: {Tag.isol, Tag.init, Tag.medi, Tag.fina},
        ),
        [22, 23, 24],
      );
      expect(
        gsub.availableFeatures(script: Tag.arab, language: Tag.dflt),
        hasLength(9),
      );
      expect(gsub.lookupOffsets, hasLength(37));
      expect(gsub.featureCount, 28);
    });

    test('lookups are deduplicated across the requested features', () {
      final lookups = gsub.lookupsFor(
        script: Tag.arab,
        language: Tag.dflt,
        features: {Tag.isol, Tag.init, Tag.medi, Tag.fina, Tag.rlig, Tag.calt},
      );
      expect(lookups.toSet().length, lookups.length);
    });

    test(
      'an unknown script falls back to DFLT rather than shaping nothing',
      () {
        const bogus = Tag(0x7A7A7A7A); // 'zzzz'
        expect(gsub.hasScript(bogus), isFalse);
        expect(
          gsub.availableFeatures(script: bogus, language: Tag.dflt),
          gsub.availableFeatures(script: Tag.dflt, language: Tag.dflt),
        );
      },
    );

    test('an unknown language falls back to the script default LangSys', () {
      const bogus = Tag(0x5A5A5A20); // 'ZZZ '
      expect(
        gsub.availableFeatures(script: Tag.arab, language: bogus),
        gsub.availableFeatures(script: Tag.arab, language: Tag.dflt),
      );
    });

    test('every feature tag maps back to its own lookups', () {
      for (var i = 0; i < gsub.featureCount; i++) {
        expect(gsub.featureTag(i), isNonZero);
        for (final lookup in gsub.featureLookups(i)) {
          expect(lookup, lessThan(gsub.lookupOffsets.length));
        }
      }
      expect(() => gsub.featureTag(gsub.featureCount), throwsFontFormat);
    });

    test('lookup offsets are absolute and land inside the file', () {
      final table = sfnt.record(Tag.gsub)!;
      for (final offset in gsub.lookupOffsets) {
        expect(offset, greaterThan(table.offset));
        expect(offset, lessThan(table.offset + table.length));
      }
    });
  });

  group('ValueRecord', () {
    test('sizeOf is two bytes per set bit', () {
      expect(ValueRecord.sizeOf(0), 0);
      expect(ValueRecord.sizeOf(ValueFormat.xAdvance), 2);
      expect(ValueRecord.sizeOf(0x0005), 4);
      expect(ValueRecord.sizeOf(0x00FF), 16);
    });

    test('fields are read in bit order and the size comes back with them', () {
      // Format 0x0015 = xPlacement | xAdvance | xPlacementDevice.
      final (value, consumed) = ValueRecord.parse(
        _reader([0xFFF6, 40, 12]), // -10, 40, device offset 12
        0,
        0x0015,
      );
      expect(consumed, 6);
      expect(value.xPlacement, -10);
      expect(value.yPlacement, 0);
      expect(value.xAdvance, 40);
      expect(value.xPlaDeviceOffset, 12);
      expect(value.yPlaDeviceOffset, isNull);
      expect(value.hasDevices, isTrue);
    });

    test('a NULL device offset collapses to null', () {
      final (value, _) = ValueRecord.parse(
        _reader([0, 0]),
        0,
        ValueFormat.xAdvance | ValueFormat.xAdvanceDevice,
      );
      expect(value.xAdvDeviceOffset, isNull);
      expect(value.hasDevices, isFalse);
      expect(value.isZero, isTrue);
    });
  });

  group('Device', () {
    test('format 3 unpacks signed 8-bit deltas', () {
      // ppem 12..14, deltas +1, -1, +2 packed two per uint16.
      final device = Device.parse(_reader([12, 14, 3, 0x01FF, 0x0200]));
      expect(device.isVariationIndex, isFalse);
      expect(device.valueAt(11), 0);
      expect(device.valueAt(12), 1);
      expect(device.valueAt(13), -1);
      expect(device.valueAt(14), 2);
      expect(device.valueAt(15), 0);
    });

    test('format 1 unpacks signed 2-bit deltas, eight per word', () {
      // ppem 8..11 with deltas -2, -1, 0, 1 → 10 11 00 01 in the high bits.
      final device = Device.parse(_reader([8, 11, 1, 0xB100]));
      expect(device.valueAt(8), -2);
      expect(device.valueAt(9), -1);
      expect(device.valueAt(10), 0);
      expect(device.valueAt(11), 1);
    });

    test('format 2 unpacks signed 4-bit deltas, four per word', () {
      // ppem 8..11 with deltas 1, -1, 7, -8 → 0x1F78.
      final device = Device.parse(_reader([8, 11, 2, 0x1F78]));
      expect(device.valueAt(8), 1);
      expect(device.valueAt(9), -1);
      expect(device.valueAt(10), 7);
      expect(device.valueAt(11), -8);
    });

    test('a VariationIndex exposes its delta-set pair and no ppem deltas', () {
      final device = Device.parse(_reader([3, 47, 0x8000]));
      expect(device.isVariationIndex, isTrue);
      expect(device.deltaSetOuter, 3);
      expect(device.deltaSetInner, 47);
      expect(device.valueAt(12), 0);
    });

    test('an unknown delta format throws rather than misreading the array', () {
      expect(() => Device.parse(_reader([8, 11, 9])), throwsFontFormat);
    });
  });

  group('Anchor', () {
    test('format 1 is bare coordinates', () {
      final anchor = Anchor.parse(_reader([1, 0xFF9C, 500])); // -100, 500
      expect(anchor.x, -100);
      expect(anchor.y, 500);
      expect(anchor.contourPoint, isNull);
      expect(anchor.xDevice, isNull);
    });

    test('format 2 carries a contour point', () {
      final anchor = Anchor.parse(_reader([2, 10, 20, 7]));
      expect(anchor.contourPoint, 7);
    });

    test('format 3 resolves its devices relative to the anchor itself', () {
      // Anchor at 0: format 3, x, y, xDeviceOffset 10, yDeviceOffset 0.
      // The Device table then starts at byte 10.
      final anchor = Anchor.parse(
        _reader([3, 10, 20, 10, 0, 12, 12, 3, 0x0300]),
      );
      expect(anchor.xDevice, isNotNull);
      expect(anchor.xDevice!.valueAt(12), 3);
      expect(anchor.yDevice, isNull);
    });

    test('an unknown anchor format throws', () {
      expect(() => Anchor.parse(_reader([9, 0, 0])), throwsFontFormat);
    });
  });

  group('resolveExtension', () {
    test('passes a non-extension subtable straight through', () {
      final subtable = _reader([1, 2, 3]);
      final (type, out) = resolveExtension(4, subtable, extensionType: 7);
      expect(type, 4);
      expect(identical(out, subtable), isTrue);
    });

    test('resolves to the real type and subtable', () {
      // ExtensionSubst at 0: format 1, real type 4, Offset32 = 12.
      final reader = _reader([1, 4, 0, 12, 0, 0, 0xBEEF]);
      final (type, out) = resolveExtension(7, reader, extensionType: 7);
      expect(type, 4);
      expect(out.position, 12);
      expect(out.uint16At(out.position), 0xBEEF);
    });

    test('a nested extension throws instead of recursing', () {
      expect(
        () => resolveExtension(7, _reader([1, 7, 0, 12]), extensionType: 7),
        throwsFontFormat,
      );
    });
  });

  group('resolveExtension (Vazirmatn GPOS)', () {
    test('every extension lookup resolves to the type fontTools reports', () {
      // Vazirmatn puts almost all of GPOS behind type-9 extensions — 16 of 18
      // lookups — because its layout data does not fit in 16-bit offsets. A
      // shaper that does not unwrap these sees sixteen unknown lookup types
      // and positions nothing: no kerning, no marks, no mkmk.
      const expected = [
        1, 2, 4, 6, 6, 1, 1, 1, 1, 1, 8, 1, 4, 5, 4, 5, 6, 6, //
      ];

      final gpos = LayoutTable.parse(sfnt.requireTable(Tag.gpos));
      final reader = sfnt.requireTable(Tag.gpos);
      expect(gpos.lookupOffsets, hasLength(expected.length));

      for (var i = 0; i < gpos.lookupOffsets.length; i++) {
        final lookup = gpos.lookupOffsets[i];
        final declaredType = reader.uint16At(lookup);
        final subtable = lookup + reader.uint16At(lookup + 6);
        final (resolvedType, _) = resolveExtension(
          declaredType,
          reader.at(subtable),
          extensionType: 9,
        );
        expect(resolvedType, expected[i], reason: 'GPOS lookup $i');
      }
    });

    test('a mark filtering set index sits after the subtable array', () {
      // Lookups 3 and 4 set UseMarkFilteringSet, so the extra uint16 that
      // follows their subtable offsets must name one of GDEF's three sets. If
      // the field were read at the wrong place the value would be garbage and
      // the lookup would silently match nothing.
      final gpos = LayoutTable.parse(sfnt.requireTable(Tag.gpos));
      final reader = sfnt.requireTable(Tag.gpos);
      for (final i in [3, 4]) {
        final lookup = gpos.lookupOffsets[i];
        expect(
          reader.uint16At(lookup + 2) & LookupFlag.useMarkFilteringSet,
          isNonZero,
        );
        final count = reader.uint16At(lookup + 4);
        final set = reader.uint16At(lookup + 6 + count * 2);
        expect(set, lessThan(3));
      }
    });
  });

  group('SkippyIterator', () {
    // b + shadda + b — the case the whole class exists for. A `calt` lookup
    // with IgnoreMarks must see the two letters as adjacent.
    GlyphBuffer buffer() {
      final b = GlyphBuffer();
      b.infos.addAll([
        GlyphInfo(
          glyphId: gidBehFinal,
          codepoint: 0x0628,
          cluster: 0,
          glyphClass: GlyphClass.base,
        ),
        GlyphInfo(
          glyphId: gidShadda,
          codepoint: 0x0651,
          cluster: 0,
          glyphClass: GlyphClass.mark,
          markAttachClass: 1,
        ),
        GlyphInfo(
          glyphId: gidBehFinal,
          codepoint: 0x0628,
          cluster: 2,
          glyphClass: GlyphClass.base,
        ),
      ]);
      b.positions.addAll([GlyphPosition(), GlyphPosition(), GlyphPosition()]);
      return b;
    }

    test('ignoreMarks makes the two letters adjacent', () {
      final it = SkippyIterator(
        buffer(),
        lookupFlag: LookupFlag.ignoreMarks,
        markFilteringSet: 0,
      );
      expect(it.next(0), 2);
      expect(it.prev(2), 0);
      expect(it.index, 0);
    });

    test('without the flag the mark is in the way', () {
      final it = SkippyIterator(buffer(), lookupFlag: 0, markFilteringSet: 0);
      expect(it.next(0), 1);
      expect(it.next(1), 2);
      expect(it.next(2), -1);
      expect(it.prev(0), -1);
    });

    test('ignoreBaseGlyphs leaves only the mark', () {
      final it = SkippyIterator(
        buffer(),
        lookupFlag: LookupFlag.ignoreBaseGlyphs,
        markFilteringSet: 0,
      );
      expect(it.next(-1), 1);
      expect(it.next(1), -1);
    });

    test('markAttachmentType filters marks by class, not bases', () {
      final matching = SkippyIterator(
        buffer(),
        lookupFlag: 1 << 8, // attachment class 1 — the shadda's
        markFilteringSet: 0,
      );
      expect(matching.next(0), 1);

      final other = SkippyIterator(
        buffer(),
        lookupFlag: 2 << 8,
        markFilteringSet: 0,
      );
      expect(other.next(0), 2, reason: 'the wrong-class mark must be skipped');
    });

    test('useMarkFilteringSet without a GDEF hides every mark', () {
      final it = SkippyIterator(
        buffer(),
        lookupFlag: LookupFlag.useMarkFilteringSet,
        markFilteringSet: 0,
      );
      expect(it.next(0), 2);
    });

    test('forward and backward walk sequence arrays', () {
      final it = SkippyIterator(buffer(), lookupFlag: 0, markFilteringSet: 0);
      expect(it.forward(-1, 3), [0, 1, 2]);
      expect(it.forward(0, 2), [1, 2]);
      expect(it.forward(0, 3), isNull, reason: 'the buffer runs out');
      expect(it.backward(2, 2), [1, 0]);
      expect(it.backward(1, 2), isNull);
      expect(it.forward(0, 0), isEmpty);
    });

    test('a failed walk leaves the cursor where it was', () {
      final it = SkippyIterator(buffer(), lookupFlag: 0, markFilteringSet: 0);
      it.index = 7;
      expect(it.forward(0, 3), isNull);
      expect(it.index, 7);
    });
  });
}

/// A reader over [words] as big-endian uint16s — the shape almost every
/// OpenType structure has, so a synthetic subtable is just its numbers.
ByteReader _reader(List<int> words) {
  final data = ByteData(words.length * 2);
  for (var i = 0; i < words.length; i++) {
    data.setUint16(i * 2, words[i]);
  }
  return ByteReader(data);
}

/// Every Coverage table reachable from a GSUB lookup whose subtables put one at
/// a fixed place (types 1–4 all do, at subtable + 2).
///
/// Walking the real LookupList rather than hand-picking one table is the point:
/// it is the only way to be sure both coverage formats are actually exercised.
List<Coverage> _gsubCoverages(SfntFile sfnt, LayoutTable gsub) {
  final reader = sfnt.requireTable(Tag.gsub);
  final out = <Coverage>[];
  for (final lookupOffset in gsub.lookupOffsets) {
    final type = reader.uint16At(lookupOffset);
    if (type < 1 || type > 4) continue;
    final count = reader.uint16At(lookupOffset + 4);
    for (var i = 0; i < count; i++) {
      final subtable = lookupOffset + reader.uint16At(lookupOffset + 6 + i * 2);
      final coverageOffset = reader.uint16At(subtable + 2);
      if (coverageOffset == 0) continue;
      out.add(Coverage.parse(reader.at(subtable + coverageOffset)));
    }
  }
  return out;
}

Matcher get throwsFontFormat => throwsA(isA<FontFormatException>());
