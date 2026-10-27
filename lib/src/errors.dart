/// The error every failed Plexivo call throws.
///
/// It carries what the Data API said: the HTTP [statusCode], a stable [code]
/// such as `missing_where`, `multiple_rows`, `record_not_found`,
/// `unique_violation`, `permission_denied` or `token_expired`, and a readable
/// [message]. When the database had more to say, [hint], [sqlstate] and
/// [details] are set too. Quote [traceId] to support.
///
/// ```dart
/// try {
///   await db.from('users').create({'email': 'asha@example.com'});
/// } on PlexivoException catch (e) {
///   if (e.isUniqueViolation) {
///     showMessage('That email is already registered.');
///   } else {
///     print('${e.code}: ${e.message} (trace ${e.traceId})');
///   }
/// }
/// ```
///
/// A few codes come from the SDK itself, before any request is sent:
/// `missing_where` (an update or delete without a filter), `multiple_rows`
/// (`single()` or `sole()` matched more than one row) and
/// `transaction_already_sent`. [RecordNotFoundException] is the subtype that
/// `first()`, `last()`, `take()`, `sole()` and `single()` throw when no row
/// matches, like GORM's `ErrRecordNotFound`.
class PlexivoException implements Exception {
  /// Creates an exception for a failed call.
  ///
  /// [message] defaults to [code]. The SDK builds these from Data API responses;
  /// apps rarely need to.
  PlexivoException(this.statusCode, this.code, {String? message, this.hint, this.sqlstate, this.traceId, this.details, this.operation})
      : message = message ?? code;

  /// The HTTP status of the failure, such as 400, 401, 403, 404 or 406.
  final int statusCode;

  /// The stable, machine-readable error code, such as `unique_violation`.
  ///
  /// It is `request_failed` when the response named no code, and
  /// `invalid_response` when a successful response was not JSON.
  final String code;

  /// A readable description of what went wrong.
  ///
  /// Falls back to [code] when the server sent no message.
  final String message;

  /// A suggestion for fixing the problem, or null when none was given.
  final String? hint;

  /// The five-character PostgreSQL SQLSTATE, such as `23505`.
  ///
  /// Null when the error did not come from the database.
  final String? sqlstate;

  /// The request's trace id to quote to support, or null if it had none.
  final String? traceId;

  /// Extra detail from the server, such as the failing constraint.
  ///
  /// Null when the server sent none.
  final Object? details;

  /// In a transaction, the 0-based index of the operation that failed.
  ///
  /// Null outside transactions, or when the server did not say.
  final int? operation;

  /// The same as [statusCode], for code written against Supabase's `status`.
  int get status => statusCode;

  /// Whether no row or resource matched (`record_not_found` or `not_found`).
  bool get isNotFound => code == 'record_not_found' || code == 'not_found';

  /// Whether a unique constraint rejected the write (`unique_violation`).
  bool get isUniqueViolation => code == 'unique_violation';

  /// Whether the request was refused (`permission_denied`, or HTTP 403).
  ///
  /// Row-level security, missing grants or the wrong key can all cause it.
  bool get isPermissionDenied => code == 'permission_denied' || statusCode == 403;

  @override
  String toString() => 'PlexivoException($statusCode, $code: $message${traceId == null ? '' : ', traceId: $traceId'})';
}

/// Thrown when a read that needs a row finds none.
///
/// `first()`, `last()`, `take()`, `sole()`, `single()`, `updateById()` and
/// `deleteById()` throw it. Its [code] is `record_not_found` and its
/// [statusCode] 404. Use `firstOrNull()` or `maybeSingle()` to get null instead.
class RecordNotFoundException extends PlexivoException {
  /// Creates the exception for a read on [table] that matched no row.
  RecordNotFoundException(this.table) : super(404, 'record_not_found', message: 'record not found in $table');

  /// The table that had no matching row.
  final String table;
}
