import 'model.dart';

/// Raw SQL and migrations, for servers holding the project's secret key.
///
/// **Server only.** Calls go to `POST /sql/v1`; with the publishable key the
/// platform refuses them whatever they send. Never ship the secret key in a
/// Flutter app. The statements in one call run in one transaction. `DateTime`
/// parameters are sent as UTC ISO 8601.
///
/// ```dart
/// // On a server:
/// final server = PlexivoClient(dataUrl, Platform.environment['PLEXIVO_SECRET_KEY']!);
///
/// final big = await server.sql.raw(r'select * from orders where total > $1', [100]);
/// await server.sql.transaction([
///   r'update accounts set balance = balance - 10 where id = 1',
///   {'sql': r'update accounts set balance = balance + $1 where id = $2', 'params': [10, 2]},
/// ]);
/// await server.migrator.autoMigrate([postModel, commentModel]);
/// ```
class PlexivoSql {
  /// Creates the SQL API over a request function; use [PlexivoClient.sql].
  PlexivoSql(this._call);

  final Future<Map<String, dynamic>> Function(String path, Map<String, dynamic> body) _call;

  Future<List<Map<String, dynamic>>> _run(List<Map<String, dynamic>> statements) async {
    final r = await _call('/sql/v1', {'statements': statements});
    return (r['results'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> _one(String sql, [List<Object?> params = const []]) async => (await _run([
        {'sql': sql, 'params': params.map(_param).toList()}
      ]))
          .first;

  /// Runs [sql] with `$1`, `$2` … [params] and returns its rows.
  ///
  /// Always pass values as [params], never by building the SQL string.
  Future<List<Map<String, dynamic>>> raw(String sql, [List<Object?> params = const []]) async =>
      ((await _one(sql, params))['rows'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  /// Runs a statement and returns its `command` tag and `rowCount`.
  ///
  /// `command` is, for example, `UPDATE`; `rowCount` is the number of rows it
  /// touched.
  Future<({String? command, int rowCount})> exec(String sql, [List<Object?> params = const []]) async {
    final r = await _one(sql, params);
    return (command: r['command'] as String?, rowCount: (r['row_count'] as num?)?.toInt() ?? 0);
  }

  /// Runs several [statements] in one transaction and returns each result.
  ///
  /// Each statement is SQL text, or `{'sql': …, 'params': [...]}`.
  Future<List<Map<String, dynamic>>> transaction(List<Object> statements) => _run([
        for (final s in statements)
          s is String ? {'sql': s, 'params': <Object?>[]} : {'sql': (s as Map)['sql'], 'params': ((s['params'] as List?) ?? const []).map(_param).toList()}
      ]);

  /// Schema inspection and changes, like GORM's Migrator.
  late final PlexivoMigrator migrator = PlexivoMigrator._(_run, _one);

  /// Applies the [migrations] not yet applied, in list order, and returns their ids.
  ///
  /// Applied ids are recorded in [table] (`plexivo_migrations`, created if
  /// missing). Each migration runs in its own transaction with its record, so a
  /// failure leaves earlier ones applied and stops there. Run migrations from one
  /// place at a time.
  ///
  /// ```dart
  /// await server.migrate([
  ///   PlexivoMigration.sql('001_slug',
  ///       'alter table posts add column slug text', 'alter table posts drop column slug'),
  /// ]);
  /// ```
  Future<List<String>> migrate(List<PlexivoMigration> migrations, {String table = 'plexivo_migrations'}) async {
    await _run([
      {'sql': 'CREATE TABLE IF NOT EXISTS ${_ident(table)} (id text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())', 'params': <Object?>[]}
    ]);
    final done = ((await _one('SELECT id FROM ${_ident(table)}'))['rows'] as List).map((r) => (r as Map)['id']).toSet();
    final applied = <String>[];
    for (final m in migrations) {
      if (done.contains(m.id)) continue;
      final plan = migrator.plan();
      m.up(plan);
      await _run([
        ...plan.statements,
        {
          'sql': 'INSERT INTO ${_ident(table)} (id) VALUES (\$1)',
          'params': [m.id]
        }
      ]);
      applied.add(m.id);
    }
    return applied;
  }

  /// Undoes the newest [steps] applied migrations with their `down`, and returns their ids.
  ///
  /// Throws a [StateError] if an applied migration is missing from
  /// [migrations] or has no `down`.
  Future<List<String>> rollback(List<PlexivoMigration> migrations, {int steps = 1, String table = 'plexivo_migrations'}) async {
    final rows = (await _one('SELECT id FROM ${_ident(table)} ORDER BY applied_at DESC, id DESC LIMIT \$1', [steps]))['rows'] as List;
    final undone = <String>[];
    for (final r in rows) {
      final id = (r as Map)['id'] as String;
      final m = migrations.firstWhere((x) => x.id == id, orElse: () => throw StateError('migration $id is not in the list'));
      if (m.down == null) throw StateError('migration $id has no down');
      final plan = migrator.plan();
      m.down!(plan);
      await _run([
        ...plan.statements,
        {
          'sql': 'DELETE FROM ${_ident(table)} WHERE id = \$1',
          'params': [id]
        }
      ]);
      undone.add(id);
    }
    return undone;
  }
}

/// One versioned migration: `up`, and optionally `down`, add statements to a plan.
///
/// ```dart
/// final migrations = [
///   PlexivoMigration.sql('001_posts',
///       'create table posts (id bigint generated always as identity primary key, title text not null)',
///       'drop table posts'),
///   PlexivoMigration('002_slug',
///       (plan) => plan.addColumn('posts', 'slug', 'text').createIndex('posts', ['slug'], unique: true),
///       (plan) => plan.dropColumn('posts', 'slug')),
/// ];
/// await server.migrate(migrations);
/// await server.rollback(migrations); // undoes 002_slug
/// ```
class PlexivoMigration {
  /// Creates migration [id] from [up] and an optional [down].
  ///
  /// [id] is unique and never changes once applied, such as `001_create_posts`.
  PlexivoMigration(this.id, this.up, [this.down]);

  /// Creates migration [id] from plain SQL: [upSql], and optionally [downSql].
  PlexivoMigration.sql(this.id, String upSql, [String? downSql])
      : up = ((p) => p.sql(upSql)),
        down = downSql == null ? null : ((p) => p.sql(downSql));

  /// The migration's unique id, recorded once it is applied.
  final String id;

  /// Adds the statements that apply this migration.
  final void Function(PlexivoMigrationPlan plan) up;

  /// Adds the statements that undo this migration, or null if it cannot be undone.
  final void Function(PlexivoMigrationPlan plan)? down;
}

Object? _param(Object? v) => v is DateTime ? v.toUtc().toIso8601String() : v;

String _ident(String name) => name.split('.').map((p) => '"${p.replaceAll('"', '""')}"').join('.');

List<String> _split(String table) {
  final parts = table.split('.');
  return parts.length == 2 ? parts : ['public', parts.first];
}

/// A column definition as SQL, for column [name] and its definition [def].
///
/// [def] is SQL text, such as `'text not null'`, or a map with `type` and
/// optionally `primaryKey`, `identity`, `notNull` (or `nullable: false`),
/// `unique`, `default` (SQL), `check` (SQL), `references` (`'table(column)'`),
/// `onDelete`, `onUpdate` and `index` (true, or index options). Throws an
/// [ArgumentError] when a map has no `type` or an unreadable `references`.
///
/// ```dart
/// columnSql('author_id', {'type': 'bigint', 'notNull': true, 'references': 'authors(id)', 'onDelete': 'cascade'});
/// // "author_id" bigint NOT NULL REFERENCES "authors" ("id") ON DELETE CASCADE
/// ```
String columnSql(String name, Object def) {
  if (def is String) return '${_ident(name)} $def';
  final d = def as Map;
  if (d['type'] == null) throw ArgumentError('column $name needs a type');
  final parts = <String>[_ident(name), d['type'] as String];
  if (d['identity'] == true) parts.add('GENERATED BY DEFAULT AS IDENTITY');
  if (d['primaryKey'] == true) parts.add('PRIMARY KEY');
  if (d['notNull'] == true || d['nullable'] == false) parts.add('NOT NULL');
  if (d['unique'] == true) parts.add('UNIQUE');
  if (d.containsKey('default')) parts.add('DEFAULT ${d['default'] ?? 'NULL'}');
  if (d['check'] != null) parts.add('CHECK (${d['check']})');
  if (d['references'] != null) {
    final m = RegExp(r'^([A-Za-z_][\w.]*)\s*(?:\(\s*([A-Za-z_]\w*)\s*\)|\.([A-Za-z_]\w*))?$').firstMatch(d['references'] as String);
    if (m == null) throw ArgumentError('references is "table(column)" for $name');
    final col = m[2] ?? m[3];
    parts.add('REFERENCES ${_ident(m[1]!)}${col == null ? '' : ' (${_ident(col)})'}');
    if (d['onDelete'] != null) parts.add('ON DELETE ${(d['onDelete'] as String).toUpperCase()}');
    if (d['onUpdate'] != null) parts.add('ON UPDATE ${(d['onUpdate'] as String).toUpperCase()}');
  }
  return parts.join(' ');
}

Map<String, dynamic> _stmt(String sql) => {'sql': sql, 'params': <Object?>[]};

List<Map<String, dynamic>> _createTable(String table, Map<String, Object> columns,
    {List<String>? compositeKey, List<Object> uniques = const [], List<String> checks = const []}) {
  final cols = [for (final e in columns.entries) columnSql(e.key, e.value)];
  if (compositeKey != null) cols.add('PRIMARY KEY (${compositeKey.map(_ident).join(', ')})');
  for (final u in uniques) {
    cols.add('UNIQUE (${(u is List ? u : [u]).map((c) => _ident(c.toString())).join(', ')})');
  }
  for (final c in checks) {
    cols.add('CHECK ($c)');
  }
  return [_stmt('CREATE TABLE IF NOT EXISTS ${_ident(table)} (${cols.join(', ')})')];
}

List<Map<String, dynamic>> _indexes(String table, List<Map<String, dynamic>> list, Map<String, Object>? columns) {
  final all = <Map<String, dynamic>>[
    for (final e in (columns ?? const <String, Object>{}).entries)
      if (e.value is Map && (e.value as Map)['index'] != null && (e.value as Map)['index'] != false)
        {
          'columns': [e.key],
          if ((e.value as Map)['index'] is Map) ...Map<String, dynamic>.from((e.value as Map)['index'] as Map)
        },
    ...list,
  ];
  return [
    for (final ix in all)
      () {
        final cols = (ix['columns'] is List ? ix['columns'] as List : [ix['columns']]).map((c) => c.toString()).toList();
        final unique = ix['unique'] == true;
        final name = ix['name'] as String? ?? '${table.replaceAll('.', '_')}_${cols.join('_')}_${unique ? 'key' : 'idx'}';
        final colSql = cols.map((c) => RegExp(r'[()\s]').hasMatch(c) ? c : _ident(c)).join(', ');
        return _stmt('CREATE ${unique ? 'UNIQUE ' : ''}INDEX IF NOT EXISTS ${_ident(name)} ON ${_ident(table)}'
            '${ix['using'] != null ? ' USING ${ix['using']}' : ''} ($colSql)${ix['where'] != null ? ' WHERE ${ix['where']}' : ''}');
      }()
  ];
}

Map<String, dynamic> _policySql(String table, Map<String, dynamic> p) {
  final cmd = ((p['for'] as String?) ?? 'all').toUpperCase();
  final to = (p['to'] is List ? p['to'] as List : [p['to'] ?? 'authenticated'])
      .map((r) => RegExp(r'^(public|anon|authenticated|service_role)$').hasMatch(r.toString()) ? r.toString() : _ident(r.toString()))
      .join(', ');
  final using = p['using'] != null && cmd != 'INSERT' ? ' USING (${p['using']})' : '';
  final check = p['check'] != null && cmd != 'SELECT' && cmd != 'DELETE' ? ' WITH CHECK (${p['check']})' : '';
  return _stmt(
      'CREATE POLICY ${_ident(p['name'] as String)} ON ${_ident(table)} AS ${((p['as'] as String?) ?? 'permissive').toUpperCase()} FOR $cmd TO $to$using$check');
}

List<Map<String, dynamic>> _security(String table, List<Map<String, dynamic>> policies, bool? rls) => [
      if (rls ?? policies.isNotEmpty) _stmt('ALTER TABLE ${_ident(table)} ENABLE ROW LEVEL SECURITY'),
      for (final p in policies) _policySql(table, p),
    ];

/// Inspects and changes the schema, like GORM's Migrator.
///
/// **Server only, with the secret key.** Each change runs at once, in its own
/// transaction. Tables are `table` (in `public`) or `schema.table`. To group
/// changes, use [plan] with a [PlexivoMigration].
///
/// ```dart
/// final m = server.migrator;
/// if (!await m.hasColumn('posts', 'slug')) {
///   await m.addColumn('posts', 'slug', 'text');
///   await m.createIndex('posts', ['slug'], unique: true);
/// }
/// ```
class PlexivoMigrator {
  PlexivoMigrator._(this._run, this._one);
  final Future<List<Map<String, dynamic>>> Function(List<Map<String, dynamic>>) _run;
  final Future<Map<String, dynamic>> Function(String, [List<Object?>]) _one;

  Future<bool> _ok(String sql, List<Object?> params) async => ((await _one(sql, params))['rows'] as List).first['ok'] == true;

  /// Whether [table] exists.
  Future<bool> hasTable(String table) => _ok('SELECT to_regclass(\$1) IS NOT NULL AS ok', [_split(table).map((p) => '"$p"').join('.')]);

  /// Whether [table] has [column].
  Future<bool> hasColumn(String table, String column) => _ok(
      'SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = \$1 AND table_name = \$2 AND column_name = \$3) AS ok',
      [..._split(table), column]);

  /// The columns of [table], in order: `name`, `type`, `nullable` and `default`.
  Future<List<Map<String, dynamic>>> columns(String table) async => ((await _one(
          'SELECT column_name AS name, data_type AS type, is_nullable = \'YES\' AS nullable, column_default AS "default" FROM information_schema.columns WHERE table_schema = \$1 AND table_name = \$2 ORDER BY ordinal_position',
          _split(table)))['rows'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  /// Creates the missing tables, columns and indexes for [models], and returns the SQL it ran.
  ///
  /// It never drops or changes anything. New tables also get their policies and
  /// row-level security; existing tables only gain missing columns and indexes.
  /// Throws an [ArgumentError] if a model has no [PlexivoModel.columns].
  Future<List<String>> autoMigrate(List<PlexivoModel> models) async {
    final statements = <Map<String, dynamic>>[];
    for (final m in models) {
      final cols = m.columns;
      if (cols == null) throw ArgumentError('autoMigrate needs columns on the ${m.table} model');
      final exists = await hasTable(m.table);
      if (!exists) {
        statements.addAll(_createTable(m.table, cols, compositeKey: m.compositeKey, uniques: m.uniques, checks: m.checks));
      } else {
        final have = (await columns(m.table)).map((c) => c['name']).toSet();
        for (final e in cols.entries) {
          if (!have.contains(e.key)) statements.add(_stmt('ALTER TABLE ${_ident(m.table)} ADD COLUMN IF NOT EXISTS ${columnSql(e.key, e.value)}'));
        }
      }
      statements.addAll(_indexes(m.table, m.indexes, cols));
      if (!exists) statements.addAll(_security(m.table, m.policies, m.rowLevelSecurity));
    }
    if (statements.isNotEmpty) await _run(statements);
    return statements.map((s) => s['sql'] as String).toList();
  }

  /// Creates [table] with [columns], if it does not exist, plus its [indexes] and [policies].
  ///
  /// Policies also turn on row-level security. Use [compositeKey] for a key
  /// over several columns.
  Future<void> createTable(String table, Map<String, Object> columns,
          {List<Map<String, dynamic>> indexes = const [], List<Map<String, dynamic>> policies = const [], List<String>? compositeKey}) =>
      _run([..._createTable(table, columns, compositeKey: compositeKey), ..._indexes(table, indexes, columns), ..._security(table, policies, null)]);

  /// Drops [table] if it exists; [cascade] also drops what depends on it.
  Future<void> dropTable(String table, {bool cascade = false}) => _run([_stmt('DROP TABLE IF EXISTS ${_ident(table)}${cascade ? ' CASCADE' : ''}')]);

  /// Renames table [from] to [to].
  Future<void> renameTable(String from, String to) => _run([_stmt('ALTER TABLE ${_ident(from)} RENAME TO ${_ident(to)}')]);

  /// Adds column [name] with definition [def] (see [columnSql]), if missing.
  Future<void> addColumn(String table, String name, Object def) =>
      _run([_stmt('ALTER TABLE ${_ident(table)} ADD COLUMN IF NOT EXISTS ${columnSql(name, def)}')]);

  /// Drops column [name] from [table], if it exists.
  Future<void> dropColumn(String table, String name) => _run([_stmt('ALTER TABLE ${_ident(table)} DROP COLUMN IF EXISTS ${_ident(name)}')]);

  /// Renames column [from] of [table] to [to].
  Future<void> renameColumn(String table, String from, String to) =>
      _run([_stmt('ALTER TABLE ${_ident(table)} RENAME COLUMN ${_ident(from)} TO ${_ident(to)}')]);

  /// Changes the type of column [name] to [type], converting with [using] when given.
  Future<void> alterColumnType(String table, String name, String type, {String? using}) =>
      _run([_stmt('ALTER TABLE ${_ident(table)} ALTER COLUMN ${_ident(name)} TYPE $type${using == null ? '' : ' USING $using'}')]);

  /// Creates an index on [columns] of [table], if it does not exist.
  ///
  /// [unique] makes it unique; [name] defaults to `<table>_<columns>_idx` (or
  /// `_key`); [using] picks the method, such as `gin`; [where] makes it partial.
  Future<void> createIndex(String table, List<String> columns, {bool unique = false, String? name, String? using, String? where}) => _run(_indexes(
      table,
      [
        {'columns': columns, 'unique': unique, if (name != null) 'name': name, if (using != null) 'using': using, if (where != null) 'where': where}
      ],
      null));

  /// Drops index [name], if it exists.
  Future<void> dropIndex(String name) => _run([_stmt('DROP INDEX IF EXISTS ${_ident(name)}')]);

  /// Turns on row-level security for [table].
  Future<void> enableRowLevelSecurity(String table) => _run([_stmt('ALTER TABLE ${_ident(table)} ENABLE ROW LEVEL SECURITY')]);

  /// Creates a row-level security [policy] on [table].
  ///
  /// See [PlexivoModel.policies] for its keys.
  Future<void> createPolicy(String table, Map<String, dynamic> policy) => _run([_policySql(table, policy)]);

  /// Drops policy [name] from [table], if it exists.
  Future<void> dropPolicy(String table, String name) => _run([_stmt('DROP POLICY IF EXISTS ${_ident(name)} ON ${_ident(table)}')]);

  /// Starts a plan: changes collected to run later, together.
  PlexivoMigrationPlan plan() => PlexivoMigrationPlan._();
}

/// Statements collected for one migration, run together in one transaction.
///
/// Each method adds a statement and returns the plan, so calls chain. Use
/// [sql] for anything else, such as renaming a table.
class PlexivoMigrationPlan {
  PlexivoMigrationPlan._();

  /// The statements so far, each `{'sql': …, 'params': [...]}`.
  final List<Map<String, dynamic>> statements = [];

  /// Adds SQL [text] with `$1`, `$2` … [params].
  PlexivoMigrationPlan sql(String text, [List<Object?> params = const []]) {
    statements.add({'sql': text, 'params': params.map(_param).toList()});
    return this;
  }

  /// Adds creating [table] with [columns], [indexes] and [policies]; see [PlexivoMigrator.createTable].
  PlexivoMigrationPlan createTable(String table, Map<String, Object> columns,
      {List<Map<String, dynamic>> indexes = const [], List<Map<String, dynamic>> policies = const [], List<String>? compositeKey}) {
    statements.addAll([..._createTable(table, columns, compositeKey: compositeKey), ..._indexes(table, indexes, columns), ..._security(table, policies, null)]);
    return this;
  }

  /// Adds dropping [table]; [cascade] also drops what depends on it.
  PlexivoMigrationPlan dropTable(String table, {bool cascade = false}) => sql('DROP TABLE IF EXISTS ${_ident(table)}${cascade ? ' CASCADE' : ''}');

  /// Adds adding column [name] with definition [def] (see [columnSql]).
  PlexivoMigrationPlan addColumn(String table, String name, Object def) => sql('ALTER TABLE ${_ident(table)} ADD COLUMN IF NOT EXISTS ${columnSql(name, def)}');

  /// Adds dropping column [name] from [table].
  PlexivoMigrationPlan dropColumn(String table, String name) => sql('ALTER TABLE ${_ident(table)} DROP COLUMN IF EXISTS ${_ident(name)}');

  /// Adds renaming column [from] of [table] to [to].
  PlexivoMigrationPlan renameColumn(String table, String from, String to) => sql('ALTER TABLE ${_ident(table)} RENAME COLUMN ${_ident(from)} TO ${_ident(to)}');

  /// Adds an index on [columns] of [table]; [unique] and [name] as in [PlexivoMigrator.createIndex].
  PlexivoMigrationPlan createIndex(String table, List<String> columns, {bool unique = false, String? name}) {
    statements.addAll(_indexes(
        table,
        [
          {'columns': columns, 'unique': unique, if (name != null) 'name': name}
        ],
        null));
    return this;
  }

  /// Adds dropping index [name].
  PlexivoMigrationPlan dropIndex(String name) => sql('DROP INDEX IF EXISTS ${_ident(name)}');

  /// Adds turning on row-level security for [table].
  PlexivoMigrationPlan enableRowLevelSecurity(String table) => sql('ALTER TABLE ${_ident(table)} ENABLE ROW LEVEL SECURITY');

  /// Adds a row-level security [policy] on [table]; see [PlexivoModel.policies].
  PlexivoMigrationPlan createPolicy(String table, Map<String, dynamic> policy) {
    statements.add(_policySql(table, policy));
    return this;
  }
}
