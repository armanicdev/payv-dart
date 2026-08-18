/// The public text-styling value types.
///
/// These are the vocabulary a caller uses; everything below them
/// ([OpenTypeFont], the shaper, the PDF writer) is internal. Keeping the public
/// surface this thin is deliberate — it is what lets the engine underneath be
/// rewritten without breaking a consumer.
library;

import 'dart:typed_data';

import '../font/open_type_font.dart';
import '../pdf/graphics_state.dart' show PdfColor;
import '../util/tag.dart';

/// A loaded font face, ready to lay out and embed.
///
/// Wraps [OpenTypeFont] with the two things a document author actually needs:
/// a variation instance, and an honest answer about whether the licence permits
/// embedding.
class PayvFont {
  PayvFont._(this.raw, this._axisValues);

  /// Parses a font file. Cheap — only the table directory is read up front.
  ///
  /// [fontIndex] selects a face from a TrueType Collection.
  factory PayvFont.load(Uint8List bytes, {int fontIndex = 0}) =>
      PayvFont._(OpenTypeFont.parse(bytes, fontIndex: fontIndex), const {});

  /// The underlying parsed font. Public because this package is meant to be
  /// built on, not just called — a consumer writing their own layout engine
  /// should not have to fork us to reach the tables.
  final OpenTypeFont raw;

  final Map<String, double> _axisValues;

  /// This face at a point in its variation space, e.g. `font.variation({'wght': 600})`.
  ///
  /// A PDF cannot carry a variable font — the format has no way to tell a viewer
  /// which instance to draw — so a variable face is instanced to a static one at
  /// embed time. Calling this pins which instance that will be; without it, the
  /// font's own default instance is used.
  PayvFont variation(Map<String, double> axisValues) {
    final coords = raw.normalizeAxisValues(axisValues);
    return PayvFont._(raw.withVariationCoords(coords), {
      ..._axisValues,
      ...axisValues,
    });
  }

  /// A weight shorthand for the common case. Equivalent to
  /// `variation({'wght': weight})` when the face has a `wght` axis; a no-op
  /// otherwise, so calling it on a static font is harmless.
  PayvFont weight(double weight) =>
      raw.isVariable && _hasAxis('wght') ? variation({'wght': weight}) : this;

  bool _hasAxis(String tag) =>
      raw.fvar?.axes.any((a) => Tag(a.tag).asString.trim() == tag) ?? false;

  Map<String, double> get axisValues => Map.unmodifiable(_axisValues);

  String? get familyName => raw.name?.familyName;

  String? get subfamilyName => raw.name?.subfamilyName;

  String? get postScriptName => raw.name?.postScriptName;

  int get unitsPerEm => raw.unitsPerEm;

  bool get isVariable => raw.isVariable;

  /// Whether the font's own `OS/2.fsType` bits permit embedding it in a PDF.
  ///
  /// This is checked and REFUSED at embed time, not merely reported. A font
  /// whose licence forbids embedding is a legal problem for whoever ships the
  /// document, and silently embedding it anyway — which most PDF libraries
  /// do — makes us the cause of it.
  ///
  /// Note this reads the font's *bits*, which are a machine-readable summary a
  /// foundry sets, not the licence itself. A permissive bit does not override a
  /// restrictive EULA; check the actual licence for any font you did not author.
  bool get canEmbedInPdf => raw.os2?.allowsEmbedding ?? true;

  /// Whether the licence bits permit embedding a SUBSET. Some faces allow full
  /// embedding but forbid subsetting (`fsType` bit 8).
  bool get canSubset => raw.os2?.allowsSubsetting ?? true;

  /// The licence text the font declares (`name` id 13), if any. Vazirmatn
  /// carries OFL 1.1 here; a font that carries nothing is worth investigating
  /// before you ship it inside a document.
  String? get licenseDescription => raw.name?.licenseDescription;

  String? get licenseUrl => raw.name?.licenseUrl;

  @override
  String toString() =>
      'PayvFont(${familyName ?? "?"}'
      '${_axisValues.isEmpty ? "" : " $_axisValues"})';
}

/// How text is drawn.
class TextStyle {
  const TextStyle({
    required this.font,
    this.size = 12,
    this.color = PdfColor.black,
    this.letterSpacing = 0,
    this.wordSpacing = 0,
    this.lineHeight,
    this.features = const <FontFeature>[],
    this.language,
    this.renderMode = TextRenderMode.fill,
  });

  final PayvFont font;

  /// Em size in PDF points.
  final double size;

  final PdfColor color;

  /// Extra space after every glyph, in points. Applied through the PDF `Tc`
  /// operator, so a viewer's own justification stays consistent with ours.
  final double letterSpacing;

  /// Extra space after every space glyph, in points (`Tw`).
  ///
  /// Careful: PDF's `Tw` applies to single-byte code 32 ONLY, which with an
  /// Identity-H encoding never occurs. The layout engine therefore applies word
  /// spacing itself, per glyph, and does not emit `Tw`.
  final double wordSpacing;

  /// Baseline-to-baseline distance in points. Defaults to the font's own
  /// `hhea` line spacing scaled to [size].
  final double? lineHeight;

  /// OpenType features to force on or off, e.g. `FontFeature.tabularFigures`.
  final List<FontFeature> features;

  /// BCP-47 language tag, mapped to an OpenType language system. This matters
  /// more than it looks: a font's `locl` feature can substitute different
  /// glyphs for Kurdish than for Arabic or Persian for the SAME codepoint.
  final String? language;

  final TextRenderMode renderMode;

  TextStyle copyWith({
    PayvFont? font,
    double? size,
    PdfColor? color,
    double? letterSpacing,
    double? wordSpacing,
    double? lineHeight,
    List<FontFeature>? features,
    String? language,
    TextRenderMode? renderMode,
  }) => TextStyle(
    font: font ?? this.font,
    size: size ?? this.size,
    color: color ?? this.color,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    wordSpacing: wordSpacing ?? this.wordSpacing,
    lineHeight: lineHeight ?? this.lineHeight,
    features: features ?? this.features,
    language: language ?? this.language,
    renderMode: renderMode ?? this.renderMode,
  );
}

/// An OpenType feature toggle.
class FontFeature {
  const FontFeature(this.feature, [this.value = 1]);

  const FontFeature.enable(this.feature) : value = 1;

  const FontFeature.disable(this.feature) : value = 0;

  /// Tabular figures — every digit the same width. Essential on an invoice:
  /// without it, a column of amounts does not line up.
  static const FontFeature tabularFigures = FontFeature('tnum');

  static const FontFeature proportionalFigures = FontFeature('pnum');
  static const FontFeature liningFigures = FontFeature('lnum');
  static const FontFeature oldStyleFigures = FontFeature('onum');
  static const FontFeature slashedZero = FontFeature('zero');
  static const FontFeature standardLigatures = FontFeature('liga');
  static const FontFeature discretionaryLigatures = FontFeature('dlig');
  static const FontFeature smallCaps = FontFeature('smcp');

  /// A 4-character OpenType feature tag.
  final String feature;

  /// 0 disables; 1 enables; higher values select an alternate for features that
  /// offer several (`salt`, `ss01`…).
  final int value;

  int get tag => Tag.parse(feature);
}

/// PDF text rendering modes (`Tr`).
enum TextRenderMode {
  fill(0),
  stroke(1),
  fillAndStroke(2),

  /// Paints no ink. Used to lay a searchable text layer over an image — the old
  /// approach this package replaces, kept because it is still the right answer
  /// for a scanned document.
  invisible(3),

  fillAndClip(4),
  strokeAndClip(5),
  fillStrokeAndClip(6),
  clip(7);

  const TextRenderMode(this.value);

  final int value;
}

/// Horizontal alignment within a text box.
///
/// [start] and [end] follow the resolved paragraph direction; [left] and
/// [right] are physical. On a bilingual document you almost always want
/// [start] — it does the right thing in both an English and a Kurdish column
/// without a conditional.
enum PayvTextAlign { start, end, left, right, center, justify }

/// Requested paragraph direction.
enum PayvTextDirection {
  ltr,
  rtl,

  /// Resolve per UAX #9 rule P2/P3 — the first strong character wins. This is
  /// the right default for user-supplied text of unknown language.
  auto,
}

/// What [PayvPage.measure] and the draw calls report back, in points.
class TextMetrics {
  const TextMetrics({
    required this.width,
    required this.ascent,
    required this.descent,
    required this.lineHeight,
    required this.glyphCount,
  });

  final double width;

  /// Distance from the baseline UP to the top of the text. Positive.
  final double ascent;

  /// Distance from the baseline DOWN. Positive.
  final double descent;

  final double lineHeight;
  final int glyphCount;

  double get height => ascent + descent;

  @override
  String toString() =>
      'TextMetrics(${width.toStringAsFixed(2)}×${height.toStringAsFixed(2)}pt, '
      '$glyphCount glyphs)';
}

/// A rectangle in PDF user space (origin bottom-left, y grows upward).
///
/// PDF's coordinate system, not a screen's. This trips up everyone once; the
/// type is named plainly and documented here rather than silently flipped,
/// because a library that quietly flips y is worse than one that does not.
class PdfRect {
  const PdfRect(this.x, this.y, this.width, this.height);

  /// Constructs from a TOP-left origin and a page height, for callers thinking
  /// in screen coordinates.
  factory PdfRect.fromTop({
    required double x,
    required double top,
    required double width,
    required double height,
    required double pageHeight,
  }) => PdfRect(x, pageHeight - top - height, width, height);

  final double x, y, width, height;

  double get left => x;
  double get bottom => y;
  double get right => x + width;
  double get top => y + height;

  @override
  String toString() => 'PdfRect($x, $y, $width × $height)';
}
