# payv

[![CI](https://github.com/armanicdev/payv-dart/actions/workflows/ci.yml/badge.svg)](https://github.com/armanicdev/payv-dart/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/payv.svg)](https://pub.dev/packages/payv)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Pure-Dart OpenType shaping and vector PDF generation.

`payv` lays out text by executing a font's own `GSUB`/`GPOS` tables, the way
HarfBuzz does. That is what lets it reach glyphs with no Unicode codepoint —
and it is why Kurdish Sorani comes out right.

Zero runtime dependencies, no FFI, no platform channels. Runs on the VM, in
Flutter, on a server, in a CLI and on the web.

## Install

```bash
dart pub add payv
```

## Quick start

```dart
import 'dart:io';
import 'package:payv/payv.dart';

void main() async {
  final font = PayvFont.load(await File('Vazirmatn.ttf').readAsBytes());

  final doc = PayvDocument(title: 'پەیڤ', language: 'ckb');
  final page = doc.addPage(format: PageFormat.a4);

  // `x` is where the run STARTS — the right edge for RTL, the left for LTR.
  // A bilingual layout needs no conditional at the call site.
  page.text(
    'پەیڤ',
    x: page.width - 56,
    y: page.height - 120,
    style: TextStyle(font: font.weight(700), size: 48),
  );

  page.textBox(
    'گۆڕینی ڕووکار',
    rect: PdfRect(56, 560, page.width - 112, 80),
    style: TextStyle(font: font, size: 14, lineHeight: 24),
    align: PayvTextAlign.start,
  );

  await File('out.pdf').writeAsBytes(doc.save());
}
```

The output is real vector text — selectable, searchable, copy-pastable, sharp at
any zoom, and about 10 KB a page. `payv` embeds only the font you hand it, and
only the glyphs the document actually draws.

A full worked page is in [`example/`](example/payv_example.dart):

```bash
dart run example/payv_example.dart path/to/YourFont.ttf
```

### Shaping without the PDF half

```dart
final font = OpenTypeFont.parse(bytes);
final run = Shaper(font).shape('پاڵاوتن');

for (var i = 0; i < run.length; i++) {
  print('gid ${run.infos[i].glyphId}  +${run.positions[i].xAdvance}');
}
```

## Why it exists

Dart PDF libraries render Arabic script by swapping each letter for its Unicode
**presentation form** (`U+FB50–FDFF` / `U+FE70–FEFF`). Four letters Kurdish
Sorani needs have no presentation form at all:

| ڕ `U+0695` | ڵ `U+06B5` | ە `U+06D5` | ێ `U+06CE` |
|:---:|:---:|:---:|:---:|

Neither does the `ڵ`+`ا` ligature. A good Kurdish font supplies those shapes —
Vazirmatn keeps them at gid 474, 839, 896 — but they are reachable only as the
*output of a `GSUB` lookup*, never through `cmap`. A library that resolves
codepoints to glyphs is on the wrong side of that wall, and cannot spell this
package's own name.

The argument in full, with measurements and prior art:
[`doc/DESIGN.md`](doc/DESIGN.md).

## Supported

| | |
|---|---|
| **Shaping** | `GSUB` 1–8, `GPOS` 1–9, `GDEF`, extension lookups |
| **Arabic** | joining state machine, `fin2`/`fin3`/`med2`, transparent marks, ZWJ/ZWNJ, tatweel |
| **Bidi** | UAX #9, isolates and paired brackets |
| **Fonts** | TrueType `glyf`, composites, variable fonts (`fvar`/`gvar`/`avar`/`HVAR`) with static instancing, subsetting |
| **Output** | PDF 1.7, CIDFontType2 / Identity-H, `ToUnicode`, `/ActualText` |
| **Scripts** | Arabic, Kurdish Sorani, Persian, Urdu, Pashto, Sindhi, Uyghur, Syriac, N'Ko, Thaana, Adlam · Latin/Cyrillic/Greek via the default shaper |

Not yet: CFF/CFF2 outlines · Indic, Khmer and Myanmar shapers · tagged PDF
(PDF/UA) · encryption, forms, annotations beyond links.

## Correctness

Shaping is graded byte-exact against HarfBuzz — 53 corpus cases, 371 glyphs, 16
distinct GSUB-only glyphs — plus Unicode's own `BidiTest.txt` and
`BidiCharacterTest.txt`. Text extraction is deliberately *not* the gate: a
perfect `/ActualText` span can sit over completely wrong glyphs.

```bash
dart test              # everything
tool/fetch_ucd.sh      # the two bidi conformance suites (15 MB, not vendored)
```

Known defects and coverage gaps are written down:
[`doc/DEFECTS.md`](doc/DEFECTS.md).

## Font licensing

`payv` reads `OS/2.fsType` and refuses to embed a font whose bits forbid it,
rather than embedding it anyway and leaving you the legal problem. Those bits
are a foundry's machine-readable summary, not the licence — check the real one
for any font you did not author.

## Contributing

Issues and PRs welcome, particularly a CFF interpreter, more shapers and PDF/UA
structure trees. See [CONTRIBUTING.md](CONTRIBUTING.md); the one hard rule is
that `dart test --tags shaping` stays green.

## Licence

Apache-2.0 © [Armanic Studio](https://github.com/armanicdev).
Third-party attribution: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
