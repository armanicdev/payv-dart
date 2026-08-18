/// The document: pages, metadata, and the one call that produces a file.
///
/// This is the whole public surface of the PDF half of `payv`. It knows about
/// pages and resources; it does not know about fonts. A font is embedded by
/// adding objects through [writer] and registering them through [addResource],
/// which is the same door any other resource comes through.
library;

import 'dart:typed_data';

import 'object.dart';
import 'page.dart';
import 'writer.dart';

/// Page sizes in points, for callers who would otherwise hard-code 595.
abstract final class PdfPageSize {
  static const double a4Width = 595.276; // 210 mm
  static const double a4Height = 841.89; // 297 mm
  static const double a5Width = 419.528;
  static const double a5Height = 595.276;
  static const double letterWidth = 612;
  static const double letterHeight = 792;

  /// Roughly 80 mm, the width of a till-roll receipt printer. Named because
  /// this package exists to print bills.
  static const double receipt80mmWidth = 226.772;
}

class PdfDocument {
  PdfDocument({bool compress = true}) : writer = PdfWriter(compress: compress);

  /// The object allocator. The font subsystem writes through this: it adds a
  /// `FontFile2` stream, a descriptor, a descendant font and a `ToUnicode`
  /// CMap, then hands the top-level font reference to [addResource].
  final PdfWriter writer;

  final List<PdfPage> _pages = <PdfPage>[];

  List<PdfPage> get pages => List<PdfPage>.unmodifiable(_pages);

  /// The document's natural language, as a BCP 47 tag (`ckb`, `ar`, `en-GB`).
  ///
  /// Not decoration: a reader hands this to a screen reader to pick a voice,
  /// and a PDF/UA validator fails a document without it. For a Kurdish
  /// document it is also the only signal in the file that the text is not
  /// Arabic.
  String? lang;

  /// Seeds the `/ID` when set; otherwise the identifier is derived from the
  /// file's own bytes. Either way the output is reproducible.
  String? documentId;

  String? _title;
  String? _author;
  String? _subject;
  String? _creator;
  String? _producer;
  DateTime? _created;

  Uint8List? _saved;

  /// Adds a page. Dimensions are in points; the default is A4 portrait.
  PdfPage addPage({
    double width = PdfPageSize.a4Width,
    double height = PdfPageSize.a4Height,
  }) {
    if (_saved != null) {
      throw StateError('cannot add a page after save()');
    }
    final page = PdfPage(ref: writer.reserve(), width: width, height: height);
    _pages.add(page);
    return page;
  }

  /// Registers an object on [page] as a resource and returns the name the
  /// content stream should use — `('Font', ref)` gives back `'F1'`.
  ///
  /// Category-agnostic on purpose. The moment this method grows a `addFont`
  /// sibling, the writer has a font-shaped dependency and can no longer be
  /// tested, or reused, without one.
  String addResource(PdfPage page, String category, PdfRef ref) =>
      page.addResource(category, ref);

  void setMetadata({
    String? title,
    String? author,
    String? subject,
    String? creator,
    String? producer,
    DateTime? created,
  }) {
    _title = title ?? _title;
    _author = author ?? _author;
    _subject = subject ?? _subject;
    _creator = creator ?? _creator;
    _producer = producer ?? _producer;
    _created = created ?? _created;
  }

  /// Serialises the document. Idempotent — the bytes are built once and
  /// returned again on any later call, so handing the result to two sinks
  /// cannot produce two different files.
  Uint8List save() {
    final done = _saved;
    if (done != null) return done;
    if (_pages.isEmpty) {
      throw StateError('a PDF needs at least one page');
    }

    final pagesRef = writer.reserve();
    final kids = PdfArray();
    for (final page in _pages) {
      final contents = writer.add(PdfStream(PdfDict(), page.content.build()));
      writer.fill(
        page.ref,
        page.buildDictionary(parent: pagesRef, contents: contents),
      );
      kids.add(page.ref);
    }

    writer.fill(
      pagesRef,
      PdfDict(<String, PdfObject>{
        'Type': const PdfName('Pages'),
        'Kids': kids,
        'Count': PdfNumber(_pages.length),
      }),
    );

    final catalog = PdfDict(<String, PdfObject>{
      'Type': const PdfName('Catalog'),
      'Pages': pagesRef,
    });
    final language = lang;
    if (language != null) catalog['Lang'] = PdfString(language);

    return _saved = writer.build(
      catalog: writer.add(catalog),
      info: _infoDictionary(),
      documentId: documentId,
    );
  }

  /// The `/Info` dictionary.
  ///
  /// `/CreationDate` appears only when a caller supplied one. Reading the
  /// clock here would make every build of the same document a different file,
  /// which breaks golden tests and content-addressed caching for the sake of a
  /// field nobody reads.
  PdfDict _infoDictionary() {
    final info = PdfDict();
    if (_title != null) info['Title'] = PdfString(_title!);
    if (_author != null) info['Author'] = PdfString(_author!);
    if (_subject != null) info['Subject'] = PdfString(_subject!);
    if (_creator != null) info['Creator'] = PdfString(_creator!);
    info['Producer'] = PdfString(_producer ?? 'payv');
    if (_created != null) info['CreationDate'] = PdfString.date(_created!);
    return info;
  }
}
