import 'dart:async';

import 'query.dart';
import 'result.dart';

/// How two tables relate, for `preload`, `joins`, `whereHas`, `withCount` and association mode.
///
/// Declare relations on a model with [PlexivoClient.model]. Without a
/// declared relation, a query can still name a related table directly, with an
/// optional `!constraint` hint, and the Data API follows the foreign key.
class PlexivoRelation {
  const PlexivoRelation._(this.kind, this.table, {this.foreignKey, this.references, this.constraint, this.through, this.otherKey, this.throughConstraint});

  /// This table holds the foreign key: `posts.author_id → authors.id`.
  ///
  /// [foreignKey] is the column on this table. [references] is the column it
  /// points to on [table], its primary key by default. [constraint] names the
  /// foreign-key constraint when more than one links the two tables.
  const PlexivoRelation.belongsTo(String table, {String? foreignKey, String? references, String? constraint})
      : this._('belongsTo', table, foreignKey: foreignKey, references: references, constraint: constraint);

  /// The other table holds the foreign key, one row per row here: `users.id ← profiles.user_id`.
  ///
  /// [foreignKey] is the column on [table]. [references] is the column it points
  /// to on this table, the primary key by default. [constraint] names the
  /// foreign-key constraint when more than one links the two tables. Preloaded,
  /// it is one map, or null.
  const PlexivoRelation.hasOne(String table, {String? foreignKey, String? references, String? constraint})
      : this._('hasOne', table, foreignKey: foreignKey, references: references, constraint: constraint);

  /// The other table holds the foreign key, many rows per row here: `posts.id ← comments.post_id`.
  ///
  /// [foreignKey] is the column on [table]. [references] is the column it points
  /// to on this table, the primary key by default. [constraint] names the
  /// foreign-key constraint when more than one links the two tables. Preloaded,
  /// it is a list.
  const PlexivoRelation.hasMany(String table, {String? foreignKey, String? references, String? constraint})
      : this._('hasMany', table, foreignKey: foreignKey, references: references, constraint: constraint);

  /// Related through a link table: `posts ⇄ post_tags ⇄ tags`.
  ///
  /// [through] is the link table. [foreignKey] is its column pointing to this
  /// table, and [otherKey] its column pointing to [table]. [constraint] and
  /// [throughConstraint] name the foreign-key constraints (link table to
  /// [table], and link table to this table) when more than one exists.
  /// Preloaded, it is a list of [table] rows.
  ///
  /// ```dart
  /// 'tags': const PlexivoRelation.manyToMany('tags',
  ///     through: 'post_tags', foreignKey: 'post_id', otherKey: 'tag_id'),
  /// ```
  const PlexivoRelation.manyToMany(String table,
      {required String through, required String foreignKey, required String otherKey, String? constraint, String? throughConstraint})
      : this._('manyToMany', table, through: through, foreignKey: foreignKey, otherKey: otherKey, constraint: constraint, throughConstraint: throughConstraint);

  /// The kind: `belongsTo`, `hasOne`, `hasMany` or `manyToMany`.
  final String kind;

  /// The related table.
  final String table;

  /// The foreign-key column; see each constructor for which table holds it.
  final String? foreignKey;

  /// The column the foreign key points to, or null for the primary key.
  final String? references;

  /// The foreign-key constraint to follow, or null to let the Data API find it.
  final String? constraint;

  /// For many-to-many, the link table; otherwise null.
  final String? through;

  /// For many-to-many, the link table's column pointing to [table]; otherwise null.
  final String? otherKey;

  /// For many-to-many, the constraint between the link table and this table; otherwise null.
  final String? throughConstraint;
}

/// A lifecycle hook: it gets a row and may return a changed one.
///
/// Return null (or nothing) to keep the row as it is. Throw to stop the
/// operation. Hooks may be async.
typedef RowHook = FutureOr<Map<String, dynamic>?> Function(Map<String, dynamic> row);

/// Lifecycle hooks, run in GORM's order around a model's reads and writes.
///
/// - Create (`create`, `insert`, `save` without a key): [beforeSave],
///   [beforeCreate], the insert, then [afterCreate], [afterSave].
/// - Update (`update`, `updateById`): [beforeSave], [beforeUpdate] on the
///   values being set, the update, then [afterUpdate], [afterSave] on each
///   updated row. `increment` runs only the after-hooks.
/// - Upsert (`upsert`, `save` with a key): [beforeSave], then [afterSave].
/// - Delete: [beforeDelete], the delete, then [afterDelete] on each deleted
///   row. [beforeDelete] gets the query's structured select operation (its
///   filter), because rows are not read first.
/// - Reads: [afterFind] on each row read.
///
/// A before-hook may return a changed row; throwing stops the write. The
/// return values of after-write hooks are ignored; [afterFind] may return a
/// changed row. Hooks run in your app, not in the database.
///
/// ```dart
/// hooks: PlexivoHooks(
///   beforeCreate: (row) => {...row, 'slug': slugify(row['title'] as String)},
///   afterFind: (row) => {...row, 'title': (row['title'] as String).trim()},
/// ),
/// ```
class PlexivoHooks {
  /// Creates a set of hooks; leave out the ones you don't need.
  const PlexivoHooks(
      {this.beforeSave,
      this.beforeCreate,
      this.afterCreate,
      this.beforeUpdate,
      this.afterUpdate,
      this.afterSave,
      this.beforeDelete,
      this.afterDelete,
      this.afterFind});

  /// Runs before every create, update and upsert.
  final RowHook? beforeSave;

  /// Runs before an insert, after [beforeSave].
  final RowHook? beforeCreate;

  /// Runs on each inserted row.
  final RowHook? afterCreate;

  /// Runs on the values of an update, after [beforeSave].
  final RowHook? beforeUpdate;

  /// Runs on each updated row.
  final RowHook? afterUpdate;

  /// Runs after every create, update and upsert, on each written row.
  final RowHook? afterSave;

  /// Runs before a delete, with the query's structured select operation.
  final RowHook? beforeDelete;

  /// Runs on each deleted row.
  final RowHook? afterDelete;

  /// Runs on each row read, and may return a changed row.
  final RowHook? afterFind;
}

/// A table described once: primary key, relations, hooks, scopes, soft deletes and schema.
///
/// Define one with [PlexivoClient.model]; from then on every query on the
/// table uses it.
///
/// ```dart
/// final posts = db.model('posts',
///     softDelete: 'deleted_at',
///     relations: {
///       'author': const PlexivoRelation.belongsTo('authors', foreignKey: 'author_id'),
///       'comments': const PlexivoRelation.hasMany('comments', foreignKey: 'post_id'),
///     },
///     hooks: PlexivoHooks(beforeCreate: (row) => {...row, 'slug': slugify(row['title'] as String)}),
///     scopes: {'popular': (q) => q.where('likes', '>=', 10)},
///     columns: {
///       'id': {'type': 'bigint', 'identity': true, 'primaryKey': true},
///       'title': 'text not null',
///       'author_id': {'type': 'bigint', 'references': 'authors(id)', 'onDelete': 'cascade'},
///       'deleted_at': 'timestamptz',
///     });
///
/// final popular = await posts.query().scopes(['popular']).preload('author').withCount('comments');
/// await posts.where('id', 7).delete(); // sets deleted_at
/// ```
class PlexivoModel {
  /// Creates a model for [table].
  ///
  /// Prefer [PlexivoClient.model], which also registers the model so that
  /// `from(table)` uses it. The named parameters set the fields of the same
  /// names.
  PlexivoModel(this._layer, this.table,
      {this.primaryKey = 'id',
      this.softDelete,
      this.relations = const {},
      this.hooks = const PlexivoHooks(),
      this.scopes = const {},
      this.columns,
      this.indexes = const [],
      this.policies = const [],
      this.compositeKey,
      this.uniques = const [],
      this.checks = const [],
      this.rowLevelSecurity});

  final DataLayer _layer;

  /// The table this model describes, optionally as `schema.table`.
  final String table;

  /// The primary-key column, `id` by default.
  final String primaryKey;

  /// The soft-delete timestamp column, or null for hard deletes.
  ///
  /// When set, deletes set this column to the current time, and reads skip rows
  /// where it is set. Use `unscoped()`, `onlyTrashed()`, `restore()` and
  /// `forceDelete()` on a query to work with deleted rows.
  final String? softDelete;

  /// Named relations to other tables.
  final Map<String, PlexivoRelation> relations;

  /// Lifecycle hooks run around this model's reads and writes.
  final PlexivoHooks hooks;

  /// Named, reusable query pieces, applied with [PlexivoQuery.scopes].
  final Map<String, PlexivoQuery Function(PlexivoQuery)> scopes;

  /// Column definitions for migrations, or null if this model does not migrate.
  ///
  /// Each value is SQL (`'text not null'`) or a map; see [columnSql] for the
  /// keys. [PlexivoMigrator.autoMigrate] needs this.
  final Map<String, Object>? columns;

  /// Indexes for migrations.
  ///
  /// Each is `{'columns': ['a', 'b'], 'unique': true, 'name': …, 'using': 'gin', 'where': …}`;
  /// only `columns` is required.
  final List<Map<String, dynamic>> indexes;

  /// Row-level security policies created with a new table.
  ///
  /// Each is `{'name': …, 'for': 'select', 'to': 'authenticated', 'using': …, 'check': …}`,
  /// with `for` one of `all`, `select`, `insert`, `update` or `delete`, and
  /// `as` `permissive` (the default) or `restrictive`.
  final List<Map<String, dynamic>> policies;

  /// The primary-key columns when the key spans several; otherwise null.
  final List<String>? compositeKey;

  /// Unique constraints: each a column name, or a list of column names.
  final List<Object> uniques;

  /// Check constraints, as SQL expressions.
  final List<String> checks;

  /// Whether a new table gets row-level security.
  ///
  /// Null turns it on when [policies] is not empty.
  final bool? rowLevelSecurity;

  /// Starts a query on this model's table.
  PlexivoQuery query() => _layer.from(table);

  // GORM-style shortcuts.
  /// Starts a query with a filter; see [PlexivoQuery.where].
  PlexivoQuery where(Object column, [Object? op = _gap, Object? value = _gap]) => identical(op, _gap)
      ? query().where(column)
      : identical(value, _gap)
          ? query().where(column, op)
          : query().where(column, op, value);

  /// Starts a query that also returns related rows; see [PlexivoQuery.preload].
  PlexivoQuery preload(String relation, [Function? callback]) => query().preload(relation, callback);

  /// Starts a query for rows with a matching related row; see [PlexivoQuery.whereHas].
  PlexivoQuery whereHas(String relation, [Function? callback]) => query().whereHas(relation, callback);

  /// Starts a query returning [columns]; see [PlexivoQuery.select].
  PlexivoQuery select([Object? columns]) => query().select(columns);

  /// Starts a query in this order; see [PlexivoQuery.order].
  PlexivoQuery order(Object column, [Object? dir]) => query().order(column, dir);

  /// The first row, or the row with primary key [id]; see [PlexivoQuery.first].
  Future<Map<String, dynamic>> first([Object? id]) => query().first(id);

  /// The last row by primary key; see [PlexivoQuery.last].
  Future<Map<String, dynamic>> last() => query().last();

  /// The first row, or null when there is none; see [PlexivoQuery.firstOrNull].
  Future<Map<String, dynamic>?> firstOrNull([Object? id]) => query().firstOrNull(id);

  /// Rows, or the rows with primary keys [ids]; see [PlexivoQuery.find].
  Future<PlexivoResult> find([List<Object?>? ids]) => query().find(ids);

  /// The number of rows; see [PlexivoQuery.count].
  Future<int> count() => query().count();

  /// Inserts one row and returns it; see [PlexivoQuery.create].
  Future<Map<String, dynamic>> create(Map<String, dynamic> values) => query().create(values);

  /// Inserts several rows and returns them; see [PlexivoQuery.createMany].
  Future<PlexivoResult> createMany(List<Map<String, dynamic>> values) => query().createMany(values);

  /// Inserts [row], or updates it when it has a primary key; see [PlexivoQuery.save].
  Future<Map<String, dynamic>> save(Map<String, dynamic> row) => query().save(row);

  /// Inserts, or updates on conflict; see [PlexivoQuery.upsert].
  PlexivoQuery upsert(Object values, {Object? onConflict, List<String>? update, bool ignore = false}) =>
      query().upsert(values, onConflict: onConflict, update: update, ignore: ignore);

  /// Finds the row matching [attributes], or creates it; see [PlexivoQuery.firstOrCreate].
  Future<Map<String, dynamic>> firstOrCreate(Map<String, dynamic> attributes, [Map<String, dynamic> defaults = const {}]) =>
      query().firstOrCreate(attributes, defaults);

  /// GORM's association mode for relation [name] of one [row].
  ///
  /// [row] is the row as a map, or just its primary key. Throws an
  /// [ArgumentError] if the model has no relation [name], or the row has no
  /// primary key.
  ///
  /// ```dart
  /// await posts.association(post, 'tags').append([tagId]);
  /// ```
  PlexivoAssociation association(Object row, String name) => PlexivoAssociation(_layer, this, row, name);
}

const Object _gap = Object();

/// What a query needs from the client: run operations and find models.
///
/// [PlexivoClient] implements it, and so does the `tx` of a transaction.
abstract class DataLayer {
  /// Starts a query on [table].
  PlexivoQuery from(String table);

  /// The model registered for [table], or null.
  PlexivoModel? modelOf(String table);

  /// Whether operations are recorded for a transaction instead of sent at once.
  ///
  /// True only on a transaction's `tx`.
  bool get deferred;

  /// Sends one structured operation [op] to the Data API and returns the response.
  Future<Map<String, dynamic>> query(Map<String, dynamic> op);

  /// Runs an operation, or records it in a transaction.
  ///
  /// [build] makes the operation and [finish] turns the response into the
  /// result. [shape] says how a later `ref()` reads the result: `rows` for a
  /// list of rows.
  Future<T> send<T>(FutureOr<Map<String, dynamic>> Function() build, FutureOr<T> Function(Map<String, dynamic>) finish, String shape);

  /// Runs the operations [callback] records in one transaction.
  ///
  /// See [PlexivoClient.transaction].
  Future<List<dynamic>> transaction(FutureOr<void> Function(DataLayer tx) callback);
}

/// The table context a query compiles and runs against, with its model applied.
///
/// The SDK creates these; apps don't need to.
class ModelContext implements TableContext {
  /// Creates the context for [table] on a data layer, with an optional model.
  ModelContext(this._layer, this.table, [this._model]);

  final DataLayer _layer;
  @override
  final String table;
  final PlexivoModel? _model;

  @override
  String get primaryKey => _model?.primaryKey ?? 'id';
  @override
  String? get softDelete => _model?.softDelete;
  @override
  bool get deferred => _layer.deferred;

  @override
  TableContext child(String t) => ModelContext(_layer, t, _layer.modelOf(t));

  PlexivoRelation _relation(String name) {
    final r = _model?.relations[name];
    if (r != null) return r;
    final parts = name.split('!');
    return PlexivoRelation._('auto', parts.first, constraint: parts.length > 1 ? parts[1] : null);
  }

  String _name(String name) => _model?.relations[name] != null ? name : name.split('!').first;

  PlexivoEmbed _sub(String t, Function? callback) {
    final q = PlexivoEmbed(child(t));
    if (callback == null) return q;
    final out = (callback as dynamic)(q);
    return out is PlexivoEmbed ? out : q;
  }

  Map<String, dynamic>? _soft(String t) {
    final soft = _layer.modelOf(t)?.softDelete;
    return soft == null ? null : {'column': soft, 'op': 'is', 'value': null};
  }

  Map<String, dynamic>? _and(List<Map<String, dynamic>?> nodes) {
    final list = nodes.whereType<Map<String, dynamic>>().toList();
    if (list.isEmpty) return null;
    return list.length == 1 ? list.first : {'and': list};
  }

  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> op) => _layer.query(_strip(op) as Map<String, dynamic>);

  @override
  Future<T> send<T>(FutureOr<Map<String, dynamic>> Function() build, FutureOr<T> Function(Map<String, dynamic> result) finish, String shape) =>
      _layer.send(() async => _strip(await build()) as Map<String, dynamic>, finish, shape);

  @override
  Map<String, dynamic> embed(String name, Function? callback, bool inner, [String? as]) {
    final rel = _relation(name);
    final out = as ?? _name(name);
    final q = _sub(rel.table, callback);
    final s = q.state;
    final cols = ((s['select'] as List?) ?? const []);
    final embeds = ((s['embeds'] as List?) ?? const []);
    final select = [...cols, ...embeds];
    final selectList = select.isEmpty ? null : (cols.isNotEmpty ? select : ['*', ...select]);
    if (rel.kind == 'manyToMany') {
      return _clean({
        'embed': rel.through,
        'as': '__m2m_$out',
        'hint': rel.throughConstraint,
        'inner': inner,
        'limit': s['limit'],
        'offset': s['offset'],
        'select': [
          _clean({
            'embed': rel.table,
            'as': '__target',
            'hint': rel.constraint,
            'inner': true,
            'select': selectList,
            'where': _and([q.node(), _soft(rel.table)])
          })
        ],
        '__m2m': {'as': out, 'order': s['order']},
      });
    }
    return _clean({
      'embed': rel.table,
      'as': out,
      'hint': rel.constraint,
      'inner': inner,
      'select': selectList,
      'where': _and([q.node(), _soft(rel.table)]),
      'order': s['order'],
      'limit': s['limit'],
      'offset': s['offset'],
      if (rel.kind == 'hasOne') '__hasOne': out,
    });
  }

  @override
  Map<String, dynamic> aggregateEmbed(String name, Function? callback, Map<String, dynamic> spec, String? as, bool countOnly) {
    final rel = _relation(name);
    final out = as ?? '${_name(name)}_${countOnly ? 'count' : 'aggregate'}';
    final node = _sub(rel.table, callback).node();
    if (rel.kind == 'manyToMany') {
      return _clean({
        'aggregate': rel.through,
        'as': out,
        'hint': rel.throughConstraint,
        ...spec,
        'where': node == null ? null : _clean({'has': rel.table, 'hint': rel.constraint, 'where': node}),
        if (countOnly) '__count': out,
      });
    }
    return _clean({'aggregate': rel.table, 'as': out, 'hint': rel.constraint, ...spec, 'where': node, if (countOnly) '__count': out});
  }

  @override
  Map<String, dynamic> has(String name, Function? callback) {
    final rel = _relation(name);
    final node = callback == null ? null : _sub(rel.table, callback).node();
    final where = _and([node, _soft(rel.table)]);
    if (rel.kind == 'manyToMany') {
      return _clean({
        'has': rel.through,
        'hint': rel.throughConstraint,
        'where': _clean({'has': rel.table, 'hint': rel.constraint, 'where': where})
      });
    }
    return _clean({'has': rel.table, 'hint': rel.constraint, 'where': where});
  }

  @override
  PlexivoQuery Function(PlexivoQuery) scope(String name) {
    final fn = _model?.scopes[name];
    if (fn == null) throw ArgumentError('$table has no scope $name');
    return fn;
  }

  @override
  List<Map<String, dynamic>> shape(List<Map<String, dynamic>> rows, List<Map<String, dynamic>> embeds) =>
      embeds.isEmpty ? rows : rows.map((r) => _shapeRow(r, embeds)).toList();

  @override
  Future<List<Map<String, dynamic>>> afterFind(List<Map<String, dynamic>> rows) async {
    final hook = _model?.hooks.afterFind;
    if (hook == null) return rows;
    return [for (final r in rows) (await hook(r)) ?? r];
  }

  @override
  Future<List<Map<String, dynamic>>> beforeWrite(String kind, List<Map<String, dynamic>> rows) async {
    final h = _model?.hooks;
    if (h == null) return rows;
    final chain = {
      'Create': [h.beforeSave, h.beforeCreate],
      'Update': [h.beforeSave, h.beforeUpdate],
      'Save': [h.beforeSave],
      'Delete': [h.beforeDelete],
    }[kind]!;
    var out = rows;
    for (final hook in chain) {
      if (hook == null) continue;
      out = [for (final r in out) (await hook(r)) ?? r];
    }
    return out;
  }

  @override
  Future<void> afterWrite(String kind, List<Map<String, dynamic>> rows) async {
    final h = _model?.hooks;
    if (h == null) return;
    final chain = {
      'Create': [h.afterCreate, h.afterSave],
      'Update': [h.afterUpdate, h.afterSave],
      'Save': [h.afterSave],
      'Delete': [h.afterDelete],
    }[kind]!;
    for (final hook in chain) {
      if (hook == null) continue;
      for (final r in rows) {
        await hook(r);
      }
    }
  }
}

Map<String, dynamic> _shapeRow(Map<String, dynamic> row, List<Map<String, dynamic>> embeds) {
  final out = Map<String, dynamic>.from(row);
  for (final e in embeds) {
    final m2m = e['__m2m'] as Map?;
    if (m2m != null) {
      final key = '__m2m_${m2m['as']}';
      var list = ((out[key] as List?) ?? const []).map((link) => (link as Map)['__target']).whereType<Map>().map((t) => Map<String, dynamic>.from(t)).toList();
      final order = (m2m['order'] as List?)?.cast<Map>() ?? const [];
      if (order.isNotEmpty) list = _sortRows(list, order);
      out.remove(key);
      out[m2m['as'] as String] = list;
    } else if (e['__hasOne'] != null) {
      final k = e['__hasOne'] as String;
      final v = out[k];
      out[k] = v is List ? (v.isEmpty ? null : v.first) : v;
    } else if (e['__count'] != null) {
      final k = e['__count'] as String;
      out[k] = ((out[k] as Map?)?['count'] as num?)?.toInt() ?? 0;
    }
    final name = (e['as'] ?? e['embed']) as String?;
    final nested = ((e['select'] as List?) ?? const [])
        .whereType<Map>()
        .where((x) => (x['embed'] != null || x['aggregate'] != null) && m2m == null)
        .map((x) => Map<String, dynamic>.from(x))
        .toList();
    if (nested.isNotEmpty && name != null && out[name] != null) {
      final v = out[name];
      out[name] =
          v is List ? v.map((r) => _shapeRow(Map<String, dynamic>.from(r as Map), nested)).toList() : _shapeRow(Map<String, dynamic>.from(v as Map), nested);
    }
  }
  return out;
}

List<Map<String, dynamic>> _sortRows(List<Map<String, dynamic>> rows, List<Map> order) {
  final copy = [...rows];
  copy.sort((a, b) {
    for (final t in order) {
      final x = a[t['column']], y = b[t['column']];
      if (x == y) continue;
      if (x == null) return t['nulls'] == 'first' ? -1 : 1;
      if (y == null) return t['nulls'] == 'first' ? 1 : -1;
      final c = (x as Comparable).compareTo(y);
      return t['dir'] == 'desc' ? -c : c;
    }
    return 0;
  });
  return copy;
}

Object? _strip(Object? value) {
  if (value is List) return value.map(_strip).toList();
  if (value is Map) {
    return {
      for (final e in value.entries)
        if (!e.key.toString().startsWith('__')) e.key.toString(): _strip(e.value)
    };
  }
  return value;
}

Map<String, dynamic> _clean(Map<String, dynamic> m) =>
    Map.fromEntries(m.entries.where((e) => e.value != null && !(e.value is List && (e.value as List).isEmpty)));

/// GORM's association mode: find, append, replace, delete, clear and count one row's related rows.
///
/// Get one from [PlexivoModel.association]. Related rows can be given as row
/// maps or as their primary keys.
///
/// ```dart
/// final posts = db.model('posts', relations: {
///   'tags': const PlexivoRelation.manyToMany('tags',
///       through: 'post_tags', foreignKey: 'post_id', otherKey: 'tag_id'),
/// });
/// final tags = posts.association(7, 'tags');
/// await tags.append([3, 4]);       // link tags 3 and 4
/// await tags.replace([4, 5]);      // now exactly 4 and 5
/// print(await tags.count());       // 2
/// await tags.clear();              // unlink all; the tags stay
/// ```
class PlexivoAssociation {
  /// Opens association mode for [name] on [row].
  ///
  /// Prefer [PlexivoModel.association]. Throws an [ArgumentError] if the model
  /// has no relation [name], or the row has no primary key.
  PlexivoAssociation(this._layer, this._model, Object row, String name)
      : _rel = _model.relations[name] ?? (throw ArgumentError('${_model.table} has no relation $name')),
        _row = row is Map ? Map<String, dynamic>.from(row) : {_model.primaryKey: row} {
    if (_row[_model.primaryKey] == null) throw ArgumentError('association needs the ${_model.table} row or its ${_model.primaryKey}');
  }

  final DataLayer _layer;
  final PlexivoModel _model;
  final PlexivoRelation _rel;
  final Map<String, dynamic> _row;

  Object get _id => _row[_model.primaryKey];
  String get _targetPk => _rel.references ?? _layer.modelOf(_rel.table)?.primaryKey ?? 'id';
  Object? _key(Object v) => v is Map ? v[_targetPk] : v;

  /// The related rows.
  ///
  /// For belongs-to, a list of zero or one row. [callback] narrows the other
  /// kinds, such as `(q) => q.where('approved', true)`.
  Future<List<Map<String, dynamic>>> find([PlexivoQuery Function(PlexivoQuery)? callback]) async {
    switch (_rel.kind) {
      case 'belongsTo':
        final r = await _layer.from(_model.table).where(_model.primaryKey, _id).select(_rel.foreignKey!).first();
        if (r[_rel.foreignKey] == null) return [];
        return [await _layer.from(_rel.table).first(r[_rel.foreignKey])];
      case 'manyToMany':
        var q = _layer.from(_rel.table).whereHas(_rel.through!, (PlexivoEmbed l) => l.where(_rel.foreignKey!, _id));
        if (callback != null) q = callback(q);
        return (await q.find()).toList();
      default:
        var q = _layer.from(_rel.table).where(_rel.foreignKey!, _owner);
        if (callback != null) q = callback(q);
        return (await q.find()).toList();
    }
  }

  Object get _owner => _rel.references != null ? _row[_rel.references] : _id;

  /// Links [related] rows to this row.
  ///
  /// - Belongs-to: points this row at the first of [related].
  /// - Many-to-many: adds link rows, skipping links that already exist.
  /// - Has-one and has-many: in one transaction, sets the foreign key on rows
  ///   given by key (or as maps with a key), and inserts maps without a key as
  ///   new related rows.
  Future<void> append(List<Object> related) async {
    switch (_rel.kind) {
      case 'belongsTo':
        await _layer.from(_model.table).where(_model.primaryKey, _id).update({_rel.foreignKey!: _key(related.first)});
        return;
      case 'manyToMany':
        await _layer.from(_rel.through!).upsert(_links(related), onConflict: [_rel.foreignKey!, _rel.otherKey!], ignore: true);
        return;
      default:
        await _layer.transaction((tx) => _attach(tx, related));
    }
  }

  void _attach(DataLayer tx, List<Object> list) {
    final existing = list.where((r) => r is! Map || r[_targetPk] != null).map(_key).toList();
    final fresh = list.whereType<Map>().where((r) => r[_targetPk] == null).map((r) => {...Map<String, dynamic>.from(r), _rel.foreignKey!: _owner}).toList();
    if (existing.isNotEmpty) tx.from(_rel.table).whereIn(_targetPk, existing).update({_rel.foreignKey!: _owner});
    if (fresh.isNotEmpty) tx.from(_rel.table).insert(fresh);
  }

  List<Map<String, dynamic>> _links(List<Object> list) => [
        for (final r in list) {_rel.foreignKey!: _id, _rel.otherKey!: _key(r)}
      ];

  /// Makes [related] the only rows linked to this row.
  ///
  /// Many-to-many and has-many changes run in one transaction. Rows no longer
  /// linked keep existing: link rows are deleted, or foreign keys set to null.
  /// For belongs-to, an empty list sets this row's foreign key to null.
  Future<void> replace(List<Object> related) async {
    switch (_rel.kind) {
      case 'belongsTo':
        await _layer.from(_model.table).where(_model.primaryKey, _id).update({_rel.foreignKey!: related.isEmpty ? null : _key(related.first)});
        return;
      case 'manyToMany':
        final keys = related.map(_key).toList();
        await _layer.transaction((tx) {
          var q = tx.from(_rel.through!).where(_rel.foreignKey!, _id);
          if (keys.isNotEmpty) q = q.whereNotIn(_rel.otherKey!, keys);
          q.delete();
          if (keys.isNotEmpty) tx.from(_rel.through!).upsert(_links(related), onConflict: [_rel.foreignKey!, _rel.otherKey!], ignore: true);
        });
        return;
      default:
        final keep = related.map(_key).where((k) => k != null && k is! Map).toList();
        await _layer.transaction((tx) {
          var q = tx.from(_rel.table).where(_rel.foreignKey!, _owner);
          if (keep.isNotEmpty) q = q.whereNotIn(_targetPk, keep);
          q.update({_rel.foreignKey!: null});
          _attach(tx, related);
        });
    }
  }

  /// Unlinks [related] rows from this row; the rows themselves stay.
  ///
  /// Many-to-many deletes the link rows. Has-one and has-many set the related
  /// rows' foreign key to null. Belongs-to sets this row's foreign key to null.
  Future<void> delete(List<Object> related) async {
    final keys = related.map(_key).toList();
    switch (_rel.kind) {
      case 'belongsTo':
        await _layer.from(_model.table).where(_model.primaryKey, _id).update({_rel.foreignKey!: null});
        return;
      case 'manyToMany':
        await _layer.from(_rel.through!).where(_rel.foreignKey!, _id).whereIn(_rel.otherKey!, keys).delete();
        return;
      default:
        await _layer.from(_rel.table).where(_rel.foreignKey!, _owner).whereIn(_targetPk, keys).update({_rel.foreignKey!: null});
    }
  }

  /// Unlinks every related row; the rows themselves stay.
  Future<void> clear() async {
    switch (_rel.kind) {
      case 'belongsTo':
        await _layer.from(_model.table).where(_model.primaryKey, _id).update({_rel.foreignKey!: null});
        return;
      case 'manyToMany':
        await _layer.from(_rel.through!).where(_rel.foreignKey!, _id).delete();
        return;
      default:
        await _layer.from(_rel.table).where(_rel.foreignKey!, _owner).update({_rel.foreignKey!: null});
    }
  }

  /// The number of related rows.
  ///
  /// For belongs-to, 1 when the foreign key is set, otherwise 0.
  Future<int> count() {
    switch (_rel.kind) {
      case 'belongsTo':
        return _layer.from(_model.table).where(_model.primaryKey, _id).whereNotNull(_rel.foreignKey!).count();
      case 'manyToMany':
        return _layer.from(_rel.through!).where(_rel.foreignKey!, _id).count();
      default:
        return _layer.from(_rel.table).where(_rel.foreignKey!, _owner).count();
    }
  }
}
