/// A page: its geometry, its content stream, and its resource dictionary.
library;

import 'content_stream.dart';
import 'object.dart';

/// Short names given to each resource category.
///
/// Nothing requires `/F1` over `/Resource7` — the name is arbitrary and local
/// to one page. But every PDF ever written uses these initials, so a content
/// stream that follows the convention can be read by a human debugging it, and
/// that is worth a map.
const Map<String, String> _resourcePrefixes = <String, String>{
  'Font': 'F',
  'XObject': 'X',
  'ExtGState': 'GS',
  'Shading': 'Sh',
  'Pattern': 'P',
  'ColorSpace': 'CS',
  'Properties': 'MC',
};

class PdfPage {
  PdfPage({required this.ref, required this.width, required this.height});

  /// The object number this page will be written under. Allocated up front so
  /// a link, an outline entry or an annotation can point at the page before
  /// its dictionary exists.
  final PdfRef ref;

  /// Page size in points (1/72 inch).
  final double width;
  final double height;

  final ContentStream content = ContentStream();

  /// The page's `/Resources`, written inline in the page dictionary.
  final PdfDict resources = PdfDict();

  /// Extra page-dictionary entries — `/Annots`, `/Rotate`, `/Group`, `/Tabs`.
  ///
  /// Left as an open dictionary on purpose. This writer models the entries it
  /// needs and refuses to grow a typed accessor for every entry in Table 30;
  /// a caller who needs one knows its name.
  final PdfDict attributes = PdfDict();

  final Map<String, Map<PdfRef, String>> _names =
      <String, Map<PdfRef, String>>{};

  /// Registers [target] under [category] and returns the name the content
  /// stream should use.
  ///
  /// Idempotent per page: asking twice for the same object returns the same
  /// name rather than growing `/Font` an entry per call. That matters because
  /// the font subsystem calls this once per text run, not once per document.
  String addResource(String category, PdfRef target) {
    final byRef = _names.putIfAbsent(category, () => <PdfRef, String>{});
    final existing = byRef[target];
    if (existing != null) return existing;

    final prefix =
        _resourcePrefixes[category] ??
        (category.isEmpty ? 'R' : category.substring(0, 1).toUpperCase());
    final name = '$prefix${byRef.length + 1}';
    byRef[target] = name;
    resources.subDict(category)[name] = target;
    return name;
  }

  /// The page dictionary, built at save time. [parent] is the `/Pages` node
  /// and [contents] the stream object holding [content].
  PdfDict buildDictionary({required PdfRef parent, required PdfRef contents}) {
    final dict = PdfDict(<String, PdfObject>{
      'Type': const PdfName('Page'),
      'Parent': parent,
      'MediaBox': PdfArray.numbers(<num>[0, 0, width, height]),
      'Resources': resources,
      'Contents': contents,
    });
    for (final entry in attributes.entries.entries) {
      dict[entry.key] = entry.value;
    }
    return dict;
  }
}
