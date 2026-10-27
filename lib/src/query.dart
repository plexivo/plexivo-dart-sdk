import 'dart:async';

import 'errors.dart';
import 'result.dart';

/// Marks an argument that was not passed (so `where('a', null)` differs from `where('a')`).
const Object _absent = Object();

const Map<String, String> _operators = {
  '=': 'eq',
  '==': 'eq',
  'eq': 'eq',
  '!=': 'neq',
  '<>': 'neq',
  'neq': 'neq',
  '>': 'gt',
  'gt': 'gt',
  '>=': 'gte',
  'gte': 'gte',
  '<': 'lt',
  'lt': 'lt',
  '<=': 'lte',
  'lte': 'lte',
  'like': 'like',
  'ilike': 'ilike',
  'match': 'match',
  'imatch': 'imatch',
  '~': 'match',
  '~*': 'imatch',
  'in': 'in',
  'is': 'is',
  'contains': 'cs',
  '@>': 'cs',
  'cs': 'cs',
  'contained by': 'cd',
  'containedby': 'cd',
  '<@': 'cd',
  'cd': 'cd',
  'overlaps': 'ov',
  '&&': 'ov',
  'ov': 'ov',
  'fts': 'fts',
  'plfts': 'plfts',
  'phfts': 'phfts',
  'wfts': 'wfts',
  'search': 'wfts',
};
const Map<String, String> _negated = {'not in': 'in', 'is not': 'is', 'not like': 'like', 'not ilike': 'ilike'};
const int _maxRows = 1000;

Object? _plain(Object? v) => v is DateTime ? v.toUtc().toIso8601String() : v;

/// Turns `where(...)` arguments into one filter node of the Data API's structured form.
///
/// Used by every `where` method. Throws an [ArgumentError] for an unknown
/// operator or an empty column.
Map<String, dynamic> condition(Object a, [Object? b = _absent, Object? c = _absent, TableContext? ctx]) {
  if (a is PlexivoConditions Function(PlexivoConditions)) {
    final group = a(PlexivoConditions._(ctx));
    return group.node() ?? {'and': <dynamic>[]};
  }
  if (a is Function) {
    final group = (a as dynamic)(PlexivoConditions._(ctx));
    return (group is PlexivoConditions ? group.node() : null) ?? {'and': <dynamic>[]};
  }
  if (a is PlexivoConditions) return a.node() ?? {'and': <dynamic>[]};
  if (a is Map) {
    final parts = a.entries.map((e) => condition(e.key.toString(), e.value)).toList();
    return parts.length == 1 ? parts.first : {'and': parts};
  }
  if (a is! String || a.isEmpty) throw ArgumentError('where() takes a column, a map or a function');
  if (identical(c, _absent)) {
    final value = identical(b, _absent) ? null : b;
    if (value is List) return {'column': a, 'op': 'in', 'value': value.map(_plain).toList()};
    if (value == null) return {'column': a, 'op': 'is', 'value': null};
    return {'column': a, 'op': 'eq', 'value': _plain(value)};
  }
  final raw = b.toString().trim().toLowerCase();
  final value = c is List ? c.map(_plain).toList() : _plain(c);
  if (_negated.containsKey(raw))
    return {
      'not': {'column': a, 'op': _negated[raw], 'value': value}
    };
  final fts = RegExp(r'^(fts|plfts|phfts|wfts)\(([a-z_]+)\)$').firstMatch(raw);
  final op = fts != null ? raw : _operators[raw];
  if (op == null) throw ArgumentError('Unknown operator $b');
  if (op == 'eq' && value == null) return {'column': a, 'op': 'is', 'value': null};
  if (op == 'neq' && value == null)
    return {
      'not': {'column': a, 'op': 'is', 'value': null}
    };
  return {'column': a, 'op': op, 'value': value};
}

/// Combines terms as SQL does: AND binds tighter than OR.
Map<String, dynamic>? _combine(List<List<Object>> terms) {
  if (terms.isEmpty) return null;
  final groups = <List<Map<String, dynamic>>>[[]];
  for (final t in terms) {
    if (t[0] == 'or' && groups.last.isNotEmpty) groups.add([]);
    groups.last.add(t[1] as Map<String, dynamic>);
  }
  final ands = groups.map((g) => g.length == 1 ? g.first : <String, dynamic>{'and': g}).toList();
  return ands.length == 1 ? ands.first : {'or': ands};
}

List<String> _splitTop(String s, [String sep = ',']) {
  final parts = <String>[];
  var depth = 0;
  var quoted = false;
  final cur = StringBuffer();
  for (final ch in s.split('')) {
    if (ch == '"') quoted = !quoted;
    if (!quoted && ch == '(') depth++;
    if (!quoted && ch == ')') depth--;
    if (!quoted && depth == 0 && ch == sep) {
      parts.add(cur.toString());
      cur.clear();
    } else {
      cur.write(ch);
    }
  }
  parts.add(cur.toString());
  return parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
}

/// Reads a PostgREST select string into structured select items.
///
/// Handles columns, `alias:column`, `column as alias`, `column::text`, `*`,
/// embeds (`author:authors(name)`, `comments!inner(id)`,
/// `posts!fk_author(id)`) and counts (`comments(count)`).
///
/// ```dart
/// parseSelect('id, title as heading, author:authors(name)');
/// // ['id', {'column': 'title', 'as': 'heading'},
/// //  {'embed': 'authors', 'as': 'author', 'select': ['name']}]
/// ```
///
/// Throws an [ArgumentError] for an item it cannot read.
List<Object> parseSelect(String spec) {
  final items = <Object>[];
  final embedRe = RegExp(r'^(?:([A-Za-z_]\w*):)?([A-Za-z_][\w.]*)(?:!([A-Za-z_]\w*))?\((.*)\)$', dotAll: true);
  final colRe = RegExp(r'^(?:([A-Za-z_]\w*):)?([A-Za-z_]\w*|\*)(?:::(text))?$');
  final asRe = RegExp(r'^([A-Za-z_]\w*)\s+as\s+([A-Za-z_]\w*)$', caseSensitive: false);
  for (final part in _splitTop(spec)) {
    final as = asRe.firstMatch(part);
    if (as != null) {
      items.add({'column': as[1], 'as': as[2]});
      continue;
    }
    final e = embedRe.firstMatch(part);
    if (e != null) {
      final alias = e[1], table = e[2]!, hint = e[3], inner = e[4]!.trim();
      if (inner == 'count') {
        items.add({'aggregate': table, 'as': alias ?? table, 'count': true, if (hint != null && hint != 'inner') 'hint': hint});
        continue;
      }
      final sub = inner.isEmpty || inner == '*' ? null : parseSelect(inner);
      items.add({
        'embed': table,
        'as': alias ?? table.split('.').last,
        if (hint == 'inner') 'inner': true,
        if (hint != null && hint != 'inner') 'hint': hint,
        if (sub != null) 'select': sub.any((x) => x is String || (x is Map && x.containsKey('column'))) ? sub : ['*', ...sub],
      });
      continue;
    }
    final m = colRe.firstMatch(part);
    if (m == null) throw ArgumentError('cannot read select item $part');
    if (m[2] == '*') {
      items.add('*');
    } else if (m[1] != null || m[3] != null) {
      items.add({'column': m[2], if (m[1] != null) 'as': m[1], if (m[3] != null) 'text': true});
    } else {
      items.add(m[2]!);
    }
  }
  return items;
}

Map<String, dynamic> _restCondition(String column, String op, String raw) {
  String unquote(String v) => RegExp(r'^".*"$').hasMatch(v) ? v.substring(1, v.length - 1).replaceAll(r'\"', '"') : v;
  String strip(String v) => v.startsWith('(') && v.endsWith(')') ? v.substring(1, v.length - 1) : v;
  if (op == 'in') return {'column': column, 'op': 'in', 'value': _splitTop(strip(raw)).map(unquote).toList()};
  if (op == 'is') {
    return {
      'column': column,
      'op': 'is',
      'value': raw == 'null'
          ? null
          : raw == 'true'
              ? true
              : raw == 'false'
                  ? false
                  : raw
    };
  }
  if (op == 'cs' || op == 'cd' || op == 'ov') {
    if (raw.startsWith('{') && raw.endsWith('}') && !raw.contains(':')) {
      return {'column': column, 'op': op, 'value': _splitTop(raw.substring(1, raw.length - 1)).map(unquote).toList()};
    }
  }
  return {'column': column, 'op': op, 'value': unquote(raw)};
}

/// Reads a PostgREST logic string into a filter tree, joining its parts with [joiner].
///
/// ```dart
/// parseLogic('status.eq.open,and(priority.gte.3,owner.is.null)');
/// ```
///
/// Supports `not.` prefixes, nested `and(...)`/`or(...)` groups, `in.(a,b)`,
/// `is.null`/`is.true`/`is.false`, and quoted values. Throws an
/// [ArgumentError] for a condition it cannot read.
Map<String, dynamic> parseLogic(String spec, [String joiner = 'or']) {
  var s = spec.trim();
  if (s.startsWith('(') && s.endsWith(')')) s = s.substring(1, s.length - 1);
  final nodes = _splitTop(s).map((part) {
    final neg = part.startsWith('not.');
    final body = neg ? part.substring(4) : part;
    final group = RegExp(r'^(and|or)\((.*)\)$', dotAll: true).firstMatch(body);
    Map<String, dynamic> node;
    if (group != null) {
      node = parseLogic(group[2]!, group[1]!);
    } else {
      final m = RegExp(r'^([A-Za-z_]\w*)\.(not\.)?([a-z]+(?:\([a-z_]+\))?)\.(.*)$', dotAll: true).firstMatch(body);
      if (m == null) throw ArgumentError('cannot read condition $part');
      node = _restCondition(m[1]!, m[3]!, m[4]!);
      if (m[2] != null) node = {'not': node};
    }
    return neg ? <String, dynamic>{'not': node} : node;
  }).toList();
  return nodes.length == 1 ? nodes.first : {joiner: nodes};
}

/// Filters alone, for a group in parentheses.
///
/// A function given to `where` gets one, and its filters become a single
/// group:
///
/// ```dart
/// db.from('tasks')
///     .where('owner_id', me)
///     .where((PlexivoConditions q) => q.where('status', 'open').orWhere('priority', '>=', 3));
/// // owner_id = me AND (status = 'open' OR priority >= 3)
/// ```
class PlexivoConditions {
  PlexivoConditions._(this._ctx, [Map<String, dynamic>? state]) : _s = {'terms': <List<Object>>[], ...?state};

  final TableContext? _ctx;
  final Map<String, dynamic> _s;

  PlexivoConditions _with(Map<String, dynamic> patch) => PlexivoConditions._(_ctx, {..._s, ...patch});
  List<List<Object>> get _terms => (_s['terms'] as List).cast<List<Object>>();
  PlexivoConditions _term(String joiner, Map<String, dynamic> node) => _with({
        'terms': [
          ..._terms,
          [joiner, node]
        ]
      });

  /// These filters as a tree, or null when there are none.
  Map<String, dynamic>? node() => _combine(_terms);

  /// Adds a filter, joined with AND; the same forms as [PlexivoQuery.where].
  PlexivoConditions where(Object column, [Object? op = _absent, Object? value = _absent]) => _term('and', condition(column, op, value, _ctx));

  /// Adds a filter joined with OR; AND binds tighter, as in SQL.
  PlexivoConditions orWhere(Object column, [Object? op = _absent, Object? value = _absent]) => _term('or', condition(column, op, value, _ctx));

  /// Adds a negated filter, `NOT (…)`, joined with AND.
  PlexivoConditions whereNot(Object column, [Object? op = _absent, Object? value = _absent]) => _term('and', {'not': condition(column, op, value, _ctx)});

  /// Keeps rows whose [column] is one of [values].
  PlexivoConditions whereIn(String column, List<Object?> values) => where(column, 'in', values);

  /// Keeps rows where [column] is null.
  PlexivoConditions whereNull(String column) => where(column, 'is', null);

  /// Keeps rows where [column] is not null.
  PlexivoConditions whereNotNull(String column) => where(column, 'is not', null);

  /// Keeps rows where [column] equals [value]; null means `IS NULL`.
  PlexivoConditions eq(String column, Object? value) => where(column, '=', value);

  /// Keeps rows where [column] is greater than [value].
  PlexivoConditions gt(String column, Object? value) => where(column, '>', value);

  /// Keeps rows where [column] is less than [value].
  PlexivoConditions lt(String column, Object? value) => where(column, '<', value);

  /// Keeps rows with a matching related row; see [PlexivoQuery.whereHas].
  ///
  /// Throws when the group was not built for a table.
  PlexivoConditions whereHas(String relation, [Function? callback]) => _term('and', _ctx!.has(relation, callback));
}

/// One table: the context a query compiles and runs against.
///
/// The client and models provide it; apps don't need to.
abstract class TableContext {
  /// The table name.
  String get table;

  /// The primary-key column.
  String get primaryKey;

  /// The soft-delete column, or null.
  String? get softDelete;

  /// Whether operations are recorded for a transaction instead of sent at once.
  bool get deferred;

  /// Sends one structured operation [op] and returns the response.
  Future<Map<String, dynamic>> run(Map<String, dynamic> op);

  /// Runs an operation, or records it in a transaction; see [DataLayer.send].
  Future<T> send<T>(FutureOr<Map<String, dynamic>> Function() build, FutureOr<T> Function(Map<String, dynamic> result) finish, String shape);

  /// The filter node for "a related row exists" through [relation].
  Map<String, dynamic> has(String relation, Function? callback);

  /// The select item that embeds [relation], as an inner join when [inner] is true.
  Map<String, dynamic> embed(String relation, Function? callback, bool inner, [String? as]);

  /// The select item that aggregates rows of [relation] by [spec].
  Map<String, dynamic> aggregateEmbed(String relation, Function? callback, Map<String, dynamic> spec, String? as, bool countOnly);

  /// The model scope called [name]; throws an [ArgumentError] when there is none.
  PlexivoQuery Function(PlexivoQuery) scope(String name);

  /// Reshapes raw [rows] for their [embeds], such as many-to-many lists and counts.
  List<Map<String, dynamic>> shape(List<Map<String, dynamic>> rows, List<Map<String, dynamic>> embeds);

  /// Runs the model's afterFind hook on [rows].
  Future<List<Map<String, dynamic>>> afterFind(List<Map<String, dynamic>> rows);

  /// Runs the model's before-hooks for a write of [kind] on [rows].
  Future<List<Map<String, dynamic>>> beforeWrite(String kind, List<Map<String, dynamic>> rows);

  /// Runs the model's after-hooks for a write of [kind] on [rows].
  Future<void> afterWrite(String kind, List<Map<String, dynamic>> rows);

  /// The context of another [table], with its model.
  TableContext child(String table);
}

Map<String, dynamic> _orderTerm(Object column, [Object? dir, bool? ascending, String? nulls]) {
  if (column is Map) return Map<String, dynamic>.from(column);
  var col = column.toString().trim();
  var d = 'asc';
  if (dir != null) {
    d = dir.toString().toLowerCase();
  } else if (ascending != null) {
    d = ascending ? 'asc' : 'desc';
  } else if (col.contains(RegExp(r'\s'))) {
    final parts = col.split(RegExp(r'\s+'));
    col = parts[0];
    d = parts[1].toLowerCase();
  }
  if (d != 'asc' && d != 'desc') throw ArgumentError('order direction is asc or desc, not $dir');
  final agg = RegExp(r'^(count|sum|avg|min|max)\((\*|[A-Za-z_]\w*)?\)$', caseSensitive: false).firstMatch(col);
  final term = agg != null
      ? <String, dynamic>{'fn': agg[1]!.toLowerCase(), if (agg[2] != null && agg[2] != '*') 'column': agg[2], 'dir': d}
      : <String, dynamic>{'column': col, 'dir': d};
  if (nulls == 'first' || nulls == 'last') term['nulls'] = nulls;
  return term;
}

List<Object> _selectItems(List<Object> columns) {
  final out = <Object>[];
  for (final c in columns) {
    if (c is String) {
      out.addAll(parseSelect(c));
    } else if (c is List) {
      out.addAll(_selectItems(c.cast<Object>()));
    } else if (c is Map && (c.containsKey('embed') || c.containsKey('aggregate') || c.containsKey('column'))) {
      out.add(Map<String, dynamic>.from(c));
    } else if (c is Map) {
      c.forEach((as, column) => out.add({'column': column, 'as': as}));
    }
  }
  return out;
}

Map<String, dynamic> _clean(Map<String, dynamic> m) =>
    Map.fromEntries(m.entries.where((e) => e.value != null && !(e.value is List && (e.value as List).isEmpty)));

/// A query on one table: chainable, immutable, and run by `await`.
///
/// Get one from [PlexivoClient.from] or [PlexivoModel.query]. Each method
/// returns a new builder, so a base query can be reused safely. Awaiting a
/// builder runs it: a read returns a [PlexivoResult], and an [insert],
/// [upsert], [update] or [delete] builder runs that write. Terminal methods
/// such as [first], [find], [count], [create] and [paginate] run at once.
///
/// It speaks both dialects:
///
/// ```dart
/// // GORM-style
/// final posts = await db.from('posts')
///     .where('likes', '>', 10)
///     .where({'published': true, 'deleted_at': null}) // null means IS NULL
///     .orWhere('title', 'ilike', '%postgres%')        // AND binds tighter than OR
///     .whereHas('comments', (PlexivoEmbed c) => c.where('approved', true))
///     .preload('author')
///     .order('created_at', 'desc')
///     .page(2, 20);
///
/// // Supabase-style
/// final res = await db.from('notes')
///     .select('id, body, author:authors(name)', 'exact')
///     .eq('pinned', true)
///     .or('priority.gte.3,body.ilike.*urgent*')
///     .range(0, 19);
/// print(res.count); // every matching row, not just this page
/// ```
///
/// Operators for [where]: `=`, `!=` (`<>`), `>`, `>=`, `<`, `<=`, `like`,
/// `ilike`, `not like`, `not ilike`, `in`, `not in`, `is`, `is not`,
/// `contains` (`@>`), `contained by` (`<@`), `overlaps` (`&&`), `~`, `~*`,
/// and full-text `fts`, `plfts`, `phfts` and `wfts` (or `search`), optionally
/// with a configuration: `wfts(english)`.
///
/// An update or delete must say which rows it touches: without a filter it
/// throws a [PlexivoException] with code `missing_where`, unless
/// [allowGlobalUpdate] is set. A read returns at most 1,000 rows per call;
/// use [findInBatches] or [each] for more.
class PlexivoQuery implements Future<PlexivoResult> {
  /// Creates a query on a table context, with optional builder state.
  ///
  /// Use [PlexivoClient.from] or [PlexivoModel.query] instead.
  PlexivoQuery(this._ctx, [Map<String, dynamic>? state]) : _s = {'terms': <List<Object>>[], ...?state};

  final TableContext _ctx;
  final Map<String, dynamic> _s;
  Future<dynamic>? _run;

  /// The table this query reads or writes.
  String get table => _ctx.table;
  PlexivoQuery _with(Map<String, dynamic> patch) => PlexivoQuery(_ctx, {..._s, ...patch});
  List<List<Object>> get _terms => (_s['terms'] as List).cast<List<Object>>();
  PlexivoQuery _term(String joiner, Map<String, dynamic> node) => _with({
        'terms': [
          ..._terms,
          [joiner, node]
        ]
      });
  List<Map<String, dynamic>> get _embeds => ((_s['embeds'] as List?) ?? const []).cast<Map<String, dynamic>>();

  /// This builder's filter tree, without soft-delete conditions.
  ///
  /// Null when there are no filters.
  Map<String, dynamic>? node() => _combine(_terms);

  // ── filters ────────────────────────────────────────────────────────────

  /// Adds a filter, joined to the previous ones with AND.
  ///
  /// Forms:
  ///
  /// - `where('status', 'open')`: equals. A `null` value means `IS NULL`; a
  ///   `List` means `IN`.
  /// - `where('likes', '>', 10)`: an operator, as listed on [PlexivoQuery].
  /// - `where({'published': true, 'author_id': 7})`: several equalities.
  /// - `where((PlexivoConditions q) => q.where('a', 1).orWhere('b', 2))`: a
  ///   group in parentheses.
  ///
  /// `DateTime` values are sent as UTC ISO 8601. Throws an [ArgumentError] for
  /// an unknown operator or an empty column.
  PlexivoQuery where(Object column, [Object? op = _absent, Object? value = _absent]) => _term('and', condition(column, op, value, _ctx));

  /// Adds a filter joined with OR.
  ///
  /// AND binds tighter than OR, as in SQL: `where(a).where(b).orWhere(c)` means
  /// `(a AND b) OR c`. Takes the same forms as [where].
  PlexivoQuery orWhere(Object column, [Object? op = _absent, Object? value = _absent]) => _term('or', condition(column, op, value, _ctx));

  /// Adds a negated filter, `NOT (…)`, joined with AND; the same forms as [where].
  PlexivoQuery whereNot(Object column, [Object? op = _absent, Object? value = _absent]) => _term('and', {'not': condition(column, op, value, _ctx)});

  /// Adds a negated filter, `NOT (…)`, joined with OR; the same forms as [where].
  PlexivoQuery orWhereNot(Object column, [Object? op = _absent, Object? value = _absent]) => _term('or', {'not': condition(column, op, value, _ctx)});

  /// Keeps rows whose [column] is one of [values] (`IN`).
  PlexivoQuery whereIn(String column, List<Object?> values) => where(column, 'in', values);

  /// Keeps rows whose [column] is none of [values] (`NOT IN`).
  PlexivoQuery whereNotIn(String column, List<Object?> values) => where(column, 'not in', values);

  /// Keeps rows where [column] is null.
  PlexivoQuery whereNull(String column) => where(column, 'is', null);

  /// Keeps rows where [column] is not null.
  PlexivoQuery whereNotNull(String column) => where(column, 'is not', null);

  /// Keeps rows where [column] is from [low] to [high], both included.
  PlexivoQuery whereBetween(String column, Object low, Object high) => _term('and', {
        'and': [condition(column, '>=', low), condition(column, '<=', high)]
      });

  /// Keeps rows where [column] is outside [low] to [high].
  PlexivoQuery whereNotBetween(String column, Object low, Object high) => _term('and', {
        'not': {
          'and': [condition(column, '>=', low), condition(column, '<=', high)]
        }
      });

  /// Keeps rows where [column] matches [pattern] (`LIKE`, case-sensitive; `%` and `_` are wildcards).
  PlexivoQuery whereLike(String column, String pattern) => where(column, 'like', pattern);

  /// Keeps rows where [column] matches [pattern], ignoring case (`ILIKE`).
  PlexivoQuery whereILike(String column, String pattern) => where(column, 'ilike', pattern);

  /// Keeps rows whose array, range or JSON [column] contains [value] (`@>`).
  PlexivoQuery whereContains(String column, Object value) => where(column, 'contains', value);

  /// Keeps rows whose array or range [column] shares an element with [value] (`&&`).
  PlexivoQuery whereOverlaps(String column, List<Object?> value) => where(column, 'overlaps', value);

  /// Full-text search of [column] for [text], in web-search syntax.
  ///
  /// Quoted phrases, `or` and `-word` work as in a search box. [language] is a
  /// text-search configuration such as `english`; null uses the database
  /// default.
  PlexivoQuery whereSearch(String column, String text, [String? language]) => where(column, language == null ? 'wfts' : 'wfts($language)', text);

  /// Filters on a value inside a `json` or `jsonb` [column].
  ///
  /// [path] is dotted (`'address.city'`) or a list of keys. Pass an operator and
  /// a value, or just a value for equality:
  ///
  /// ```dart
  /// q.whereJson('meta', 'address.city', '=', 'Chennai');
  /// q.whereJson('meta', 'level', 2);
  /// ```
  PlexivoQuery whereJson(String column, Object path, Object? op, [Object? value = _absent]) {
    final keys = path is List ? path.map((e) => e.toString()).toList() : path.toString().split('.');
    final node = identical(value, _absent) ? condition('x', '=', op) : condition('x', op!, value);
    final leaf = (node['not'] ?? node) as Map<String, dynamic>;
    final built = <String, dynamic>{'column': column, 'path': keys, 'op': leaf['op'], 'value': leaf['value']};
    return _term('and', node.containsKey('not') ? {'not': built} : built);
  }

  /// Keeps rows that have at least one related row through [relation].
  ///
  /// [relation] is a relation of the table's model, or a related table name
  /// (with an optional `!constraint` hint). [callback] narrows the related rows:
  ///
  /// ```dart
  /// q.whereHas('comments', (PlexivoEmbed c) => c.where('approved', true));
  /// ```
  PlexivoQuery whereHas(String relation, [Function? callback]) => _term('and', _ctx.has(relation, callback));

  /// Like [whereHas], joined with OR.
  PlexivoQuery orWhereHas(String relation, [Function? callback]) => _term('or', _ctx.has(relation, callback));

  /// Keeps rows with no related row through [relation] (matching [callback], when given).
  PlexivoQuery whereDoesntHave(String relation, [Function? callback]) => _term('and', {'not': _ctx.has(relation, callback)});

  // Supabase / PostgREST names (`is` and `in` are Dart keywords: isFilter, inFilter).
  /// Supabase-style: [column] equals [value]; null means `IS NULL`.
  PlexivoQuery eq(String column, Object? value) => where(column, '=', value);

  /// Supabase-style: [column] does not equal [value].
  PlexivoQuery neq(String column, Object? value) => where(column, '!=', value);

  /// Supabase-style: [column] is greater than [value].
  PlexivoQuery gt(String column, Object? value) => where(column, '>', value);

  /// Supabase-style: [column] is greater than or equal to [value].
  PlexivoQuery gte(String column, Object? value) => where(column, '>=', value);

  /// Supabase-style: [column] is less than [value].
  PlexivoQuery lt(String column, Object? value) => where(column, '<', value);

  /// Supabase-style: [column] is less than or equal to [value].
  PlexivoQuery lte(String column, Object? value) => where(column, '<=', value);

  /// Supabase-style: [column] matches [pattern] (`LIKE`).
  PlexivoQuery like(String column, String pattern) => where(column, 'like', pattern);

  /// Supabase-style: [column] matches [pattern], ignoring case (`ILIKE`).
  PlexivoQuery ilike(String column, String pattern) => where(column, 'ilike', pattern);

  /// Supabase's `is`: [column] `IS` [value] (null, true or false).
  ///
  /// Named so because `is` is a Dart keyword.
  PlexivoQuery isFilter(String column, Object? value) => where(column, 'is', value);

  /// Supabase's `in`: [column] is one of [values].
  ///
  /// Named so because `in` is a Dart keyword.
  PlexivoQuery inFilter(String column, List<Object?> values) => where(column, 'in', values);

  /// Supabase-style: [column] contains [value] (`@>`).
  PlexivoQuery contains(String column, Object value) => where(column, 'contains', value);

  /// Supabase-style: [column] is contained by [value] (`<@`).
  PlexivoQuery containedBy(String column, Object value) => where(column, 'contained by', value);

  /// Supabase-style: [column] shares an element with [value] (`&&`).
  PlexivoQuery overlaps(String column, List<Object?> value) => where(column, 'overlaps', value);

  /// Supabase-style full-text search of [column] for [query].
  ///
  /// [type] is `plain`, `phrase` or `websearch`; null uses `to_tsquery` syntax.
  /// [config] is a text-search configuration such as `english`.
  PlexivoQuery textSearch(String column, String query, {String? type, String? config}) {
    final fn = const {'plain': 'plfts', 'phrase': 'phfts', 'websearch': 'wfts'}[type] ?? 'fts';
    return where(column, config == null ? fn : '$fn($config)', query);
  }

  /// Supabase-style: every column in [values] equals its value.
  PlexivoQuery match(Map<String, Object?> values) => where(values);

  /// Supabase-style negated filter with a PostgREST operator [op].
  ///
  /// `not('status', 'eq', 'done')`, or `not('id', 'in', [1, 2])`.
  PlexivoQuery not(String column, String op, Object? value) =>
      _term('and', {'not': _restCondition(column, op, value is List ? '(${value.join(',')})' : '$value')});

  /// Supabase-style OR group from a PostgREST logic string.
  ///
  /// `or('priority.gte.3,body.ilike.*urgent*')`. The group is joined to the
  /// other filters with AND. Throws an [ArgumentError] if it cannot be read.
  PlexivoQuery or(String filters) => _term('and', parseLogic(filters, 'or'));

  /// Supabase-style filter with a PostgREST operator [op], such as `cs` or `fts`.
  ///
  /// Prefix `not.` to negate it: `filter('status', 'not.eq', 'done')`.
  PlexivoQuery filter(String column, String op, Object? value) =>
      op.startsWith('not.') ? not(column, op.substring(4), value) : _term('and', _restCondition(column, op, value is List ? '(${value.join(',')})' : '$value'));

  // ── shaping ────────────────────────────────────────────────────────────

  /// Chooses the columns and related rows to return.
  ///
  /// [columns] is a PostgREST string
  /// (`'id, title as heading, author:authors(name), comments!inner(id)'`), a
  /// list of strings, or a map of `{'alias': 'column'}`. Without columns, or
  /// with `*`, every column is returned. Calling it again adds to the selection.
  ///
  /// Pass `'exact'` (any non-null value) as [count] to also get the total number
  /// of matching rows in [PlexivoResult.count]. Set [head] to get only that
  /// total, with no rows.
  PlexivoQuery select([Object? columns, String? count, bool head = false]) {
    final items = columns == null ? <Object>[] : _selectItems(columns is List ? columns.cast<Object>() : [columns]);
    final cols = items.where((x) => x is String || (x is Map && x.containsKey('column'))).toList();
    final embeds = items.whereType<Map<String, dynamic>>().where((x) => !x.containsKey('column')).toList();
    final keep = cols.where((c) => c != '*' || embeds.isNotEmpty || cols.length > 1).toList();
    var q = _with({
      'select': [...((_s['select'] as List?) ?? const []), ...keep],
      'embeds': [..._embeds, ...embeds]
    });
    if (count != null) q = q._with({'count': true});
    if (head) q = q._with({'head': true});
    return q;
  }

  /// Orders rows by [column]; later calls add tie-breakers.
  ///
  /// [dir] is `'asc'` (the default) or `'desc'`, or a bool meaning ascending;
  /// `'title desc'` in [column] works too. [nulls] is `'first'` or `'last'`.
  /// After [groupBy], [column] can be an aggregate such as `count(*)` or
  /// `sum(likes)`. Throws an [ArgumentError] for any other direction.
  PlexivoQuery order(Object column, [Object? dir, String? nulls]) => _with({
        'order': [...((_s['order'] as List?) ?? const []), _orderTerm(column, dir is String ? dir : null, dir is bool ? dir : null, nulls)]
      });

  /// Orders rows; the same as [order].
  PlexivoQuery orderBy(Object column, [Object? dir, String? nulls]) => order(column, dir, nulls);

  /// Newest first, by [column] (`created_at` by default).
  PlexivoQuery latest([String column = 'created_at']) => order(column, 'desc');

  /// Oldest first, by [column] (`created_at` by default).
  PlexivoQuery oldest([String column = 'created_at']) => order(column, 'asc');

  /// Returns at most [n] rows.
  PlexivoQuery limit(int n) => _with({'limit': n});

  /// Skips the first [n] rows.
  PlexivoQuery offset(int n) => _with({'offset': n});

  /// Returns page [number] (from 1) of [size] rows.
  ///
  /// Numbers below 1 mean the first page.
  PlexivoQuery page(int number, [int size = 20]) => _with({'limit': size, 'offset': (number < 1 ? 0 : number - 1) * size});

  /// Returns rows [from] to [to], both included and counted from 0, as in Supabase.
  PlexivoQuery range(int from, int to) => _with({'offset': from, 'limit': to - from + 1});

  /// Returns distinct rows: across the selected columns, or by [columns] only.
  PlexivoQuery distinct([List<String>? columns]) => _with({'distinct': columns == null || columns.isEmpty ? true : columns});

  /// Also returns related rows through [relation], like GORM's Preload.
  ///
  /// Rows without related rows are still returned. A has-many or many-to-many
  /// relation comes back as a list, a has-one as one map or null. [callback]
  /// shapes the related rows:
  ///
  /// ```dart
  /// q.preload('author', (PlexivoEmbed a) => a.select('name'))
  ///  .preload('comments', (PlexivoEmbed c) => c.where('approved', true).order('id').limit(5));
  /// ```
  PlexivoQuery preload(String relation, [Function? callback]) => _with({
        'embeds': [..._embeds, _ctx.embed(relation, callback, false)]
      });

  /// Like [preload], but keeps only rows with at least one matching related row (an inner join).
  PlexivoQuery joins(String relation, [Function? callback]) => _with({
        'embeds': [..._embeds, _ctx.embed(relation, callback, true)]
      });

  /// Adds the number of related rows as `<relation>_count`, or [as].
  ///
  /// [callback] counts only matching rows.
  PlexivoQuery withCount(String relation, [Function? callback, String? as]) => _with({
        'embeds': [
          ..._embeds,
          _ctx.aggregateEmbed(relation, callback, {'count': true}, as, true)
        ]
      });

  /// Adds aggregates of related rows as `<relation>_aggregate`, or [as].
  ///
  /// [spec] is like `{'count': true, 'sum': ['likes'], 'max': ['created_at']}`.
  PlexivoQuery withAggregate(String relation, Map<String, dynamic> spec, [Function? callback, String? as]) => _with({
        'embeds': [..._embeds, _ctx.aggregateEmbed(relation, callback, spec, as, false)]
      });

  /// Locks the rows a read selects until its transaction ends.
  ///
  /// [strength] is `update` or `share`; [wait] is `nowait` or `skip_locked`.
  /// Use it inside [PlexivoClient.transaction].
  PlexivoQuery lock([String strength = 'update', String? wait]) => _with({
        'lock': {'strength': strength, if (wait != null) 'wait': wait}
      });

  /// Locks the selected rows for update (`FOR UPDATE`), optionally [nowait] or [skipLocked].
  PlexivoQuery lockForUpdate({bool nowait = false, bool skipLocked = false}) => lock(
      'update',
      nowait
          ? 'nowait'
          : skipLocked
              ? 'skip_locked'
              : null);

  /// Locks the selected rows for share (`FOR SHARE`), optionally [nowait] or [skipLocked].
  PlexivoQuery forShare({bool nowait = false, bool skipLocked = false}) => lock(
      'share',
      nowait
          ? 'nowait'
          : skipLocked
              ? 'skip_locked'
              : null);

  /// Groups rows by one column or a list, for [aggregate].
  PlexivoQuery groupBy(Object columns) => _with({
        'groupBy': [
          ...((_s['groupBy'] as List?) ?? const []),
          ...(columns is List ? columns : [columns])
        ]
      });

  /// Filters groups after [groupBy].
  ///
  /// `having('count', '>', 1)`, `having('sum', '>=', 100, 'likes')`, or as one
  /// expression: `having('sum(likes) > ?', 100)`.
  PlexivoQuery having(String fnOrExpression, Object opOrValue, [Object? value = _absent, String? column]) {
    String fn;
    String? col = column;
    Object op;
    Object? v;
    final expr =
        RegExp(r'^\s*(count|sum|avg|min|max)\s*\(\s*(\*|[A-Za-z_]\w*)?\s*\)\s*(=|!=|<>|>=|<=|>|<)\s*\?\s*$', caseSensitive: false).firstMatch(fnOrExpression);
    if (expr != null) {
      fn = expr[1]!.toLowerCase();
      col = expr[2] == '*' ? null : expr[2];
      op = expr[3]!;
      v = opOrValue;
    } else {
      fn = fnOrExpression.toLowerCase();
      op = opOrValue;
      v = identical(value, _absent) ? null : value;
    }
    final leaf = condition('x', op, v);
    return _with({
      'having': [
        ...((_s['having'] as List?) ?? const []),
        _clean({'fn': fn, 'column': col, 'op': leaf['op'], 'value': leaf['value']})
      ]
    });
  }

  /// Applies reusable query pieces: functions, or the names of model scopes.
  ///
  /// ```dart
  /// q.scopes(['popular', (PlexivoQuery q) => q.where('lang', 'en')]);
  /// ```
  ///
  /// Throws an [ArgumentError] for a name the table's model does not define.
  PlexivoQuery scopes(List<Object> scopes) {
    var q = this;
    for (final s in scopes) {
      final fn = s is String ? _ctx.scope(s) : s as PlexivoQuery Function(PlexivoQuery);
      q = fn(q);
    }
    return q;
  }

  /// Includes soft-deleted rows; a delete then removes rows for good.
  PlexivoQuery unscoped() => _with({'unscoped': true});

  /// Returns only soft-deleted rows.
  PlexivoQuery onlyTrashed() => _with({'onlyTrashed': true});

  /// Lets an update or delete without a filter touch every row.
  ///
  /// Without it, such a write throws `missing_where`.
  PlexivoQuery allowGlobalUpdate() => _with({'allowGlobal': true});

  /// Sets what a write returns.
  ///
  /// `'minimal'` returns no rows: the result is empty but keeps its count.
  PlexivoQuery returning(String mode) => _with({'returning': mode});

  // ── compiling ──────────────────────────────────────────────────────────

  Map<String, dynamic>? _where() {
    final nodes = <Map<String, dynamic>>[];
    final base = node();
    if (base != null) nodes.add(base);
    final soft = _ctx.softDelete;
    if (soft != null && _s['onlyTrashed'] == true) {
      nodes.add({
        'not': {'column': soft, 'op': 'is', 'value': null}
      });
    } else if (soft != null && _s['unscoped'] != true) {
      nodes.add({'column': soft, 'op': 'is', 'value': null});
    }
    if (nodes.isEmpty) return null;
    return nodes.length == 1 ? nodes.first : {'and': nodes};
  }

  Map<String, dynamic> _writeWhere(String op) {
    if (node() == null && _s['allowGlobal'] != true) {
      throw PlexivoException(400, 'missing_where', message: 'an $op must say which rows it touches: add where(), or allowGlobalUpdate() to touch every row');
    }
    return _where() ??
        {
          'not': {'column': _ctx.primaryKey, 'op': 'is', 'value': null}
        };
  }

  /// The structured select operation this builder sends, without running it (GORM's DryRun).
  ///
  /// Includes soft-delete filters. [extra] keys are merged in.
  Map<String, dynamic> toQuery([Map<String, dynamic> extra = const {}]) {
    final select = [...((_s['select'] as List?) ?? const []), ..._embeds];
    final hasCols = ((_s['select'] as List?) ?? const []).isNotEmpty;
    return _clean({
      'op': 'select',
      'from': table,
      'select': select.isEmpty ? null : (hasCols ? select : ['*', ...select]),
      'where': _where(),
      'order': _s['order'],
      'limit': _s['limit'],
      'offset': _s['offset'],
      'distinct': _s['distinct'],
      'lock': _s['lock'],
      ...extra,
    });
  }

  /// Inside a transaction, a reference to a value from this operation's first row, for a later operation.
  ///
  /// ```dart
  /// await db.transaction((tx) {
  ///   final author = tx.from('authors').insert({'name': 'Asha'});
  ///   tx.from('posts').insert({'title': 'Hi', 'author_id': author.ref('id')});
  /// });
  /// ```
  ///
  /// An empty [path] refers to the whole row. Throws a [StateError] outside a
  /// transaction.
  Map<String, dynamic> ref([String path = '']) {
    final run = _run;
    if (run is! RefSource) throw StateError('ref() is for operations recorded inside a transaction');
    return (run as RefSource).ref(path);
  }

  // ── Future: awaiting runs the builder ──────────────────────────────────

  Future<dynamic> _execute() => _run ??= _s['write'] != null ? _runWrite() : _runRead();

  Future<dynamic> _runRead() {
    final single = _s['single'] as String?;
    final q = single != null ? limit(2) : this;
    return _ctx.send(() => q.toQuery(_s['count'] == true ? {'count': true} : {}), (r) async {
      final rows = await _ctx.afterFind(_ctx.shape(_rows(r['data']), _embeds));
      final count = (r['count'] as num?)?.toInt();
      if (single != null) return _single(rows, single, count);
      if (_s['head'] == true) return PlexivoResult([], count);
      return PlexivoResult(rows, count);
    }, 'rows');
  }

  Future<dynamic> _runWrite() {
    final w = _s['write'] as Map<String, dynamic>;
    final single = _s['single'] as String?;
    Future<dynamic> out;
    switch (w['kind']) {
      case 'insert':
        out = _insertRows(w['values'], returning: _s['returning'] as String?);
        break;
      case 'upsert':
        out = _upsert(w['values'], w['options'] as Map<String, dynamic>);
        break;
      case 'update':
        out = _update(Map<String, dynamic>.from(w['values'] as Map), returning: _s['returning'] as String?);
        break;
      default:
        out = _delete(returning: _s['returning'] as String?);
    }
    return single == null ? out : out.then((rows) => _single((rows as PlexivoResult).toList(), single, null));
  }

  PlexivoSingle _single(List<Map<String, dynamic>> rows, String mode, int? count) {
    if (rows.length > 1) throw PlexivoException(406, 'multiple_rows', message: 'more than one row in $table');
    if (rows.isEmpty && mode == 'one') throw RecordNotFoundException(table);
    return PlexivoSingle(rows.isEmpty ? null : rows.first, count ?? rows.length);
  }

  /// Runs the query and returns exactly one row as a [PlexivoSingle].
  ///
  /// Throws a [RecordNotFoundException] when no row matches, and a
  /// [PlexivoException] with code `multiple_rows` (406) when more than one does.
  /// Works after a write too: `insert(row).select().single()`.
  Future<PlexivoSingle> single() => _with({'single': 'one'})._execute().then((v) => v as PlexivoSingle);

  /// Runs the query and returns one row, or a [PlexivoSingle] whose `data` is null.
  ///
  /// Throws a [PlexivoException] with code `multiple_rows` when more than one
  /// row matches.
  Future<PlexivoSingle> maybeSingle() => _with({'single': 'maybe'})._execute().then((v) => v as PlexivoSingle);

  Future<PlexivoResult> _asResult() => _execute().then((v) => v is PlexivoResult ? v : PlexivoResult([if (v is PlexivoSingle && v.data != null) v.data!]));

  @override
  Future<R> then<R>(FutureOr<R> Function(PlexivoResult value) onValue, {Function? onError}) => _asResult().then(onValue, onError: onError);
  @override
  Future<PlexivoResult> catchError(Function onError, {bool Function(Object error)? test}) => _asResult().catchError(onError, test: test);
  @override
  Future<PlexivoResult> whenComplete(FutureOr<void> Function() action) => _asResult().whenComplete(action);
  @override
  Future<PlexivoResult> timeout(Duration timeLimit, {FutureOr<PlexivoResult> Function()? onTimeout}) => _asResult().timeout(timeLimit, onTimeout: onTimeout);
  @override
  Stream<PlexivoResult> asStream() => _asResult().asStream();

  // ── reading ────────────────────────────────────────────────────────────

  /// Runs the read and returns the rows.
  ///
  /// With [ids], only rows whose primary key is one of them. Returns up to the
  /// limit, and at most 1,000 rows per call.
  Future<PlexivoResult> find([List<Object?>? ids]) {
    final q = ids == null ? this : whereIn(_ctx.primaryKey, ids);
    return _ctx.send(
        () => q.toQuery(), (r) async => PlexivoResult(await _ctx.afterFind(_ctx.shape(_rows(r['data']), q._embeds)), (r['count'] as num?)?.toInt()), 'rows');
  }

  /// Runs the read and returns the rows; the same as [find].
  Future<PlexivoResult> get([List<Object?>? ids]) => find(ids);

  /// The first row, or the row whose primary key is [id].
  ///
  /// Orders by primary key unless the query has an order. Throws a
  /// [RecordNotFoundException] when no row matches; use [firstOrNull] to get
  /// null instead.
  ///
  /// ```dart
  /// final post = await db.from('posts').first(7);
  /// final newest = await db.from('posts').latest().first();
  /// ```
  Future<Map<String, dynamic>> first([Object? id]) async {
    final q = id == null ? this : where(_ctx.primaryKey, id);
    final ordered = (q._s['order'] as List?)?.isNotEmpty == true ? q : q.order(_ctx.primaryKey, 'asc');
    final rows = await ordered.limit(1).find();
    if (rows.isEmpty) throw RecordNotFoundException(table);
    return rows.first;
  }

  /// The last row: the query's order reversed, or the highest primary key.
  ///
  /// Throws a [RecordNotFoundException] when no row matches.
  Future<Map<String, dynamic>> last() async {
    final order = (_s['order'] as List?)?.cast<Map<String, dynamic>>();
    final q = order != null && order.isNotEmpty
        ? _with({
            'order': order.map((t) => {...t, 'dir': t['dir'] == 'desc' ? 'asc' : 'desc'}).toList()
          })
        : this.order(_ctx.primaryKey, 'desc');
    final rows = await q.limit(1).find();
    if (rows.isEmpty) throw RecordNotFoundException(table);
    return rows.first;
  }

  /// One matching row, in no particular order.
  ///
  /// Throws a [RecordNotFoundException] when no row matches.
  Future<Map<String, dynamic>> take() async {
    final rows = await limit(1).find();
    if (rows.isEmpty) throw RecordNotFoundException(table);
    return rows.first;
  }

  /// Like [first], but returns null when no row matches.
  Future<Map<String, dynamic>?> firstOrNull([Object? id]) async {
    try {
      return await first(id);
    } on RecordNotFoundException {
      return null;
    }
  }

  /// The only matching row.
  ///
  /// Throws a [RecordNotFoundException] when none matches, and a
  /// [PlexivoException] with code `multiple_rows` when more than one does.
  Future<Map<String, dynamic>> sole() async {
    final rows = await limit(2).find();
    if (rows.isEmpty) throw RecordNotFoundException(table);
    if (rows.length > 1) throw PlexivoException(406, 'multiple_rows', message: 'more than one row in $table');
    return rows.first;
  }

  /// The values of one [column], one per matching row.
  Future<List<dynamic>> pluck(String column) async => (await _with({
        'select': [column],
        'embeds': <Object>[]
      }).find())
          .map((r) => r[column])
          .toList();

  /// The number of matching rows; limit, offset and order are ignored.
  Future<int> count() async {
    final r = await _ctx.run(_clean({'op': 'aggregate', 'from': table, 'where': _where(), 'count': true}));
    return ((r['data'] as Map)['count'] as num).toInt();
  }

  /// Whether at least one row matches.
  Future<bool> exists() async => (await limit(1)._with({
        'select': [_ctx.primaryKey],
        'embeds': <Object>[]
      }).find())
          .isNotEmpty;

  /// The sum of [column] over matching rows, or null when there are none.
  Future<num?> sum(String column) async => _num(((await _aggregate({
        'sum': [column]
      }))['sum'] as Map?)?[column]);

  /// The average of [column] over matching rows, or null when there are none.
  Future<num?> avg(String column) async => _num(((await _aggregate({
        'avg': [column]
      }))['avg'] as Map?)?[column]);

  /// The smallest value of [column], or null when no row matches.
  Future<Object?> min(String column) async => ((await _aggregate({
        'min': [column]
      }))['min'] as Map?)?[column];

  /// The largest value of [column], or null when no row matches.
  Future<Object?> max(String column) async => ((await _aggregate({
        'max': [column]
      }))['max'] as Map?)?[column];

  /// Aggregates matching rows by [spec], such as `{'count': true, 'sum': ['likes']}`.
  ///
  /// Returns one map, or after [groupBy] a list with one map per group, where
  /// [having], [order] and [limit] apply.
  ///
  /// ```dart
  /// final perAuthor = await db.from('posts')
  ///     .groupBy('author_id')
  ///     .having('count', '>', 1)
  ///     .order('count(*)', 'desc')
  ///     .aggregate({'count': true, 'sum': ['likes']});
  /// ```
  Future<dynamic> aggregate([Map<String, dynamic> spec = const {'count': true}]) async {
    final group = (_s['groupBy'] as List?) ?? const [];
    if (group.isNotEmpty) {
      final having = (_s['having'] as List?) ?? const [];
      final r = await _ctx.run(_clean({
        'op': 'aggregate',
        'from': table,
        'where': _where(),
        'group_by': group,
        'having': having.isEmpty ? null : (having.length == 1 ? having.first : {'and': having}),
        'order': _s['order'],
        'limit': _s['limit'],
        ..._aggSpec(spec),
      }));
      return (r['data'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return _aggregate(spec);
  }

  Future<Map<String, dynamic>> _aggregate(Map<String, dynamic> spec) async {
    final r = await _ctx.run(_clean({'op': 'aggregate', 'from': table, 'where': _where(), ..._aggSpec(spec)}));
    return Map<String, dynamic>.from(r['data'] as Map);
  }

  /// One page of rows with the totals: a [PlexivoPage].
  ///
  /// [page] counts from 1. Runs one request that also counts every matching row.
  ///
  /// ```dart
  /// final p = await db.from('posts').latest().paginate(page: 2, perPage: 20);
  /// print('${p.page} of ${p.totalPages}: ${p.data.length} of ${p.total}');
  /// ```
  Future<PlexivoPage> paginate({int page = 1, int perPage = 20}) async {
    final q = this.page(page, perPage);
    final r = await _ctx.run(q.toQuery({'count': true}));
    final total = (r['count'] as num?)?.toInt() ?? 0;
    final rows = await _ctx.afterFind(_ctx.shape(_rows(r['data']), q._embeds));
    return PlexivoPage(rows, total, page, perPage, total == 0 ? 1 : (total / perPage).ceil());
  }

  /// Reads every matching row in batches of [size], by primary key with a cursor (GORM's FindInBatches).
  ///
  /// [callback] gets each batch and its index from 0; return `false` to stop.
  /// [size] is kept between 1 and 1,000. The query's own order and limit are
  /// replaced by primary-key order.
  ///
  /// ```dart
  /// await db.from('events').where('kind', 'click').findInBatches(500, (rows, batch) async {
  ///   await export(rows);
  ///   return true;
  /// });
  /// ```
  Future<void> findInBatches(int size, FutureOr<bool?> Function(List<Map<String, dynamic>> rows, int batch) callback) async {
    final pk = _ctx.primaryKey;
    final n = size.clamp(1, _maxRows);
    Object? cursor;
    var batch = 0;
    while (true) {
      var q = _with({
        'order': [
          {'column': pk, 'dir': 'asc'}
        ],
        'limit': n
      });
      if (cursor != null) q = q.where(pk, '>', cursor);
      final rows = await q.find();
      if (rows.isEmpty) return;
      if (await callback(rows, batch++) == false) return;
      if (rows.length < n) return;
      cursor = rows.last[pk];
    }
  }

  /// Every matching row, read 500 at a time in primary-key order.
  ///
  /// ```dart
  /// await for (final row in db.from('events').each()) {
  ///   print(row['id']);
  /// }
  /// ```
  Stream<Map<String, dynamic>> each() async* {
    final pk = _ctx.primaryKey;
    Object? cursor;
    while (true) {
      var q = _with({
        'order': [
          {'column': pk, 'dir': 'asc'}
        ],
        'limit': 500
      });
      if (cursor != null) q = q.where(pk, '>', cursor);
      final rows = await q.find();
      for (final r in rows) {
        yield r;
      }
      if (rows.length < 500) return;
      cursor = rows.last[pk];
    }
  }

  // ── writing ────────────────────────────────────────────────────────────

  /// Inserts one row and returns it as stored, with defaults and generated keys.
  ///
  /// [only] keeps just those keys of [values]; [omit] drops those. Runs the
  /// model's create hooks. Use [createMany] for several rows.
  ///
  /// ```dart
  /// final post = await db.from('posts').create({'title': 'Hello'});
  /// print(post['id']);
  /// ```
  Future<Map<String, dynamic>> create(Map<String, dynamic> values, {List<String>? omit, List<String>? only}) async =>
      (await createMany([values], omit: omit, only: only)).first;

  /// Inserts several rows in one request and returns them.
  ///
  /// [only] and [omit] pick keys as in [create]; [returning] as in [returning].
  Future<PlexivoResult> createMany(List<Map<String, dynamic>> values, {List<String>? omit, List<String>? only, String? returning}) =>
      _insertRows(values.map((r) => _pick(r, omit, only)).toList(), returning: returning);

  /// Inserts [values] in requests of [size] rows and returns every inserted row.
  ///
  /// Each batch is its own request, so an error can leave earlier batches
  /// written.
  Future<PlexivoResult> createInBatches(List<Map<String, dynamic>> values, [int size = 100]) async {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < values.length; i += size) {
      out.addAll(await createMany(values.sublist(i, i + size > values.length ? values.length : i + size)));
    }
    return PlexivoResult(out);
  }

  Future<PlexivoResult> _insertRows(Object values, {String? returning}) {
    final list = (values is List ? values : [values]).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return _ctx.send(
      () async => _clean({'op': 'insert', 'into': table, 'values': await _ctx.beforeWrite('Create', list), 'returning': returning}),
      (r) async {
        final rows = _rows(r['data']);
        if (returning == 'minimal') return PlexivoResult([], (r['count'] as num?)?.toInt());
        await _ctx.afterWrite('Create', rows);
        return PlexivoResult(rows, (r['count'] as num?)?.toInt());
      },
      'rows',
    );
  }

  /// Supabase-style insert of one row (a map) or several (a list).
  ///
  /// Awaiting the returned builder runs it and returns the inserted rows;
  /// `insert(row).select().single()` returns one. Inside a transaction it is
  /// recorded at once.
  ///
  /// ```dart
  /// await db.from('notes').insert({'body': 'Hello from Flutter'});
  /// ```
  PlexivoQuery insert(Object values) {
    if (_ctx.deferred) {
      return _with({
        'write': {'kind': 'insert', 'values': values}
      })
        .._run = _insertRows(values, returning: _s['returning'] as String?);
    }
    return _with({
      'write': {'kind': 'insert', 'values': values}
    });
  }

  /// Inserts [values], or on conflict updates the existing row.
  ///
  /// [onConflict] is the unique column or columns (`'sku'`, `'a,b'` or a list),
  /// the primary key by default. On conflict, only the [update] columns are
  /// overwritten when given, otherwise every supplied column. With [ignore], the
  /// existing row is kept. Awaiting the builder runs it and returns the rows.
  ///
  /// ```dart
  /// await db.from('products').upsert({'sku': 'A1', 'price': 11}, onConflict: 'sku', update: ['price']);
  /// ```
  PlexivoQuery upsert(Object values, {Object? onConflict, List<String>? update, bool ignore = false}) {
    final options = {'onConflict': onConflict, 'update': update, 'ignore': ignore};
    final q = _with({
      'write': {'kind': 'upsert', 'values': values, 'options': options}
    });
    if (_ctx.deferred) q._run = _upsert(values, options);
    return q;
  }

  Future<PlexivoResult> _upsert(Object values, Map<String, dynamic> options) {
    final list = (values is List ? values : [values]).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final oc = options['onConflict'];
    final conflict = oc == null
        ? [_ctx.primaryKey]
        : oc is String
            ? oc.split(',').map((s) => s.trim()).toList()
            : (oc as List).cast<String>();
    return _ctx.send(
      () async => _clean({
        'op': 'insert',
        'into': table,
        'values': await _ctx.beforeWrite('Save', list),
        'on_conflict': conflict,
        'upsert': options['ignore'] == true ? 'ignore' : 'merge',
        'update_columns': options['update'],
      }),
      (r) async {
        final rows = _rows(r['data']);
        await _ctx.afterWrite('Save', rows);
        return PlexivoResult(rows, (r['count'] as num?)?.toInt());
      },
      'rows',
    );
  }

  /// GORM's Save: inserts [row] when it has no primary key, otherwise writes every column it carries.
  ///
  /// A row with a key is upserted on that key, so it is created if missing.
  Future<Map<String, dynamic>> save(Map<String, dynamic> row) async {
    final pk = _ctx.primaryKey;
    if (row[pk] == null) return create(row);
    return (await _upsert(row, {
      'onConflict': [pk]
    }))
        .first;
  }

  /// Updates the matching rows with [values]; awaiting the builder runs it and returns them.
  ///
  /// Filters may come before or after (`update({...}).eq('id', 7)`). A filter
  /// is required: without one it throws a [PlexivoException] with code
  /// `missing_where`, unless [allowGlobalUpdate] is set.
  ///
  /// ```dart
  /// await db.from('posts').where('id', 7).update({'title': 'New title'});
  /// ```
  PlexivoQuery update(Map<String, dynamic> values) {
    final q = _with({
      'write': {'kind': 'update', 'values': values}
    });
    if (_ctx.deferred) q._run = _update(values, returning: _s['returning'] as String?);
    return q;
  }

  /// Updates the row whose primary key is [id] and returns it.
  ///
  /// Throws a [RecordNotFoundException] when there is no such row.
  Future<Map<String, dynamic>> updateById(Object id, Map<String, dynamic> values) async {
    final rows = await where(_ctx.primaryKey, id)._update(values);
    if (rows.isEmpty) throw RecordNotFoundException(table);
    return rows.first;
  }

  Future<PlexivoResult> _update(Map<String, dynamic> values, {String? returning}) {
    final Map<String, dynamic> where;
    try {
      where = _writeWhere('update');
    } catch (e) {
      return Future.error(e);
    }
    return _write(
        () async => {
              'op': 'update',
              'table': table,
              'set': (await _ctx.beforeWrite('Update', [values])).first,
              'where': where,
              'returning': returning
            },
        'Update',
        returning);
  }

  /// Updates one [column] to [value]; the same as `update({column: value})`.
  PlexivoQuery updateColumn(String column, Object? value) => update({column: value});

  /// Adds [by] to [column] in the matching rows, atomically, and returns them.
  ///
  /// [extra] sets other columns in the same update. A filter is required, as
  /// for [update].
  ///
  /// ```dart
  /// await db.from('posts').where('id', 7).increment('views');
  /// await db.from('products').where('sku', 'A1').increment('stock', by: -2);
  /// ```
  Future<PlexivoResult> increment(String column, {num by = 1, Map<String, dynamic>? extra}) {
    final Map<String, dynamic> where;
    try {
      where = _writeWhere('update');
    } catch (e) {
      return Future.error(e);
    }
    return _write(
        () => {
              'op': 'update',
              'table': table,
              'set': extra == null || extra.isEmpty ? null : extra,
              'inc': {column: by},
              'where': where
            },
        'Update',
        null);
  }

  /// Subtracts [by] from [column] in the matching rows; see [increment].
  Future<PlexivoResult> decrement(String column, {num by = 1, Map<String, dynamic>? extra}) => increment(column, by: -by, extra: extra);

  /// Deletes the matching rows; awaiting the builder runs it and returns them.
  ///
  /// When the model has a soft-delete column, it is set to now instead (use
  /// [unscoped] or [forceDelete] to remove rows for good). A filter is
  /// required: without one it throws a [PlexivoException] with code
  /// `missing_where`, unless [allowGlobalUpdate] is set.
  ///
  /// ```dart
  /// await db.from('posts').where('id', 7).delete();
  /// ```
  PlexivoQuery delete() {
    final q = _with({
      'write': {'kind': 'delete'}
    });
    if (_ctx.deferred) q._run = _delete(returning: _s['returning'] as String?);
    return q;
  }

  /// Deletes the row whose primary key is [id] and returns it.
  ///
  /// Throws a [RecordNotFoundException] when there is no such row.
  Future<Map<String, dynamic>> deleteById(Object id) async {
    final rows = await where(_ctx.primaryKey, id)._delete();
    if (rows.isEmpty) throw RecordNotFoundException(table);
    return rows.first;
  }

  Future<PlexivoResult> _delete({String? returning}) {
    final Map<String, dynamic> where;
    try {
      where = _writeWhere('delete');
    } catch (e) {
      return Future.error(e);
    }
    final soft = _ctx.softDelete != null && _s['unscoped'] != true;
    return _write(() async {
      await _ctx.beforeWrite('Delete', [toQuery()]);
      return soft
          ? {
              'op': 'update',
              'table': table,
              'set': {_ctx.softDelete!: DateTime.now().toUtc().toIso8601String()},
              'where': where
            }
          : {'op': 'delete', 'from': table, 'where': where, 'returning': returning};
    }, 'Delete', returning);
  }

  /// Deletes the matching rows for good, even with soft deletes. A filter is required.
  Future<PlexivoResult> forceDelete() => unscoped()._delete();

  /// Brings back soft-deleted rows that match, by clearing their soft-delete column.
  ///
  /// Throws a [StateError] when the table has no soft-delete column.
  Future<PlexivoResult> restore() {
    final soft = _ctx.softDelete;
    if (soft == null) throw StateError('$table has no soft-delete column');
    return _write(
        () => {
              'op': 'update',
              'table': table,
              'set': {soft: null},
              'where': unscoped()._where()
            },
        'Update',
        null);
  }

  Future<PlexivoResult> _write(FutureOr<Map<String, dynamic>> Function() build, String hook, String? returning) => _ctx.send(
        () async => _clean(await build()),
        (r) async {
          if (returning == 'minimal') return PlexivoResult([], (r['count'] as num?)?.toInt());
          final rows = _rows(r['data']);
          await _ctx.afterWrite(hook, rows);
          return PlexivoResult(rows, (r['count'] as num?)?.toInt());
        },
        'rows',
      );

  /// The first row matching [attributes], or a new one created from [attributes] and [defaults].
  ///
  /// Not atomic: use [upsert] with a unique key when two clients may race.
  Future<Map<String, dynamic>> firstOrCreate(Map<String, dynamic> attributes, [Map<String, dynamic> defaults = const {}]) async =>
      await where(attributes).firstOrNull() ?? await create({...attributes, ...defaults});

  /// The first row matching [attributes], or an unsaved map of [attributes] and [defaults].
  Future<Map<String, dynamic>> firstOrInit(Map<String, dynamic> attributes, [Map<String, dynamic> defaults = const {}]) async =>
      await where(attributes).firstOrNull() ?? {...attributes, ...defaults};

  /// Updates rows matching [attributes] with [values] and returns the first, or creates one.
  ///
  /// Not atomic: use [upsert] with a unique key when two clients may race.
  Future<Map<String, dynamic>> updateOrCreate(Map<String, dynamic> attributes, [Map<String, dynamic> values = const {}]) async {
    final rows = await where(attributes)._update(values);
    return rows.isNotEmpty ? rows.first : await create({...attributes, ...values});
  }
}

/// What a transaction's recorded operation can hand to a later one.
abstract class RefSource {
  /// A reference to [path] in this operation's result; an empty path refers to the whole result.
  Map<String, dynamic> ref([String path = '']);
}

/// One page of rows with its totals, as [PlexivoQuery.paginate] returns it.
class PlexivoPage {
  /// Creates a page.
  PlexivoPage(this.data, this.total, this.page, this.perPage, this.totalPages);

  /// The rows on this page.
  final List<Map<String, dynamic>> data;

  /// The number of matching rows on every page.
  final int total;

  /// This page's number, from 1.
  final int page;

  /// The page size.
  final int perPage;

  /// The number of pages; at least 1.
  final int totalPages;
}

/// Related rows inside a query: their columns, filters, order, limits and own relations.
///
/// Callbacks of `preload`, `joins`, `whereHas` and `withCount` get one:
///
/// ```dart
/// db.from('posts').preload('comments', (PlexivoEmbed c) => c
///     .select('id, body')
///     .where('approved', true)
///     .order('created_at', 'desc')
///     .limit(3)
///     .preload('author'));
/// ```
class PlexivoEmbed {
  /// Creates an embed on a table context; the SDK does this for callbacks.
  PlexivoEmbed(this._ctx, [Map<String, dynamic>? state]) : _s = {'terms': <List<Object>>[], ...?state};
  final TableContext _ctx;
  final Map<String, dynamic> _s;

  /// The builder state the SDK compiles: filters, select, order and limits.
  Map<String, dynamic> get state => _s;
  PlexivoEmbed _with(Map<String, dynamic> patch) => PlexivoEmbed(_ctx, {..._s, ...patch});
  List<List<Object>> get _terms => (_s['terms'] as List).cast<List<Object>>();
  PlexivoEmbed _term(String joiner, Map<String, dynamic> node) => _with({
        'terms': [
          ..._terms,
          [joiner, node]
        ]
      });

  /// These filters as a tree, or null when there are none.
  Map<String, dynamic>? node() => _combine(_terms);

  /// Adds a filter, joined with AND; the same forms as [PlexivoQuery.where].
  PlexivoEmbed where(Object column, [Object? op = _absent, Object? value = _absent]) => _term('and', condition(column, op, value, _ctx));

  /// Adds a filter joined with OR; AND binds tighter, as in SQL.
  PlexivoEmbed orWhere(Object column, [Object? op = _absent, Object? value = _absent]) => _term('or', condition(column, op, value, _ctx));

  /// Adds a negated filter, `NOT (…)`, joined with AND.
  PlexivoEmbed whereNot(Object column, [Object? op = _absent, Object? value = _absent]) => _term('and', {'not': condition(column, op, value, _ctx)});

  /// Keeps related rows whose [column] is one of [values].
  PlexivoEmbed whereIn(String column, List<Object?> values) => where(column, 'in', values);

  /// Keeps related rows where [column] is null.
  PlexivoEmbed whereNull(String column) => where(column, 'is', null);

  /// Keeps related rows that themselves have a matching row through [relation].
  PlexivoEmbed whereHas(String relation, [Function? callback]) => _term('and', _ctx.has(relation, callback));

  /// Keeps related rows where [column] equals [value].
  PlexivoEmbed eq(String column, Object? value) => where(column, '=', value);

  /// Chooses the related rows' columns and nested embeds; see [PlexivoQuery.select].
  PlexivoEmbed select([Object? columns]) {
    final items = columns == null ? <Object>[] : _selectItems(columns is List ? columns.cast<Object>() : [columns]);
    final cols = items.where((x) => x is String || (x is Map && x.containsKey('column'))).toList();
    final embeds = items.whereType<Map<String, dynamic>>().where((x) => !x.containsKey('column')).toList();
    return _with({
      'select': [...((_s['select'] as List?) ?? const []), ...cols],
      'embeds': [...((_s['embeds'] as List?) ?? const []), ...embeds]
    });
  }

  /// Orders the related rows; see [PlexivoQuery.order].
  PlexivoEmbed order(Object column, [Object? dir, String? nulls]) => _with({
        'order': [...((_s['order'] as List?) ?? const []), _orderTerm(column, dir is String ? dir : null, dir is bool ? dir : null, nulls)]
      });

  /// Returns at most [n] related rows per row.
  PlexivoEmbed limit(int n) => _with({'limit': n});

  /// Skips the first [n] related rows per row.
  PlexivoEmbed offset(int n) => _with({'offset': n});

  /// Also returns the related rows' own [relation]; see [PlexivoQuery.preload].
  PlexivoEmbed preload(String relation, [Function? callback]) => _with({
        'embeds': [...((_s['embeds'] as List?) ?? const []), _ctx.embed(relation, callback, false)]
      });

  /// Keeps related rows with a matching row through [relation]; see [PlexivoQuery.joins].
  PlexivoEmbed joins(String relation, [Function? callback]) => _with({
        'embeds': [...((_s['embeds'] as List?) ?? const []), _ctx.embed(relation, callback, true)]
      });

  /// Adds the number of the related rows' own [relation] rows; see [PlexivoQuery.withCount].
  PlexivoEmbed withCount(String relation, [Function? callback, String? as]) => _with({
        'embeds': [
          ...((_s['embeds'] as List?) ?? const []),
          _ctx.aggregateEmbed(relation, callback, {'count': true}, as, true)
        ]
      });
}

Map<String, dynamic> _aggSpec(Map<String, dynamic> spec) => {
      if (spec['count'] == true) 'count': true,
      for (final k in const ['sum', 'avg', 'min', 'max'])
        if (spec[k] != null) k: spec[k] is List ? spec[k] : [spec[k]],
    };

num? _num(Object? v) => v == null ? null : (v is num ? v : num.tryParse(v.toString()));

List<Map<String, dynamic>> _rows(Object? data) => data is List ? data.map((e) => Map<String, dynamic>.from(e as Map)).toList() : <Map<String, dynamic>>[];

Map<String, dynamic> _pick(Map<String, dynamic> row, List<String>? omit, List<String>? only) {
  var out = Map<String, dynamic>.from(row);
  if (only != null) out.removeWhere((k, _) => !only.contains(k));
  if (omit != null) out.removeWhere((k, _) => omit.contains(k));
  return out;
}
