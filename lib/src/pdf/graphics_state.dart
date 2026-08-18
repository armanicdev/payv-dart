/// Colour, and the slice of PDF graphics state worth remembering.
///
/// The point of tracking state is one measurement that needs no measuring: a
/// page of body text sets the same fill colour and the same font before every
/// single `Tj`. Emitting `0 0 0 rg` a thousand times is a thousand times seven
/// bytes of content stream, deflated badly, for no visual difference at all.
library;

/// Which colour space a [PdfColor] lives in. PDF has no universal colour
/// operator — the space decides both the operator and the operand count.
enum PdfColorSpace { gray, rgb, cmyk }

/// A device colour. Components are 0.0–1.0, as PDF's operators take them.
class PdfColor {
  const PdfColor.gray(double level)
    : space = PdfColorSpace.gray,
      c0 = level,
      c1 = 0,
      c2 = 0,
      c3 = 0;

  const PdfColor.rgb(double r, double g, double b)
    : space = PdfColorSpace.rgb,
      c0 = r,
      c1 = g,
      c2 = b,
      c3 = 0;

  const PdfColor.cmyk(double c, double m, double y, double k)
    : space = PdfColorSpace.cmyk,
      c0 = c,
      c1 = m,
      c2 = y,
      c3 = k;

  /// From a packed `0xRRGGBB`. Every design system on the calling side stores
  /// colour that way, and dividing three channels by 255 at each call site is
  /// how a rounding difference sneaks between two supposedly identical inks.
  factory PdfColor.hex(int rgb) => PdfColor.rgb(
    ((rgb >> 16) & 0xFF) / 255.0,
    ((rgb >> 8) & 0xFF) / 255.0,
    (rgb & 0xFF) / 255.0,
  );

  static const PdfColor black = PdfColor.gray(0);
  static const PdfColor white = PdfColor.gray(1);

  final PdfColorSpace space;
  final double c0;
  final double c1;
  final double c2;
  final double c3;

  @override
  bool operator ==(Object other) =>
      other is PdfColor &&
      other.space == space &&
      other.c0 == c0 &&
      other.c1 == c1 &&
      other.c2 == c2 &&
      other.c3 == c3;

  @override
  int get hashCode => Object.hash(space, c0, c1, c2, c3);

  @override
  String toString() => switch (space) {
    PdfColorSpace.gray => 'PdfColor.gray($c0)',
    PdfColorSpace.rgb => 'PdfColor.rgb($c0, $c1, $c2)',
    PdfColorSpace.cmyk => 'PdfColor.cmyk($c0, $c1, $c2, $c3)',
  };
}

/// The parameters a content stream will skip re-emitting when unchanged.
///
/// Every field is nullable, and null means "never set in this stream", which
/// forces the first emission. That matters after `Q`: restoring a saved copy
/// restores the *reader's* state exactly, including the fields that were still
/// unknown when `q` ran, so the suppression can never diverge from the file.
///
/// Only replace-valued parameters live here. `cm` and `Tm` compose rather than
/// replace, so there is nothing to compare them against and they are always
/// emitted.
class PdfGraphicsState {
  PdfGraphicsState();

  PdfColor? fillColor;
  PdfColor? strokeColor;
  double? lineWidth;
  int? lineCap;
  int? lineJoin;
  double? miterLimit;

  /// The serialised dash operand (`[3 2] 0`), compared as text because that is
  /// cheaper and no less exact than comparing the array element-wise.
  String? dash;

  /// Text state. PDF puts all of this in the graphics state proper (§9.3), so
  /// it is saved and restored by `q`/`Q` along with everything else — which is
  /// exactly why it belongs in this object and not in some separate text
  /// tracker that would go stale on the first `Q`.
  String? fontName;
  double? fontSize;
  double? characterSpacing;
  double? wordSpacing;
  double? horizontalScaling;
  double? leading;
  double? textRise;
  int? textRenderMode;

  PdfGraphicsState copy() => PdfGraphicsState()
    ..fillColor = fillColor
    ..strokeColor = strokeColor
    ..lineWidth = lineWidth
    ..lineCap = lineCap
    ..lineJoin = lineJoin
    ..miterLimit = miterLimit
    ..dash = dash
    ..fontName = fontName
    ..fontSize = fontSize
    ..characterSpacing = characterSpacing
    ..wordSpacing = wordSpacing
    ..horizontalScaling = horizontalScaling
    ..leading = leading
    ..textRise = textRise
    ..textRenderMode = textRenderMode;
}
