/// The page content stream — PDF's graphics operators, typed.
///
/// The text side is deliberately raw: [setFontRaw] takes a resource name and
/// [showTextRaw] takes bytes that are already the font's own codes. Nothing
/// here knows what a glyph is. The font subsystem shapes a string, subsets a
/// face, allocates CIDs and then calls down into these two methods — so this
/// file stays the same size whether the document is Latin or Sorani.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'graphics_state.dart';
import 'object.dart';
import 'writer.dart';

export 'graphics_state.dart' show PdfColor, PdfColorSpace, PdfGraphicsState;

/// Text rendering modes (§9.3.6). [invisible] is the one that matters here: it
/// is how a searchable text layer is laid under drawn glyph outlines.
abstract final class PdfTextRenderMode {
  static const int fill = 0;
  static const int stroke = 1;
  static const int fillThenStroke = 2;
  static const int invisible = 3;
  static const int fillAndClip = 4;
  static const int strokeAndClip = 5;
  static const int fillStrokeAndClip = 6;
  static const int clip = 7;
}

class ContentStream {
  final PdfSink _out = PdfSink();
  final List<PdfGraphicsState> _stack = <PdfGraphicsState>[];

  PdfGraphicsState _state = PdfGraphicsState();
  bool _inText = false;
  int _markedDepth = 0;

  /// Bytes written so far. Useful to a caller deciding whether a page is full.
  int get length => _out.length;

  // ── state ───────────────────────────────────────────────────────────────────

  void save() {
    _stack.add(_state.copy());
    _op('q');
  }

  void restore() {
    if (_stack.isEmpty) {
      throw StateError('restore() without a matching save()');
    }
    _state = _stack.removeLast();
    _op('Q');
  }

  void transform(double a, double b, double c, double d, double e, double f) {
    _num(a);
    _num(b);
    _num(c);
    _num(d);
    _num(e);
    _num(f);
    _op('cm');
  }

  void translate(double x, double y) => transform(1, 0, 0, 1, x, y);

  void scale(double sx, double sy) => transform(sx, 0, 0, sy, 0, 0);

  /// Rotates by [radians] counter-clockwise about the current origin.
  void rotate(double radians) {
    final c = math.cos(radians);
    final s = math.sin(radians);
    transform(c, s, -s, c, 0, 0);
  }

  void setFillColor(PdfColor color) {
    if (_state.fillColor == color) return;
    _state.fillColor = color;
    _writeColor(color, stroke: false);
  }

  void setStrokeColor(PdfColor color) {
    if (_state.strokeColor == color) return;
    _state.strokeColor = color;
    _writeColor(color, stroke: true);
  }

  void setLineWidth(double width) {
    if (_state.lineWidth == width) return;
    _state.lineWidth = width;
    _num(width);
    _op('w');
  }

  /// 0 butt, 1 round, 2 projecting square.
  void setLineCap(int cap) {
    if (_state.lineCap == cap) return;
    _state.lineCap = cap;
    _num(cap);
    _op('J');
  }

  /// 0 miter, 1 round, 2 bevel.
  void setLineJoin(int join) {
    if (_state.lineJoin == join) return;
    _state.lineJoin = join;
    _num(join);
    _op('j');
  }

  void setMiterLimit(double limit) {
    if (_state.miterLimit == limit) return;
    _state.miterLimit = limit;
    _num(limit);
    _op('M');
  }

  /// An empty [pattern] means solid.
  void setDash(List<double> pattern, {double phase = 0}) {
    final encoded =
        '[${pattern.map(pdfFormatNumber).join(' ')}] '
        '${pdfFormatNumber(phase)}';
    if (_state.dash == encoded) return;
    _state.dash = encoded;
    _out.writeAscii(encoded);
    _out.writeByte(0x20);
    _op('d');
  }

  // ── paths ───────────────────────────────────────────────────────────────────

  void moveTo(double x, double y) {
    _num(x);
    _num(y);
    _op('m');
  }

  void lineTo(double x, double y) {
    _num(x);
    _num(y);
    _op('l');
  }

  /// Cubic Bézier to (x3, y3) with control points (x1, y1) and (x2, y2).
  void curveTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    _num(x1);
    _num(y1);
    _num(x2);
    _num(y2);
    _num(x3);
    _num(y3);
    _op('c');
  }

  void closePath() => _op('h');

  void rect(double x, double y, double width, double height) {
    _num(x);
    _num(y);
    _num(width);
    _num(height);
    _op('re');
  }

  void fill({bool evenOdd = false}) => _op(evenOdd ? 'f*' : 'f');

  void stroke() => _op('S');

  void closeAndStroke() => _op('s');

  void fillAndStroke({bool evenOdd = false}) => _op(evenOdd ? 'B*' : 'B');

  /// Ends the path without painting it — the `n` operator.
  void endPath() => _op('n');

  /// Intersects the clip with the current path and ends it.
  ///
  /// Emits `W n` together because `W` alone only *marks* the path for
  /// clipping; the clip does not take effect until a painting operator ends
  /// the path, and a stray unterminated path is a syntax error in the next
  /// operator rather than here.
  void clip({bool evenOdd = false}) {
    _op(evenOdd ? 'W*' : 'W');
    _op('n');
  }

  /// Path operators produced elsewhere — a glyph outline converted from
  /// `glyf`, already in the space the caller has set up. Must be ASCII PDF
  /// syntax; it is spliced in verbatim.
  void appendRawPath(String ops) {
    _out.writeAscii(ops);
    _out.writeByte(0x0A);
  }

  // ── text ────────────────────────────────────────────────────────────────────

  void beginText() {
    if (_inText) throw StateError('beginText() inside an open text object');
    _inText = true;
    _op('BT');
  }

  void endText() {
    if (!_inText) throw StateError('endText() without beginText()');
    _inText = false;
    _op('ET');
  }

  /// Sets the text matrix *and* the line matrix (`Tm`).
  ///
  /// There is no operator to set one without the other, and `BT` resets both
  /// to identity — so a run positioned before `BT` is a run drawn at the
  /// origin.
  void setTextMatrix(
    double a,
    double b,
    double c,
    double d,
    double e,
    double f,
  ) {
    _requireText('setTextMatrix');
    _num(a);
    _num(b);
    _num(c);
    _num(d);
    _num(e);
    _num(f);
    _op('Tm');
  }

  /// Moves to the next line, [tx]/[ty] from the start of the current one.
  void moveTextPosition(double tx, double ty) {
    _requireText('moveTextPosition');
    _num(tx);
    _num(ty);
    _op('Td');
  }

  void nextLine() {
    _requireText('nextLine');
    _op('T*');
  }

  void setTextRenderMode(int mode) {
    if (_state.textRenderMode == mode) return;
    _state.textRenderMode = mode;
    _num(mode);
    _op('Tr');
  }

  void setCharacterSpacing(double spacing) {
    if (_state.characterSpacing == spacing) return;
    _state.characterSpacing = spacing;
    _num(spacing);
    _op('Tc');
  }

  /// Extra space applied to byte 32 only.
  ///
  /// Worth knowing before reaching for it: with a two-byte CID encoding, PDF
  /// applies word spacing to the *single byte* 32, which never occurs on its
  /// own in a two-byte code — so this operator silently does nothing to shaped
  /// Arabic or Kurdish text. Space adjustment there belongs in the `TJ` array.
  void setWordSpacing(double spacing) {
    if (_state.wordSpacing == spacing) return;
    _state.wordSpacing = spacing;
    _num(spacing);
    _op('Tw');
  }

  /// Horizontal scaling as a percentage; 100 is normal.
  void setHorizontalScaling(double percent) {
    if (_state.horizontalScaling == percent) return;
    _state.horizontalScaling = percent;
    _num(percent);
    _op('Tz');
  }

  void setTextLeading(double leading) {
    if (_state.leading == leading) return;
    _state.leading = leading;
    _num(leading);
    _op('TL');
  }

  void setTextRise(double rise) {
    if (_state.textRise == rise) return;
    _state.textRise = rise;
    _num(rise);
    _op('Ts');
  }

  /// `Tf` with a resource name the caller already registered on the page.
  void setFontRaw(String name, double size) {
    if (_state.fontName == name && _state.fontSize == size) return;
    _state.fontName = name;
    _state.fontSize = size;
    PdfName(name).write(_out);
    _out.writeByte(0x20);
    _num(size);
    _op('Tf');
  }

  /// `Tj` with codes already in the font's own encoding.
  ///
  /// Written as a hex string, always. A one-byte encoding could use a literal
  /// string, but two-byte CIDs are full of NUL and parenthesis bytes, and one
  /// escaping bug there costs a whole page of text.
  void showTextRaw(Uint8List codes) {
    _requireText('showTextRaw');
    PdfHexString(codes).write(_out);
    _out.writeByte(0x20);
    _op('Tj');
  }

  /// `TJ`. Each part is either a [Uint8List] of codes or a [num] of kerning,
  /// in thousandths of an em, subtracted from the advance.
  void showTextAdjustedRaw(List<Object> parts) {
    _requireText('showTextAdjustedRaw');
    _out.writeByte(0x5B); // [
    for (final part in parts) {
      switch (part) {
        case final Uint8List codes:
          PdfHexString(codes).write(_out);
        case final num adjustment:
          _out.writeAscii(pdfFormatNumber(adjustment));
          _out.writeByte(0x20);
        default:
          throw ArgumentError.value(
            part,
            'parts',
            'a TJ array holds only Uint8List codes and numbers',
          );
      }
    }
    _out.writeAscii('] ');
    _op('TJ');
  }

  // ── marked content ──────────────────────────────────────────────────────────

  /// Opens a marked-content sequence — `BMC`, or `BDC` when [properties] is
  /// given.
  ///
  /// The reason this primitive exists at all: `/Span << /ActualText (…) >>`
  /// is the only way to tell a reader what a run of shaped glyphs *says* when
  /// the glyphs no longer correspond one-to-one to characters. A Sorani
  /// ligature drawn from a GSUB-only glyph has no codepoint to recover; copy,
  /// search and screen readers get the text from here or not at all.
  void beginMarkedContent(String tag, {PdfDict? properties}) {
    PdfName(tag).write(_out);
    _out.writeByte(0x20);
    if (properties == null) {
      _op('BMC');
    } else {
      properties.write(_out);
      _out.writeByte(0x20);
      _op('BDC');
    }
    _markedDepth++;
  }

  /// Opens a `/Span` that declares what the glyphs inside it SAY.
  ///
  /// The only channel a reader takes text from ahead of the glyphs themselves.
  /// A ligature carrying two codepoints has a correct `ToUnicode` entry and
  /// still extracts backwards — a reader reordering a visual RTL line back to
  /// logical order reverses that two-character expansion along with everything
  /// else, having no way to know the pair belongs to one glyph. Naming the text
  /// here is what fixes it: `پاڵاوتن` comes back as `پاڵاوتن`, not `پااڵوتن`.
  ///
  /// [text] is NOT protected from that bidi pass — readers reorder a span's
  /// replacement text exactly as they reorder glyphs — so it is the caller's
  /// job to hand over the order the glyphs are drawn in. `TextEngine._program`
  /// carries the measurement behind that.
  void beginActualText(String text) => beginMarkedContent(
    'Span',
    properties: PdfDict(<String, PdfObject>{
      'ActualText': PdfHexString.text(text),
    }),
  );

  void endMarkedContent() {
    if (_markedDepth == 0) {
      throw StateError('endMarkedContent() without a matching begin');
    }
    _markedDepth--;
    _op('EMC');
  }

  // ── output ──────────────────────────────────────────────────────────────────

  /// The finished stream body.
  ///
  /// Unbalanced `q`, `BT` or `BMC` throws rather than being papered over. A
  /// content stream that ends inside a text object is not a slightly wrong
  /// page — most readers abandon the page, and the failure surfaces far from
  /// the code that caused it.
  Uint8List build() {
    if (_inText) {
      throw StateError('content stream ended inside a text object');
    }
    if (_stack.isNotEmpty) {
      throw StateError(
        'content stream ended with ${_stack.length} unbalanced '
        'save() call(s)',
      );
    }
    if (_markedDepth != 0) {
      throw StateError('content stream ended inside a marked-content sequence');
    }
    return _out.toBytes();
  }

  // ── internals ───────────────────────────────────────────────────────────────

  void _requireText(String what) {
    if (!_inText) {
      throw StateError(
        '$what() is only valid between beginText() and '
        'endText()',
      );
    }
  }

  void _writeColor(PdfColor color, {required bool stroke}) {
    switch (color.space) {
      case PdfColorSpace.gray:
        _num(color.c0);
        _op(stroke ? 'G' : 'g');
      case PdfColorSpace.rgb:
        _num(color.c0);
        _num(color.c1);
        _num(color.c2);
        _op(stroke ? 'RG' : 'rg');
      case PdfColorSpace.cmyk:
        _num(color.c0);
        _num(color.c1);
        _num(color.c2);
        _num(color.c3);
        _op(stroke ? 'K' : 'k');
    }
  }

  void _num(num value) {
    _out.writeAscii(pdfFormatNumber(value));
    _out.writeByte(0x20);
  }

  /// Operators end with a newline rather than a space: it costs the same one
  /// byte, deflates identically, and makes a broken stream readable in a hex
  /// dump instead of one endless line.
  void _op(String op) {
    _out.writeAscii(op);
    _out.writeByte(0x0A);
  }
}
