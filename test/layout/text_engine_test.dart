/// The layout engine: shaped glyphs onto a page.
///
/// These tests read the CONTENT STREAM, not a rendered picture. That is
/// deliberate — the two properties that are hardest to get right here are
/// invisible in a rendering: whether an RTL run was stored in visual order (a
/// backwards line looks fine until someone copies it out) and whether a mark's
/// vertical offset survived (a fatha on the baseline looks like a font bug).
/// Both are plain to see in the operators.
///
/// The font embedder is faked. This file is about layout, and a fake with
/// CID == glyph id makes every assertion below readable as glyph ids — which
/// are the numbers the HarfBuzz gate speaks in.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:payv/payv.dart';
import 'package:payv/src/layout/line_breaker.dart';
import 'package:payv/src/layout/text_engine.dart';
import 'package:payv/src/pdf/document.dart';
import 'package:payv/src/pdf/font_descriptor.dart' show scaleToPdfGlyphSpace;
import 'package:payv/src/pdf/object.dart';
import 'package:payv/src/pdf/page.dart';
import 'package:test/test.dart';

/// An encoder that hands back the glyph id itself as the CID.
///
/// Which is not a toy: an Identity-H CIDFontType2 that has not been subsetted
/// addresses glyphs by exactly this identity. It skips only the renumbering a
/// real subset does, so the bytes in the stream stay legible as glyph ids —
/// the numbers the HarfBuzz gate speaks in.
class _IdentityEncoder implements GlyphEncoder {
  _IdentityEncoder(this.document);

  static final List<_IdentityEncoder> created = <_IdentityEncoder>[];

  final PdfDocument document;

  /// Glyph → the codepoints it was recorded as carrying.
  final Map<int, List<int>> sources = <int, List<int>>{};

  PdfRef? _font;
  bool finished = false;
  int finishCalls = 0;

  @override
  String attach(PdfPage page, PayvFont font) {
    final ref = _font ??= document.writer.add(
      PdfDict(<String, PdfObject>{
        'Type': const PdfName('Font'),
        'Subtype': const PdfName('Type0'),
        'BaseFont': const PdfName('Test'),
        'Encoding': const PdfName('Identity-H'),
      }),
    );
    return document.addResource(page, 'Font', ref);
  }

  @override
  void use(PayvFont font, int glyphId, List<int> codepoints) {
    expect(finished, isFalse, reason: 'a glyph was used after finishAll()');
    final existing = sources[glyphId];
    if (existing != null && existing.isNotEmpty) return;
    sources[glyphId] = codepoints;
  }

  @override
  int declaredWidth(PayvFont font, int glyphId) =>
      scaleToPdfGlyphSpace(font.raw.advanceWidth(glyphId), font.unitsPerEm);

  @override
  void finishAll() {
    finished = true;
    finishCalls++;
  }

  @override
  int cidFor(PayvFont font, int glyphId) {
    expect(finished, isTrue, reason: 'a CID was asked for before finishAll()');
    return glyphId;
  }
}

/// The bytes of a page's content stream.
///
/// Goes through `save()` first, and that is the contract, not a convenience: a
/// glyph's code is its id in the final subset, so nothing can be written until
/// every page has been drawn.
String _content(PayvDocument document, PayvPage page) {
  document.save();
  return latin1.decode(page.graphics.build());
}

/// Every glyph code shown on the page, in stream order.
List<int> _codes(PayvDocument document, PayvPage page) {
  final text = _content(document, page);
  final out = <int>[];
  for (final match in RegExp('<([0-9A-Fa-f]+)>').allMatches(text)) {
    final hex = match.group(1)!;
    for (var i = 0; i + 4 <= hex.length; i += 4) {
      out.add(int.parse(hex.substring(i, i + 4), radix: 16));
    }
  }
  return out;
}

/// The text objects on a page, one string of operators each.
List<String> _textObjects(PayvDocument document, PayvPage page) => [
  for (final m in RegExp(
    r'^BT$(.*?)^ET$',
    multiLine: true,
    dotAll: true,
  ).allMatches(_content(document, page)))
    m.group(1)!,
];

/// Replays one text object the way a viewer would, and returns how far the pen
/// travelled.
///
/// This is the assertion that actually grades the `TJ` arithmetic: a viewer
/// advances by the width the embedded font declares plus `Tc`, and SUBTRACTS
/// each array number scaled by size/1000. If the engine's numbers are wrong —
/// a sign flip, a missing GPOS delta, a forgotten word space — the replayed
/// displacement stops matching the width the engine reported, and every
/// alignment in the document is quietly off by that much.
///
/// Compared against [_glyphSpaceUnit], not exactly. The `/W` array declares
/// widths in 1000-unit glyph space, so each is rounded off the font's own
/// 2048-unit grid; the engine's `TJ` numbers absorb that residue on the NEXT
/// glyph, which leaves the last glyph of a line carrying up to half a unit of
/// it. That half unit lands in the trailing advance, after which the text
/// object ends and nothing is drawn — every glyph ORIGIN is still exact.
/// One unit of PDF glyph space at a given size — the resolution a `/W` array
/// can express, and therefore the floor on how exactly a replayed line can
/// land.
double _glyphSpaceUnit(double size) => size / 1000;

double _replayDisplacement(
  String textObject, {
  required OpenTypeFont font,
  required double size,
  double letterSpacing = 0,
}) {
  var x = 0.0;
  for (final array in RegExp(
    r'\[(.*?)\] TJ',
    dotAll: true,
  ).allMatches(textObject)) {
    for (final token in RegExp(
      '<([0-9A-Fa-f]*)>|(-?[0-9.]+)',
    ).allMatches(array.group(1)!)) {
      final hex = token.group(1);
      if (hex != null) {
        for (var i = 0; i + 4 <= hex.length; i += 4) {
          final gid = int.parse(hex.substring(i, i + 4), radix: 16);
          x +=
              scaleToPdfGlyphSpace(font.advanceWidth(gid), font.unitsPerEm) *
                  size /
                  1000 +
              letterSpacing;
        }
      } else {
        x -= double.parse(token.group(2)!) * size / 1000;
      }
    }
  }
  return x;
}

/// The `e` and `f` of the last `Tm` — where the line was placed.
(double, double) _textOrigin(PayvDocument document, PayvPage page) {
  final matches = RegExp(
    r'([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+) Tm',
  ).allMatches(_content(document, page)).toList();
  expect(matches, isNotEmpty, reason: 'no Tm in the content stream');
  final m = matches.last;
  return (double.parse(m.group(5)!), double.parse(m.group(6)!));
}

void main() {
  final fontFile = File('test/fonts/Vazirmatn.ttf');
  if (!fontFile.existsSync()) {
    throw StateError('test font not found at ${fontFile.path}');
  }
  final bytes = fontFile.readAsBytesSync();
  final raw = OpenTypeFont.parse(bytes);
  final shaper = Shaper(raw);

  setUpAll(() {
    TextEngine.encoderFactory = (document) {
      final encoder = _IdentityEncoder(document);
      _IdentityEncoder.created.add(encoder);
      return encoder;
    };
  });

  setUp(_IdentityEncoder.created.clear);

  PayvFont newFont() => PayvFont.load(Uint8List.fromList(bytes));

  TextStyle styleOf({
    double size = 12,
    double letterSpacing = 0,
    double wordSpacing = 0,
    String? language,
  }) => TextStyle(
    font: newFont(),
    size: size,
    letterSpacing: letterSpacing,
    wordSpacing: wordSpacing,
    language: language,
  );

  /// The width the shaper says a string is, in points — the number every
  /// measurement below has to agree with.
  double shapedWidth(String text, double size) =>
      shaper.shape(text).totalXAdvance * size / raw.unitsPerEm;

  group('measure', () {
    test('a Kurdish string measures the sum of its shaped advances', () {
      const text = 'ژمارەی ناسنامە';
      final doc = PayvDocument();
      final page = doc.addPage();

      final metrics = page.measure(text, style: styleOf(size: 14));

      expect(metrics.width, closeTo(shapedWidth(text, 14), 1e-9));
      expect(metrics.glyphCount, shaper.shape(text).length);
    });

    test('an English string measures the sum of its shaped advances', () {
      const text = 'Total due 125,000 IQD';
      final doc = PayvDocument();
      final page = doc.addPage();

      expect(
        page.measure(text, style: styleOf(size: 11)).width,
        closeTo(shapedWidth(text, 11), 1e-9),
      );
    });

    test('width scales linearly with the point size', () {
      const text = 'ناسنامە';
      final doc = PayvDocument();
      final page = doc.addPage();

      final small = page.measure(text, style: styleOf(size: 10)).width;
      final large = page.measure(text, style: styleOf(size: 30)).width;

      expect(large, closeTo(small * 3, 1e-9));
    });

    test(
      'letter spacing lands on every glyph, word spacing on every space',
      () {
        const text = 'a b c';
        final doc = PayvDocument();
        final page = doc.addPage();

        final plain = page.measure(text, style: styleOf()).width;
        final spaced = page
            .measure(text, style: styleOf(letterSpacing: 2, wordSpacing: 5))
            .width;

        // Five glyphs at +2, two U+0020 glyphs at +5.
        expect(spaced - plain, closeTo(5 * 2 + 2 * 5, 1e-9));
      },
    );

    test('vertical metrics come from hhea, scaled to the size', () {
      final doc = PayvDocument();
      final page = doc.addPage();
      final metrics = page.measure('x', style: styleOf(size: 20));

      expect(metrics.ascent, greaterThan(0));
      expect(metrics.descent, greaterThan(0));
      // The default leading is ascender - descender + lineGap, so it can never
      // be smaller than the ink it has to hold.
      expect(metrics.lineHeight, greaterThanOrEqualTo(metrics.height));
    });

    test('an empty string measures zero but still reports line metrics', () {
      final doc = PayvDocument();
      final page = doc.addPage();
      final metrics = page.measure('', style: styleOf());

      expect(metrics.width, 0);
      expect(metrics.glyphCount, 0);
      expect(metrics.lineHeight, greaterThan(0));
    });
  });

  group('drawLine', () {
    test('an RTL run reaches the content stream in VISUAL order', () {
      // The invariant that cost a round of measurement: every extractor runs
      // its own bidi pass over what it finds, so a PDF must store the LAST
      // logical glyph leftmost.
      const text = 'ڕۆژنامە';
      final doc = PayvDocument();
      final page = doc.addPage();

      page.text(text, x: 500, y: 700, style: styleOf());

      final run = shaper.shape(text);
      expect(
        run.direction,
        TextDirection.rtl,
        reason: 'the fixture string must actually be RTL',
      );
      // Clusters DESCEND through the shaped run — glyph 0 is the last thing
      // the author typed. That is what "visual order" means here.
      expect(run.infos.first.cluster, greaterThan(run.infos.last.cluster));

      expect(
        _codes(doc, page),
        [for (final info in run.infos) info.glyphId],
        reason: 'the stream must follow the shaper, not logical order',
      );
    });

    test('an LTR run reaches the content stream in logical order', () {
      const text = 'Receipt';
      final doc = PayvDocument();
      final page = doc.addPage();

      page.text(text, x: 40, y: 700, style: styleOf());

      final run = shaper.shape(text);
      expect(run.infos.first.cluster, lessThan(run.infos.last.cluster));
      expect(_codes(doc, page), [for (final info in run.infos) info.glyphId]);
    });

    test('a Latin island inside Kurdish stays upright and in place', () {
      // The bidi runs already say where the island is; the engine must not
      // re-detect it, and must not reverse it back.
      const text = 'ژمارە IQD کۆتایی';
      final doc = PayvDocument();
      final page = doc.addPage();

      page.text(text, x: 500, y: 700, style: styleOf());

      final codes = _codes(doc, page);
      final latin = [for (final c in 'IQD'.codeUnits) raw.glyphForCodepoint(c)];
      final at = _indexOfSublist(codes, latin);
      expect(
        at,
        isNot(-1),
        reason:
            'IQD must appear left-to-right inside the RTL line, not '
            'reversed to DQI',
      );
    });

    test('Arabic-Indic digits read left to right, not with the RTL run', () {
      // The counterpart to visual order, and the one that looks like a font
      // bug when it is wrong: UAX #9 I1/I2 puts AN two levels up, so a date
      // inside a Kurdish line is its own LTR run. Emit it with the rest of the
      // line and ٢٠٢٦ comes out ٦٢٠٢ — the right glyphs in the wrong order,
      // which no reader would report as anything but a corrupt document.
      const text = '٢٠٢٦/٠٨/١٨';
      final doc = PayvDocument();
      final page = doc.addPage();

      page.text(text, x: 500, y: 700, style: styleOf());

      final codes = _codes(doc, page);
      expect(codes.first, raw.glyphForCodepoint(text.codeUnitAt(0)));
      expect(
        codes.last,
        raw.glyphForCodepoint(text.codeUnitAt(text.length - 1)),
      );
    });

    test('a digit island keeps its order inside a Kurdish line', () {
      const digits = '٢٠٢٦';
      final doc = PayvDocument();
      final page = doc.addPage();

      page.text('بەرواری $digits ی پارەدان', x: 500, y: 700, style: styleOf());

      final codes = _codes(doc, page);
      final island = [
        for (var i = 0; i < digits.length; i++)
          raw.glyphForCodepoint(digits.codeUnitAt(i)),
      ];
      expect(
        _indexOfSublist(codes, island),
        isNot(-1),
        reason: 'the digits were reversed with the Kurdish around them',
      );
    });

    test('x is the line START — its right edge for RTL', () {
      const text = 'ناسنامە';
      final doc = PayvDocument();
      final page = doc.addPage();

      final metrics = page.text(text, x: 500, y: 700, style: styleOf());
      final (originX, originY) = _textOrigin(doc, page);

      expect(originX, closeTo(500 - metrics.width, 1e-4));
      expect(originY, closeTo(700, 1e-9));
    });

    test('x is the line START — its left edge for LTR', () {
      final doc = PayvDocument();
      final page = doc.addPage();

      page.text('Receipt', x: 40, y: 700, style: styleOf());
      final (originX, _) = _textOrigin(doc, page);

      expect(originX, closeTo(40, 1e-9));
    });

    test('a mark is lifted off the baseline with Ts', () {
      // بَب — the fatha carries a GPOS y-offset of -183 design units. Drop it
      // and every diacritic in the document stacks on the baseline.
      const text = 'بَب';
      final doc = PayvDocument();
      final page = doc.addPage();

      final run = shaper.shape(text);
      expect(
        run.positions.any((p) => p.yOffset != 0),
        isTrue,
        reason: 'the fixture must actually produce a vertical offset',
      );

      page.text(text, x: 300, y: 700, style: styleOf(size: 20));

      final rises = RegExp(r'([-\d.]+) Ts')
          .allMatches(_content(doc, page))
          .map((m) => double.parse(m.group(1)!))
          .toList();
      expect(rises, isNotEmpty, reason: 'no text rise was emitted');
      expect(
        rises.any((r) => r != 0),
        isTrue,
        reason: 'the mark was drawn on the baseline',
      );
      // And the rise is the GPOS offset scaled to points, not a guess.
      final expected =
          run.positions.firstWhere((p) => p.yOffset != 0).yOffset *
          20 /
          raw.unitsPerEm;
      expect(rises, contains(closeTo(expected, 1e-4)));
    });

    test('one TJ carries the whole run, not a Tm per glyph', () {
      final doc = PayvDocument();
      final page = doc.addPage();
      page.text('Total due', x: 40, y: 700, style: styleOf());

      final content = _content(doc, page);
      expect(
        RegExp('Tm').allMatches(content).length,
        1,
        reason: 'the pen is placed once per line',
      );
      expect(RegExp('TJ').allMatches(content).length, 1);
    });

    test('a replayed LTR line lands exactly on the reported width', () {
      const text = 'Total due 125,000 IQD — VAT included';
      final doc = PayvDocument();
      final page = doc.addPage();

      final metrics = page.text(text, x: 40, y: 700, style: styleOf(size: 11));

      expect(
        _replayDisplacement(
          _textObjects(doc, page).single,
          font: raw,
          size: 11,
        ),
        closeTo(metrics.width, _glyphSpaceUnit(11)),
      );
    });

    test('a replayed Kurdish line lands exactly on the reported width', () {
      // The one that matters: this line has GPOS marks and cursive joins, so
      // its declared widths and its shaped advances genuinely disagree.
      const text = 'ژمارەی ناسنامەی نیشتمانی';
      final doc = PayvDocument();
      final page = doc.addPage();

      final metrics = page.text(text, x: 500, y: 700, style: styleOf(size: 13));

      expect(
        _replayDisplacement(
          _textObjects(doc, page).single,
          font: raw,
          size: 13,
        ),
        closeTo(metrics.width, _glyphSpaceUnit(13)),
      );
    });

    test('a replayed line with letter and word spacing still lands', () {
      const text = 'a b c';
      final doc = PayvDocument();
      final page = doc.addPage();

      final metrics = page.text(
        text,
        x: 40,
        y: 700,
        style: styleOf(letterSpacing: 1.5, wordSpacing: 4),
      );

      expect(
        _replayDisplacement(
          _textObjects(doc, page).single,
          font: raw,
          size: 12,
          letterSpacing: 1.5,
        ),
        closeTo(metrics.width, _glyphSpaceUnit(12)),
      );
    });

    test('letter spacing is emitted as Tc, and word spacing is not Tw', () {
      final doc = PayvDocument();
      final page = doc.addPage();
      page.text(
        'a b',
        x: 40,
        y: 700,
        style: styleOf(letterSpacing: 1.5, wordSpacing: 4),
      );

      final content = _content(doc, page);
      expect(content, contains('1.5 Tc'));
      // Tw applies to single-byte code 32, which an Identity-H stream never
      // contains — emitting it would look like word spacing and do nothing.
      expect(content, isNot(contains(' Tw')));
    });

    test('the text object is balanced and bracketed by q/Q', () {
      final doc = PayvDocument();
      final page = doc.addPage();
      page.text('Receipt', x: 40, y: 700, style: styleOf());

      final content = _content(doc, page);
      expect(RegExp('^BT\$', multiLine: true).allMatches(content).length, 1);
      expect(RegExp('^ET\$', multiLine: true).allMatches(content).length, 1);
      expect(RegExp('^q\$', multiLine: true).allMatches(content).length, 1);
      expect(RegExp('^Q\$', multiLine: true).allMatches(content).length, 1);
      // build() throws on an unbalanced stream, so reaching here proves it too.
      expect(page.graphics.build(), isNotEmpty);
    });

    test('the ToUnicode text of a cluster goes on exactly one glyph', () {
      const text = 'بَب';
      final doc = PayvDocument();
      final page = doc.addPage();
      page.text(text, x: 300, y: 700, style: styleOf());

      final encoder = _IdentityEncoder.created.single;
      final recorded = [for (final source in encoder.sources.values) ...source];
      expect(
        String.fromCharCodes(recorded..sort()),
        String.fromCharCodes(text.codeUnits.toList()..sort()),
        reason:
            'every character maps back exactly once — a cluster recorded '
            'twice extracts twice, and one recorded never is unsearchable',
      );
    });

    test('a character the font cannot draw is refused, not drawn as a box', () {
      final doc = PayvDocument();
      final page = doc.addPage();

      expect(
        () => page.text('total 😀', x: 40, y: 700, style: styleOf()),
        throwsA(isA<MissingGlyphException>()),
      );
    });
  });

  group('drawBox', () {
    const paragraph =
        'ئەم بڕگەیە بۆ تاقیکردنەوەی دابەشکردنی دێڕەکانە لەناو چوارچێوەیەکی '
        'تەسکدا، بۆ ئەوەی دڵنیا بین لەوەی کە دەقەکە بە دروستی دەبڕدرێت و '
        'ئەوەی نەگونجاوە دەگەڕێتەوە.';

    test('returns null when everything fits', () {
      final doc = PayvDocument();
      final page = doc.addPage();

      final left = page.textBox(
        paragraph,
        rect: const PdfRect(40, 40, 500, 700),
        style: styleOf(size: 11),
      );

      expect(left, isNull);
    });

    test('returns the leftover text when it does not', () {
      final doc = PayvDocument();
      final page = doc.addPage();

      final left = page.textBox(
        paragraph,
        rect: const PdfRect(40, 600, 240, 40),
        style: styleOf(size: 11),
      );

      expect(left, isNotNull);
      expect(paragraph, endsWith(left!));
      expect(left.length, lessThan(paragraph.length));
    });

    test('flowing the leftover onward terminates and loses nothing', () {
      final doc = PayvDocument();
      var remaining = paragraph;
      final drawn = StringBuffer();
      var guard = 0;

      while (remaining.isNotEmpty && guard++ < 50) {
        final page = doc.addPage();
        final left = page.textBox(
          remaining,
          rect: const PdfRect(40, 600, 200, 40),
          style: styleOf(size: 11),
        );
        drawn.write(
          left == null
              ? remaining
              : remaining.substring(0, remaining.length - left.length),
        );
        remaining = left ?? '';
      }

      expect(guard, lessThan(50), reason: 'the flow loop did not terminate');
      expect(drawn.toString(), paragraph);
    });

    test('a box too short for one line places nothing and returns it all', () {
      final doc = PayvDocument();
      final page = doc.addPage();

      final left = page.textBox(
        'Total due',
        rect: const PdfRect(40, 600, 300, 2),
        style: styleOf(size: 11),
      );

      expect(left, 'Total due');
      expect(_codes(doc, page), isEmpty);
    });

    test('a hard break starts a new line', () {
      final doc = PayvDocument();
      final page = doc.addPage();

      page.textBox(
        'one\ntwo',
        rect: const PdfRect(40, 40, 400, 400),
        style: styleOf(),
      );

      final origins = RegExp(r'([-\d.]+) ([-\d.]+) Tm')
          .allMatches(_content(doc, page))
          .map((m) => double.parse(m.group(2)!))
          .toList();
      expect(origins.length, 2);
      expect(origins[1], lessThan(origins[0]));
    });

    test('end alignment puts an LTR line against the right edge', () {
      final doc = PayvDocument();
      final page = doc.addPage();

      final metrics = page.measure('Total', style: styleOf());
      page.textBox(
        'Total',
        rect: const PdfRect(40, 40, 400, 400),
        style: styleOf(),
        align: PayvTextAlign.end,
        direction: PayvTextDirection.ltr,
      );

      final (originX, _) = _textOrigin(doc, page);
      expect(originX, closeTo(440 - metrics.width, 1e-4));
    });

    test('start alignment puts an RTL line against the right edge', () {
      final doc = PayvDocument();
      final page = doc.addPage();

      final metrics = page.measure('ناسنامە', style: styleOf());
      page.textBox(
        'ناسنامە',
        rect: const PdfRect(40, 40, 400, 400),
        style: styleOf(),
      );

      final (originX, _) = _textOrigin(doc, page);
      expect(originX, closeTo(440 - metrics.width, 1e-4));
    });

    test('justify stretches every line but the last to the full measure', () {
      const text = 'alpha beta gamma delta epsilon zeta eta theta iota';
      final doc = PayvDocument();
      final page = doc.addPage();

      page.textBox(
        text,
        rect: const PdfRect(40, 40, 150, 400),
        style: styleOf(size: 10),
        align: PayvTextAlign.justify,
      );

      final objects = _textObjects(doc, page);
      expect(objects.length, greaterThan(1), reason: 'the text must wrap');

      for (var i = 0; i < objects.length - 1; i++) {
        expect(
          _replayDisplacement(objects[i], font: raw, size: 10),
          closeTo(150, _glyphSpaceUnit(10)),
          reason: 'justified line $i does not reach the right margin',
        );
      }
      // The last line is left alone; stretching it is the classic tell of a
      // layout engine that was not finished.
      expect(
        _replayDisplacement(objects.last, font: raw, size: 10),
        lessThan(150),
      );
    });

    test('an unjustified line is not stretched', () {
      const text = 'alpha beta gamma delta epsilon zeta eta theta iota';
      final doc = PayvDocument();
      final page = doc.addPage();

      page.textBox(
        text,
        rect: const PdfRect(40, 40, 150, 400),
        style: styleOf(size: 10),
      );

      for (final object in _textObjects(doc, page)) {
        expect(_replayDisplacement(object, font: raw, size: 10), lessThan(150));
      }
    });

    test('clipping wraps the whole box in one q/Q', () {
      final doc = PayvDocument();
      final page = doc.addPage();

      page.textBox(
        'Total due',
        rect: const PdfRect(40, 40, 200, 100),
        style: styleOf(),
        clip: true,
      );

      final content = _content(doc, page);
      expect(content, contains('40 40 200 100 re'));
      expect(content, contains('W\nn'));
    });
  });

  group('the document as a whole', () {
    /// Builds the same one-page document from scratch, twice.
    Uint8List build() {
      final doc = PayvDocument(title: 'Receipt', language: 'ckb');
      final page = doc.addPage();
      page.text('ژمارەی ناسنامە', x: 555, y: 780, style: styleOf(size: 14));
      page.text('Total due 125,000 IQD', x: 40, y: 760, style: styleOf());
      page.textBox(
        'ئەم بڕگەیە بۆ تاقیکردنەوەیە.',
        rect: const PdfRect(40, 600, 300, 120),
        style: styleOf(size: 11),
      );
      return doc.save();
    }

    test('the same document built twice is byte-identical', () {
      // No clock, no hash-order iteration, no floating-point path that depends
      // on allocation. A generated document that differs run to run cannot be
      // diffed, cached or checksummed by whoever has to audit it later.
      expect(build(), build());
    });

    test('save() finishes the fonts exactly once, before any code is asked '
        'for', () {
      final doc = PayvDocument();
      final page = doc.addPage();
      page.text('Receipt', x: 40, y: 700, style: styleOf());
      doc.save();

      // The fake asserts the ordering itself: use() throws after finishAll,
      // cidFor() throws before it.
      expect(_IdentityEncoder.created.single.finishCalls, 1);
    });

    test('a document with no text embeds nothing', () {
      final doc = PayvDocument();
      doc.addPage();
      doc.save();

      expect(_IdentityEncoder.created, isEmpty);
    });
  });

  group('end to end, on the REAL embedder', () {
    // Everything above fakes the encoder to keep the assertions about layout.
    // This group does not: it is the only place that proves the two halves
    // actually fit — that a glyph id the shaper produced survives subsetting,
    // renumbering and embedding, and comes out of a real file as a CID.
    setUp(() => TextEngine.encoderFactory = null);
    tearDown(() {
      TextEngine.encoderFactory = (document) {
        final encoder = _IdentityEncoder(document);
        _IdentityEncoder.created.add(encoder);
        return encoder;
      };
    });

    Uint8List buildReal() {
      final doc = PayvDocument(language: 'ckb', title: 'Receipt');
      final page = doc.addPage();
      page.text(
        'ژمارەی ناسنامە',
        x: 555,
        y: 780,
        style: TextStyle(font: newFont(), size: 14, language: 'ckb'),
      );
      page.text(
        'Total due 125,000 IQD',
        x: 40,
        y: 760,
        style: TextStyle(font: newFont(), size: 11),
      );
      return doc.save();
    }

    test('a Kurdish document embeds and saves', () {
      final pdf = buildReal();
      final text = latin1.decode(pdf, allowInvalid: true);

      expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
      expect(text, contains('/Identity-H'));
      expect(text, contains('/CIDFontType2'));
      expect(text, contains('/FontFile2'));
      expect(text, contains('/ToUnicode'));
    });

    test('the codes in the stream are SUBSET ids, not original glyph ids', () {
      final doc = PayvDocument();
      final page = doc.addPage();
      const text = 'ژمارەی ناسنامە';
      page.text(
        text,
        x: 555,
        y: 780,
        style: TextStyle(font: newFont(), size: 14),
      );
      doc.save();

      final codes = _codes(doc, page);
      final original = [for (final i in shaper.shape(text).infos) i.glyphId];

      int highest(List<int> ids) => ids.reduce((a, b) => a > b ? a : b);

      expect(codes.length, original.length);
      // If these were equal, subsetting did not happen and every document
      // would carry the whole 240 KB face.
      expect(codes, isNot(original));
      expect(
        highest(original),
        greaterThan(1000),
        reason: 'these are real Vazirmatn glyph ids',
      );
      // Renumbered into a subset of fifteen glyphs — a few more than were
      // drawn, because a composite glyph drags its components in with it.
      expect(highest(codes), lessThan(64));
    });

    test('the same real document built twice is byte-identical', () {
      expect(buildReal(), buildReal());
    });
  });

  group('LineBreaker', () {
    List<int> softBreaks(String text) => [
      for (final o in LineBreaker.opportunities(text))
        if (!o.mandatory) o.contentEnd,
    ];

    test('breaks after a space run, once', () {
      expect(softBreaks('ab  cd'), [4]);
    });

    test('does not break at a no-break space', () {
      expect(softBreaks('ab cd'), isEmpty);
    });

    test('breaks after a hyphen but not before a digit', () {
      expect(softBreaks('co-op'), [3]);
      expect(softBreaks('2026-08'), isEmpty);
    });

    test('breaks at a zero-width space, which is its only job', () {
      expect(softBreaks('ab​cd'), [3]);
    });

    test('never breaks between a letter and its mark', () {
      // The space is a break; the fatha after it is not.
      expect(softBreaks('ب بَ'), [2]);
    });

    test('CRLF is one mandatory break, not two', () {
      final mandatory = LineBreaker.opportunities(
        'a\r\nb',
      ).where((o) => o.mandatory).toList();
      expect(mandatory.length, 2); // the CRLF and the end of text
      expect(mandatory.first.contentEnd, 1);
      expect(mandatory.first.nextStart, 3);
    });

    test('trailing spaces are trimmed off a measured line', () {
      expect(LineBreaker.trimTrailing('ab   ', 0, 5), 2);
      expect(LineBreaker.trimTrailing('ab ', 0, 3), 3);
    });

    test('the end of the text is always a mandatory opportunity', () {
      final last = LineBreaker.opportunities('abc').last;
      expect(last.contentEnd, 3);
      expect(last.mandatory, isTrue);
    });
  });
}

/// Index of [needle] inside [haystack], or -1.
int _indexOfSublist(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return -1;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
}
