// Models of the CRUD guarantee tests (T4): a soft-delete + timestamps table, a table with a time to live, a plain
// table with an ISO DateTime format.
import 'package:fluent_sqflite/src/internal.dart';

/// Soft delete + timestamps; an instance may carry a `timeToLive`.
class Doc extends FluentStorable with FluentSoftDeletable, FluentTimestamps {
  Doc({this.id, this.title = '', this.qty = 0, this.note, this.code, this.flag, this.seen, super.timeToLive});

  int? id;
  String title;
  int qty;
  String? note;
  String? code;
  bool? flag;
  DateTime? seen;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'qty': qty, 'note': note, 'code': code, 'flag': flag, 'seen': seen};

  @override
  List<FluentDbColumn> get tableSchema => [
    FluentDbColumn.integer('id'),
    FluentDbColumn.text('title', isNotNull: true),
    FluentDbColumn.integer('qty'),
    FluentDbColumn.text('note'),
    FluentDbColumn.text('code', isUnique: true),
    FluentDbColumn.boolean('flag'),
    FluentDbColumn.timestamp('seen'),
  ];
}

/// Provider of [Doc] (table `docs`).
class DocProvider extends FluentProvider<Doc> {
  @override
  String get tableName => 'docs';

  @override
  Doc get modelSample => Doc();

  @override
  Doc fromCacheJson(Map<String, dynamic> json) => Doc(
    id: json['id'] as int?,
    title: json['title'] as String,
    qty: json['qty'] as int? ?? 0,
    note: json['note'] as String?,
    code: json['code'] as String?,
    flag: json['flag'] as bool?,
    seen: json['seen'] as DateTime?,
  );
}

/// A cache row: lives one hour after every save (table-level `timeToLive`).
class Lease extends FluentStorable {
  Lease({this.id, this.val = ''});

  int? id;
  String val;

  @override
  Duration? get timeToLive => const Duration(hours: 1);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'val': val};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('val')];
}

/// Provider of [Lease] (table `leases`).
class LeaseProvider extends FluentProvider<Lease> {
  @override
  String get tableName => 'leases';

  @override
  Lease get modelSample => Lease();

  @override
  Lease fromCacheJson(Map<String, dynamic> json) => Lease(id: json['id'] as int?, val: json['val'] as String);
}

/// A table that stores DateTime values as ISO text, ordered by a DateTime column.
class Stamp extends FluentStorable with FluentSoftDeletable {
  Stamp({this.id, required this.at, this.label = ''});

  int? id;
  DateTime at;
  String label;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'at': at, 'label': label};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.timestamp('at'), FluentDbColumn.text('label')];
}

/// Provider of [Stamp] (table `stamps`).
class StampProvider extends FluentProvider<Stamp> {
  @override
  String get tableName => 'stamps';

  @override
  Stamp get modelSample => Stamp(at: DateTime.utc(2000));

  @override
  Stamp fromCacheJson(Map<String, dynamic> json) => Stamp(id: json['id'] as int?, at: json['at'] as DateTime, label: json['label'] as String? ?? '');
}
