// Proves the PDF writer serialises identically on the VM and on the web.
//
// `payv` promises byte-determinism: the same document written twice produces
// the same bytes and the same `/ID`. That promise spans TARGETS as well as
// runs — a Flutter app can render the same receipt natively and in a browser,
// and a `/ID` that differs between them means one of the two files is not the
// file it says it is.
//
// Dart's numeric model is where that breaks. On dart2js and dart2wasm one
// JavaScript number backs both `int` and `double`, so `value is int` is TRUE
// for every integral double and a type test written for the VM silently routes
// the web down a different branch. That is defect O5: `1e21` serialised as
// `1e+21` (not a number in PDF at all) and `-0.0` as `-0.0` against the VM's
// `0`.
//
// Run it after touching anything in the serialisation path:
//
//   dart run tool/web_number_parity.dart > /tmp/vm.txt
//   dart compile js -O2 -o /tmp/probe.js tool/web_number_parity.dart
//   node /tmp/probe.js > /tmp/web.txt
//   diff /tmp/vm.txt /tmp/web.txt && echo IDENTICAL
//
// No `dart:io`: it has to compile to JavaScript, so output goes through
// `print`.
library;

import 'dart:typed_data';

import 'package:payv/src/pdf/object.dart';
import 'package:payv/src/util/ascii85.dart';
import 'package:payv/src/util/deflate.dart';

/// Numbers chosen for the boundaries, not for coverage: the integral doubles
/// the bad type test swallowed, both zeros, the 2^53 edge where `toInt()` stops
/// being exact, and the magnitudes where `toString` reaches for an exponent.
const List<num> _numbers = <num>[
  0,
  0.0,
  -0.0,
  1,
  -1,
  12.0,
  0.5,
  -2.25,
  1e-9,
  1e-7,
  0.0000001,
  1234567.891,
  9007199254740992.0,
  9007199254740993.0,
  1e21,
  -1e21,
  1e300,
  123456789012345678.0,
  0.1 + 0.2,
  1 / 3,
];

void main() {
  for (final v in _numbers) {
    // NOT `v.runtimeType`: that legitimately differs (`double` on the VM,
    // `int` on the web) and would drown the diff in noise. The bytes are the
    // contract, not the type that produced them.
    print('num -> ${pdfFormatNumber(v)}');
  }

  // A double that only a computation produces, which is how -0.0 reaches the
  // writer in practice: ContentStream.rotate(0.0) emits `-sin(0)`.
  print('neg zero -> ${pdfFormatNumber(-(0.0 * 1.0))}');

  print('text ascii -> ${encodePdfTextString('Receipt 2026').join(",")}');
  print('text kurdish -> ${encodePdfTextString('کۆی گشتی').join(",")}');

  final payload = Uint8List.fromList(
    List<int>.generate(1024, (i) => (i * 37 + (i >> 3)) & 0xFF),
  );
  final deflated = zlibDeflate(payload);
  print('deflate -> ${deflated.length} ${_sum(deflated)}');
  print('adler32 -> ${adler32(payload)}');
  print('ascii85 -> ${ascii85Encode(payload, lineWidth: 0).length}');
  print('ascii85 head -> ${ascii85Encode(payload).substring(0, 40)}');
  print('ascii85 round -> ${_sum(ascii85Decode(ascii85Encode(payload)))}');
}

int _sum(List<int> bytes) {
  var total = 0;
  for (final b in bytes) {
    total = (total + b * 31) & 0xFFFFFFF;
  }
  return total;
}
