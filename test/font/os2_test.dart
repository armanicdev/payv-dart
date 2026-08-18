// `OS/2` — the version tail, and why the guard has to know the table's length.
//
// Everything here runs against the real Vazirmatn `OS/2`, with one field
// deliberately corrupted. A synthetic table would not reproduce the defect this
// file pins: the whole point is that the bytes AFTER the table are a real
// neighbouring table, so a runaway read returns plausible numbers instead of
// throwing.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:payv/src/font/sfnt.dart';
import 'package:payv/src/font/tables/os2.dart';
import 'package:payv/src/util/byte_reader.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

final String fontPath =
    Platform.environment['PAYV_TEST_FONT'] ?? 'test/fonts/Vazirmatn.ttf';

void main() {
  late Uint8List bytes;
  late SfntFile sfnt;
  late TableRecord record;

  setUpAll(() {
    bytes = File(fontPath).readAsBytesSync();
    sfnt = SfntFile.parse(bytes);
    record = sfnt.record(Tag.os2)!;
  });

  /// The font with `OS/2`'s version word overwritten, parsed both ways.
  Os2Table parseWithVersion(int version, {required bool bounded}) {
    final copy = Uint8List.fromList(bytes);
    copy[record.offset] = (version >> 8) & 0xFF;
    copy[record.offset + 1] = version & 0xFF;
    final reader = ByteReader.fromBytes(copy, record.offset);
    return Os2Table.parse(reader, tableLength: bounded ? record.length : null);
  }

  test('the fixture is the table these expectations were pinned against', () {
    // Vazirmatn ships a version 4 header over a 96-byte body: it has the v2
    // metrics and does not have the v5 optical-size fields.
    final os2 = Os2Table.parse(
      sfnt.requireTable(Tag.os2),
      tableLength: record.length,
    );
    expect(os2.version, 4);
    expect(record.length, 96);
    expect(os2.sCapHeight, isNot(0));
    expect(os2.sxHeight, isNot(0));
    expect(os2.usLowerOpticalPointSize, 0);
  });

  test('a version word past the body does not read the next table', () {
    final bounded = parseWithVersion(5, bounded: true);
    expect(bounded.version, 5);
    // 96 bytes of body cannot hold the v5 tail, so both fields stay at the
    // "unknown" value the PDF descriptor understands.
    expect(bounded.usLowerOpticalPointSize, 0);
    expect(bounded.usUpperOpticalPointSize, 0);
    // The v2 metrics the body really does hold are still read.
    expect(bounded.sCapHeight, isNot(0));
  });

  test('bounding against the file instead is the defect, and it is real', () {
    // The unbounded call is what `parse` did before it took a length, and it is
    // kept here as the reproduction rather than as supported behaviour: `OS/2`
    // is never the last table, so `canRead` against the file always says yes.
    final unbounded = parseWithVersion(5, bounded: false);
    expect(
      unbounded.usLowerOpticalPointSize,
      908,
      reason: 'these bytes belong to the table that follows OS/2',
    );
    expect(unbounded.usUpperOpticalPointSize, isNot(0));
  });

  test('a v2 header over a v1 body fabricates neither metric', () {
    // The case the code comment names: real fonts ship a version number their
    // body does not earn. Truncating to 86 bytes is that font.
    final reader = ByteReader.fromBytes(
      Uint8List.sublistView(bytes, record.offset, record.offset + 86),
    );
    final os2 = Os2Table.parse(reader, tableLength: 86);
    expect(os2.version, 4);
    expect(os2.ulCodePageRange1, isNot(0), reason: 'the v1 tail is present');
    expect(os2.sCapHeight, 0, reason: '/CapHeight must say "unknown"');
    expect(os2.sxHeight, 0);
  });

  test('a body shorter than version 0 is rejected outright', () {
    final reader = ByteReader.fromBytes(
      Uint8List.sublistView(bytes, record.offset, record.offset + 96),
    );
    expect(
      () => Os2Table.parse(reader, tableLength: 40),
      throwsA(isA<FontFormatException>()),
    );
  });

  test('a declared length longer than the file is clamped, not trusted', () {
    // A corrupt directory record must not become a licence to read heap.
    final reader = ByteReader.fromBytes(
      Uint8List.sublistView(bytes, record.offset, record.offset + 96),
    );
    final os2 = Os2Table.parse(reader, tableLength: 1 << 20);
    expect(os2.version, 4);
    expect(os2.usLowerOpticalPointSize, 0);
  });

  test('the embedding licence bits are read as a bitfield', () {
    final os2 = Os2Table.parse(
      sfnt.requireTable(Tag.os2),
      tableLength: record.length,
    );
    expect(os2.allowsEmbedding, isTrue, reason: 'Vazirmatn is OFL');
    expect(os2.allowsSubsetting, isTrue);
  });
}
