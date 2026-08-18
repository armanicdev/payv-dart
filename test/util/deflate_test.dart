/// The honest test for a hand-written compressor: hand the output to a real
/// inflater and demand the original back.
///
/// `dart:io`'s `ZLibDecoder` is zlib itself, so a round trip through it is the
/// same bar a PDF reader applies. (`dart:io` is banned in `lib/` because this
/// package must run on the web; a test binds to no such thing.)
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:payv/src/util/deflate.dart';
import 'package:test/test.dart';

Uint8List _inflate(Uint8List bytes) =>
    Uint8List.fromList(ZLibDecoder().convert(bytes));

void _roundTrip(String label, Uint8List input, {int level = 6}) {
  final packed = zlibDeflate(input, level: level);
  expect(
    _inflate(packed),
    equals(input),
    reason: '$label did not survive a zlib round trip at level $level',
  );
}

void main() {
  group('adler32', () {
    test('matches the published checksum of "Wikipedia"', () {
      // The RFC-era worked example; a wrong-endian or wrong-modulo adler
      // still round-trips through some decoders but fails here.
      expect(adler32(utf8.encode('Wikipedia')), 0x11E60398);
    });

    test('seeds and stays inside 32 bits', () {
      final big = Uint8List(200000)..fillRange(0, 200000, 0xFF);
      final sum = adler32(big);
      expect(sum, greaterThan(0));
      expect(sum, lessThan(4294967296));
    });
  });

  group('zlib framing', () {
    test('emits a 0x78 CMF whose header divides by 31', () {
      for (var level = 0; level <= 9; level++) {
        final out = zlibDeflate(utf8.encode('hello'), level: level);
        expect(out[0], 0x78, reason: 'level $level CMF');
        expect((out[0] * 256 + out[1]) % 31, 0, reason: 'level $level FCHECK');
        expect(out[1] & 0x20, 0, reason: 'level $level must not set FDICT');
      }
    });

    test('rejects an out-of-range level', () {
      expect(() => zlibDeflate(Uint8List(0), level: 10), throwsArgumentError);
      expect(() => zlibDeflate(Uint8List(0), level: -1), throwsArgumentError);
    });
  });

  group('round trips', () {
    test('empty input', () {
      for (var level = 0; level <= 9; level++) {
        _roundTrip('empty', Uint8List(0), level: level);
      }
    });

    test('a single byte', () {
      for (var level = 0; level <= 9; level++) {
        _roundTrip('single', Uint8List.fromList([0x41]), level: level);
      }
    });

    test('every byte value once — no match is findable', () {
      final input = Uint8List(256);
      for (var i = 0; i < 256; i++) {
        input[i] = i;
      }
      for (var level = 0; level <= 9; level++) {
        _roundTrip('identity', input, level: level);
      }
    });

    test('one byte repeated 100k times — the longest-match extreme', () {
      final input = Uint8List(100000)..fillRange(0, 100000, 0x61);
      for (var level = 0; level <= 9; level++) {
        _roundTrip('runs', input, level: level);
      }
      // 100 KB of one byte has to collapse to almost nothing; if it does not,
      // the match finder is not finding matches and the round trip alone
      // would never say so.
      expect(zlibDeflate(input).length, lessThan(500));
    });

    test('a PDF content stream, which is the real payload', () {
      final buf = StringBuffer();
      for (var i = 0; i < 400; i++) {
        buf.writeln('BT /F1 12 Tf 1 0 0 1 ${i % 90} ${800 - i} Tm');
        buf.writeln('<0041004200430044> Tj ET');
        buf.writeln('0.2 0.2 0.2 rg 10 ${i % 700} 120 18 re f');
      }
      final input = Uint8List.fromList(utf8.encode(buf.toString()));
      for (var level = 0; level <= 9; level++) {
        _roundTrip('content stream', input, level: level);
      }
      expect(zlibDeflate(input).length, lessThan(input.length ~/ 4));
    });

    test('incompressible pseudo-random bytes', () {
      final rng = Random(20260818);
      final input = Uint8List.fromList(
        List<int>.generate(70000, (_) => rng.nextInt(256)),
      );
      for (var level = 0; level <= 9; level++) {
        _roundTrip('random', input, level: level);
      }
      // Random data must not INFLATE much: the stored-block fallback exists
      // exactly so a bad payload costs a few bytes of framing, not 5%.
      expect(zlibDeflate(input).length, lessThan(input.length + 512));
    });

    test('input larger than one token block, forcing multiple blocks', () {
      final rng = Random(7);
      final words = <String>[
        'شەقام',
        'کوردستان',
        'ڕێگا',
        'هەولێر',
        'PDF',
        'glyph',
        'lookup',
      ];
      final buf = StringBuffer();
      for (var i = 0; i < 60000; i++) {
        buf.write(words[rng.nextInt(words.length)]);
        buf.write(i % 13 == 0 ? '\n' : ' ');
      }
      final input = Uint8List.fromList(utf8.encode(buf.toString()));
      expect(input.length, greaterThan(400000));
      for (final level in [1, 3, 6, 9]) {
        _roundTrip('multi-block', input, level: level);
      }
    });

    test('data with matches at the far edge of the 32K window', () {
      final rng = Random(99);
      final head = List<int>.generate(4000, (_) => rng.nextInt(256));
      final middle = List<int>.generate(25000, (_) => rng.nextInt(256));
      final input = Uint8List.fromList([...head, ...middle, ...head]);
      for (final level in [1, 6, 9]) {
        _roundTrip('window edge', input, level: level);
      }
      // The tail is a verbatim copy 29000 bytes back — just inside the 32768
      // window, so it must actually be matched away rather than re-emitted.
      // Push the middle past 28768 and this match legitimately disappears,
      // which is how this assertion earned its numbers.
      expect(zlibDeflate(input).length, lessThan(input.length - 3500));
    });

    test('every length between 0 and 600 bytes', () {
      final rng = Random(4242);
      for (var n = 0; n <= 600; n++) {
        // Mixed entropy so short inputs exercise literals, matches and the
        // stored fallback rather than one path 600 times.
        final input = Uint8List.fromList(
          List<int>.generate(n, (i) => i % 7 == 0 ? rng.nextInt(256) : i % 5),
        );
        _roundTrip('length $n', input, level: 9);
      }
    });
  });

  test('rawDeflate output inflates as a raw stream', () {
    final input = utf8.encode('payv ' * 500);
    final raw = ZLibDecoder(raw: true).convert(rawDeflate(input));
    expect(Uint8List.fromList(raw), equals(input));
  });
}
