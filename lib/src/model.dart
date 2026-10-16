import 'dart:async';

import 'query.dart';
import 'result.dart';

/// How two tables relate.
class PlexivoRelation {
  const PlexivoRelation._(this.kind, this.table, {this.foreignKey, this.references, this.constraint, this.through, this.otherKey, this.throughConstraint});

  /// This table holds the foreign key: `posts.author_id → authors.id`.
  const PlexivoRelation.belongsTo(String table, {String? foreignKey, String? references, String? constraint})
      : this._('belongsTo', table, foreignKey: foreignKey, references: references, constraint: constraint);

  /// The other table holds the foreign key, one row per row here.
  const PlexivoRelation.hasOne(String table, {String? foreignKey, String? references, String? constraint})
      : this._('hasOne', table, foreignKey: foreignKey, references: references, constraint: constraint);

  /// The other table holds the foreign key, many rows per row here.
  const PlexivoRelation.hasMany(String table, {String? foreignKey, String? references, String? constraint})
      : this._('hasMany', table, foreignKey: foreignKey, references: references, constraint: constraint);

  /// Related through a link table: `posts ⇄ post_tags ⇄ tags`.
  const PlexivoRelation.manyToMany(String table,
      {required String through, required String foreignKey, required String otherKey, String? constraint, String? throughConstraint})
      : this._('manyToMany', table, through: through, foreignKey: foreignKey, otherKey: otherKey, constraint: constraint, throughConstraint: throughConstraint);

  final String kind;
  final String table;
  final String? foreignKey;
  final String? references;
  final String? constraint;
  final String? through;
  final String? otherKey;
  final String? throughConstraint;
}

typedef RowHook = FutureOr<Map<String, dynamic>?> Function(Map<String, dynamic> row);

/// Lifecycle hooks, run in GORM's order. A before-hook may return a changed row; throwing stops the write.
class PlexivoHooks {
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
  final RowHook? beforeSave;
  final RowHook? beforeCreate;
  final RowHook? afterCreate;
  final RowHook? beforeUpdate;
  final RowHook? afterUpdate;
  final RowHook? afterSave;
  final RowHook? beforeDelete;
  final RowHook? afterDelete;
  final RowHook? afterFind;
}

/// A table described once: primary key, relations, hooks, scopes, soft
/// deletes, and (for migrations) columns, indexes and policies.
class PlexivoModel {
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
  final String table;
  final String primaryKey;
  final String? softDelete;
  final Map<String, PlexivoRelation> relations;
  final PlexivoHooks hooks;
  final Map<String, PlexivoQuery Function(PlexivoQuery)> scopes;

  /// For migrations: `{'title': 'text not null'}` or `{'title': {'type': 'text', 'notNull': true}}`.
  final Map<String, Object>? columns;
  final List<Map<String, dynamic>> indexes;
  final List<Map<String, dynamic>> policies;
  final List<String>? compositeKey;
  final List<Object> uniques;
  final List<String> checks;
  final bool? rowLevelSecurity;

  PlexivoQuery query() => _layer.from(table);

  // GORM-style shortcuts.
  PlexivoQuery where(Object column, [Object? op = _gap, Object? value = _gap]) => identical(op, _gap)
      ? query().where(column)
      : identical(value, _gap)
          ? query().where(column, op)
          : query().where(column, op, value);
  PlexivoQuery preload(String relation, [Function? callback]) => query().preload(relation, callback);
  PlexivoQuery whereHas(String relation, [Function? callback]) => query().whereHas(relation, callback);
  PlexivoQuery select([Object? columns]) => query().select(columns);
  PlexivoQuery order(Object column, [Object? dir]) => query().order(column, dir);
  Future<Map<String, dynamic>> first([Object? id]) => query().first(id);
  Future<Map<String, dynamic>> last() => query().last();
  Future<Map<String, dynamic>?> firstOrNull([Object? id]) => query().firstOrNull(id);
  Future<PlexivoResult> find([List<Object?>? ids]) => query().find(ids);
  Future<int> count() => query().count();
  Future<Map<String, dynamic>> create(Map<String, dynamic> values) => query().create(values);
  Future<PlexivoResult> createMany(List<Map<String, dynamic>> values) => query().createMany(values);
  Future<Map<String, dynamic>> save(Map<String, dynamic> row) => query().save(row);
  PlexivoQuery upsert(Object values, {Object? onConflict, List<String>? update, bool ignore = false}) =>
      query().upsert(values, onConflict: onConflict, update: update, ignore: ignore);
  Future<Map<String, dynamic>> firstOrCreate(Map<String, dynamic> attributes, [Map<String, dynamic> defaults = const {}]) =>
      query().firstOrCreate(attributes, defaults);

  /// GORM's association mode for one row.
  PlexivoAssociation association(Object row, String name) => PlexivoAssociation(_layer, this, row, name);
}

const Object _gap = Object();

/// What a table context needs from the client: run operations, find models.
abstract class DataLayer {
  PlexivoQuery from(String table);
  PlexivoModel? modelOf(String table);
  bool get deferred;
  Future<Map<String, dynamic>> query(Map<String, dynamic> op);
  Future<T> send<T>(FutureOr<Map<String, dynamic>> Function() build, FutureOr<T> Function(Map<String, dynamic>) finish, String shape);
  Future<List<dynamic>> transaction(FutureOr<void> Function(DataLayer tx) callback);
}

/// The per-table context a query compiles and runs against.
class ModelContext implements TableContext {
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

/// GORM's association mode: find, append, replace, delete (the link), clear, count.
class PlexivoAssociation {
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
