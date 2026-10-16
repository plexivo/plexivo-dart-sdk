import 'dart:collection';

/// Rows that read both ways: a list (`rows[0]`, `rows.length`, `for … in`)
/// that also carries [data] (itself) and [count], as Supabase returns them.
class PlexivoResult extends ListBase<Map<String, dynamic>> {
  PlexivoResult(List<Map<String, dynamic>> rows, [int? count])
      : _rows = rows,
        count = count ?? rows.length;

  final List<Map<String, dynamic>> _rows;

  /// The total from `count: true` / `select(count: 'exact')`, else the rows read.
  int? count;

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

/// One row as `{data}`: what `single()` and `maybeSingle()` return.
class PlexivoSingle {
  PlexivoSingle(this.data, [this.count]);
  final Map<String, dynamic>? data;
  final int? count;
}
