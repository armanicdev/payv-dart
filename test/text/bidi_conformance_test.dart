// The Unicode Consortium's own bidi conformance suites, run whole.
//
// `bidi_test.dart` proves the rules that matter to an invoice, by hand. This
// file proves the other 861,000 cases — every combination of bidi classes up
// to length four, every explicit-formatting and isolate permutation, and the
// annex's own worked examples — including the VISUAL ORDER, not just the
// levels. Hand-written cases cannot reach the overflow counters or a
// four-deep isolate nest; these do.
//
// The two data files are not checked in (they are ~7 MB of UCD text), so this
// suite SKIPS when they are absent rather than failing a fresh clone. Fetch
// them next to the other UCD files to arm it:
//
//   curl -o tool/ucd/BidiCharacterTest.txt \
//     https://www.unicode.org/Public/16.0.0/ucd/BidiCharacterTest.txt
//   curl -o tool/ucd/BidiTest.txt \
//     https://www.unicode.org/Public/16.0.0/ucd/BidiTest.txt
//
// Deliberately NOT tagged `@Tags(['conformance'])`: `dart test` warns on every
// run about a tag no `dart_test.yaml` declares, and this suite costs about a
// second. If a `dart_test.yaml` ever lands, tagging it there is free.
library;

import 'dart:io';

import 'package:payv/src/text/bidi.dart';
import 'package:payv/src/text/unicode.dart';
import 'package:test/test.dart';

const String _ucd = 'tool/ucd';

/// Visual order as a list of source indices, with the X9-removed characters
/// dropped — the exact shape both data files report.
List<int> _visualOrder(List<int> scalars, BidiResult r) {
  final out = <int>[];
  for (final run in r.visualRuns) {
    if (run.level.isOdd) {
      for (var i = run.end - 1; i >= run.start; i--) {
        out.add(i);
      }
    } else {
      for (var i = run.start; i < run.end; i++) {
        out.add(i);
      }
    }
  }
  return [
    for (final i in out)
      if (!BidiClass.isRemovedByX9(bidiClassOf(scalars[i]))) i,
  ];
}

/// Returns a failure description, or null when the case passes.
String? _check(
  List<int> scalars,
  int? paragraphLevel,
  int? expectedParagraphLevel,
  List<String> expectedLevels,
  List<int> expectedOrder,
) {
  final r = Bidi.resolve(scalars, paragraphLevel: paragraphLevel);
  if (expectedParagraphLevel != null &&
      r.paragraphLevel != expectedParagraphLevel) {
    return 'paragraph level ${r.paragraphLevel} != $expectedParagraphLevel';
  }
  for (var i = 0; i < expectedLevels.length; i++) {
    // 'x' marks a character rule X9 removes; the annex does not specify a
    // level for it, so neither file checks one.
    if (expectedLevels[i] == 'x') continue;
    if (r.levels[i] != int.parse(expectedLevels[i])) {
      return 'levels ${r.levels.join(" ")} != ${expectedLevels.join(" ")}';
    }
  }
  final order = _visualOrder(scalars, r).join(' ');
  if (order != expectedOrder.join(' ')) {
    return 'order [$order] != [${expectedOrder.join(" ")}]';
  }
  return null;
}

final RegExp _ws = RegExp(r'\s+');

/// One representative codepoint per bidi class, for BidiTest.txt's symbolic
/// input. Verified against the generated table before use — a stale
/// representative would silently test the wrong class for a million cases.
const Map<String, int> _representatives = <String, int>{
  'L': 0x006C,
  'R': 0x05D0,
  'AL': 0x0627,
  'EN': 0x0030,
  'ES': 0x002B,
  'ET': 0x0023,
  'AN': 0x0660,
  'CS': 0x002C,
  'NSM': 0x0300,
  'BN': 0x00AD,
  'B': 0x2029,
  'S': 0x0009,
  'WS': 0x0020,
  'ON': 0x0021,
  'LRE': 0x202A,
  'RLE': 0x202B,
  'LRO': 0x202D,
  'RLO': 0x202E,
  'PDF': 0x202C,
  'LRI': 0x2066,
  'RLI': 0x2067,
  'FSI': 0x2068,
  'PDI': 0x2069,
};

void main() {
  test('BidiCharacterTest.txt — every case, levels and visual order', () {
    final file = File('$_ucd/BidiCharacterTest.txt');
    if (!file.existsSync()) {
      markTestSkipped('$_ucd/BidiCharacterTest.txt not fetched');
      return;
    }

    var cases = 0;
    final failures = <String>[];
    for (final line in file.readAsLinesSync()) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final f = line.split(';');
      final scalars = [
        for (final h in f[0].trim().split(_ws)) int.parse(h, radix: 16),
      ];
      final direction = int.parse(f[1]);
      final order = f[4].trim();
      cases++;
      final problem = _check(
        scalars,
        direction == 2 ? null : direction, // 2 = auto, by P2/P3
        int.parse(f[2]),
        f[3].trim().split(_ws),
        order.isEmpty
            ? const <int>[]
            : [for (final v in order.split(_ws)) int.parse(v)],
      );
      if (problem != null && failures.length < 10) {
        failures.add('$line\n    $problem');
      }
    }

    expect(cases, greaterThan(90000), reason: 'data file looks truncated');
    expect(failures, isEmpty, reason: '${failures.length} case(s) failed');
  });

  test('BidiTest.txt — every class combination, levels and visual order', () {
    final file = File('$_ucd/BidiTest.txt');
    if (!file.existsSync()) {
      markTestSkipped('$_ucd/BidiTest.txt not fetched');
      return;
    }

    _representatives.forEach((name, cp) {
      expect(
        bidiClassNames[bidiClassOf(cp)],
        name,
        reason: 'U+${cp.toRadixString(16)} no longer stands for $name',
      );
    });

    var cases = 0;
    final failures = <String>[];
    var levels = <String>[];
    var order = <int>[];

    for (final line in file.readAsLinesSync()) {
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('@Levels:')) {
        final v = line.substring(8).trim();
        levels = v.isEmpty ? <String>[] : v.split(_ws);
        continue;
      }
      if (line.startsWith('@Reorder:')) {
        final v = line.substring(9).trim();
        order = v.isEmpty
            ? <int>[]
            : [for (final t in v.split(_ws)) int.parse(t)];
        continue;
      }
      if (line.startsWith('@')) continue;

      final f = line.split(';');
      final scalars = [
        for (final c in f[0].trim().split(_ws)) _representatives[c]!,
      ];
      final bitset = int.parse(f[1].trim(), radix: 16);
      // 1 = auto (P2/P3), 2 = LTR, 4 = RTL.
      for (final (mask, paragraphLevel) in const [(1, null), (2, 0), (4, 1)]) {
        if (bitset & mask == 0) continue;
        cases++;
        final problem = _check(scalars, paragraphLevel, null, levels, order);
        if (problem != null && failures.length < 10) {
          failures.add(
            '$line [para=${paragraphLevel ?? "auto"}]\n    $problem',
          );
        }
      }
    }

    expect(cases, greaterThan(700000), reason: 'data file looks truncated');
    expect(failures, isEmpty, reason: '${failures.length} case(s) failed');
  });
}
