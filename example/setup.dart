// One-time setup, from your own machine: creates the example tables and
// their row-level security policies (example/schema.sql) with the
// project's SECRET key.
//
//   PLEXIVO_URL=https://… PLEXIVO_SECRET_KEY=… dart run example/setup.dart
//
// The secret key runs as the database owner and bypasses row-level
// security. It belongs on a server or your laptop — never in a Flutter app.
import 'dart:io';

import 'package:plexivo_client/plexivo_client.dart';

Future<void> main() async {
  final url = Platform.environment['PLEXIVO_URL'];
  final secretKey = Platform.environment['PLEXIVO_SECRET_KEY'];
  if (url == null || secretKey == null) {
    stderr.writeln('Set PLEXIVO_URL and PLEXIVO_SECRET_KEY (or run example/schema.sql in psql).');
    exit(2);
  }
  final server = PlexivoClient(url, secretKey);

  // schema.sql, one statement at a time (comments dropped).
  final sql = File.fromUri(Platform.script.resolve('schema.sql')).readAsStringSync();
  final statements = sql
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('--'))
      .join('\n')
      .split(RegExp(r';\s*$', multiLine: true))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  // All of them in one transaction: every statement commits, or none does.
  await server.sql.transaction(statements);
  print('Applied ${statements.length} statements.');
  print('todos exists: ${await server.migrator.hasTable('todos')}');
  exit(0);
}
