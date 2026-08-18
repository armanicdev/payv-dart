// The case that matters most here is the boring one: a space between two
// Kurdish words must NOT end the Arabic run. If it does, the joining state
// machine restarts at the second word and both words render with the wrong
// contextual forms — a bug that looks like a broken font, not like a broken
// itemizer.
import 'package:payv/src/text/script_itemizer.dart';
import 'package:payv/src/text/unicode.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

List<int> cps(String s) => toScalars(s).$1;

/// `(start, end, tag)` triples, for readable expectations.
List<String> shape(String s) => [
  for (final r in ScriptItemizer.itemize(cps(s)))
    '${r.start}-${r.end}:${Tag(r.scriptTag).asString}',
];

void main() {
  test('a single script is one run', () {
    expect(shape('hello'), ['0-5:latn']);
    expect(shape('سڵاو'), ['0-4:arab']);
  });

  test('a space between two Arabic words does not split the run', () {
    expect(shape('سڵاو هاوڕێ'), ['0-10:arab']);
  });

  test('Arabic punctuation and commas stay inside the Arabic run', () {
    expect(shape('کۆیە، هەولێر.'), ['0-13:arab']);
  });

  test('a script boundary cuts at the first character of the new script', () {
    // The space belongs to the run it follows.
    expect(shape('abc عربی'), ['0-4:latn', '4-8:arab']);
    expect(shape('عربی abc'), ['0-5:arab', '5-8:latn']);
  });

  test('leading common characters join the first real script', () {
    expect(shape('«عربی»'), ['0-6:arab']);
    expect(shape('  abc'), ['0-5:latn']);
  });

  test('combining marks inherit the run they sit in', () {
    // U+0651 SHADDA is Inherited; it must never start a run of its own.
    expect(shape('بّت'), ['0-3:arab']);
  });

  test('text with no strong script at all falls back to DFLT', () {
    expect(shape('125,000'), ['0-7:DFLT']);
    expect(shape(' '), ['0-1:DFLT']);
  });

  test('empty input yields no runs', () {
    expect(ScriptItemizer.itemize(const <int>[]), isEmpty);
  });

  test('Hiragana and Katakana share one run under the kana tag', () {
    expect(shape('ひらカタ'), ['0-4:kana']);
  });

  test('the required script tags map as specified', () {
    expect(shape('日本'), ['0-2:hani']);
    expect(shape('שלום'), ['0-4:hebr']);
    expect(shape('привет'), ['0-6:cyrl']);
    expect(shape('ελληνικά'), ['0-8:grek']);
    expect(shape('ไทย'), ['0-3:thai']);
    expect(shape('देवनागरी'), ['0-8:dev2']);
    expect(shape('ܣܘܪܝܝܐ'), ['0-6:syrc']);
    expect(shape('ߊߋ'), ['0-2:nko ']); // N'Ko, space-padded tag
    expect(shape('ދިވެހި'), ['0-6:thaa']);
    expect(shape('ᠠᠡ'), ['0-2:mong']);
    // Two Adlam scalars — four UTF-16 code units, but the run is 0-2.
    expect(shape('\u{1E900}\u{1E901}'), ['0-2:adlm']);
  });

  test('run bounds are scalar indices, not UTF-16 indices', () {
    // Adlam is astral: two scalars, four code units. A run reported in UTF-16
    // coordinates would slice the shaping buffer in the wrong place.
    final runs = ScriptItemizer.itemize(cps('a\u{1E900}'));
    expect(runs.length, 2);
    expect(runs.last.start, 1);
    expect(runs.last.end, 2);
  });
}
