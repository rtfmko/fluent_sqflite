// Names derived from type / relation names: the 2.0 rule (`HTTPAuthor` → `http_author`, `Note2` → `note2`) and the
// adoption of a database written with the 1.x rule (`h_t_t_p_author`, `note_2`): tables, reference columns, link
// tables and their columns, polymorphic type values are renamed at start, the data and relations stay.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common/sqlite_api.dart';

class HTTPAuthor extends FluentStorable {
  HTTPAuthor({this.id, required this.name});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class Label extends FluentStorable {
  Label({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class Remark extends FluentStorable {
  Remark({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class Note2 extends FluentStorable with FluentRelations {
  Note2({this.id, required this.title, this.mainWriterV2, this.remarks, this.labels});

  final int? id;
  final String title;
  final HTTPAuthor? mainWriterV2;
  final List<Remark>? remarks;
  final List<Label>? labels;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Note2, HTTPAuthor>('mainWriterV2', (n) => n.mainWriterV2),
    FluentRelation.many<Note2, Remark>('remarks', (n) => n.remarks, orderBy: 'id'),
    FluentRelation.manyToMany<Note2, Label>('labels', (n) => n.labels, orderBy: 'id'),
  ];
}

class Pin2 extends FluentStorable with FluentRelations {
  Pin2({this.id, this.target});

  final int? id;
  final FluentStorable? target;

  @override
  Map<String, dynamic> buildJson() => {'id': id};

  @override
  List<FluentRelation> get relations => [FluentRelation.oneOf<Pin2>('pinTarget', (p) => p.target, types: [Note2, HTTPAuthor])];
}

class HTTPAuthorProvider extends FluentProvider<HTTPAuthor> {
  @override
  HTTPAuthor get modelSample => HTTPAuthor(name: '');

  @override
  HTTPAuthor fromCacheJson(Map<String, dynamic> json) => HTTPAuthor(id: json['id'] as int?, name: json['name'] as String);
}

class LabelProvider extends FluentProvider<Label> {
  @override
  Label get modelSample => Label(text: '');

  @override
  Label fromCacheJson(Map<String, dynamic> json) => Label(id: json['id'] as int?, text: json['text'] as String);
}

class RemarkProvider extends FluentProvider<Remark> {
  @override
  Remark get modelSample => Remark(text: '');

  @override
  Remark fromCacheJson(Map<String, dynamic> json) => Remark(id: json['id'] as int?, text: json['text'] as String);
}

class Note2Provider extends FluentProvider<Note2> {
  @override
  Note2 get modelSample => Note2(title: '');

  @override
  Note2 fromCacheJson(Map<String, dynamic> json) => Note2(
    id: json['id'] as int?,
    title: json['title'] as String,
    mainWriterV2: json['mainWriterV2'] as HTTPAuthor?,
    remarks: (json['remarks'] as List<dynamic>?)?.cast<Remark>(),
    labels: (json['labels'] as List<dynamic>?)?.cast<Label>(),
  );
}

class Pin2Provider extends FluentProvider<Pin2> {
  @override
  Pin2 get modelSample => Pin2();

  @override
  Pin2 fromCacheJson(Map<String, dynamic> json) => Pin2(id: json['id'] as int?, target: json['pinTarget'] as FluentStorable?);
}

void main() {
  setUpFluentTests();

  group('the 2.0 naming rule', () {
    test('words, acronyms, digits and generics', () {
      expect(FluentUtils.toSnakeCase('UserName'), 'user_name');
      expect(FluentUtils.toSnakeCase('userName'), 'user_name');
      expect(FluentUtils.toSnakeCase('user_name'), 'user_name');
      expect(FluentUtils.toSnakeCase('mainAuthor_profile'), 'main_author_profile');
      expect(FluentUtils.toSnakeCase('Item2'), 'item2');
      expect(FluentUtils.toSnakeCase('item2Box'), 'item2_box');
      expect(FluentUtils.toSnakeCase('HTTPServer'), 'http_server');
      expect(FluentUtils.toSnakeCase('userID'), 'user_id');
      expect(FluentUtils.toSnakeCase('HTTPAuthor'), 'http_author');
      expect(FluentUtils.toSnakeCase('Box<Note>'), 'box_note');
      expect(FluentUtils.toSnakeCase('Map<String, int>'), 'map_string_int');
      expect(FluentUtils.toSnakeCase('_Draft'), '_draft');
      expect(FluentUtils.toSnakeCase('__x__y'), '_x_y');
      expect(FluentUtils.toSnakeCase('A'), 'a');
      expect(FluentUtils.toSnakeCase(''), '');
      expect(FluentUtils.toSnakeCase('ÄpfelBaum'), 'äpfel_baum');
    });

    test('the 1.x rule is kept for adopting old databases', () {
      expect(FluentUtils.legacySnakeCase('Item2'), 'item_2');
      expect(FluentUtils.legacySnakeCase('HTTPServer'), 'h_t_t_p_server');
      expect(FluentUtils.legacySnakeCase('Box<Note>'), 'box_<_note_>');
      expect(FluentUtils.withLegacyNames(() => FluentUtils.toSnakeCase('Item2')), 'item_2');
      expect(FluentUtils.toSnakeCase('Item2'), 'item2', reason: 'only inside withLegacyNames');
    });

    test('default table names and derived columns follow the new rule', () async {
      final FluentTestDb db = FluentTestDb(name: 'r3_names_new');
      final Note2Provider notes = Note2Provider();
      await db.open([HTTPAuthorProvider(), LabelProvider(), RemarkProvider(), notes, Pin2Provider()]);
      final Set<String> tables = {for (final Map<String, Object?> r in await notes.db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'")) r['name']! as String};
      expect(tables, containsAll(<String>['http_author', 'note2', 'label', 'remark', 'pin2', 'label_note2']));
      expect(await _columns(notes.db, 'note2'), contains('main_writer_v2_id'));
      expect(await _columns(notes.db, 'remark'), contains('note2_id'));
      expect(await _columns(notes.db, 'label_note2'), containsAll(<String>['note2_id', 'label_id']));
      expect(await _columns(notes.db, 'pin2'), containsAll(<String>['pin_target_type', 'pin_target_id']));
      expect([for (final FluentIssue i in db.issues) if (i.kind == FluentIssueKind.legacyNameAdopted) i], isEmpty);
      await db.close();
    });
  });

  group('a database written with the 1.x names', () {
    List<FluentProvider> providers() => [HTTPAuthorProvider(), LabelProvider(), RemarkProvider(), Note2Provider(), Pin2Provider()];

    /// Writes the database of a 1.x app: the same models, named by the 1.x rule.
    Future<FluentTestDb> legacyDatabase(String name) async {
      final FluentTestDb db = FluentTestDb(name: name, persistent: true);
      await FluentUtils.withLegacyNames(() async {
        final List<FluentProvider> list = providers();
        await db.open(list);
        final HTTPAuthorProvider authors = list[0] as HTTPAuthorProvider;
        final Note2Provider notes = list[3] as Note2Provider;
        final Pin2Provider pins = list[4] as Pin2Provider;
        final HTTPAuthor ann = HTTPAuthor(name: 'Ann');
        await authors.save(ann);
        final Note2 note = Note2(title: 'First', mainWriterV2: ann, remarks: [Remark(text: 'r1'), Remark(text: 'r2')], labels: [Label(text: 'l1'), Label(text: 'l2')]);
        await notes.save(note);
        await pins.save(Pin2(target: note));
        await pins.save(Pin2(target: ann));
        final Set<String> tables = {for (final Map<String, Object?> r in await notes.db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'")) r['name']! as String};
        expect(tables, containsAll(<String>['h_t_t_p_author', 'note_2', 'label_note_2', 'pin_2']), reason: 'the 1.x names');
        expect(await _columns(notes.db, 'note_2'), contains('main_writer_v_2_id'));
        expect(await _columns(notes.db, 'remark'), contains('note_2_id'));
        expect(await _columns(notes.db, 'pin_2'), containsAll(<String>['pin_target_type', 'pin_target_id']));
        expect({for (final Map<String, Object?> r in await notes.db.rawQuery('SELECT pin_target_type FROM pin_2')) r['pin_target_type']}, {'note_2', 'h_t_t_p_author'});
      });
      return db;
    }

    test('the start renames tables, columns, link tables and type values; data and relations stay', () async {
      final FluentTestDb db = await legacyDatabase('r3_names_adopt');
      final List<FluentProvider> list = providers();
      await db.restart(list);
      final Note2Provider notes = list[3] as Note2Provider;
      final Pin2Provider pins = list[4] as Pin2Provider;
      final Set<String> tables = {for (final Map<String, Object?> r in await notes.db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'")) r['name']! as String};
      expect(tables, containsAll(<String>['http_author', 'note2', 'label_note2', 'pin2']));
      expect(tables.intersection({'h_t_t_p_author', 'note_2', 'label_note_2', 'pin_2'}), isEmpty);
      expect(await _columns(notes.db, 'note2'), contains('main_writer_v2_id'));
      expect(await _columns(notes.db, 'note2'), isNot(contains('main_writer_v_2_id')));
      expect(await _columns(notes.db, 'remark'), contains('note2_id'));
      expect(await _columns(notes.db, 'label_note2'), containsAll(<String>['note2_id', 'label_id']));

      final Note2 note = (await notes.find()).single;
      expect(note.title, 'First');
      expect(note.mainWriterV2?.name, 'Ann');
      expect([for (final Remark r in note.remarks!) r.text], ['r1', 'r2']);
      expect([for (final Label l in note.labels!) l.text], ['l1', 'l2']);
      final List<Pin2> all = await pins.find(orderBy: 'id');
      expect(all.map((p) => p.target.runtimeType).toList(), [Note2, HTTPAuthor]);

      final List<FluentIssue> adopted = [for (final FluentIssue i in db.issues) if (i.kind == FluentIssueKind.legacyNameAdopted) i];
      expect(adopted.map((i) => i.subject), containsAll(<String>['h_t_t_p_author', 'note_2', 'pin_2', 'label_note_2']));
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.relationChanged || i.kind == FluentIssueKind.unusedLinkTable), isEmpty);

      // The next start finds nothing to adopt and keeps everything.
      final List<FluentProvider> again = providers();
      await db.restart(again);
      expect((await (again[3] as Note2Provider).find()).single.labels, hasLength(2));
      await db.close();
    });

    test('the plan shows the renames and changes nothing', () async {
      final FluentTestDb db = await legacyDatabase('r3_names_plan');
      await db.close(keepFile: true);
      final FluentMigrationPlan plan = await db.plan(providers());
      expect(plan.changes.where((c) => c.kind == FluentSchemaChangeKind.renameTable).map((c) => c.subject), containsAll(<String>['h_t_t_p_author', 'note_2']));
      expect(plan.losesData, isFalse);
      await db.close();
    });

    test('a table under both names is not renamed over and is reported', () async {
      final FluentTestDb db = await legacyDatabase('r3_names_both');
      final List<FluentProvider> list = providers();
      await db.restart(list);
      // Recreate the old table next to the adopted one and start again from the 1.x snapshot state.
      await (list[0] as HTTPAuthorProvider).db.execute('CREATE TABLE "h_t_t_p_author" (id INTEGER PRIMARY KEY, name TEXT)');
      await (list[0] as HTTPAuthorProvider).db.execute("INSERT INTO \"h_t_t_p_author\" VALUES (99, 'Old')");
      final List<FluentProvider> again = providers();
      await db.restart(again);
      expect((await (again[0] as HTTPAuthorProvider).find()).map((a) => a.name), ['Ann'], reason: 'the adopted table is kept');
      final Set<String> tables = {for (final Map<String, Object?> r in await (again[0] as HTTPAuthorProvider).db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'")) r['name']! as String};
      expect(tables, contains('h_t_t_p_author'), reason: 'never dropped');
      await db.close();
    });
  });
}

Future<Set<String>> _columns(DatabaseExecutor db, String table) async => {
  for (final Map<String, Object?> r in await db.rawQuery('PRAGMA table_info("$table")')) r['name']! as String,
};
