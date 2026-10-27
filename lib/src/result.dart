import 'dart:collection';

/// Rows from a query, readable both as a list and Supabase-style.
///
/// It is a `List<Map<String, dynamic>>` (`rows[0]`, `rows.length`,
/// `for (final row in rows)`) that also carries [data] (itself) and [count].
///
/// ```dart
/// final notes = await db.from('notes').select('id, body', 'exact').limit(10);
/// print(notes.length); // rows in this page
/// print(notes.count);  // every matching row
/// ```
class PlexivoResult extends ListBase<Map<String, dynamic>> {
  /// Wraps [rows]; [count] defaults to the number of rows.
  PlexivoResult(List<Map<String, dynamic>> rows, [int? count])
      : _rows = rows,
        count = count ?? rows.length;

  final List<Map<String, dynamic>> _rows;

  /// The total number of matching rows, or the number of rows read.
  ///
  /// When the query asked for a count (`select(columns, 'exact')`), this is the
  /// total across every page; otherwise it is the number of rows returned. The
  /// SDK always sets it; it is nullable for Supabase compatibility.
  int? count;

  /// These same rows, for code written as `result.data`.
  List<Map<String, dynamic>> get data => this;

  @override
  int get length => _rows.length;
  @override
  set length(int n) => _rows.length = n;
  @override
  Map<String, dynamic> operator [](int i) => _rows[i];
  @override
  void operator []=(int i, Map<String, dynamic> v) => _rows[i] = v;
  @override
  void add(Map<String, dynamic> element) => _rows.add(element);
}

/// One row, as `single()` and `maybeSingle()` return it.
///
/// Read the row from [data]:
///
/// ```dart
/// final res = await db.from('notes').select().eq('id', 1).maybeSingle();
/// final note = res.data; // null when no row matched
/// ```
class PlexivoSingle {
  /// Wraps one row, [data], and an optional [count].
  PlexivoSingle(this.data, [this.count]);

  /// The row, or null when `maybeSingle()` found none.
  final Map<String, dynamic>? data;

  /// How many rows were read: 1, or 0 when [data] is null.
  ///
  /// It is the total matching rows when the query asked for a count, and null
  /// only when built without one.
  final int? count;
}
