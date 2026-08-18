/// ASCII85 round trips, including the two special cases that get hand-rolled
/// implementations wrong: the `z` shorthand and the truncated final group.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:payv/src/util/ascii85.dart';
import 'package:test/test.dart';

void main() {
  test('encodes the canonical example', () {
    // Adobe's own worked example, minus the `<~` opener PDF does not use.
    expect(ascii85Encode(utf8.encode('Man ')), '9jqo^~>');
  });

  test('four zero bytes collapse to z', () {
    expect(ascii85Encode(Uint8List(4)), 'z~>');
    expect(ascii85Encode(Uint8List(8)), 'zz~>');
  });

  test('a partial final group encodes n+1 characters', () {
    for (var n = 1; n <= 3; n++) {
      final encoded = ascii85Encode(
        Uint8List.fromList(List<int>.generate(n, (i) => i + 1)),
      );
      expect(encoded.length, n + 1 + 2, reason: '$n leftover byte(s)');
    }
  });

  test('a trailing all-zero partial group does not become z', () {
    // `z` is legal only for a whole group; emitting it for a short tail adds
    // bytes that were never there.
    final encoded = ascii85Encode(Uint8List.fromList(<int>[1, 0, 0]));
    expect(encoded, isNot(contains('z')));
    expect(ascii85Decode(encoded), equals(<int>[1, 0, 0]));
  });

  test('round trips every length up to 300 bytes', () {
    for (var n = 0; n <= 300; n++) {
      final input = Uint8List.fromList(
        List<int>.generate(n, (i) => (i * 37 + i ~/ 4) & 0xFF),
      );
      expect(
        ascii85Decode(ascii85Encode(input)),
        equals(input),
        reason: 'length $n',
      );
    }
  });

  test('round trips bytes above 0x7F — the 32-bit overflow case', () {
    // A group starting 0xFF exceeds 2^31; a `<<` based encoder goes negative
    // here on the web and silently emits the wrong characters.
    final input = Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF, 0xFF, 0x80, 0x00]);
    expect(ascii85Decode(ascii85Encode(input)), equals(input));
  });

  test('wraps at the requested column and decodes across the breaks', () {
    final input = Uint8List.fromList(
      List<int>.generate(400, (i) => (i * 91) & 0xFF),
    );
    final encoded = ascii85Encode(input, lineWidth: 20);
    expect(encoded, contains('\n'));
    for (final line in encoded.split('\n')) {
      expect(line.length, lessThanOrEqualTo(20));
    }
    expect(ascii85Decode(encoded), equals(input));
  });

  test('unwrapped output has no line breaks', () {
    final input = Uint8List.fromList(List<int>.filled(200, 0x41));
    expect(ascii85Encode(input, lineWidth: 0), isNot(contains('\n')));
  });

  test('decoding tolerates white space and stops at the terminator', () {
    expect(ascii85Decode(' 9jq\no^ ~> trailing junk'), utf8.encode('Man '));
  });

  test('rejects malformed input rather than guessing', () {
    expect(() => ascii85Decode('9jqo^v~>'), throwsFormatException);
    expect(() => ascii85Decode('9~x'), throwsFormatException);
    expect(
      () => ascii85Decode('9jqo^9~>'),
      throwsFormatException,
      reason: 'a one-character trailing group encodes nothing',
    );
    expect(
      () => ascii85Decode('9z~>'),
      throwsFormatException,
      reason: 'z is only legal on a group boundary',
    );
  });
}
