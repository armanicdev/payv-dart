// The FACADE has to pass the directory's record length. This file is the pin.
//
// `SfntFile.table()` returns a reader over the whole file positioned at the
// table — deliberately, because an OpenType offset may point backwards into a
// parent and slicing per table would break real fonts. The consequence is that
// a parser's own `canRead` asks "does the FILE have room", and for any table
// that is not the last one the answer is always yes. A version word is then
// believed over the body it sits on, and the tail decodes out of the NEXT table.
//
// `Os2Table`, `PostTable` and `MaxpTable` each take a `tableLength` to close
// that. Taking it is not the same as being given it: `os2_test.dart` proved the
// parameter worked while `OpenTypeFont.os2` was still calling without it, and
// the fabricated `usLowerOpticalPointSize` reached the PDF descriptor anyway.
// So every test here goes through [OpenTypeFont], not through `parse`.
//
// Each case is paired: the bounded call through the facade, and the unbounded
// call kept beside it as the REPRODUCTION. If a future change stops passing the
// length, the bounded expectation becomes the unbounded one and these fail.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:payv/src/font/open_type_font.dart';
import 'package:payv/src/font/sfnt.dart';
import 'package:payv/src/font/tables/maxp.dart';
import 'package:payv/src/font/tables/os2.dart';
import 'package:payv/src/font/tables/post.dart';
import 'package:payv/src/util/byte_reader.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

final String fontPath =
    Platform.environment['PAYV_TEST_FONT'] ?? 'test/fonts/Vazirmatn.ttf';

void main() {
  late Uint8List bytes;
  late SfntFile sfnt;

  setUpAll(() {
    bytes = File(fontPath).readAsBytesSync();
    sfnt = SfntFile.parse(bytes);
  });

  /// A copy of the font with [tag]'s directory record rewritten — its declared
  /// length, its version word, or both.
  ///
  /// Rewriting the DIRECTORY rather than a local reader is what makes these
  /// tests reach the facade: `OpenTypeFont` reads the record itself, so this is
  /// the only way to hand it a length it did not compute.
  Uint8List forge(int tag, {int? declaredLength, int? versionU16}) {
    final copy = Uint8List.fromList(bytes);
    final view = ByteData.view(copy.buffer);
    final rec = sfnt.record(tag)!;
    if (versionU16 != null) view.setUint16(rec.offset, versionU16);
    if (declaredLength != null) {
      final numTables = view.getUint16(4);
      for (var i = 0; i < numTables; i++) {
        final slot = 12 + i * 16;
        if (view.getUint32(slot) == tag) {
          view.setUint32(slot + 12, declaredLength);
        }
      }
    }
    return copy;
  }

  group('OS/2 — the tail that reaches the PDF font descriptor', () {
    test('a version word past the body reads zeros, not the next table', () {
      // Vazirmatn: a version 4 header over 96 bytes. Claiming version 5 asks for
      // an optical-size tail the body does not have.
      final font = OpenTypeFont.parse(forge(Tag.os2, versionU16: 5));
      final os2 = font.os2!;
      expect(os2.version, 5);
      expect(os2.usLowerOpticalPointSize, 0);
      expect(os2.usUpperOpticalPointSize, 0);
      // The v2 metrics the body DOES hold are still read — the bound truncates
      // the fabrication, it does not blind the parser.
      expect(os2.sCapHeight, 1638);
      expect(os2.sxHeight, 1082);
    });

    test('and unbounded it fabricates 908 out of the following table', () {
      final rec = sfnt.record(Tag.os2)!;
      expect(
        rec.length,
        96,
        reason: 'the fixture these numbers were read from',
      );
      // No `tableLength` — what the facade used to do.
      final table = Os2Table.parse(
        SfntFile.parse(forge(Tag.os2, versionU16: 5)).requireTable(Tag.os2),
      );
      expect(
        table.usLowerOpticalPointSize,
        908,
        reason: 'these bytes belong to the table after OS/2',
      );
    });
  });

  group('maxp — the outline limits a subsetter sizes its buffers from', () {
    test('a 6-byte body keeps numGlyphs and zeroes the v1 tail', () {
      // The CFF half-version shape: numGlyphs and nothing else. A 1.0 version
      // word over it must not conjure the twelve limits that follow.
      final font = OpenTypeFont.parse(forge(Tag.maxp, declaredLength: 6));
      final maxp = font.maxp!;
      expect(maxp.version, 0x00010000);
      expect(maxp.numGlyphs, 1333, reason: 'offset 4 is inside the 6 bytes');
      expect(maxp.maxPoints, 0);
      expect(maxp.maxContours, 0);
      expect(maxp.maxComponentDepth, 0);
    });

    test('and unbounded it reads the real limits it was not given', () {
      final unbounded = MaxpTable.parse(sfnt.requireTable(Tag.maxp));
      expect(unbounded.maxPoints, 336);
      expect(unbounded.maxContours, 21);
    });

    test('the intact font still reports its real limits', () {
      final maxp = OpenTypeFont.parse(bytes).maxp!;
      expect(maxp.numGlyphs, 1333);
      expect(maxp.maxPoints, 336);
      expect(maxp.maxContours, 21);
      expect(maxp.maxComponentDepth, 1);
    });
  });

  group('post — glyph names, which a corrupt length turns into other tables', () {
    test('the fixture is a real 2.0 table with names', () {
      final post = OpenTypeFont.parse(bytes).post!;
      expect(post.version, 0x00020000);
      expect(post.glyphNameIndex, hasLength(1333));
      expect(post.customNames, hasLength(1080));
    });

    test('a length that stops after the index yields no names', () {
      // 34 bytes of header + count, then 1333 two-byte indices = 2700. The
      // string run starts exactly at the declared end, so there are no names to
      // read — and crucially the parser must not walk on into `loca`.
      final font = OpenTypeFont.parse(
        forge(Tag.post, declaredLength: 34 + 1333 * 2),
      );
      final post = font.post!;
      expect(post.glyphNameIndex, hasLength(1333));
      expect(post.customNames, isEmpty);
    });

    test('and unbounded the same record reads all 1080 anyway', () {
      final unbounded = PostTable.parse(sfnt.requireTable(Tag.post));
      expect(unbounded.customNames, hasLength(1080));
    });

    test('a 2.0 version word with no room for the count is rejected', () {
      expect(
        () => OpenTypeFont.parse(forge(Tag.post, declaredLength: 32)).post,
        throwsA(isA<FontFormatException>()),
      );
    });
  });
}
