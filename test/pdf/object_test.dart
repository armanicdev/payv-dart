// Two defects in the object model that both end as a corrupt file rather than
// as an error: a number the web serialises differently from the VM, and a
// stream whose declared filter was thrown away and replaced.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:payv/src/pdf/object.dart';
import 'package:payv/src/pdf/writer.dart';
import 'package:test/test.dart';

/// Four bytes that begin a JPEG. Nothing here decodes them — they stand in for
/// a payload that is already compressed and must not be compressed again.
final Uint8List _jpeg = Uint8List.fromList(<int>[
  0xFF, 0xD8, 0xFF, 0xE0, //
  ...List<int>.filled(2000, 0x5A),
]);

void main() {
  group('pdfFormatNumber', () {
    // The web half of this is not testable from the VM: `value is int` being
    // true for an integral double is a dart2js/dart2wasm fact, and reproducing
    // it needs a real compile. `tool/web_number_parity.dart` does that and is
    // the proof of record; these pin the VM side of the same values so a
    // regression shows up in `dart test` too.
    test('an integral double is a plain integer, both zeros included', () {
      expect(pdfFormatNumber(12.0), '12');
      expect(pdfFormatNumber(-0.0), '0');
      expect(pdfFormatNumber(-(0.0 * 1.0)), '0');
      expect(pdfFormatNumber(0.0), '0');
      expect(pdfFormatNumber(0), '0');
    });

    test('a magnitude past 2^53 stays plain decimal, never an exponent', () {
      // `(1e21).toString()` is "1e+21", which PDF has no syntax for at all —
      // readers report it as a corrupt page rather than as a bad number.
      expect(pdfFormatNumber(1e21), '1000000000000000000000');
      expect(pdfFormatNumber(-1e21), '-1000000000000000000000');
      expect(pdfFormatNumber(1e300), isNot(contains('e')));
      expect(pdfFormatNumber(1e300).length, 301);
      expect(pdfFormatNumber(9007199254740992.0), '9007199254740992');
    });

    test('a real int keeps its exact value past 2^53', () {
      // The reason the int branch survives at all: on the VM an int above 2^53
      // cannot round-trip through a double, so it must not be routed there.
      expect(pdfFormatNumber(9007199254740993), '9007199254740993');
      expect(pdfFormatNumber(-9007199254740993), '-9007199254740993');
    });

    test('small magnitudes round to zero rather than to an exponent', () {
      expect(pdfFormatNumber(1e-9), '0');
      expect(pdfFormatNumber(-1e-9), '0');
      expect(pdfFormatNumber(0.0000001), '0');
    });
  });

  group('PdfStream — a declared /Filter', () {
    test('is adopted rather than dropped', () {
      final stream = PdfStream(
        PdfDict(<String, PdfObject>{'Filter': const PdfName('DCTDecode')}),
        _jpeg,
      );
      expect(stream.filters, <String>['DCTDecode']);
      expect(stream.toString(), contains('/Filter /DCTDecode'));
    });

    test('is adopted from an array, in order', () {
      final stream = PdfStream(
        PdfDict(<String, PdfObject>{
          'Filter': PdfArray.names(<String>['ASCII85Decode', 'FlateDecode']),
        }),
        _jpeg,
      );
      expect(stream.filters, <String>['ASCII85Decode', 'FlateDecode']);
      expect(
        stream.toString(),
        contains('/Filter [/ASCII85Decode /FlateDecode]'),
      );
    });

    test('stops the writer re-filtering an already-compressed payload', () {
      // The defect, end to end. `_deflateStream` consults only `filters`, so a
      // dropped `/Filter` left it looking at an unfiltered stream: the JPEG was
      // deflated and declared `/FlateDecode`, and a reader then handed raw JPEG
      // bytes to an XObject declared as uncompressed samples. Corrupt image, no
      // error anywhere.
      final writer = PdfWriter();
      final stream = PdfStream(
        PdfDict(<String, PdfObject>{
          'Type': const PdfName('XObject'),
          'Subtype': const PdfName('Image'),
          'Filter': const PdfName('DCTDecode'),
        }),
        _jpeg,
      );
      final catalog = writer.add(
        PdfDict(<String, PdfObject>{'Type': const PdfName('Catalog')}),
      );
      writer.add(stream);
      final text = latin1.decode(writer.build(catalog: catalog));

      expect(text, contains('/Filter /DCTDecode'));
      expect(text, isNot(contains('FlateDecode')));
      expect(stream.bytes.length, _jpeg.length, reason: 'bytes untouched');
    });

    test('an explicit list still wins over the dictionary', () {
      final stream = PdfStream(
        PdfDict(<String, PdfObject>{'Filter': const PdfName('DCTDecode')}),
        _jpeg,
        filters: <String>['ASCII85Decode'],
      );
      expect(stream.filters, <String>['ASCII85Decode']);
    });

    test('an explicitly empty list means no filters, and is not seeded', () {
      // Otherwise a caller could not say "ignore what the dictionary claims".
      final stream = PdfStream(
        PdfDict(<String, PdfObject>{'Filter': const PdfName('DCTDecode')}),
        Uint8List.fromList(<int>[1, 2, 3]),
        filters: const <String>[],
      );
      expect(stream.filters, isEmpty);
      expect(stream.toString(), isNot(contains('/Filter')));
    });

    test('a stream with no declared filter is unaffected', () {
      final stream = PdfStream(
        PdfDict(<String, PdfObject>{'Type': const PdfName('XObject')}),
        Uint8List.fromList(<int>[1, 2, 3]),
      );
      expect(stream.filters, isEmpty);
      expect(stream.toString(), contains('/Length 3'));
    });
  });
}
