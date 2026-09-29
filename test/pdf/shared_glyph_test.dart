// One glyph, two letters.
//
// Leraw (Rubik with the Sorani letters, OFL) builds ڕ from the glyph of ر and
// a V mark, ۆ from و and ێ from ی. `ToUnicode` is keyed by glyph, so the base
// glyph can map back to only one of its two letters, and the first one drawn
// won: a receipt that drew a ڕ first had every plain ر extract as ڕ (`کردن`
// came back `کڕدن`), and one that drew و first lost the V of every ۆ (`دۆخ`
// came back `دوخ`). The V mark has no codepoint of its own, so it had no entry
// at all, which MuPDF reads as U+FFFD.
//
// An occurrence whose own letter differs from its glyph's entry now carries
// it in an `/ActualText` span, and a glyph that says nothing, the mark, an
// empty one. Measured before and after on pdftotext 26.06 and mutool 1.28.2:
// the letters were wrong in both and MuPDF added a U+FFFD per mark; after,
// every line comes back whole.
@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:payv/payv.dart';
import 'package:test/test.dart';

/// In LOGICAL order. Each shared glyph is drawn as both of its letters, in
/// the same joining form, so whichever claims the CMap entry, the other has
/// to come back through its span.
const List<String> _lines = <String>[
  'زانیاری ڕێکەوت',
  'دۆخ و',
  'ڕێکەوتی زانیاری',
  'و دۆخ',
  'ڵ لەگەڵ',
];

/// Directional formatting a reader wraps its output in. Not content.
const Set<int> _bidiMarks = <int>{0x202A, 0x202B, 0x202C, 0x200E, 0x200F};

/// Matches a string holding exactly the characters of [logical], in any
/// order: MuPDF's line order depends on its build (see
/// actual_text_test.dart), its letters do not.
Matcher _sameLetters(String logical) {
  final want = (logical.runes.toList()..sort()).join(',');
  return predicate<String>(
    (actual) => (actual.runes.toList()..sort()).join(',') == want,
    'holds exactly the characters of "$logical", in any order',
  );
}

void main() {
  final fontFile = File('test/fonts/Leraw.ttf');
  if (!fontFile.existsSync()) {
    throw StateError('test font not found at ${fontFile.path}');
  }
  final fontBytes = fontFile.readAsBytesSync();

  Uint8List build(List<String> text, {bool compress = true}) {
    final font = PayvFont.load(fontBytes);
    final doc = PayvDocument(compress: compress, language: 'ckb');
    final page = doc.addPage();
    var y = page.height - 80;
    for (final line in text) {
      page.text(
        line,
        // The START of an RTL line is its right edge; invariant 2.
        x: page.width - 48,
        y: y,
        style: TextStyle(font: font, size: 14),
      );
      y -= 40;
    }
    return doc.save();
  }

  /// The file as ASCII, for reading the operators out of an uncompressed build.
  String operators(List<String> text) =>
      latin1.decode(build(text, compress: false), allowInvalid: true);

  /// [text] built and read back by [executable], or null when it is not
  /// installed.
  List<String>? extract(
    List<String> text,
    String executable,
    List<String> Function(String path) arguments,
  ) {
    final file = File('${Directory.systemTemp.path}/payv_shared_glyph.pdf')
      ..writeAsBytesSync(build(text));
    try {
      return _extract(executable, arguments(file.path));
    } finally {
      file.deleteSync();
    }
  }

  List<String>? pdftotext(List<String> text) =>
      extract(text, 'pdftotext', _pdftotext);

  group('each letter comes back as itself', () {
    test('pdftotext returns every line in logical order', () {
      final lines = pdftotext(_lines);
      if (lines == null) {
        markTestSkipped('pdftotext is not installed');
        return;
      }
      expect(lines, _lines);
    });

    test('the letter drawn first no longer decides the others', () {
      // The same two words in both orders, one document each; ر and ڕ both
      // stand alone in them, on the one glyph. Before, the word drawn second
      // took the first one's letter.
      const a = 'دار';
      const b = 'ڕاست';
      final first = pdftotext(<String>[a, b]);
      if (first == null) {
        markTestSkipped('pdftotext is not installed');
        return;
      }
      expect(first, <String>[a, b]);
      expect(pdftotext(<String>[b, a]), <String>[b, a]);
    });

    test('mutool returns every letter, and no U+FFFD for a mark', () {
      final lines = extract(_lines, 'mutool', _mutool);
      if (lines == null) {
        markTestSkipped('mutool is not installed');
        return;
      }
      expect(lines, hasLength(_lines.length));
      for (final (i, expected) in _lines.indexed) {
        expect(
          lines[i],
          _sameLetters(expected),
          reason: 'line $i lost, gained or substituted a character',
        );
      }
    });
  });

  group('the spans go where a glyph says something else', () {
    // ر and ڕ in the same form share one glyph. The RTL line is drawn from
    // its left, so ڕ, the logically last, is drawn first and claims the
    // entry; the plain ر after it is the one that needs a span.
    const pair = 'بر بڕ';

    test('the letter the entry does not say, and only that one', () {
      final raw = operators(<String>[pair]);
      expect(RegExp('/ActualText <FEFF0631>').allMatches(raw).length, 1);
      expect(raw, isNot(contains('/ActualText <FEFF0695>')));
    });

    test('an empty span on the mark, which says nothing', () {
      final raw = operators(<String>[pair]);
      expect(RegExp('/ActualText <>').allMatches(raw).length, 1);
    });

    test('no TJ array straddles a BDC or an EMC', () {
      // Counted in the page's content stream alone: uncompressed, the
      // embedded font program before it is raw bytes, brackets included.
      final file = operators(_lines);
      final start = file.indexOf('stream\nq\n');
      expect(start, isNot(-1), reason: 'no content stream found');
      final raw = file.substring(start, file.indexOf('endstream', start));
      expect(raw, contains('BDC'));
      for (final match in RegExp('BDC|EMC').allMatches(raw)) {
        final before = raw.substring(0, match.start);
        expect(
          '['.allMatches(before).length,
          ']'.allMatches(before).length,
          reason:
              'a TJ array was still open at the ${match.group(0)} at '
              '${match.start}',
        );
      }
    });
  });
}

/// pdftotext's arguments for the file at [path]: its text, to stdout.
List<String> _pdftotext(String path) => <String>[path, '-'];

/// mutool's: the page drawn as text, to stdout.
List<String> _mutool(String path) =>
    <String>['draw', '-F', 'txt', '-o', '-', path];

/// [executable] run over a file, split into non-empty lines with the reader's
/// directional marks and page breaks removed; null when it cannot run.
List<String>? _extract(String executable, List<String> arguments) {
  final ProcessResult result;
  try {
    result = Process.runSync(
      executable,
      arguments,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) return null;

  final lines = <String>[];
  for (final line in (result.stdout as String).split('\n')) {
    // 0x0C is the page break both readers end a page with.
    final text = String.fromCharCodes(
      line.runes.where((r) => !_bidiMarks.contains(r) && r != 0x0C),
    ).trim();
    if (text.isNotEmpty) lines.add(text);
  }
  return lines;
}
