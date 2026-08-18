// The one input ASCII85 cannot represent, and used to accept anyway.
//
// Five base-85 digits reach 85^5 − 1 = 4437053124; four bytes stop at
// 4294967295. Every value in the 142085829-wide gap is an encoding error under
// PDF §7.4.3, and masking it with `& 0xFF` produced four entirely plausible
// bytes — the quiet corruption the decoder's own doc comment says it exists to
// prevent.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:payv/src/util/ascii85.dart';
import 'package:test/test.dart';

void main() {
  test('the reviewer\'s reproduction throws instead of wrapping', () {
    // 'uuuuu' is 85^5 − 1. It used to decode to [8, 120, 14, 196].
    expect(() => ascii85Decode('uuuuu~>'), throwsFormatException);
  });

  test('the boundary is exact: s8W-! is the largest legal group', () {
    // 0xFFFFFFFF encodes as 's8W-!'; the next value up is over range.
    expect(ascii85Decode('s8W-!~>'), <int>[255, 255, 255, 255]);
    expect(() => ascii85Decode('s8W-"~>'), throwsFormatException);
  });

  test('an over-range group is caught mid-stream, not only at the end', () {
    expect(() => ascii85Decode('!!!!!uuuuu!!!!!~>'), throwsFormatException);
  });

  test('a padded partial group is never a false positive', () {
    // The decoder pads a short final group with 'u', which raises its value —
    // the guard must not fire on that. The padding only replaces digits that
    // were at most 84 to begin with, so it cannot push a legal tail over, and
    // this sweeps every 1- and 2-byte tail plus a sample of 3-byte ones to say
    // so out loud.
    for (var b = 0; b < 256; b++) {
      final one = Uint8List.fromList(<int>[b]);
      expect(ascii85Decode(ascii85Encode(one)), one);
      for (var c = 0; c < 256; c++) {
        final two = Uint8List.fromList(<int>[b, c]);
        expect(ascii85Decode(ascii85Encode(two)), two);
      }
    }
    final random = Random(85);
    for (var i = 0; i < 5000; i++) {
      final three = Uint8List.fromList(<int>[
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      ]);
      expect(ascii85Decode(ascii85Encode(three)), three);
    }
    // The largest 3-byte tail is the tightest case in the whole space.
    final max = Uint8List.fromList(<int>[255, 255, 255]);
    expect(ascii85Decode(ascii85Encode(max)), max);
  });

  test('the thrown error is a FormatException, as documented', () {
    expect(
      () => ascii85Decode('uuuuu~>'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('4437053124'),
        ),
      ),
    );
  });
}
