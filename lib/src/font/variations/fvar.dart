/// `fvar` — the font variations table: what axes exist and where their
/// named instances sit.
///
/// Its real job in `payv` is [FvarTable.normalize]. A PDF cannot carry a
/// variable font — there is no way to tell a viewer which instance to draw — so
/// every export of a variable face pins a point in variation space first, and
/// that point has to be in the same normalised coordinates the rest of
/// OpenType uses.
library;

import '../../util/byte_reader.dart';
import '../../util/tag.dart';
import 'avar.dart';

/// One variation axis, in user coordinates (`wght` 100 … 900).
class VariationAxis {
  const VariationAxis({
    required this.tag,
    required this.minValue,
    required this.defaultValue,
    required this.maxValue,
    required this.flags,
    required this.nameId,
  });

  /// Packed 4-byte tag; compare against [Tag] constants.
  final int tag;
  final double minValue;
  final double defaultValue;
  final double maxValue;
  final int flags;

  /// `name` record holding the axis's display name.
  final int nameId;

  String get tagString => Tag(tag).asString;

  /// `HIDDEN_AXIS` — the axis exists but no UI should offer it.
  bool get isHidden => flags & 0x0001 != 0;

  @override
  String toString() =>
      'VariationAxis($tagString $minValue/$defaultValue/$maxValue)';
}

/// A named point in variation space ("SemiBold"), in user coordinates.
class NamedInstance {
  const NamedInstance({
    required this.coordinates,
    required this.subfamilyNameId,
    required this.postScriptNameId,
    required this.flags,
  });

  /// User-space values, one per axis, in the axis order of [FvarTable.axes].
  final List<double> coordinates;
  final int subfamilyNameId;

  /// 0 when the instance record omits it — the field is optional, and most
  /// fonts that do carry it store 0xFFFF meaning "none", which is normalised to
  /// 0 here so there is one "absent" value rather than three.
  final int postScriptNameId;
  final int flags;

  @override
  String toString() => 'NamedInstance($coordinates)';
}

/// A parsed `fvar` table.
class FvarTable {
  FvarTable._(this.axes, this.instances);

  static FvarTable parse(ByteReader r) {
    final base = r.position;
    final major = r.uint16At(base);
    if (major != 1) throw FontFormatException('fvar version $major is not 1');

    final axesArrayOffset = r.uint16At(base + 4);
    final axisCount = r.uint16At(base + 8);
    final axisSize = r.uint16At(base + 10);
    final instanceCount = r.uint16At(base + 12);
    final instanceSize = r.uint16At(base + 14);

    // The two `*Size` fields exist so that a later spec revision can grow a
    // record; a font is free to make them LARGER than we know about and we must
    // stride by the font's value, not by ours. Smaller is corrupt.
    if (axisSize < 20) {
      throw FontFormatException('fvar axisSize $axisSize is below 20');
    }
    if (instanceSize < axisCount * 4 + 4) {
      throw FontFormatException('fvar instanceSize $instanceSize is too small');
    }

    final axesAt = base + axesArrayOffset;
    if (!r.canRead(axesAt, axisCount * axisSize)) {
      throw const FontFormatException('fvar axis array overruns the font');
    }
    final axes = List<VariationAxis>.generate(axisCount, (i) {
      final p = axesAt + i * axisSize;
      return VariationAxis(
        tag: r.tagAt(p),
        minValue: r.fixedAt(p + 4),
        defaultValue: r.fixedAt(p + 8),
        maxValue: r.fixedAt(p + 12),
        flags: r.uint16At(p + 16),
        nameId: r.uint16At(p + 18),
      );
    }, growable: false);

    final instancesAt = axesAt + axisCount * axisSize;
    if (!r.canRead(instancesAt, instanceCount * instanceSize)) {
      throw const FontFormatException('fvar instance array overruns the font');
    }
    final hasPostScriptName = instanceSize >= axisCount * 4 + 6;
    final instances = List<NamedInstance>.generate(instanceCount, (i) {
      final p = instancesAt + i * instanceSize;
      final psId = hasPostScriptName
          ? r.uint16At(p + 4 + axisCount * 4)
          : 0xFFFF;
      return NamedInstance(
        subfamilyNameId: r.uint16At(p),
        flags: r.uint16At(p + 2),
        coordinates: List<double>.generate(
          axisCount,
          (a) => r.fixedAt(p + 4 + a * 4),
          growable: false,
        ),
        postScriptNameId: psId == 0xFFFF ? 0 : psId,
      );
    }, growable: false);

    return FvarTable._(axes, instances);
  }

  final List<VariationAxis> axes;
  final List<NamedInstance> instances;

  int get axisCount => axes.length;

  /// Index of the axis tagged [tag] (`'wght'`), or -1.
  int axisIndex(String tag) {
    for (var i = 0; i < axes.length; i++) {
      if (axes[i].tagString == tag) return i;
    }
    return -1;
  }

  /// Converts user-space axis values into normalised coordinates, applying the
  /// `avar` segment maps when [avar] is supplied.
  ///
  /// Axes the caller does not mention stay at their default, which normalises
  /// to exactly 0 — that is what makes `normalize(const {})` the identity
  /// instance rather than a subtly-off one.
  List<double> normalize(Map<String, double> axisValues, {ByteReader? avar}) {
    final out = List<double>.filled(axes.length, 0);
    for (var i = 0; i < axes.length; i++) {
      final a = axes[i];
      final v = (axisValues[a.tagString] ?? a.defaultValue).clamp(
        a.minValue,
        a.maxValue,
      );
      double n;
      if (v < a.defaultValue) {
        final range = a.defaultValue - a.minValue;
        n = range > 0 ? (v - a.defaultValue) / range : 0.0;
      } else if (v > a.defaultValue) {
        final range = a.maxValue - a.defaultValue;
        n = range > 0 ? (v - a.defaultValue) / range : 0.0;
      } else {
        n = 0.0;
      }
      out[i] = _quantize(n);
    }

    if (avar != null) {
      final map = AvarTable.parse(avar);
      for (var i = 0; i < out.length; i++) {
        out[i] = _quantize(map.map(i, out[i]));
      }
    }
    return out;
  }

  /// Snaps to the F2Dot14 grid.
  ///
  /// Not cosmetic. `avar`'s knots are themselves F2Dot14, so a float `wght` 700
  /// normalises to 0.6 and lands a hair off the 0.5999755859375 knot that the
  /// font pinned there — interpolating across the wrong segment and producing a
  /// weight nobody drew. HarfBuzz normalises in 2.14 integer space for exactly
  /// this reason; quantising at both ends of the `avar` hop matches it.
  static double _quantize(double v) {
    final q = (v * 16384.0).roundToDouble() / 16384.0;
    return q < -1.0 ? -1.0 : (q > 1.0 ? 1.0 : q);
  }
}
