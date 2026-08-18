// A one-page type specimen, written as real vector text.
//
//     dart run example/payv_example.dart path/to/YourFont.ttf
//
// Open the PDF, select the Kurdish, and paste it somewhere. You get the same
// characters back, in the same order — because every word on the page is text,
// not a picture of text. Zoom to 800% and nothing pixelates.
//
// Each word below contains at least one glyph that has no Unicode codepoint at
// all, reachable only by executing the font's own GSUB lookups. See
// doc/DESIGN.md for why that matters.
import 'dart:io';

import 'package:payv/payv.dart';

/// One word per form-less Sorani letter, with the letter it demonstrates.
const _specimens = <(String, String)>[
  ('ڕ', 'گۆڕینی'),
  ('ڵ', 'پاڵاوتن'),
  ('ە', 'پەیڤ'),
  ('ێ', 'ڕێگە'),
];

void main(List<String> args) async {
  final fontPath = args.isNotEmpty ? args.first : 'test/fonts/Vazirmatn.ttf';
  final fontFile = File(fontPath);
  if (!fontFile.existsSync()) {
    stderr.writeln(
      'Font not found: $fontPath\n'
      'Pass a Kurdish-capable OpenType font, e.g. Vazirmatn:\n'
      '  dart run example/payv_example.dart /path/to/Vazirmatn.ttf',
    );
    exit(1);
  }

  final font = PayvFont.load(fontFile.readAsBytesSync());

  // Enforced, not merely reported: a font whose fsType bits forbid embedding is
  // refused rather than embedded anyway and left as your legal problem.
  if (!font.canEmbedInPdf) {
    stderr.writeln('${font.familyName} forbids PDF embedding (fsType).');
    exit(1);
  }

  final regular = font.weight(400);
  final bold = font.weight(700);
  const ink = PdfColor.rgb(0.07, 0.07, 0.10);
  const muted = PdfColor.gray(0.55);

  final doc = PayvDocument(
    title: 'payv — specimen',
    author: 'payv',
    language: 'ckb', // so a screen reader picks the right voice
  );
  final page = doc.addPage(format: PageFormat.a4);

  final left = 56.0;
  final right = page.width - 56; // an RTL run starts at the right margin
  var y = page.height - 132;

  // The package's own name, at display size.
  page.text(
    'پەیڤ',
    x: right,
    y: y,
    style: TextStyle(font: bold, size: 76, color: ink),
  );

  y -= 34;
  page.text(
    'payv · pure-Dart OpenType shaping',
    x: left,
    y: y,
    style: TextStyle(font: regular, size: 11, color: muted),
  );

  y -= 26;
  page.graphics
    ..setStrokeColor(const PdfColor.gray(0.86))
    ..setLineWidth(0.75)
    ..moveTo(left, y)
    ..lineTo(right, y)
    ..stroke();

  // Four letters, four words. None of these shapes exists as a Unicode
  // codepoint; each one is the output of a GSUB lookup.
  y -= 56;
  for (final (letter, word) in _specimens) {
    page.text(
      word,
      x: right,
      y: y,
      style: TextStyle(font: regular, size: 34, color: ink),
    );
    page.text(
      'U+${letter.runes.first.toRadixString(16).toUpperCase().padLeft(4, '0')}'
      '  $letter',
      x: left,
      y: y + 8,
      style: TextStyle(font: regular, size: 10, color: muted),
    );
    y -= 62;
  }

  // Mixed direction on one line: Kurdish, Latin and Arabic-Indic digits, with
  // no conditional at the call site — `x` is where the run STARTS.
  y -= 4;
  page.text(
    'کوردی · payv ٠.١.٠',
    x: right,
    y: y,
    style: TextStyle(
      font: regular,
      size: 16,
      color: ink,
      features: const [FontFeature.tabularFigures],
    ),
  );

  // A wrapped paragraph, to exercise line breaking.
  y -= 52;
  page.graphics
    ..setStrokeColor(const PdfColor.gray(0.86))
    ..setLineWidth(0.75)
    ..moveTo(left, y)
    ..lineTo(right, y)
    ..stroke();

  y -= 26;
  page.textBox(
    'Every word on this page is a real vector outline, selectable and '
    'searchable, laid out by executing the font’s own GSUB and GPOS '
    'tables. Try selecting the Kurdish above and pasting it somewhere: you '
    'get the same characters back, in the same order.',
    rect: PdfRect(left, y - 56, right - left, 56),
    style: TextStyle(font: regular, size: 10.5, lineHeight: 17, color: muted),
    align: PayvTextAlign.start,
  );

  final bytes = doc.save();
  final out = File('payv_specimen.pdf');
  await out.writeAsBytes(bytes);

  stdout
    ..writeln(
      'wrote ${out.path} (${(bytes.length / 1024).toStringAsFixed(1)} KB)',
    )
    ..writeln(r"check it: pdftotext payv_specimen.pdf - | grep 'پەیڤ'");
}
