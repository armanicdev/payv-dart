/// Core SFNT tables, checked against the real Vazirmatn build in the repo.
///
/// Every expected number here was read out of that exact file, not out of the
/// spec — a test that asserts what the parser already believes proves nothing.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:payv/src/font/sfnt.dart';
import 'package:payv/src/font/tables/head.dart';
import 'package:payv/src/font/tables/hhea.dart';
import 'package:payv/src/font/tables/hmtx.dart';
import 'package:payv/src/font/tables/maxp.dart';
import 'package:payv/src/font/tables/name.dart';
import 'package:payv/src/font/tables/os2.dart';
import 'package:payv/src/font/tables/post.dart';
import 'package:payv/src/util/byte_reader.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

/// The face the whole project exists to render.
const vazirmatnPath = 'test/fonts/Vazirmatn.ttf';

void main() {
  late Uint8List bytes;
  late SfntFile sfnt;

  setUpAll(() {
    final file = File(vazirmatnPath);
    if (!file.existsSync()) {
      throw StateError(
        'Vazirmatn is missing at $vazirmatnPath — run these tests from '
        'packages/payv.',
      );
    }
    bytes = file.readAsBytesSync();
    sfnt = SfntFile.parse(bytes);
  });

  group('head', () {
    test('reads the fields the rest of the parse depends on', () {
      final head = HeadTable.parse(sfnt.requireTable(Tag.head));
      expect(head.unitsPerEm, 2048);
      expect(head.indexToLocFormat, 0, reason: 'Vazirmatn uses short loca');
      expect(head.flags, 3);
      expect(head.macStyle, 0);
      expect(head.isBold, isFalse);
      expect(head.isItalic, isFalse);
      expect(
        [head.xMin, head.yMin, head.xMax, head.yMax],
        [-1825, -1142, 4188, 2163],
      );
    });

    test('keeps fontRevision as its raw Fixed word', () {
      final head = HeadTable.parse(sfnt.requireTable(Tag.head));
      expect(head.fontRevision, 0x002100C5);
      // Derived from the raw word, not typed in. The previous expectation here
      // was `closeTo(33.005, 0.001)`, which was invented — the font actually
      // says 33.00300598144531 (fontTools agrees), so the test was red against
      // correct code. A Fixed 16.16 is exactly `raw / 65536`; asserting that
      // relationship cannot drift from the font the way a literal can.
      expect(head.fontRevisionValue, 0x002100C5 / 65536);
    });

    test('reads LONGDATETIME without a 64-bit int', () {
      final head = HeadTable.parse(sfnt.requireTable(Tag.head));
      // Any real font was made after 1904 and before now.
      expect(head.createdSeconds, greaterThan(0));
      expect(head.created.year, inInclusiveRange(1990, 2100));
    });

    test('rejects a head whose magic number is wrong', () {
      final corrupt = Uint8List.fromList(bytes);
      final at = sfnt.record(Tag.head)!.offset;
      corrupt[at + 12] = 0x00;
      expect(
        () => HeadTable.parse(SfntFile.parse(corrupt).requireTable(Tag.head)),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('rejects a unitsPerEm of zero rather than dividing by it', () {
      final corrupt = Uint8List.fromList(bytes);
      final at = sfnt.record(Tag.head)!.offset;
      corrupt[at + 18] = 0;
      corrupt[at + 19] = 0;
      expect(
        () => HeadTable.parse(SfntFile.parse(corrupt).requireTable(Tag.head)),
        throwsA(isA<FontFormatException>()),
      );
    });
  });

  group('maxp', () {
    test('reports the glyph count every other array is bounded by', () {
      final maxp = MaxpTable.parse(sfnt.requireTable(Tag.maxp));
      expect(maxp.numGlyphs, 1333);
      expect(maxp.version, 0x00010000);
      expect(maxp.isCffProfile, isFalse);
      expect(maxp.maxComponentDepth, greaterThan(0));
    });
  });

  group('hhea', () {
    test('reads line metrics and the hmtx split point', () {
      final hhea = HheaTable.parse(sfnt.requireTable(Tag.hhea));
      expect(hhea.ascender, 2100);
      expect(hhea.descender, -1100);
      expect(hhea.lineGap, 0);
      expect(hhea.numberOfHMetrics, 1333);
      expect(hhea.metricDataFormat, 0);
    });
  });

  group('hmtx', () {
    late HmtxTable hmtx;

    setUpAll(() {
      final hhea = HheaTable.parse(sfnt.requireTable(Tag.hhea));
      hmtx = HmtxTable.parse(
        sfnt.requireTable(Tag.hmtx),
        numberOfHMetrics: hhea.numberOfHMetrics,
        numGlyphs: 1333,
        tableLength: sfnt.record(Tag.hmtx)!.length,
      );
    });

    test('reads real advances for the Sorani letters', () {
      // gid 804 = uni0695 (ڕ), gid 895 = uni06D5 (ە).
      expect(hmtx.advanceWidth(804), 701);
      expect(hmtx.leftSideBearing(804), -12);
      expect(hmtx.advanceWidth(895), 954);
      expect(hmtx.leftSideBearing(895), 99);
      expect(hmtx.advanceWidth(3), 1158);
    });

    test('returns 0 outside the glyph range instead of reading on', () {
      expect(hmtx.advanceWidth(-1), 0);
      expect(hmtx.advanceWidth(1333), 0);
      expect(hmtx.leftSideBearing(99999), 0);
    });

    test('repeats the last advance past numberOfHMetrics', () {
      // Vazirmatn ships a metric pair per glyph, so the repeat rule is
      // exercised on a synthetic table instead: 2 pairs, 4 glyphs.
      final synthetic = Uint8List.fromList([
        0x01, 0x00, 0x00, 0x0A, // gid 0: advance 256, lsb 10
        0x02, 0x00, 0x00, 0x14, // gid 1: advance 512, lsb 20
        0x00, 0x1E, // gid 2: lsb 30
        0xFF, 0xF6, // gid 3: lsb -10
      ]);
      final t = HmtxTable.parse(
        ByteReader.fromBytes(synthetic),
        numberOfHMetrics: 2,
        numGlyphs: 4,
      );
      expect(t.advanceWidth(0), 256);
      expect(t.advanceWidth(1), 512);
      expect(t.advanceWidth(2), 512, reason: 'repeats the LAST advance');
      expect(t.advanceWidth(3), 512);
      // Sidebearings do NOT repeat — each glyph has its own.
      expect(t.leftSideBearing(2), 30);
      expect(t.leftSideBearing(3), -10);
    });

    test('tolerates a truncated trailing sidebearing array', () {
      final truncated = Uint8List.fromList([0x01, 0x00, 0x00, 0x0A]);
      final t = HmtxTable.parse(
        ByteReader.fromBytes(truncated),
        numberOfHMetrics: 1,
        numGlyphs: 3,
        tableLength: 4,
      );
      expect(t.advanceWidth(2), 256);
      expect(t.leftSideBearing(2), 0);
    });

    test('rejects a numberOfHMetrics of zero', () {
      expect(
        () => HmtxTable.parse(
          ByteReader.fromBytes(Uint8List(8)),
          numberOfHMetrics: 0,
          numGlyphs: 2,
        ),
        throwsA(isA<FontFormatException>()),
      );
    });
  });

  group('name', () {
    late NameTable name;

    setUpAll(() => name = NameTable.parse(sfnt.requireTable(Tag.name)));

    test('decodes UTF-16BE Windows records', () {
      expect(name.familyName, contains('Vazirmatn'));
      expect(name.subfamilyName, 'Regular');
      expect(name.postScriptName, 'Vazirmatn-Regular');
    });

    test('falls back from nameId 16/17 to 1/2', () {
      // This build ships no typographic family names, so the fallback is the
      // only reason familyName resolves at all.
      expect(name.get(16), isNull);
      expect(name.get(17), isNull);
      expect(name.get(1), 'Vazirmatn');
      expect(name.get(2), 'Regular');
    });

    test('surfaces the licence an embedding PDF has to honour', () {
      expect(name.licenseDescription, contains('SIL Open Font License'));
      expect(name.licenseUrl, 'https://scripts.sil.org/OFL');
    });

    test('can be pinned to one platform', () {
      expect(name.get(6, platformId: 3), 'Vazirmatn-Regular');
      expect(name.get(6, platformId: 1), isNull);
      expect(name.records, isNotEmpty);
      expect(name.records.every((r) => r.value.isNotEmpty), isTrue);
    });
  });

  group('OS/2', () {
    late Os2Table os2;

    setUpAll(() => os2 = Os2Table.parse(sfnt.requireTable(Tag.os2)));

    test('reads the descriptor metrics', () {
      expect(os2.version, 4);
      expect(os2.usWeightClass, 400);
      expect(os2.usWidthClass, 5);
      expect(os2.sTypoAscender, 2100);
      expect(os2.sTypoDescender, -1100);
      expect(os2.sTypoLineGap, 0);
      expect(os2.usWinAscent, 2200);
      expect(os2.usWinDescent, 1300);
      expect(os2.sCapHeight, 1638);
      expect(os2.sxHeight, 1082);
      expect(os2.panose, hasLength(10));
    });

    test('reads fsSelection flags', () {
      expect(os2.fsSelection, 192);
      expect(os2.isRegular, isTrue, reason: 'bit 6');
      expect(os2.useTypoMetrics, isTrue, reason: 'bit 7');
      expect(os2.isBold, isFalse);
      expect(os2.isItalic, isFalse);
    });

    test('an fsType of 0 permits both embedding and subsetting', () {
      expect(os2.fsType, 0);
      expect(os2.allowsEmbedding, isTrue);
      expect(os2.allowsSubsetting, isTrue);
    });

    test('honours the licence bits by their spec numbers', () {
      Os2Table withFsType(int fsType) {
        final copy = Uint8List.fromList(bytes);
        final at = sfnt.record(Tag.os2)!.offset;
        copy[at + 8] = (fsType >> 8) & 0xFF;
        copy[at + 9] = fsType & 0xFF;
        return Os2Table.parse(SfntFile.parse(copy).requireTable(Tag.os2));
      }

      // 0x0002 restricted — the only value that forbids embedding outright.
      expect(withFsType(0x0002).allowsEmbedding, isFalse);
      expect(withFsType(0x0002).allowsSubsetting, isFalse);
      // 0x0004 preview-and-print and 0x0008 editable both permit embedding.
      expect(withFsType(0x0004).allowsEmbedding, isTrue);
      expect(withFsType(0x0008).allowsEmbedding, isTrue);
      // 0x0100 is NO SUBSETTING — not 0x0200. Swapping the two is the bug
      // this case exists to catch.
      expect(withFsType(0x0100).allowsEmbedding, isTrue);
      expect(withFsType(0x0100).allowsSubsetting, isFalse);
      // 0x0200 is bitmap-embedding-only, which payv cannot satisfy.
      expect(withFsType(0x0200).allowsEmbedding, isFalse);
    });
  });

  group('post', () {
    late PostTable post;

    setUpAll(() => post = PostTable.parse(sfnt.requireTable(Tag.post)));

    test('reads the PostScript descriptor fields', () {
      expect(post.version, 0x00020000);
      expect(post.italicAngle, 0.0);
      expect(post.underlinePosition, -730);
      expect(post.underlineThickness, 100);
      expect(post.isFixedPitch, isFalse);
      expect(post.hasGlyphNames, isTrue);
    });

    test('names the GSUB-only Sorani glyphs no codepoint can reach', () {
      // The three glyphs that are the entire reason this package exists.
      expect(post.glyphName(474), 'lamVabove_alef.isol');
      expect(post.glyphName(839), 'uni06B5.init');
      expect(post.glyphName(896), 'uni06D5.fina');
    });

    test('resolves a standard Macintosh index rather than a custom name', () {
      // gid 2 stores index 36, which is 'A' in the standard order — proof the
      // 258-name table is wired in, not just the Pascal strings.
      expect(post.glyphName(2), 'A');
      expect(post.glyphName(0), '.notdef');
      expect(PostTable.standardMacGlyphNames, hasLength(258));
      expect(PostTable.standardMacGlyphNames[36], 'A');
      expect(PostTable.standardMacGlyphNames.last, 'dcroat');
    });

    test('returns null past the end instead of throwing', () {
      expect(post.glyphName(1333), isNull);
      expect(post.glyphName(-1), isNull);
    });
  });
}
