/// [PayvDocument] — the front door.
///
/// Wraps the font-agnostic PDF core with the text capability that is the point
/// of this package. The split is deliberate: `lib/src/pdf/` knows nothing about
/// fonts or shaping, so it stays small and independently correct, and every
/// piece of glyph knowledge lives above it.
library;

import 'dart:typed_data';

import '../layout/text_engine.dart' show MissingGlyph, TextEngine;
import '../pdf/content_stream.dart';
import '../pdf/document.dart';
import '../pdf/page.dart';
import 'text_style.dart';

/// Standard page sizes, in PDF points (1/72").
///
/// A4 is 595.276 × 841.89 pt, not 595 × 842. Rounding it is the reason so many
/// generated PDFs print with a hairline margin error.
class PageFormat {
  const PageFormat(this.width, this.height);

  static const PageFormat a3 = PageFormat(841.89, 1190.55);
  static const PageFormat a4 = PageFormat(595.276, 841.89);
  static const PageFormat a5 = PageFormat(419.53, 595.276);
  static const PageFormat a6 = PageFormat(297.64, 419.53);
  static const PageFormat letter = PageFormat(612, 792);
  static const PageFormat legal = PageFormat(612, 1008);

  /// A 80 mm thermal receipt roll, unbounded in height until you set it.
  static const PageFormat receipt80mm = PageFormat(226.77, 0);

  final double width;
  final double height;

  PageFormat get landscape =>
      width >= height ? this : PageFormat(height, width);

  PageFormat get portrait => height >= width ? this : PageFormat(height, width);

  PageFormat copyWith({double? width, double? height}) =>
      PageFormat(width ?? this.width, height ?? this.height);

  @override
  String toString() => 'PageFormat($width×$height pt)';
}

/// A PDF being built.
class PayvDocument {
  PayvDocument({
    bool compress = true,
    this.title,
    this.author,
    this.subject,
    this.creator,

    /// BCP-47 tag written to the catalog's `/Lang`. Set it — a document whose
    /// language a reader cannot determine gets read aloud in the wrong one.
    this.language,
  }) : _pdf = PdfDocument(compress: compress) {
    _pdf.setMetadata(
      title: title,
      author: author,
      subject: subject,
      creator: creator,
      producer: producerString,
    );
    _pdf.lang = language;
  }

  /// Identifies this library in `/Producer`. Honest provenance in the file
  /// itself matters for a document that gets archived: whoever audits it later can tell
  /// what generated it.
  static const String producerString = 'payv (pure-Dart OpenType + PDF)';

  final PdfDocument _pdf;
  final List<PayvPage> _pages = <PayvPage>[];
  late final TextEngine _engine = TextEngine(_pdf);

  final String? title;
  final String? author;
  final String? subject;
  final String? creator;
  final String? language;

  List<PayvPage> get pages => List.unmodifiable(_pages);

  /// Called for every character the font cannot draw.
  ///
  /// By default a missing glyph throws [MissingGlyphException] — loud, because
  /// the alternative every other library picks is to draw `.notdef` and carry
  /// on, which ships a document with a hole in someone's name that nobody ever
  /// notices.
  ///
  /// Installing a handler switches that off and draws `.notdef` instead. Do it
  /// deliberately, and only where NO document is worse than an imperfect one —
  /// a payment receipt, say, which its recipient needs whether or not one
  /// character of their address is outside the face's coverage. The handler is
  /// how you still find out.
  set onMissingGlyph(void Function(MissingGlyph glyph)? handler) =>
      _engine.onMissingGlyph = handler;

  void Function(MissingGlyph glyph)? get onMissingGlyph =>
      _engine.onMissingGlyph;

  PayvPage addPage({PageFormat format = PageFormat.a4}) {
    final page = PayvPage._(
      _pdf.addPage(width: format.width, height: format.height),
      _engine,
      format,
    );
    _pages.add(page);
    return page;
  }

  /// Serialises the document.
  ///
  /// Fonts are subsetted here, not per page — a face used on forty pages is
  /// embedded once, containing the union of the glyphs all of them used.
  Uint8List save() {
    _engine.embedFonts();
    return _pdf.save();
  }
}

/// One page, with text.
class PayvPage {
  PayvPage._(this._page, this._engine, this.format);

  final PdfPage _page;
  final TextEngine _engine;
  final PageFormat format;

  double get width => _page.width;

  double get height => _page.height;

  /// The raw content stream, for drawing that this package does not wrap
  /// (paths, images, clipping). Text drawn through here will NOT be shaped —
  /// use [text] or [textBox].
  ContentStream get graphics => _page.content;

  /// Draws a single line at a baseline origin, shaping and embedding as needed.
  ///
  /// [x] and [y] are the baseline START of the line — its left edge for LTR
  /// text and its RIGHT edge for RTL. That is what "start" means, and it is why
  /// laying out a bilingual document does not need a conditional at every call
  /// site.
  ///
  /// The line is not wrapped and not clipped; use [textBox] for either.
  TextMetrics text(
    String text, {
    required double x,
    required double y,
    required TextStyle style,
    PayvTextDirection direction = PayvTextDirection.auto,
  }) => _engine.drawLine(
    page: _page,
    text: text,
    x: x,
    y: y,
    style: style,
    direction: direction,
  );

  /// Lays text out inside [rect], wrapping at word boundaries.
  ///
  /// Returns the text that did NOT fit, or null when everything did — so
  /// flowing a long document across pages is a loop, not a guess.
  String? textBox(
    String text, {
    required PdfRect rect,
    required TextStyle style,
    PayvTextAlign align = PayvTextAlign.start,
    PayvTextDirection direction = PayvTextDirection.auto,
    bool clip = false,
  }) => _engine.drawBox(
    page: _page,
    text: text,
    rect: rect,
    style: style,
    align: align,
    direction: direction,
    clip: clip,
  );

  /// Measures without drawing. Same shaping path as [text], so the numbers
  /// agree with what would be drawn — a measure that uses a cheaper path is
  /// how tables end up one pixel off.
  TextMetrics measure(
    String text, {
    required TextStyle style,
    PayvTextDirection direction = PayvTextDirection.auto,
  }) => _engine.measure(text: text, style: style, direction: direction);
}
