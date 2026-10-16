/// Errors the SDK throws. Every API failure is a [PlexivoException] carrying
/// what the Data API said (code, message, hint, SQLSTATE) and the trace id to
/// quote to support. [RecordNotFoundException] is what `first()`, `last()`
/// and `take()` throw when no row matches, like GORM's ErrRecordNotFound.
class PlexivoException implements Exception {
  PlexivoException(this.statusCode, this.code, {String? message, this.hint, this.sqlstate, this.traceId, this.details, this.operation})
      : message = message ?? code;

  final int statusCode;
  final String code;
  final String message;
  final String? hint;
  final String? sqlstate;
  final String? traceId;
  final Object? details;

  /// In a transaction, which operation failed (0-based).
  final int? operation;

  int get status => statusCode;

  bool get isNotFound => code == 'record_not_found' || code == 'not_found';
  bool get isUniqueViolation => code == 'unique_violation';
  bool get isPermissionDenied => code == 'permission_denied' || statusCode == 403;

  @override
  String toString() => 'PlexivoException($statusCode, $code: $message${traceId == null ? '' : ', traceId: $traceId'})';
}

class RecordNotFoundException extends PlexivoException {
  RecordNotFoundException(this.table) : super(404, 'record_not_found', message: 'record not found in $table');
  final String table;
}
