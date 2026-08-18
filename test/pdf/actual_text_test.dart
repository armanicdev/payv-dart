// The ligature that extracted backwards.
//
// `ToUnicode` was never the defect. `<0004> <06B50627>` is exactly right: the
// ڵ+ا ligature is ONE glyph (`lamVabove_alef.isol`) carrying TWO codepoints, in
// logical order. What broke was the reader's reconstruction. RTL glyphs are
// stored VISUALLY — see invariant 1 in `lib/src/layout/text_engine.dart`, and
// every extractor depends on it — so a reader reorders the line back to logical
// order, and it reverses the ligature's two characters along with the rest of
// the line. It cannot know they belong to one glyph. `پاڵاوتن` came back as
// `پااڵوتن`; `ڵا` came back as `اڵ`.
//
// The fix is `/ActualText` on a marked-content span around that one glyph, and
// the part of it worth a test rather than a comment is the ORDER of the span's
// text. A reader does not treat `/ActualText` as finished logical text: it
// spreads those characters across the span's box left to right and runs the
// same bidi pass over them it runs over glyphs. Written logically they are
// reversed a second time and nothing improves. Measured on `ڵا · ڵا ژمارە ·
// ژمارە ڵا · پاڵاوتن · ڵاو`, one line each, compared line-exact:
//
//                       pdftotext 26.06   mutool 1.28.2   PDFKit (macOS)
//     no span                 0/5              1/5              5/5
//     span, logical order     0/5              1/5              5/5
//     span, VISUAL order      5/5              4/5              5/5
//
// Read the first two rows together: a span written in logical order is worth
// exactly nothing, cell for cell. Visual order is worth 14 of 15. PDFKit
// ignores `/ActualText` entirely — its column never moves — and already treats
// the cluster as atomic, so it neither helps nor is harmed.
//
// CORRECTION, measured in CI on 2026-08-18. Every number above was taken on
// macOS. Ubuntu's `mupdf-tools` reports the SAME version string — MuPDF
// 1.28.2 — and behaves differently: it reverses nothing at all, returning our
// visual order verbatim on every line, not just on a line holding the ligature
// alone. The original note blamed "no second glyph to prove the line is RTL";
// the real variable is the build. MuPDF's text device only reorders when the
// binary was compiled with its bidi support, and the two distributions differ.
//
// So mutool's LINE ORDER is not a portable property and this file no longer
// asserts it. What mutool is still worth running for is portable and is what
// the tests below check: the same characters come back, none of them is a
// presentation form, and the ligature still contributes BOTH its codepoints —
// which is the entire point of the `/ActualText` span. Order is poppler's job;
// it implements UAX #9 properly and is asserted exactly, in both directions,
// on every platform.
//
// The lesson is cheap to state and was expensive to find: an external tool's
// version string does not identify its behaviour.
@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:payv/payv.dart';
import 'package:test/test.dart';

/// In LOGICAL order — what the author typed, and what must come back.
const String _ligatureWord = 'پاڵاوتن';
const String _ligatureAlone = 'ڵا';
const String _noLigature = 'گۆڕینی ڕووکار';
const List<String> _probes = <String>[
  _ligatureWord,
  _ligatureAlone,
  _noLigature,
];

/// Matches a string holding exactly the characters of [logical], in any order.
///
/// See the CORRECTION at the top of this file. Two failed attempts got us here
/// and both are worth recording, because each looked right:
///
///  1. Assert the logical string. Passes only on a MuPDF built with bidi.
///  2. Assert "logical OR the whole string reversed". Still wrong — a build
///     without bidi emits GLYPHS in visual order but each glyph's `ToUnicode`
///     in LOGICAL order, so the ڵ+ا ligature's two codepoints do not reverse
///     with the rest of the line. `پاڵاوتن` comes back `نتوڵااپ`, which is not
///     the reverse of anything.
///
/// Modelling an extractor's internal reordering is not this suite's job and
/// there is no stable answer to model. Order is asserted exactly through
/// poppler, which implements UAX #9. What mutool proves portably — and it is
/// worth proving, from a second independent codebase — is that no letter was
/// dropped or substituted, and that the ligature still yields BOTH codepoints
/// rather than one. A multiset comparison says exactly that and nothing it
/// cannot back up.
Matcher _sameLetters(String logical) {
  final want = (logical.runes.toList()..sort()).join(',');
  return predicate<String>(
    (actual) => (actual.runes.toList()..sort()).join(',') == want,
    'holds exactly the characters of "$logical", in any order',
  );
}

/// The `/Span` the ڵ+ا glyph must carry, byte for byte.
///
/// `FEFF` is the byte-order mark a PDF text string needs; `0627 06B5` is ا then
/// ڵ, the order the glyph DRAWS them, which is the reverse of the order the
/// `ToUnicode` CMap records. The two being opposite is the point, not a slip.
const String _span = '/Span <</ActualText <FEFF062706B5>>> BDC';

/// What `ToUnicode` says about the same glyph, and must keep saying.
const String _toUnicode = '<06B50627>';

/// Directional formatting a reader wraps its output in. Not content.
const Set<int> _bidiMarks = <int>{0x202A, 0x202B, 0x202C, 0x200E, 0x200F};

void main() {
  final fontFile = File('test/fonts/Vazirmatn.ttf');
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

  group('the ligature survives a real extractor', () {
    late File file;

    setUpAll(() {
      file = File('${Directory.systemTemp.path}/payv_actual_text.pdf')
        ..writeAsBytesSync(build(_probes));
    });

    tearDownAll(() {
      if (file.existsSync()) file.deleteSync();
    });

    test('pdftotext returns all three probes in logical order', () {
      final lines = _extract('pdftotext', <String>[file.path, '-']);
      if (lines == null) {
        markTestSkipped('pdftotext is not installed');
        return;
      }
      expect(lines, _probes);
    });

    test('mutool returns every letter, in whichever order its build uses', () {
      final lines = _extract('mutool', <String>[
        'draw',
        '-F',
        'txt',
        '-o',
        '-',
        file.path,
      ]);
      if (lines == null) {
        markTestSkipped('mutool is not installed');
        return;
      }
      expect(lines, hasLength(3));

      // Deliberately direction-agnostic — see the CORRECTION at the top of this
      // file. Whether a given MuPDF build reverses an RTL line depends on how
      // it was compiled, so asserting one orientation passes on one machine and
      // fails on another for reasons no commit caused.
      //
      // This still catches everything mutool can actually prove: a dropped
      // letter, a substituted letter, or a ligature that came back as one
      // codepoint instead of two. Only the direction is unpinned.
      for (final (i, expected) in _probes.indexed) {
        expect(
          lines[i],
          _sameLetters(expected),
          reason: 'line \$i lost, gained or substituted a character',
        );
      }
    });
  });

  group('the span is on the ligature and nowhere else', () {
    test('wraps the two-codepoint glyph, in visual order, as hex', () {
      expect(operators(<String>[_ligatureAlone]), contains(_span));
    });

    test('leaves single-codepoint glyphs bare', () {
      // گۆڕینی ڕووکار is thirteen letters and not one of them ligates. Wrapping
      // them anyway would cost ~45 bytes each and buy nothing: one codepoint
      // cannot be reversed against itself.
      final raw = operators(<String>[_noLigature]);
      expect(raw, isNot(contains('/ActualText')));
      expect(raw, isNot(contains('BDC')));
      expect(raw, isNot(contains('EMC')));
    });

    test('one span per ligature drawn, not one per glyph', () {
      final raw = operators(_probes);
      expect(RegExp('/ActualText').allMatches(raw).length, 2);
      expect(RegExp('BDC').allMatches(raw).length, 2);
      expect(RegExp('EMC').allMatches(raw).length, 2);
    });

    test('an LTR ligature is NOT reversed', () {
      // The `fi` of Vazirmatn's Latin is also one glyph for two codepoints, and
      // its run is drawn left to right — so visual order and logical order are
      // the same thing and the reversal must not fire. This is the branch a
      // reader of the emitter would most likely get wrong by applying the
      // reversal unconditionally.
      //
      // `<6669>` and not `<FEFF00660069>` because a PDF text string that is all
      // ASCII is written as PDFDocEncoding — `encodePdfTextString`'s documented
      // shortcut, shared with `/Title`. Both spellings mean `fi`; the Kurdish
      // path, which is the one that ships, takes the UTF-16BE branch and its
      // BOM. Asserted as much for the reversal as for the encoding.
      final raw = operators(<String>['fi']);
      expect(raw, contains('/Span <</ActualText <6669>>> BDC'));
      expect(raw, isNot(contains('<6966>')));
    });

    test('ToUnicode keeps the LOGICAL order the span inverts', () {
      // Both live in the same file, deliberately opposite. Anyone "fixing" the
      // apparent inconsistency by reversing the CMap breaks every reader that
      // has no span to read — and PDFKit, which ignores spans entirely.
      final raw = operators(<String>[_ligatureAlone]);
      expect(raw, contains(_toUnicode));
      expect(raw, contains(_span));
    });
  });

  group('the span does not corrupt the text object', () {
    test('no TJ array straddles a BDC or an EMC', () {
      // A `TJ` array must be complete before the span opens and complete again
      // before it closes. Square brackets reach a content stream only from a
      // `TJ` (nothing here sets a dash pattern), so counting them at every
      // marked-content operator is the whole invariant.
      final raw = operators(_probes);
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

    test('the span holds a finished TJ and nothing else', () {
      expect(
        RegExp(
          r'BDC\n\[<[0-9A-F]+>\] TJ\nEMC',
        ).hasMatch(operators(<String>[_ligatureAlone])),
        isTrue,
      );
    });

    test('every marked-content sequence is closed', () {
      // `ContentStream.build` throws on an unbalanced BMC/BDC, so a document
      // that saves at all has already proved this — which is exactly why it is
      // worth one line to say so out loud.
      expect(() => build(_probes), returnsNormally);
    });
  });

  test('the same document twice is still byte-identical', () {
    // The span adds a dictionary per ligature, and a dictionary is where a
    // writer usually starts leaking map iteration order into its bytes.
    expect(build(_probes), build(_probes));
  });
}

/// Runs an extractor and returns its non-empty lines, or null if the binary is
/// not on this machine.
///
/// Strips the directional marks a reader wraps an RTL line in: they are the
/// reader telling a terminal how to draw the line, not part of the text a
/// someone copied.
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
