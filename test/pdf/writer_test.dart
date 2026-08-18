/// Structural tests for the PDF writer.
///
/// A PDF that "opens in Preview" proves very little — readers reconstruct a
/// broken cross-reference table rather than complain. So this file parses the
/// bytes the way a strict reader would: it follows `startxref` to the table,
/// reads each 20-byte entry, and jumps to the offset to check the object it
/// claims is there really is.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:payv/src/pdf/content_stream.dart';
import 'package:payv/src/pdf/document.dart';
import 'package:payv/src/pdf/object.dart';
import 'package:payv/src/pdf/writer.dart';
import 'package:test/test.dart';

String _ascii(Uint8List bytes) => latin1.decode(bytes);

/// The `startxref` value at the end of a file.
int _startXref(Uint8List bytes) {
  final text = _ascii(bytes);
  final marker = text.lastIndexOf('startxref');
  expect(marker, isNot(-1), reason: 'no startxref keyword');
  final tail = text.substring(marker + 'startxref'.length);
  final digits = RegExp(r'\d+').firstMatch(tail);
  expect(digits, isNotNull, reason: 'startxref has no offset after it');
  return int.parse(digits!.group(0)!);
}

/// Parses the classic cross-reference table at [offset], returning the byte
/// offset recorded for each object number.
Map<int, int> _readXrefTable(Uint8List bytes, int offset) {
  final text = _ascii(bytes);
  expect(
    text.substring(offset, offset + 4),
    'xref',
    reason: 'startxref does not point at the xref keyword',
  );

  var cursor = offset + 4;
  while (text.codeUnitAt(cursor) == 0x0A || text.codeUnitAt(cursor) == 0x0D) {
    cursor++;
  }
  final header = RegExp(r'^(\d+) (\d+)').firstMatch(text.substring(cursor));
  expect(header, isNotNull, reason: 'malformed subsection header');
  final first = int.parse(header!.group(1)!);
  final count = int.parse(header.group(2)!);
  expect(first, 0, reason: 'the table must start at object 0');

  cursor += header.group(0)!.length;
  while (text.codeUnitAt(cursor) == 0x0A || text.codeUnitAt(cursor) == 0x0D) {
    cursor++;
  }

  final offsets = <int, int>{};
  for (var i = 0; i < count; i++) {
    final entry = text.substring(cursor, cursor + 20);
    expect(
      entry.length,
      20,
      reason:
          'entry $i is not 20 bytes — readers index this table by '
          'multiplication, so a short entry corrupts everything after it',
    );
    expect(
      RegExp(r'^\d{10} \d{5} [nf] [\r\n]$').hasMatch(entry),
      isTrue,
      reason: 'entry $i is malformed: "$entry"',
    );
    if (i == 0) {
      expect(entry.substring(0, 16), '0000000000 65535');
      expect(entry[17], 'f', reason: 'entry 0 must be the free-list head');
    } else {
      expect(entry[17], 'n');
      offsets[first + i] = int.parse(entry.substring(0, 10));
    }
    cursor += 20;
  }
  return offsets;
}

PdfDocument _sampleDocument({bool compress = true}) {
  final doc = PdfDocument(compress: compress);
  doc.lang = 'ckb';
  doc.setMetadata(
    title: 'وەسڵی کارەبا',
    author: 'payv',
    producer: 'payv test',
    created: DateTime.utc(2026, 8, 18, 9, 30),
  );

  final page = doc.addPage();
  final content = page.content;

  content.save();
  content.setFillColor(const PdfColor.rgb(0.1, 0.2, 0.3));
  content.rect(72, 600, 200, 120);
  content.fill();
  content.setStrokeColor(PdfColor.black);
  content.setLineWidth(1.5);
  content.moveTo(72, 560);
  content.lineTo(472, 560);
  content.stroke();
  content.restore();

  // Raw text ops, the way the font subsystem will drive them.
  final fontRef = doc.writer.add(
    PdfDict(<String, PdfObject>{
      'Type': const PdfName('Font'),
      'Subtype': const PdfName('Type1'),
      'BaseFont': const PdfName('Helvetica'),
    }),
  );
  final name = doc.addResource(page, 'Font', fontRef);

  content.beginText();
  content.setFontRaw(name, 12);
  content.setTextMatrix(1, 0, 0, 1, 72, 500);
  content.showTextRaw(Uint8List.fromList(latin1.encode('PAYV')));
  content.showTextAdjustedRaw(<Object>[
    Uint8List.fromList(latin1.encode('AV')),
    -120,
    Uint8List.fromList(latin1.encode('A')),
  ]);
  content.endText();

  return doc;
}

void main() {
  group('file structure', () {
    late Uint8List bytes;

    setUp(() => bytes = _sampleDocument().save());

    test('starts with the 1.7 header and a binary sniff comment', () {
      expect(_ascii(bytes).startsWith('%PDF-1.7\n'), isTrue);
      final comment = bytes.sublist(9, 15);
      expect(comment[0], 0x25, reason: 'the sniff line must be a comment');
      for (var i = 1; i < 5; i++) {
        expect(
          comment[i],
          greaterThanOrEqualTo(0x80),
          reason:
              'byte $i of the sniff comment must be >= 0x80 or a '
              'text-mode transfer will rewrite the file',
        );
      }
      expect(comment[5], 0x0A);
    });

    test('ends with %%EOF', () {
      expect(_ascii(bytes).trimRight().endsWith('%%EOF'), isTrue);
    });

    test('startxref points at the xref keyword', () {
      final offset = _startXref(bytes);
      expect(offset, greaterThan(0));
      expect(offset, lessThan(bytes.length));
      expect(_ascii(bytes).substring(offset, offset + 4), 'xref');
    });

    test('every xref offset lands on the object it claims', () {
      final offsets = _readXrefTable(bytes, _startXref(bytes));
      final text = _ascii(bytes);
      expect(offsets, isNotEmpty);
      for (final entry in offsets.entries) {
        expect(
          text.startsWith('${entry.key} 0 obj', entry.value),
          isTrue,
          reason: 'object ${entry.key} is not at offset ${entry.value}',
        );
      }
    });

    test('object numbering is contiguous from 1', () {
      final offsets = _readXrefTable(bytes, _startXref(bytes));
      final numbers = offsets.keys.toList()..sort();
      expect(numbers.first, 1);
      for (var i = 0; i < numbers.length; i++) {
        expect(numbers[i], i + 1);
      }
      // /Size counts the free entry too.
      expect(
        RegExp(r'/Size (\d+)').firstMatch(_ascii(bytes))!.group(1),
        '${numbers.length + 1}',
      );
    });

    test('the trailer names a catalog that really is one', () {
      final text = _ascii(bytes);
      final root = RegExp(r'/Root (\d+) 0 R').firstMatch(text);
      expect(root, isNotNull);
      final offsets = _readXrefTable(bytes, _startXref(bytes));
      final at = offsets[int.parse(root!.group(1)!)]!;
      final window = text.substring(at, math.min(at + 160, text.length));
      expect(window, contains('/Type /Catalog'));
    });

    test('/Info is indirect, as Table 15 requires', () {
      final text = _ascii(bytes);
      expect(RegExp(r'/Info \d+ 0 R').hasMatch(text), isTrue);
    });

    test('/ID is present and the two halves match on a first write', () {
      final id = RegExp(
        r'/ID \[<([0-9A-F]+)> <([0-9A-F]+)>\]',
      ).firstMatch(_ascii(bytes));
      expect(id, isNotNull);
      expect(id!.group(1), id.group(2));
      expect(id.group(1)!.length, 32, reason: '16 bytes, hex');
    });

    test('the document language reaches the catalog', () {
      expect(_ascii(bytes), contains('/Lang (ckb)'));
    });

    test('a non-ASCII title is UTF-16BE behind a BOM', () {
      // "وەسڵی کارەبا" cannot survive PDFDocEncoding; the BOM is what tells a
      // reader not to try.
      expect(_ascii(bytes), contains(r'/Title (\376\377'));
    });
  });

  group('determinism', () {
    test('two builds of the same document are byte-identical', () {
      expect(_sampleDocument().save(), equals(_sampleDocument().save()));
    });

    test('a different document gets a different /ID', () {
      final a = _sampleDocument().save();
      final other = _sampleDocument();
      other.pages.first.content.rect(0, 0, 1, 1);
      other.pages.first.content.fill();
      final b = other.save();
      expect(_ascii(a), isNot(_ascii(b)));
    });

    test('save() is idempotent', () {
      final doc = _sampleDocument();
      expect(identical(doc.save(), doc.save()), isTrue);
    });
  });

  group('streams', () {
    test('a compressed content stream declares FlateDecode and inflates', () {
      final doc = PdfDocument();
      final page = doc.addPage();
      for (var i = 0; i < 300; i++) {
        page.content.rect(10, i.toDouble(), 100, 8);
        page.content.fill();
      }
      final bytes = doc.save();
      final text = _ascii(bytes);
      expect(text, contains('/Filter /FlateDecode'));

      final start = text.indexOf('stream\n') + 'stream\n'.length;
      final end = text.indexOf('\nendstream', start);
      final inflated = _ascii(
        Uint8List.fromList(ZLibDecoder().convert(bytes.sublist(start, end))),
      );
      expect(inflated, contains('re'));
      expect(inflated, contains('f\n'));
    });

    test('compression can be turned off', () {
      final doc = PdfDocument(compress: false);
      final page = doc.addPage();
      for (var i = 0; i < 300; i++) {
        page.content.rect(10, i.toDouble(), 100, 8);
        page.content.fill();
      }
      expect(_ascii(doc.save()), isNot(contains('/FlateDecode')));
    });

    test('/Length matches the bytes actually written', () {
      final text = _ascii(_sampleDocument(compress: false).save());
      for (final match in RegExp(
        r'/Length (\d+)>>\nstream\n',
      ).allMatches(text)) {
        final declared = int.parse(match.group(1)!);
        final start = match.end;
        final end = text.indexOf('\nendstream', start);
        expect(end - start, declared);
      }
    });
  });

  group('resources', () {
    test('the same object registers once and keeps its name', () {
      final doc = PdfDocument();
      final page = doc.addPage();
      final a = doc.writer.add(const PdfName('A'));
      final b = doc.writer.add(const PdfName('B'));
      expect(doc.addResource(page, 'Font', a), 'F1');
      expect(doc.addResource(page, 'Font', a), 'F1');
      expect(doc.addResource(page, 'Font', b), 'F2');
      expect(doc.addResource(page, 'XObject', a), 'X1');
      expect(page.resources.subDict('Font').keys, <String>['F1', 'F2']);
    });
  });

  group('writer invariants', () {
    test('a reserved but unfilled object is a build error', () {
      final writer = PdfWriter();
      final catalog = writer.add(PdfDict());
      writer.reserve();
      expect(() => writer.build(catalog: catalog), throwsStateError);
    });

    test('building twice throws instead of duplicating /Info', () {
      final writer = PdfWriter();
      final catalog = writer.add(PdfDict());
      writer.build(catalog: catalog);
      expect(() => writer.build(catalog: catalog), throwsStateError);
    });

    test('filling an unknown reference throws', () {
      final writer = PdfWriter();
      expect(
        () => writer.fill(const PdfRef(9), PdfDict()),
        throwsArgumentError,
      );
    });

    test(
      'a document with no pages throws rather than writing a broken file',
      () {
        expect(() => PdfDocument().save(), throwsStateError);
      },
    );
  });

  group('content stream balance', () {
    test('an unbalanced save() is caught at build', () {
      final content = ContentStream()..save();
      expect(content.build, throwsStateError);
    });

    test('an unclosed text object is caught at build', () {
      final content = ContentStream()..beginText();
      expect(content.build, throwsStateError);
    });

    test('an unclosed marked-content sequence is caught at build', () {
      final content = ContentStream()..beginMarkedContent('Span');
      expect(content.build, throwsStateError);
    });

    test('restore() without save() throws where the mistake is', () {
      expect(ContentStream().restore, throwsStateError);
    });

    test('showing text outside BT/ET throws', () {
      expect(() => ContentStream().showTextRaw(Uint8List(2)), throwsStateError);
    });
  });

  group('redundant operator suppression', () {
    test('an unchanged colour and font are emitted once', () {
      final content = ContentStream();
      content.beginText();
      for (var i = 0; i < 50; i++) {
        content.setFillColor(PdfColor.black);
        content.setFontRaw('F1', 12);
        content.showTextRaw(Uint8List.fromList(<int>[65]));
      }
      content.endText();
      final text = latin1.decode(content.build());
      expect('rg'.allMatches(text).length + 'g\n'.allMatches(text).length, 1);
      expect('Tf'.allMatches(text).length, 1);
      expect('Tj'.allMatches(text).length, 50);
    });

    test('Q restores the suppression state, so the next set re-emits', () {
      final content = ContentStream();
      content.setFillColor(PdfColor.black);
      content.save();
      content.setFillColor(PdfColor.white);
      content.restore();
      // After Q the reader's fill colour is black again. If the tracker had
      // kept "white", this call would be suppressed and the rectangle would
      // come out the wrong colour — the exact bug the saved copy prevents.
      content.setFillColor(PdfColor.white);
      final text = latin1.decode(content.build());
      expect('1 g'.allMatches(text).length, 2);
    });
  });

  group('number syntax', () {
    test('never emits exponent notation', () {
      final content = ContentStream()
        ..moveTo(0.0000001, 1e21)
        ..lineTo(-0.0, 1234567.891)
        ..closePath();
      final text = latin1.decode(content.build());
      expect(text, isNot(contains('e')));
      expect(text, isNot(contains('E')));
      expect(text, isNot(contains('-0 ')));
    });

    test('formats integers, negative zero and rounding as PDF wants', () {
      expect(pdfFormatNumber(12), '12');
      expect(pdfFormatNumber(12.0), '12');
      expect(pdfFormatNumber(-0.0), '0');
      expect(pdfFormatNumber(0.5), '0.5');
      expect(pdfFormatNumber(1 / 3), '0.33333');
      expect(pdfFormatNumber(-2.25), '-2.25');
      expect(pdfFormatNumber(1e-9), '0');
    });

    test('rejects values PDF cannot express', () {
      expect(() => pdfFormatNumber(double.nan), throwsArgumentError);
      expect(() => pdfFormatNumber(double.infinity), throwsArgumentError);
    });
  });

  group('object syntax', () {
    test('names escape delimiters and non-ASCII', () {
      expect(const PdfName('Simple').toString(), '/Simple');
      expect(const PdfName('A B').toString(), '/A#20B');
      expect(const PdfName('a#b').toString(), '/a#23b');
      expect(const PdfName('(x)').toString(), '/#28x#29');
    });

    test('literal strings escape what would break the parser', () {
      expect(PdfString('a(b)c\\d').toString(), r'(a\(b\)c\\d)');
      expect(
        PdfString.bytes(Uint8List.fromList(<int>[0, 10])).toString(),
        r'(\000\n)',
      );
    });

    test('a PDF date carries its zone', () {
      expect(
        PdfString.date(DateTime.utc(2026, 8, 18, 9, 5, 3)).toString(),
        "(D:20260818090503Z00'00')",
      );
    });

    test('dictionaries keep insertion order', () {
      final dict = PdfDict()
        ..['Z'] = const PdfNumber(1)
        ..['A'] = const PdfNumber(2);
      expect(dict.toString(), '<</Z 1 /A 2>>');
    });

    test('a stream recomputes /Length and ignores a stale one', () {
      final stream = PdfStream(
        PdfDict(<String, PdfObject>{'Length': const PdfNumber(9999)}),
        Uint8List.fromList(<int>[1, 2, 3]),
      );
      expect(stream.toString(), contains('/Length 3'));
      expect(stream.toString(), isNot(contains('9999')));
    });

    test('references compare by number and generation', () {
      expect(const PdfRef(3), const PdfRef(3));
      expect(const PdfRef(3), isNot(const PdfRef(3, 1)));
      expect(const PdfRef(3).hashCode, const PdfRef(3).hashCode);
    });
  });
}
