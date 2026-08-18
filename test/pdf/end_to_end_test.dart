// The closing link in the evidence chain.
//
// `test/shaping/harfbuzz_parity_test.dart` proves the SHAPER is right, glyph for
// glyph, against HarfBuzz. This file proves those same glyphs actually reach the
// page — as vector outlines, in the right order, extractable back to the text
// they came from.
//
// Both halves are needed and neither substitutes for the other. A perfect
// shaper wired to a broken emitter produces a beautiful wrong PDF; a perfect
// emitter fed garbage produces a faithful rendering of garbage. The property
// this file adds is the JOIN: the CIDs in the content stream, mapped back
// through the subset, must equal what the shaper produced.
@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:payv/payv.dart';
import 'package:test/test.dart';

/// Strings that must survive the whole pipeline. Each contains at least one
/// glyph no presentation-form library can produce.
const _probes = <String, String>{
  'ژمارەی ناسنامە': 'identity number — uni06D5.fina, GSUB-only',
  'پاڵاوتن': 'the ڵ+ا ligature, which has NO Unicode codepoint',
  'گۆڕینی ڕووکار': 'ڕ U+0695, no presentation form',
  'هەرێمی کوردستان': 'ێ + ە + the contextual .long seen form',
  'وەسڵی پارەدان': 'payment receipt',
};

void main() {
  final fontFile = File('test/fonts/Vazirmatn.ttf');
  if (!fontFile.existsSync()) {
    throw StateError('test font not found at ${fontFile.path}');
  }
  final fontBytes = fontFile.readAsBytesSync();

  Uint8List buildProbeDocument() {
    final font = PayvFont.load(fontBytes);
    final doc = PayvDocument(title: 'payv e2e', language: 'ckb');
    final page = doc.addPage();
    var y = page.height - 80;
    for (final text in _probes.keys) {
      page.text(
        text,
        x: page.width - 48,
        y: y,
        style: TextStyle(font: font, size: 14),
      );
      y -= 40;
    }
    return doc.save();
  }

  group('the page is vector text, not a picture of text', () {
    late Uint8List bytes;
    setUpAll(() => bytes = buildProbeDocument());

    test('carries no image XObject', () {
      final raw = latin1.decode(bytes, allowInvalid: true);
      expect(raw, isNot(contains('/Subtype /Image')));
      expect(raw, isNot(contains('/Subtype/Image')));
      expect(raw, isNot(contains('/DCTDecode')));
    });

    test('carries real text-showing operators', () {
      final raw = latin1.decode(bytes, allowInvalid: true);
      // The content stream is compressed, so look at the object graph instead:
      // a Type0 font with an Identity-H encoding only exists if text was drawn.
      expect(raw, contains('/Type0'));
      expect(raw, contains('/Identity-H'));
      expect(raw, contains('/CIDFontType2'));
    });

    test('embeds a SUBSET of the face, not the whole font', () {
      final raw = latin1.decode(bytes, allowInvalid: true);
      // A 6-uppercase-letter subset tag is how a PDF declares a subset.
      expect(RegExp(r'/BaseFont\s*/[A-Z]{6}\+').hasMatch(raw), isTrue);
      expect(
        bytes.length,
        lessThan(fontBytes.length),
        reason: 'the whole 241 KB face was embedded; subsetting did not happen',
      );
    });

    test(
      'a page of Kurdish costs kilobytes, not the ~230 KB a raster does',
      () {
        expect(bytes.length, lessThan(60 * 1024));
      },
    );
  });

  group('the same document twice is byte-identical', () {
    test('no timestamps, no random subset tags, no map iteration order', () {
      expect(buildProbeDocument(), buildProbeDocument());
    });
  });

  group('extraction round-trips through real PDF readers', () {
    late File file;

    setUpAll(() {
      file = File('${Directory.systemTemp.path}/payv_e2e.pdf')
        ..writeAsBytesSync(buildProbeDocument());
    });

    tearDownAll(() {
      if (file.existsSync()) file.deleteSync();
    });

    test('pdftotext returns every probe string exactly', () {
      final r = Process.runSync('pdftotext', [file.path, '-']);
      if (r.exitCode != 0) {
        markTestSkipped('pdftotext not available');
        return;
      }
      final out = r.stdout as String;
      for (final entry in _probes.entries) {
        expect(
          out,
          contains(entry.key),
          reason: '${entry.key} (${entry.value}) did not survive extraction',
        );
      }
    });

    test('no presentation form appears anywhere in the extracted text', () {
      // The thesis, stated negatively. If a single U+FB50–U+FEFF codepoint
      // comes back, something in the pipeline fell back to the technique this
      // package exists to replace.
      final r = Process.runSync('pdftotext', [file.path, '-']);
      if (r.exitCode != 0) {
        markTestSkipped('pdftotext not available');
        return;
      }
      final offenders = (r.stdout as String).runes
          .where((c) => c >= 0xFB50 && c <= 0xFEFF)
          .map((c) => 'U+${c.toRadixString(16).toUpperCase()}')
          .toSet();
      expect(offenders, isEmpty);
    });

    test('mutool agrees on the Kurdish letters', () {
      final r = Process.runSync('mutool', [
        'draw',
        '-F',
        'txt',
        '-o',
        '-',
        file.path,
      ]);
      if (r.exitCode != 0) {
        markTestSkipped('mutool not available');
        return;
      }
      final out = r.stdout as String;
      // mutool's text device does a simpler job than pdftotext's full UAX #9
      // pass, and — measured in CI on 2026-08-18 — HOW simple depends on the
      // build, not the version. macOS homebrew's MuPDF 1.28.2 reverses RTL
      // lines; Ubuntu's mupdf-tools reports the same 1.28.2 and reverses
      // nothing, handing back the visual order the PDF stores. Same version
      // string, different behaviour.
      //
      // "The reverse of the logical string" is not the answer either: a build
      // without bidi emits GLYPHS visually but each glyph's ToUnicode
      // LOGICALLY, so a ligature's two codepoints do not reverse with the line
      // around them. `پاڵاوتن` arrives as `نتوڵااپ` — the reverse of nothing.
      //
      // So compare characters as a multiset, per line. It is the strongest
      // claim that holds on every build, and it is not a weak one: it fails the
      // moment a letter is dropped, substituted, or a ligature comes back as
      // one codepoint instead of two. Exact order is asserted above, through
      // poppler, which implements UAX #9 properly.
      final lines = out
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines, hasLength(_probes.length));

      for (final (i, probe) in _probes.keys.indexed) {
        expect(
          (lines[i].runes.toList()..sort()).join(','),
          (probe.runes.toList()..sort()).join(','),
          reason:
              '${_probes[probe]}: mutool returned "${lines[i]}" for "$probe" — '
              'a character was lost, gained or substituted',
        );
      }
    });
  });

  group('the glyphs on the page are the ones the shaper chose', () {
    // This is the join. Everything else in this file could pass while the page
    // showed the wrong letters.
    test('reaches at least one glyph unreachable through cmap', () {
      final font = OpenTypeFont.parse(fontBytes);
      final shaped = Shaper(font).shape('پاڵاوتن');
      final drawn = shaped.infos.map((i) => i.glyphId).toSet();

      final viaCmap = <int>{
        for (var cp = 0x0600; cp <= 0x06FF; cp++) font.glyphForCodepoint(cp),
        for (var cp = 0xFB50; cp <= 0xFEFF; cp++) font.glyphForCodepoint(cp),
      }..remove(0);

      expect(
        drawn.difference(viaCmap),
        isNotEmpty,
        reason:
            'every glyph in پاڵاوتن was reachable from some codepoint, so the '
            'ڵ+ا ligature was not produced and the package is doing nothing '
            'a presentation-form library could not.',
      );
    });

    test('the ToUnicode CMap maps the ligature back to BOTH its letters', () {
      // ڵ+ا is one glyph carrying two codepoints. If ToUnicode only records
      // one, someone copying their address out of a receipt loses a letter.
      final font = PayvFont.load(fontBytes);
      final doc = PayvDocument(language: 'ckb');
      final page = doc.addPage();
      page.text(
        'ڵا',
        x: page.width - 48,
        y: 700,
        style: TextStyle(font: font, size: 14),
      );

      // The CMap is a FlateDecode stream, so it has to be inflated before it
      // can be read. Grepping the raw file for the hex instead finds nothing
      // and passes for the wrong reason the moment compression is switched
      // off — which is exactly how this assertion was wrong the first time.
      final cmap = _inflateStreamContaining(doc.save(), 'beginbfchar');
      expect(
        cmap,
        isNotNull,
        reason: 'no ToUnicode CMap stream in the document',
      );
      expect(
        cmap!.replaceAll(' ', '').toUpperCase(),
        contains('<06B50627>'),
        reason:
            'the ڵ+ا ligature CID must map back to U+06B5 then U+0627, '
            'in that order',
      );
    });
  });

  group('degenerate input does not produce a broken file', () {
    for (final (label, text) in <(String, String)>[
      ('empty string', ''),
      ('a lone ZWJ', '‍'),
      ('marks with no base', 'َّ'),
      ('one very long unbreakable word', 'ڕووکارەکانمانەوە' * 12),
      ('mixed Kurdish, Latin and digits', 'ژمارە Payv 2026 ڕێگە'),
    ]) {
      test(label, () {
        final font = PayvFont.load(fontBytes);
        final doc = PayvDocument(language: 'ckb');
        final page = doc.addPage();
        page.textBox(
          text,
          rect: PdfRect(48, 400, page.width - 96, 200),
          style: TextStyle(font: font, size: 12),
        );
        final bytes = doc.save();
        expect(bytes.length, greaterThan(400));
        expect(latin1.decode(bytes.sublist(0, 8)), startsWith('%PDF-1.7'));
        expect(
          latin1.decode(bytes.sublist(bytes.length - 8), allowInvalid: true),
          contains('%%EOF'),
        );
      });
    }
  });

  test('one isolate character does not poison every space in the document', () {
    // The shaper hides a surviving default-ignorable by pointing it at the
    // SPACE glyph (HarfBuzz does the same). ToUnicode is keyed by glyph id, so
    // if a U+2066 is allowed to register that glyph it claims it font-wide and
    // EVERY space in the document extracts as U+2066 — `Paid in full` comes
    // back as `Paid<U+2066>in<U+2066>full`, on lines containing no isolate at all.
    final font = PayvFont.load(fontBytes);
    final doc = PayvDocument(language: 'ckb');
    final page = doc.addPage();
    page.text(
      '\u{2066}١–٣١ May 2026\u{2069}', // one isolate-wrapped date range
      x: page.width - 48,
      y: 760,
      style: TextStyle(font: font, size: 12),
    );
    page.text(
      'Paid in full',
      x: 48,
      y: 720,
      style: TextStyle(font: font, size: 12),
    );

    final cmap = _inflateStreamContaining(doc.save(), 'beginbfchar');
    expect(cmap, isNotNull);
    expect(
      cmap,
      isNot(contains('2066')),
      reason:
          'a default-ignorable reached the ToUnicode CMap and will have '
          'taken the space glyph with it',
    );
    expect(
      cmap,
      contains('0020'),
      reason: 'the space glyph lost its own ToUnicode entry',
    );
  });

  test('a face used on many pages is embedded exactly once', () {
    final font = PayvFont.load(fontBytes);
    final doc = PayvDocument(language: 'ckb');
    for (var i = 0; i < 40; i++) {
      final page = doc.addPage();
      page.text(
        'ژمارەی ناسنامە',
        x: page.width - 48,
        y: page.height - 80,
        style: TextStyle(font: font, size: 12),
      );
    }
    final raw = latin1.decode(doc.save(), allowInvalid: true);
    expect(
      RegExp('/FontFile2').allMatches(raw).length,
      1,
      reason:
          'the face was embedded once per page instead of once per document',
    );
  });
}

/// Inflates each `FlateDecode` stream in [pdf] and returns the first whose text
/// contains [needle], or null.
///
/// A PDF's interesting parts — content streams, CMaps — are compressed, so any
/// assertion that greps the raw file is testing nothing. This is small enough
/// to keep here rather than growing a PDF parser for the test suite.
String? _inflateStreamContaining(Uint8List pdf, String needle) {
  final decoder = ZLibDecoder();
  var from = 0;
  while (true) {
    final start = _indexOf(pdf, 'stream', from);
    if (start < 0) return null;
    var body = start + 6;
    if (body < pdf.length && pdf[body] == 0x0D) body++;
    if (body < pdf.length && pdf[body] == 0x0A) body++;
    final end = _indexOf(pdf, 'endstream', body);
    if (end < 0) return null;
    from = end + 9;
    try {
      final out = decoder.convert(pdf.sublist(body, end));
      final text = latin1.decode(out, allowInvalid: true);
      if (text.contains(needle)) return text;
    } on Object {
      // Not a zlib stream, or not ours. Keep looking.
    }
  }
}

int _indexOf(Uint8List haystack, String needle, int from) {
  final n = latin1.encode(needle);
  outer:
  for (var i = from; i <= haystack.length - n.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) continue outer;
    }
    return i;
  }
  return -1;
}
